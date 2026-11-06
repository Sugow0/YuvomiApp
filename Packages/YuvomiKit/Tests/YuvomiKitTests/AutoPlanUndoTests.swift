import Foundation
import Testing
@testable import YuvomiKit

@Test func theLastRunIsRememberedAndForgotten() throws {
    let defaults = try #require(UserDefaults(suiteName: "test.autoplan.\(UUID().uuidString)"))
    let settings = AutoPlanSettings(defaults: defaults)
    #expect(settings.lastRun == nil)
    settings.lastRun = AutoPlanRun(mealIDs: [4, 5], firstDay: "2026-11-09", lastDay: "2026-11-15", listID: 2)
    settings.lastPeriodID = "2026-W46"
    #expect(AutoPlanSettings(defaults: defaults).lastRun?.mealIDs == [4, 5])
    settings.forgetLastRun()
    #expect(settings.lastRun == nil)
    #expect(settings.lastPeriodID == nil)
}

@Test func undoingTakesOffEachCookingOnceNotItsLeftovers() {
    let curry = Recipe(id: 1, title: "Curry", mealTypes: [.lunch, .dinner], servings: 4,
                       ingredients: [RecipeIngredient(name: "Riz", quantity: "300 g", category: nil)])
    let omelette = Recipe(id: 2, title: "Omelette", mealTypes: [.lunch, .dinner], servings: 2,
                          ingredients: [RecipeIngredient(name: "Œufs", quantity: "3", category: nil)])
    let meals = [
        Meal(id: 10, date: "2026-11-09", kind: .lunch, title: "Curry", recipeID: 1),
        Meal(id: 11, date: "2026-11-10", kind: .lunch, title: "Curry · restes", recipeID: 1),
        Meal(id: 12, date: "2026-11-09", kind: .dinner, title: "Omelette", recipeID: 2),
        Meal(id: 13, date: "2026-11-10", kind: .dinner, title: "Pizza du vendredi"), // no recipe
    ]
    let back = AutoPlanRun.shopping(of: meals, recipes: [curry, omelette], people: 2)
    // Curry once (4 portions, 2 meals), the omelette doubled (2 portions for 2 people over 2 meals).
    #expect(ShoppingTotals.combine(back).map(\.quantity) == ["300 g", "6"])
}
