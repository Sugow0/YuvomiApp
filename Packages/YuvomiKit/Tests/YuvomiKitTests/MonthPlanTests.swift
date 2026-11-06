import Foundation
import Testing
@testable import YuvomiKit

/// Same seed, same plan: lets the tests pin a random draw.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func recipe(_ id: Int, _ kinds: [Meal.Kind] = [.lunch, .dinner]) -> Recipe {
    Recipe(id: id, title: "R\(id)", mealTypes: kinds)
}

@Test func remainingDaysRunFromTodayToTheEndOfTheMonth() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
    let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
    let days = MonthPlanner.remainingDays(of: first, calendar: calendar)
    #expect(days.count == 31)
    #expect(days.first == "2026-12-01")
    #expect(days.last == "2026-12-31")

    let late = try #require(calendar.date(from: DateComponents(year: 2027, month: 2, day: 27, hour: 23)))
    #expect(MonthPlanner.remainingDays(of: late, calendar: calendar) == ["2027-02-27", "2027-02-28"])
}

@Test func spansCoverAWeekAHalfMonthOrTheRestOfTheMonth() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
    func on(_ day: Int, _ month: Int = 12) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
    }

    let week = MonthPlanner.days(.week, from: try on(28), calendar: calendar)
    #expect(week == ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"])

    let firstHalf = MonthPlanner.days(.halfMonth, from: try on(1), calendar: calendar)
    #expect(firstHalf.first == "2026-12-01")
    #expect(firstHalf.last == "2026-12-15")
    let secondHalf = MonthPlanner.days(.halfMonth, from: try on(16), calendar: calendar)
    #expect(secondHalf.first == "2026-12-16")
    #expect(secondHalf.last == "2026-12-31")
    let lateStart = MonthPlanner.days(.halfMonth, from: try on(10, 2), calendar: calendar)
    #expect(lateStart == (10...15).map { "2026-02-\($0)" })

    #expect(MonthPlanner.days(.month, from: try on(20, 11), calendar: calendar).count == 11)
}

@Test func planFillsEverySlotWithARecipeMeantForIt() {
    var rng = SeededGenerator(state: 1)
    let recipes = [recipe(1, [.lunch]), recipe(2, [.dinner]), recipe(3), recipe(4, [.breakfast]), recipe(5, [])]
    let days = ["2026-12-01", "2026-12-02", "2026-12-03"]
    let plan = MonthPlanner.plan(days: days, kinds: [.lunch, .dinner], recipes: recipes, using: &rng)

    #expect(plan.count == 6)
    #expect(plan.map(\.date) == ["2026-12-01", "2026-12-01", "2026-12-02", "2026-12-02", "2026-12-03", "2026-12-03"])
    #expect(plan.map(\.kind) == [.lunch, .dinner, .lunch, .dinner, .lunch, .dinner])
    for meal in plan { #expect(meal.recipe.mealTypes.contains(meal.kind)) }
    // A recipe with no meal type, or only breakfast, stays out of the automatic plan.
    #expect(!plan.contains { [4, 5].contains($0.recipe.id) })
}

@Test func planSpreadsRecipesAndNeverRepeatsBackToBack() {
    var rng = SeededGenerator(state: 42)
    let recipes = (1...10).map { recipe($0) }
    let days = (1...30).map { String(format: "2026-11-%02d", $0) }
    let plan = MonthPlanner.plan(days: days, kinds: [.lunch, .dinner], recipes: recipes, using: &rng)

    #expect(plan.count == 60)
    let uses = Dictionary(grouping: plan, by: \.recipe.id).mapValues(\.count)
    #expect(uses.count == 10)
    #expect(uses.values.allSatisfy { $0 == 6 })
    for (a, b) in zip(plan, plan.dropFirst()) { #expect(a.recipe.id != b.recipe.id) }
}

@Test func planWithOneRecipeStillFillsTheMonth() {
    var rng = SeededGenerator(state: 7)
    let plan = MonthPlanner.plan(days: ["2026-12-01", "2026-12-02"], kinds: [.dinner],
                                 recipes: [recipe(1)], using: &rng)
    #expect(plan.map(\.recipe.id) == [1, 1])
}

@Test func planIsEmptyWithoutAFittingRecipe() {
    var rng = SeededGenerator(state: 7)
    let plan = MonthPlanner.plan(days: ["2026-12-01"], kinds: [.lunch],
                                 recipes: [recipe(1, [.dinner])], using: &rng)
    #expect(plan.isEmpty)
}

extension StubbedNetwork { @Suite struct MonthPlanAPITests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func recipesDecodeMealTypesAndIgnoreUnknownOnes() async throws {
        StubProtocol.routes = ["GET /api/v1/recipes": (200, """
            {"data":[{"id":3,"title":"Curry","recipe_url":"https://mealie.local/r/curry",
                      "meal_types":["lunch","dinner","brunch"],"provider_type":"mealie",
                      "ingredients":[{"id":1,"recipe_id":3,"name":"Riz","quantity":"300 g","category":"Épicerie",
                                      "pantry_item_id":null}]},
                     {"id":4,"title":"Porridge","meal_types":[],"ingredients":[]}]}
            """)]
        let recipes = try await client.recipes()
        #expect(recipes.map(\.title) == ["Curry", "Porridge"])
        #expect(recipes[0].mealTypes == [.lunch, .dinner])
        #expect(recipes[0].recipeURL == "https://mealie.local/r/curry")
        #expect(recipes[1].mealTypes.isEmpty)
        #expect(recipes[0].ingredients == [RecipeIngredient(name: "Riz", quantity: "300 g", category: "Épicerie")])
    }

    @Test func replacingPutsTheNewRecipeOnTheSameMeal() async throws {
        StubProtocol.routes = ["PUT /api/v1/meals/11": (200, """
            {"data":{"id":11,"date":"2026-12-01","meal_type":"dinner","title":"Curry","recipe_id":3,"ingredients":[]}}
            """)]
        let curry = Recipe(id: 3, title: "Curry", mealTypes: [.dinner])
        let meal = try await client.replaceRecipe(ofMeal: 11, with: curry)
        #expect(meal.recipeID == 3)
        let request = try #require(StubProtocol.seen.first)
        #expect(request.url?.query() == nil) // this meal only, never the series
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["recipe_id"] as? Int == 3)
        #expect(json["title"] as? String == "Curry")
        #expect(json["recipe_url"] is NSNull)
        #expect(json["notes"] == nil && json["date"] == nil) // the rest of the meal stays as it is
    }

    @Test func applyPlanSkipsOccupiedSlotsAndLinksTheRecipe() async throws {
        StubProtocol.routes = ["POST /api/v1/meals/apply-plan": (201, """
            {"data":[{"id":11,"date":"2026-12-01","meal_type":"lunch","title":"Curry","ingredients":[],
                      "recipe_ingredient_count":5}],
             "skipped":[{"index":1,"date":"2026-12-01","meal_type":"dinner","reason":"occupied"}]}
            """)]
        let curry = Recipe(id: 3, title: "Curry", recipeURL: "https://mealie.local/r/curry", mealTypes: [.lunch, .dinner])
        let created = try await client.applyPlan([
            PlannedMeal(date: "2026-12-01", kind: .lunch, recipe: curry),
            PlannedMeal(date: "2026-12-01", kind: .dinner, recipe: curry),
        ])
        #expect(created.map(\.id) == [11])
        #expect(created.first?.recipeIngredientCount == 5)

        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["skip_occupied"] as? Bool == true)
        let first = try #require((json["assignments"] as? [[String: Any]])?.first)
        #expect(first["meal_type"] as? String == "lunch")
        #expect(first["recipe_id"] as? Int == 3)
        #expect(first["recipe_url"] as? String == "https://mealie.local/r/curry")
        #expect(first["title"] as? String == "Curry")
    }
}
}

