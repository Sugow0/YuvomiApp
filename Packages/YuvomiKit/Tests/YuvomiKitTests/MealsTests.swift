import Foundation
import Testing
@testable import YuvomiKit

@Test func weekListsSevenDaysAndOrdersMealsByKind() {
    let week = MealWeek(start: "2026-11-02", end: "2026-11-08", meals: [
        Meal(id: 2, date: "2026-11-05", kind: .dinner, title: "Soupe"),
        Meal(id: 1, date: "2026-11-05", kind: .lunch, title: "Salade",
             ingredients: [.init(id: 1, name: "Laitue"), .init(id: 2, name: "Tomates", onShoppingList: true)]),
    ])
    #expect(week.days.count == 7)
    #expect(week.days.first == "2026-11-02")
    #expect(week.days.last == "2026-11-08")
    #expect(week.meals(on: "2026-11-05").map(\.title) == ["Salade", "Soupe"])
    #expect(week.pendingIngredients == 1)
}

extension StubbedNetwork { @Suite struct MealsTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func weekDecodesCamelCaseBoundsAndFlags() async throws {
        StubProtocol.routes = ["GET /api/v1/meals": (200, """
            {"data":[{"id":7,"date":"2026-11-05","meal_type":"dinner","title":"Lasagnes","notes":null,
                      "recurrence_template_id":3,"cook_name":"Sam","recipe_ingredient_count":0,
                      "ingredients":[{"id":1,"meal_id":7,"name":"Pâtes","quantity":"500 g","on_shopping_list":1}]}],
             "weekStart":"2026-11-02","weekEnd":"2026-11-08"}
            """)]
        let week = try await client.mealWeek(containing: "2026-11-05")
        #expect(week.start == "2026-11-02")
        #expect(week.meals.first?.isRecurring == true)
        #expect(week.meals.first?.ingredients.first?.onShoppingList == true)
        #expect(StubProtocol.seen.first?.url?.query() == "week=2026-11-05")
    }

    @Test func transferSendsListIdInCamelCase() async throws {
        StubProtocol.routes = ["POST /api/v1/meals/7/to-shopping-list": (200,
            #"{"data":{"transferred":2,"skipped":1,"added_ids":[4,5],"ingredient_ids":[1,2]}}"#)]
        let result = try await client.sendMealToShopping(7, listID: 3)
        #expect(result == ShoppingTransfer(transferred: 2, skipped: 1))
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Int])
        #expect(json == ["listId": 3])
    }

    @Test func createSendsSnakeCaseMealType() async throws {
        StubProtocol.routes = ["POST /api/v1/meals": (201,
            #"{"data":{"id":9,"date":"2026-11-06","meal_type":"lunch","title":"Quiche","ingredients":[]}}"#)]
        _ = try await client.createMeal(date: "2026-11-06", kind: .lunch, title: "Quiche",
                                        ingredients: ShoppingEntry.parse("3 œufs et de la crème"))
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["meal_type"] as? String == "lunch")
        #expect((json["ingredients"] as? [[String: Any]])?.count == 2)
    }
}
}
