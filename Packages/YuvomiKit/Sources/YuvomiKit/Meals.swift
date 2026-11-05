import Foundation

// MARK: - Models (server/routes/meals.js)

public struct Meal: Sendable, Hashable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Codable, CaseIterable, Identifiable {
        case breakfast, lunch, dinner, snack
        public var id: Self { self }
        public var label: String {
            switch self {
            case .breakfast: "Petit-déjeuner"
            case .lunch: "Déjeuner"
            case .dinner: "Dîner"
            case .snack: "Goûter"
            }
        }
        public var symbol: String {
            switch self {
            case .breakfast: "cup.and.saucer"
            case .lunch: "sun.max"
            case .dinner: "moon.stars"
            case .snack: "carrot"
            }
        }
    }

    public struct Ingredient: Sendable, Hashable, Identifiable, Decodable {
        public let id: Int
        public let name: String
        public let quantity: String?
        public var onShoppingList: Bool

        enum CodingKeys: String, CodingKey { case id, name, quantity, onShoppingList }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            quantity = try c.decodeIfPresent(String.self, forKey: .quantity)
            onShoppingList = ((try? c.decode(Int.self, forKey: .onShoppingList)) ?? 0) != 0
                || ((try? c.decode(Bool.self, forKey: .onShoppingList)) ?? false)
        }

        public init(id: Int, name: String, quantity: String? = nil, onShoppingList: Bool = false) {
            self.id = id; self.name = name; self.quantity = quantity; self.onShoppingList = onShoppingList
        }
    }

    public let id: Int
    /// `YYYY-MM-DD`.
    public let date: String
    public let kind: Kind
    public let title: String
    public let notes: String?
    public let cookName: String?
    public let cookColor: String?
    public let recipeURL: String?
    public let isRecurring: Bool
    public var ingredients: [Ingredient]
    /// Ingredients still held by a linked recipe (copied over on transfer).
    public let recipeIngredientCount: Int

    enum CodingKeys: String, CodingKey {
        case id, date, mealType, title, notes, cookName, cookColor, recipeUrl, recurrenceTemplateId
        case ingredients, recipeIngredientCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        kind = (try? c.decode(Kind.self, forKey: .mealType)) ?? .dinner
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        cookName = try? c.decodeIfPresent(String.self, forKey: .cookName)
        cookColor = try? c.decodeIfPresent(String.self, forKey: .cookColor)
        recipeURL = try? c.decodeIfPresent(String.self, forKey: .recipeUrl)
        isRecurring = (try? c.decodeIfPresent(Int.self, forKey: .recurrenceTemplateId)) != nil
        ingredients = (try? c.decodeIfPresent([Ingredient].self, forKey: .ingredients)) ?? []
        recipeIngredientCount = (try? c.decodeIfPresent(Int.self, forKey: .recipeIngredientCount)) ?? 0
    }

    public init(id: Int, date: String, kind: Kind, title: String, ingredients: [Ingredient] = []) {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.ingredients = ingredients
        notes = nil; cookName = nil; cookColor = nil; recipeURL = nil; isRecurring = false; recipeIngredientCount = 0
    }

    /// Ingredients not yet sent to a shopping list (recipe ones count as pending).
    public var pendingIngredients: Int {
        ingredients.filter { !$0.onShoppingList }.count + (ingredients.isEmpty ? recipeIngredientCount : 0)
    }
}

/// One week of the household plan; the server decides which day a week starts on.
public struct MealWeek: Sendable, Equatable {
    public let start: String
    public let end: String
    public var meals: [Meal]

    /// The seven `YYYY-MM-DD` keys from `start` to `end`.
    public var days: [String] {
        guard let first = Self.date(start) else { return [] }
        return (0..<7).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: first).map { TodayBuckets.dayKey($0) }
        }.filter { $0 <= end }
    }

    public func meals(on day: String) -> [Meal] {
        meals.filter { $0.date == day }.sorted {
            (Meal.Kind.allCases.firstIndex(of: $0.kind)!, $0.id) < (Meal.Kind.allCases.firstIndex(of: $1.kind)!, $1.id)
        }
    }

    public var pendingIngredients: Int { meals.reduce(0) { $0 + $1.pendingIngredients } }

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

public struct ShoppingTransfer: Sendable, Decodable, Equatable {
    public let transferred: Int
    public let skipped: Int
}

// MARK: - Endpoints

extension YuvomiClient {
    /// The week containing `day` (`YYYY-MM-DD`), or the current one.
    public func mealWeek(containing day: String? = nil) async throws -> MealWeek {
        struct Response: Decodable { let data: [Meal]; let weekStart: String; let weekEnd: String }
        // `weekStart`/`weekEnd` are camelCase on the wire; the snake_case decoder leaves them alone.
        let r = try await http.send(
            "GET", "api/v1/meals", query: day.map { [URLQueryItem(name: "week", value: $0)] } ?? [],
            as: Response.self
        )
        return MealWeek(start: r.weekStart, end: r.weekEnd, meals: r.data)
    }

    public func createMeal(date: String, kind: Meal.Kind, title: String, ingredients: [ShoppingEntry]) async throws -> Meal {
        struct Item: Encodable, Sendable { let name: String; let quantity: String? }
        struct Body: Encodable, Sendable { let date: String; let mealType: Meal.Kind; let title: String; let ingredients: [Item] }
        return try await http.send(
            "POST", "api/v1/meals",
            body: Body(date: date, mealType: kind, title: title,
                       ingredients: ingredients.map { Item(name: $0.name, quantity: $0.quantity) }),
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<Meal>.self
        ).data
    }

    public func deleteMeal(_ id: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/meals/\(id)", as: Empty.self)
    }

    public func addIngredient(to mealID: Int, _ entry: ShoppingEntry) async throws -> Meal.Ingredient {
        struct Body: Encodable, Sendable { let name: String; let quantity: String? }
        return try await http.send(
            "POST", "api/v1/meals/\(mealID)/ingredients", body: Body(name: entry.name, quantity: entry.quantity),
            as: DataEnvelope<Meal.Ingredient>.self
        ).data
    }

    public func deleteIngredient(_ id: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/meals/ingredients/\(id)", as: Empty.self)
    }

    /// Sends what is not on a list yet; names already open on the list are skipped.
    public func sendMealToShopping(_ mealID: Int, listID: Int) async throws -> ShoppingTransfer {
        struct Body: Encodable, Sendable, VerbatimKeys { let listId: Int }
        return try await http.send(
            "POST", "api/v1/meals/\(mealID)/to-shopping-list", body: Body(listId: listID),
            as: DataEnvelope<ShoppingTransfer>.self
        ).data
    }

    public func sendWeekToShopping(containing day: String, listID: Int) async throws -> ShoppingTransfer {
        struct Body: Encodable, Sendable, VerbatimKeys { let listId: Int; let week: String }
        return try await http.send(
            "POST", "api/v1/meals/week-to-shopping-list", body: Body(listId: listID, week: day),
            as: DataEnvelope<ShoppingTransfer>.self
        ).data
    }
}
