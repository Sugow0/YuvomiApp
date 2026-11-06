import Foundation
import Testing
@testable import YuvomiKit

private func dish(_ id: Int, servings: Int? = 6) -> Recipe {
    Recipe(id: id, title: "Plat \(id)", mealTypes: [.lunch, .dinner], servings: servings,
           ingredients: [RecipeIngredient(name: "Riz", quantity: "300 g", category: nil)])
}

private func dessert(_ id: Int, servings: Int? = 8) -> Recipe {
    Recipe(id: id, title: "Dessert \(id)", mealTypes: [.snack], servings: servings)
}

private let week = (9...15).map { String(format: "2026-11-%02d", $0) }

@Test func portionsSayHowManyMealsOneCookingCovers() {
    let range = 2...4
    #expect(BatchPlanner.coverage(servings: 8, people: 2, meals: range) == .init(meals: 4, factor: 1))
    #expect(BatchPlanner.coverage(servings: 6, people: 2, meals: range) == .init(meals: 3, factor: 1))
    #expect(BatchPlanner.coverage(servings: 12, people: 2, meals: range) == .init(meals: 4, factor: 1))
    #expect(BatchPlanner.coverage(servings: 8, people: 4, meals: range) == .init(meals: 2, factor: 1))
    // Too small for two meals: cook it twice as big.
    #expect(BatchPlanner.coverage(servings: 2, people: 2, meals: range) == .init(meals: 2, factor: 2))
    #expect(BatchPlanner.coverage(servings: 6, people: 4, meals: range) == .init(meals: 3, factor: 2))
    // No portions on the recipe: count it as four.
    #expect(BatchPlanner.coverage(servings: nil, people: 2, meals: range) == .init(meals: 2, factor: 1))
}

@Test func aWeekIsAFewBigCookingsEatenInTurns() throws {
    var rng = SeededGenerator(state: 5)
    let batches = BatchPlanner.plan(days: week, dishes: (1...10).map { dish($0) }, desserts: [],
                                    options: .init(people: 2), using: &rng)
    let meals = batches.flatMap(\.meals)

    // 14 slots, 3 meals per cooking: 3 cookings for lunch, 3 for dinner.
    #expect(meals.count == 14)
    #expect(batches.count == 6)
    #expect(Set(batches.map(\.recipe.id)).count == 6)
    for day in week {
        let lunch = meals.first { $0.date == day && $0.kind == .lunch }
        let dinner = meals.first { $0.date == day && $0.kind == .dinner }
        #expect(lunch != nil && dinner != nil)
        #expect(lunch?.recipe.id != dinner?.recipe.id) // never the same dish twice in a row
    }
    for batch in batches {
        #expect(batch.meals.first?.isLeftover == false)
        #expect(batch.meals.dropFirst().allSatisfy { $0.isLeftover })
        #expect(batch.meals.allSatisfy { $0.kind == batch.meals[0].kind })
    }
    #expect(meals.filter { !$0.isLeftover }.count == 6)
    let leftover = try #require(meals.first { $0.isLeftover })
    #expect(leftover.title == "Plat \(leftover.recipe.id) · restes")
}

@Test func dessertsComeAsOftenAsAsked() {
    var rng = SeededGenerator(state: 8)
    let batches = BatchPlanner.plan(days: week, dishes: [dish(1), dish(2)], desserts: (20...24).map { dessert($0) },
                                    options: .init(people: 2, dessertsPerWeek: 3), using: &rng)
    let desserts = batches.filter { $0.meals.first?.kind == .snack }
    #expect(desserts.count == 3)
    #expect(desserts.map { $0.meals[0].date } == ["2026-11-09", "2026-11-11", "2026-11-13"])
    // 8 portions for 2 last up to 3 days, but never into the next dessert's day.
    #expect(desserts.map(\.meals.count) == [2, 2, 3])
}

@Test func noDessertWhenNoneAsked() {
    var rng = SeededGenerator(state: 8)
    let batches = BatchPlanner.plan(days: week, dishes: [dish(1), dish(2)], desserts: [dessert(20)],
                                    options: .init(people: 2, dessertsPerWeek: 0), using: &rng)
    #expect(!batches.contains { $0.meals.first?.kind == .snack })
}

@Test func lateEatenRecipesComeBackLast() {
    var rng = SeededGenerator(state: 2)
    let dishes = (1...4).map { dish($0) }
    let batches = BatchPlanner.plan(days: Array(week.prefix(3)), dishes: dishes, desserts: [],
                                    options: .init(people: 2), history: [1, 2], using: &rng)
    #expect(Set(batches.map(\.recipe.id)) == [3, 4])
}

@Test func ingredientsAreBoughtOncePerCookingAndScaled() {
    var rng = SeededGenerator(state: 1)
    let small = Recipe(id: 1, title: "Omelette", mealTypes: [.lunch, .dinner], servings: 2,
                       ingredients: [RecipeIngredient(name: "Œufs", quantity: "3", category: nil)])
    let batches = BatchPlanner.plan(days: ["2026-11-09", "2026-11-10"], dishes: [small], desserts: [],
                                    options: .init(people: 2), using: &rng)
    // Lunch and dinner each cook it once, twice as big (2 portions for 2 people over 2 meals).
    #expect(batches.count == 2)
    #expect(ShoppingTotals.combine(batches.flatMap(\.shopping)).map(\.quantity) == ["12"])
}

@Test func scalingKeepsWordsAndConvertsUnits() {
    #expect(ShoppingTotals.scaled("300 g", by: 2) == "600 g")
    #expect(ShoppingTotals.scaled("750 g", by: 2) == "1,5 kg")
    #expect(ShoppingTotals.scaled("1/2 citron", by: 3) == "1,5 citron")
    #expect(ShoppingTotals.scaled("au goût", by: 2) == "au goût")
    #expect(ShoppingTotals.scaled(nil, by: 2) == nil)
    #expect(ShoppingTotals.scaled("3", by: 1) == "3")
}