@Test func historySteersThePlanToRecipesNotEatenLately() {
    var rng = SeededGenerator(state: 3)
    let recipes = (1...6).map { recipe($0) }
    // 1, 2 and 3 were eaten twice in the last weeks, 4 once; 5 and 6 not at all.
    let plan = MonthPlanner.plan(days: ["2026-12-01"], kinds: [.lunch, .dinner], recipes: recipes,
                                 history: [1, 1, 2, 2, 3, 3, 4], using: &rng)
    #expect(Set(plan.map(\.recipe.id)) == [5, 6])
}

@Test func theFirstMealNeverRepeatsTheLastOneEaten() {
    var rng = SeededGenerator(state: 9)
    let plan = MonthPlanner.plan(days: ["2026-12-01"], kinds: [.lunch], recipes: [recipe(1), recipe(2)],
                                 history: [2, 1], using: &rng)
    #expect(plan.map(\.recipe.id) == [2])
}

@Test func periodsHaveStableIDsWithinOneShoppingTrip() throws {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
    func on(_ day: Int) throws -> Date { try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day))) }
    #expect(PlanSpan.month.periodID(for: try on(2), calendar: calendar) == PlanSpan.month.periodID(for: try on(30), calendar: calendar))
    #expect(PlanSpan.halfMonth.periodID(for: try on(15), calendar: calendar) != PlanSpan.halfMonth.periodID(for: try on(16), calendar: calendar))
    // Monday 9 and Sunday 15 November are one week; Monday 16 starts the next.
    #expect(PlanSpan.week.periodID(for: try on(9), calendar: calendar) == PlanSpan.week.periodID(for: try on(15), calendar: calendar))
    #expect(PlanSpan.week.periodID(for: try on(15), calendar: calendar) != PlanSpan.week.periodID(for: try on(16), calendar: calendar))
}

@Test func excludedRecipesPersistInTheSuite() throws {
    let defaults = try #require(UserDefaults(suiteName: "test.autoplan.\(UUID().uuidString)"))
    var settings = AutoPlanSettings(defaults: defaults)
    #expect(settings.excludedRecipeIDs.isEmpty)
    settings.setExcluded(true, recipeID: 7)
    settings.setExcluded(true, recipeID: 9)
    settings.setExcluded(false, recipeID: 9)
    #expect(AutoPlanSettings(defaults: defaults).excludedRecipeIDs == [7])
}

@Test func dessertsAndPeopleAreRemembered() throws {
    let defaults = try #require(UserDefaults(suiteName: "test.autoplan.\(UUID().uuidString)"))
    var settings = AutoPlanSettings(defaults: defaults)
    #expect(settings.people == 2)
    settings.people = 3
    settings.setDessert(true, recipeID: 4)
    let again = AutoPlanSettings(defaults: defaults)
    #expect(again.people == 3)
    #expect(again.dessertRecipeIDs == [4])
}
