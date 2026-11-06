import Foundation

// What the "Planifier les repas" shortcut and the app's "Remplacer" share.

extension YuvomiClient {
    /// Recipe ids of the meals from four weeks before `days` to their end, oldest first, so a
    /// plan picks what was not eaten lately.
    public func recipeHistory(around days: [String], calendar: Calendar = .current) async throws -> [Int] {
        guard let first = days.first.flatMap(MealWeek.date), let last = days.last.flatMap(MealWeek.date),
              var day = calendar.date(byAdding: .day, value: -28, to: first) else { return [] }
        var meals: [Int: Meal] = [:]
        while day <= last {
            for meal in try await mealWeek(containing: TodayBuckets.dayKey(day)).meals { meals[meal.id] = meal }
            guard let next = calendar.date(byAdding: .day, value: 7, to: day) else { break }
            day = next
        }
        let order = Meal.Kind.allCases
        return meals.values
            .sorted { ($0.date, order.firstIndex(of: $0.kind) ?? 0) < ($1.date, order.firstIndex(of: $1.kind) ?? 0) }
            .filter { !$0.title.hasSuffix(PlannedMeal.leftoverSuffix) } // count cookings, not leftovers
            .compactMap(\.recipeID)
    }

    /// Puts another recipe on this meal only; date, kind, cook and notes stay.
    public func replaceRecipe(ofMeal mealID: Int, with recipe: Recipe, title: String? = nil) async throws -> Meal {
        struct Body: Encodable, Sendable {
            let title: String; let recipeId: Int; let recipeUrl: String?
            enum CodingKeys: String, CodingKey { case title, recipeId, recipeUrl }
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(title, forKey: .title)
                try c.encode(recipeId, forKey: .recipeId)
                try c.encode(recipeUrl, forKey: .recipeUrl) // null clears the old recipe's link
            }
        }
        return try await http.send(
            "PUT", "api/v1/meals/\(mealID)",
            body: Body(title: title ?? recipe.title, recipeId: recipe.id, recipeUrl: recipe.recipeURL),
            as: DataEnvelope<Meal>.self
        ).data
    }
}

/// The open items of one list, kept up to date while ingredients go on and come off.
public struct OpenShoppingItems: Sendable {
    public let listID: Int
    private var byKey: [String: ShoppingItem]

    public init(listID: Int, items: [ShoppingItem]) {
        self.listID = listID
        byKey = Dictionary(items.filter { !$0.isChecked }.map { (ShoppingTotals.matchKey($0.name), $0) },
                           uniquingKeysWith: { first, _ in first })
    }

    public func contains(_ name: String) -> Bool { byKey[ShoppingTotals.matchKey(name)] != nil }

    /// One line per ingredient; one already open gets the new amount added instead of a second line.
    /// Returns how many lines were added or changed.
    @discardableResult
    public mutating func put(_ ingredients: [RecipeIngredient], using client: YuvomiClient) async throws -> Int {
        var touched = 0
        for total in ShoppingTotals.combine(ingredients) {
            let key = ShoppingTotals.matchKey(total.name)
            if let item = byKey[key] {
                let amount = ShoppingTotals.adding(total.quantity, to: item.quantity)
                guard amount != item.quantity else { continue }
                byKey[key] = try await client.setShoppingItem(item.id, quantity: amount)
            } else {
                byKey[key] = try await client.addShoppingItem(listID: listID, name: total.name,
                                                              quantity: total.quantity, category: total.category)
            }
            touched += 1
        }
        return touched
    }

    /// Takes a recipe's counted amounts back off; an item whose amount reaches zero goes.
    @discardableResult
    public mutating func takeOff(_ ingredients: [RecipeIngredient], using client: YuvomiClient) async throws -> Int {
        var touched = 0
        for total in ShoppingTotals.combine(ingredients) {
            let key = ShoppingTotals.matchKey(total.name)
            guard let item = byKey[key] else { continue }
            switch ShoppingTotals.removing(total.quantity, from: item.quantity) {
            case .remove:
                try await client.deleteShoppingItem(item.id)
                byKey[key] = nil
            case .keep(let amount) where amount != item.quantity:
                byKey[key] = try await client.setShoppingItem(item.id, quantity: amount)
            case .keep:
                continue
            }
            touched += 1
        }
        return touched
    }
}

/// The meals one run of the shortcut created, and the list it filled.
public struct AutoPlanRun: Sendable, Codable, Equatable {
    public var mealIDs: [Int]
    public var firstDay: String
    public var lastDay: String
    public var listID: Int

    public init(mealIDs: [Int], firstDay: String, lastDay: String, listID: Int) {
        self.mealIDs = mealIDs; self.firstDay = firstDay; self.lastDay = lastDay; self.listID = listID
    }

    /// What was bought for these meals: each cooking once, sized as the planner sized it.
    public static func shopping(of meals: [Meal], recipes: [Recipe], people: Int) -> [RecipeIngredient] {
        let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return meals
            .filter { !$0.title.hasSuffix(PlannedMeal.leftoverSuffix) }
            .compactMap { meal in
                meal.recipeID.flatMap { byID[$0] }.map { $0.shopping(factor: $0.cookingFactor(people: people, for: meal.kind)) }
            }
            .flatMap(\.self)
    }
}

extension YuvomiClient {
    public struct UndoResult: Sendable, Equatable {
        public let meals: Int
        public let items: Int
    }

    /// Deletes the meals `run` created (those still there) and takes their ingredients back off
    /// its list, or empties the list entirely.
    public func undo(_ run: AutoPlanRun, people: Int, emptyingList: Bool) async throws -> UndoResult {
        let ids = Set(run.mealIDs)
        var meals: [Int: Meal] = [:]
        if let first = MealWeek.date(run.firstDay), let last = MealWeek.date(run.lastDay) {
            var day = first
            while day <= last {
                for meal in try await mealWeek(containing: TodayBuckets.dayKey(day)).meals where ids.contains(meal.id) {
                    meals[meal.id] = meal
                }
                guard let next = Calendar.current.date(byAdding: .day, value: 7, to: day) else { break }
                day = next
            }
            // The week holding the last day, when the loop stepped past it.
            for meal in try await mealWeek(containing: run.lastDay).meals where ids.contains(meal.id) {
                meals[meal.id] = meal
            }
        }

        let items = try await shoppingItems(listID: run.listID).items
        var touched = 0
        if emptyingList {
            for item in items { try await deleteShoppingItem(item.id) }
            touched = items.count
        } else {
            var open = OpenShoppingItems(listID: run.listID, items: items)
            touched = try await open.takeOff(
                AutoPlanRun.shopping(of: Array(meals.values), recipes: recipes(), people: people), using: self
            )
        }
        for meal in meals.values { try await deleteMeal(meal.id) }
        return UndoResult(meals: meals.count, items: touched)
    }
}
