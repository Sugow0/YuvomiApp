import Foundation
import Testing
@testable import YuvomiKit

private func recipe(_ id: Int, slug: String?, kinds: [Meal.Kind] = Meal.Kind.allCases) -> Recipe {
    Recipe(id: id, title: "R\(id)", mealTypes: kinds, providerSlug: slug)
}

@Test func mealieCategoriesDecideTheRole() {
    let recipes = [
        recipe(1, slug: "curry"), recipe(2, slug: "brownie"), recipe(3, slug: "pancakes"),
        recipe(4, slug: "sans-categorie"), recipe(5, slug: "chili"),
        recipe(6, slug: nil), recipe(7, slug: nil), // typed in Yuvomi itself
    ]
    let categories = ["curry": ["Plat"], "brownie": ["Dessert"], "pancakes": ["Petit-déj"], "chili": ["plat"]]
    let roles = RecipeRoles(recipes: recipes, mealieCategories: categories, excluded: [5], localDesserts: [7])
    #expect(roles.dishes.map(\.id) == [1, 6])   // 5 is excluded on the device, 3 and 4 are no dish
    #expect(roles.desserts.map(\.id) == [2, 7])
}

@Test func withoutMealieTheDeviceSettingsDecide() {
    let recipes = [recipe(1, slug: "curry"), recipe(2, slug: "brownie"), recipe(3, slug: nil, kinds: [.breakfast])]
    let roles = RecipeRoles(recipes: recipes, mealieCategories: nil, excluded: [], localDesserts: [2])
    #expect(roles.dishes.map(\.id) == [1])
    #expect(roles.desserts.map(\.id) == [2])
}

extension StubbedNetwork { @Suite struct MealieTests {
    let client = MealieClient(config: MealieConfig(server: ServerURL("https://mealie.example.com")!, token: "tok"),
                              session: StubProtocol.session())

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func categoriesAreReadBySlugWithTheToken() async throws {
        StubProtocol.routes = ["GET /api/recipes": (200, """
            {"page":1,"per_page":1000,"total":2,"total_pages":1,
             "items":[{"slug":"curry","name":"Curry","recipeCategory":[{"id":"c1","name":"Plat","slug":"plat"}]},
                      {"slug":"brownie","name":"Brownie","recipeCategory":[]}]}
            """)]
        let categories = try await client.categoriesBySlug()
        #expect(categories == ["curry": ["Plat"], "brownie": []])
        let request = try #require(StubProtocol.seen.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func aRejectedTokenSaysSo() async throws {
        StubProtocol.routes = ["GET /api/recipes": (401, #"{"detail":"Unauthorized"}"#)]
        await #expect(throws: MealieError.rejectedToken) { try await client.categoriesBySlug() }
    }

    @Test func recipesKeepTheirMealieSlug() async throws {
        StubProtocol.routes = ["GET /api/v1/recipes": (200, """
            {"data":[{"id":3,"title":"Curry","provider_slug":"curry","provider_type":"mealie","servings":4,"ingredients":[]}]}
            """)]
        let yuvomi = YuvomiClient(
            credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
            session: StubProtocol.session()
        )
        let recipes = try await yuvomi.recipes()
        #expect(recipes.first?.providerSlug == "curry")
        #expect(recipes.first?.servings == 4)
    }
}
}
