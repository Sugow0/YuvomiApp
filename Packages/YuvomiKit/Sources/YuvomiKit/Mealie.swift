import Foundation

// Mealie's own API, only to read recipe categories: Yuvomi's sync mirrors the recipes but not
// their categories, and the household sorts its recipes there ("Plat", "Dessert", "Petit-déj").

public struct MealieConfig: Sendable, Codable, Equatable {
    public var server: ServerURL
    public var token: String

    public init(server: ServerURL, token: String) { self.server = server; self.token = token }
}

/// Keeps the configuration in the shared keychain (it holds the API token).
public enum MealieStore {
    private static let account = "mealie"

    public static func load() -> MealieConfig? {
        guard let data = try? AppGroup.credentialStore().secret(account) else { return nil }
        return try? JSONDecoder().decode(MealieConfig.self, from: data)
    }

    public static func save(_ config: MealieConfig) throws {
        try AppGroup.credentialStore().setSecret(account, JSONEncoder().encode(config))
    }

    public static func clear() {
        try? AppGroup.credentialStore().removeSecret(account)
    }
}

public enum MealieError: Error, Sendable, Equatable, LocalizedError {
    case rejectedToken
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .rejectedToken: "Jeton Mealie refusé. Créez-en un dans Mealie → Profil → Jetons d'API."
        case .server(let status): "Mealie a répondu \(status)."
        }
    }
}

public struct MealieClient: Sendable {
    private let http: HTTP

    public init(config: MealieConfig, session: URLSession = YuvomiClient.session) {
        http = HTTP(server: config.server, session: session, bearer: config.token)
    }

    /// Category names of every recipe, by slug.
    public func categoriesBySlug() async throws -> [String: [String]] {
        struct Category: Decodable { let name: String }
        struct Item: Decodable { let slug: String; let recipeCategory: [Category]? }
        struct Page: Decodable { let items: [Item]; let totalPages: Int? }
        var result: [String: [String]] = [:]
        var page = 1
        while true {
            let response: Page
            do {
                response = try await http.send(
                    "GET", "api/recipes",
                    query: [URLQueryItem(name: "perPage", value: "1000"), URLQueryItem(name: "page", value: "\(page)")],
                    as: Page.self
                )
            } catch ClientError.unexpectedStatus(let status) {
                throw status == 401 || status == 403 ? MealieError.rejectedToken : MealieError.server(status)
            } catch let error as APIError {
                throw error.code == 401 || error.code == 403 ? MealieError.rejectedToken : MealieError.server(error.code)
            }
            for item in response.items { result[item.slug] = (item.recipeCategory ?? []).map(\.name) }
            guard page < (response.totalPages ?? 1) else { return result }
            page += 1
        }
    }
}

/// Which recipes the automatic plan uses as dishes (lunch and dinner) and as desserts.
///
/// A recipe from Mealie follows its Mealie category: "Plat" is a dish, "Dessert" a dessert,
/// anything else (Petit-déj, none) stays out. Without Mealie, and for recipes typed in Yuvomi,
/// the device's own setting decides. A recipe excluded on the device always stays out.
public struct RecipeRoles: Sendable {
    public static let dishCategory = "plat"
    public static let dessertCategory = "dessert"

    public let dishes: [Recipe]
    public let desserts: [Recipe]

    public init(recipes: [Recipe], mealieCategories: [String: [String]]?, excluded: Set<Int>, localDesserts: Set<Int>) {
        var dishes: [Recipe] = []
        var desserts: [Recipe] = []
        for recipe in recipes where !excluded.contains(recipe.id) {
            if let mealieCategories, let slug = recipe.providerSlug {
                let names = Set((mealieCategories[slug] ?? []).map { $0.lowercased() })
                if names.contains(Self.dishCategory) { dishes.append(recipe) }
                else if names.contains(Self.dessertCategory) { desserts.append(recipe) }
            } else if localDesserts.contains(recipe.id) {
                desserts.append(recipe)
            } else if !Set(recipe.mealTypes).isDisjoint(with: [.lunch, .dinner]) {
                dishes.append(recipe)
            }
        }
        self.dishes = dishes
        self.desserts = desserts
    }
}

extension RecipeRoles {
    /// Roles from Mealie when it is connected, else from the device. A Mealie that cannot be
    /// reached fails the call: planning without its categories would put desserts at dinner.
    public static func load(for recipes: [Recipe], settings: AutoPlanSettings = AutoPlanSettings(),
                            mealie: MealieConfig? = MealieStore.load()) async throws -> RecipeRoles {
        var categories: [String: [String]]?
        if let mealie { categories = try await MealieClient(config: mealie).categoriesBySlug() }
        return RecipeRoles(recipes: recipes, mealieCategories: categories,
                           excluded: settings.excludedRecipeIDs, localDesserts: settings.dessertRecipeIDs)
    }
}
