import Foundation
import Observation
import WidgetKit
import YuvomiKit

/// One week of meals at a time, and the bridge to the shopping list.
@MainActor @Observable
final class MealsModel {
    let client: YuvomiClient

    private(set) var week: MealWeek?
    private(set) var lists: [ShoppingList] = []
    private(set) var anchor = TodayBuckets.dayKey()
    private(set) var isLoading = false
    var errorMessage: String?
    /// Short confirmation after sending ingredients to the shopping list.
    var notice: String?
    /// Recipes the "Planifier les repas" shortcut never picks.
    private(set) var excludedRecipes = AutoPlanSettings().excludedRecipeIDs
    private(set) var dessertRecipes = AutoPlanSettings().dessertRecipeIDs

    enum RecipeRole: String, CaseIterable, Identifiable {
        case dish = "Plat", dessert = "Dessert", excluded = "Exclue"
        var id: Self { self }
    }

    func role(of recipeID: Int) -> RecipeRole {
        if excludedRecipes.contains(recipeID) { return .excluded }
        return dessertRecipes.contains(recipeID) ? .dessert : .dish
    }

    func setRole(_ role: RecipeRole, recipeID: Int) {
        var settings = AutoPlanSettings()
        settings.setExcluded(role == .excluded, recipeID: recipeID)
        settings.setDessert(role == .dessert, recipeID: recipeID)
        excludedRecipes = settings.excludedRecipeIDs
        dessertRecipes = settings.dessertRecipeIDs
    }

    init(client: YuvomiClient) { self.client = client }

    var isCurrentWeek: Bool {
        guard let week else { return true }
        let today = TodayBuckets.dayKey()
        return week.start <= today && today <= week.end
    }

    /// The list the shopping screen last showed, else the first.
    var targetList: ShoppingList? {
        let selected = AppGroup.defaults.object(forKey: "shopping.selectedList") as? Int
        return lists.first { $0.id == selected } ?? lists.first
    }

    func meal(_ id: Int) -> Meal? { week?.meals.first { $0.id == id } }

    func setAutoPlan(_ included: Bool, recipeID: Int) {
        var settings = AutoPlanSettings()
        settings.setExcluded(!included, recipeID: recipeID)
        excludedRecipes = settings.excludedRecipeIDs
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let lists = try? client.shoppingLists()
        do {
            week = try await client.mealWeek(containing: anchor)
        } catch {
            errorMessage = error.userMessage
        }
        self.lists = await lists ?? self.lists
    }

    func shift(weeks: Int) async {
        guard let date = MealWeekDay.date(anchor),
              let moved = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: date) else { return }
        anchor = TodayBuckets.dayKey(moved)
        await load()
    }

    func goToToday() async {
        anchor = TodayBuckets.dayKey()
        await load()
    }

    func create(date: String, kind: Meal.Kind, title: String, ingredients: String) async -> Bool {
        do {
            let meal = try await client.createMeal(date: date, kind: kind, title: title,
                                                   ingredients: ShoppingEntry.parse(ingredients))
            if let week, week.start <= meal.date, meal.date <= week.end { self.week?.meals.append(meal) }
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    /// Returns false on failure. A meal moved out of the shown week leaves it.
    func update(_ meal: Meal, date: String, kind: Meal.Kind, title: String, notes: String) async -> Bool {
        do {
            let saved = try await client.updateMeal(meal.id, date: date, kind: kind, title: title, notes: notes)
            if let week, week.start <= saved.date, saved.date <= week.end {
                update(meal.id) { $0 = saved }
            } else {
                self.week?.meals.removeAll { $0.id == meal.id }
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func delete(_ meal: Meal) async -> Bool {
        let backup = week
        week?.meals.removeAll { $0.id == meal.id }
        do {
            try await client.deleteMeal(meal.id)
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
            return true
        } catch {
            week = backup
            errorMessage = error.userMessage
            return false
        }
    }

    func addIngredients(_ text: String, to meal: Meal) async {
        for entry in ShoppingEntry.parse(text) {
            do {
                let ingredient = try await client.addIngredient(to: meal.id, entry)
                update(meal.id) { $0.ingredients.append(ingredient) }
            } catch {
                errorMessage = error.userMessage
                return
            }
        }
    }

    func deleteIngredient(_ ingredient: Meal.Ingredient, of meal: Meal) async {
        update(meal.id) { $0.ingredients.removeAll { $0.id == ingredient.id } }
        do {
            try await client.deleteIngredient(ingredient.id)
        } catch {
            update(meal.id) { $0.ingredients.append(ingredient) }
            errorMessage = error.userMessage
        }
    }

    func sendToShopping(_ meal: Meal) async {
        guard let list = targetList else { errorMessage = "Aucune liste de courses."; return }
        do {
            let result = try await client.sendMealToShopping(meal.id, listID: list.id)
            await afterTransfer(result, list: list)
        } catch {
            errorMessage = error.userMessage
        }
    }

    func sendWeekToShopping() async {
        guard let list = targetList, let week else { errorMessage = "Aucune liste de courses."; return }
        do {
            let result = try await client.sendWeekToShopping(containing: week.start, listID: list.id)
            await afterTransfer(result, list: list)
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// How many meals "Annuler le planning auto" would delete; 0 hides it.
    var undoableMeals: Int { AutoPlanSettings().lastRun?.mealIDs.count ?? 0 }

    func undoAutoPlan(emptyingList: Bool) async {
        let settings = AutoPlanSettings()
        guard let run = settings.lastRun else { return }
        do {
            let result = try await client.undo(run, people: settings.people, emptyingList: emptyingList)
            settings.forgetLastRun()
            notice = UndoMealPlanIntent.sentence(result, emptied: emptyingList)
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
            await load()
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Another recipe for this meal's whole cooking (the meal and its leftovers on the days around
    /// it), picked like the shortcut does. When the old recipe's ingredients are on the list, its
    /// amounts come off and the new recipe's go on.
    func replace(_ meal: Meal) async {
        do {
            let settings = AutoPlanSettings()
            let recipes = try await client.recipes()
            let roles = try await RecipeRoles.load(for: recipes, settings: settings)
            let old = recipes.first { $0.id == meal.recipeID }
            let cooking = cookingMeals(of: meal)
            // Not the old dish, nor the one on the other track those days.
            let busy = Set((week?.meals ?? [])
                .filter { other in cooking.contains { $0.date == other.date } && other.kind != meal.kind }
                .compactMap(\.recipeID))
            let pool = meal.kind == .snack ? roles.desserts : roles.dishes
            let candidates = pool.filter { $0.id != meal.recipeID && !busy.contains($0.id) }
            let history = try await client.recipeHistory(around: [meal.date])
            var rng = SystemRandomNumberGenerator()
            guard let pick = MonthPlanner.plan(days: [meal.date], kinds: [meal.kind], recipes: candidates,
                                               history: history, using: &rng).first?.recipe else {
                errorMessage = "Aucune autre recette proposée pour le \(meal.kind.label.lowercased())."
                return
            }
            for (index, part) in cooking.enumerated() {
                let title = index == 0 ? pick.title : pick.title + PlannedMeal.leftoverSuffix
                let updated = try await client.replaceRecipe(ofMeal: part.id, with: pick, title: title)
                update(part.id) { $0 = updated }
            }

            var text = cooking.count > 1
                ? "« \(old?.title ?? meal.title) » remplacé par « \(pick.title) » sur \(cooking.count) repas."
                : "« \(meal.title) » remplacé par « \(pick.title) »."
            if let list = targetList, let old, !old.ingredients.isEmpty {
                var open = OpenShoppingItems(listID: list.id, items: try await client.shoppingItems(listID: list.id).items)
                if old.ingredients.contains(where: { open.contains($0.name) }) {
                    let people = settings.people
                    try await open.takeOff(old.shopping(factor: old.cookingFactor(people: people, for: meal.kind)), using: client)
                    try await open.put(pick.shopping(factor: pick.cookingFactor(people: people, for: meal.kind)), using: client)
                    text += " \(list.name) est à jour."
                    WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
                }
            }
            notice = text
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// The meal's cooking as far as this week shows it: same recipe, same kind, day after day.
    private func cookingMeals(of meal: Meal) -> [Meal] {
        guard let recipeID = meal.recipeID else { return [meal] }
        let same = (week?.meals ?? []).filter { $0.recipeID == recipeID && $0.kind == meal.kind }
        let byDay = Dictionary(same.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        func shifted(_ key: String, _ days: Int) -> String? {
            DayKey.date(key).flatMap { Calendar.current.date(byAdding: .day, value: days, to: $0) }.map { TodayBuckets.dayKey($0) }
        }
        var start = meal.date
        // Walk back to the cooking day: the first one not titled as leftovers.
        while byDay[start]?.title.hasSuffix(PlannedMeal.leftoverSuffix) == true,
              let previous = shifted(start, -1), byDay[previous] != nil { start = previous }
        var run: [Meal] = []
        var day: String? = start
        while let key = day, let next = byDay[key], run.isEmpty || next.title.hasSuffix(PlannedMeal.leftoverSuffix) {
            run.append(next)
            day = shifted(key, 1)
        }
        return run.isEmpty ? [meal] : run
    }

    private func afterTransfer(_ result: ShoppingTransfer, list: ShoppingList) async {
        var text = switch result.transferred {
        case 0: "Rien de nouveau à ajouter à \(list.name)."
        case 1: "1 ingrédient ajouté à \(list.name)."
        default: "\(result.transferred) ingrédients ajoutés à \(list.name)."
        }
        if result.skipped > 0 { text += " \(result.skipped) déjà sur la liste." }
        notice = text
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
        await load() // refresh the "sur la liste" marks
    }

    private func update(_ id: Int, _ change: (inout Meal) -> Void) {
        guard let index = week?.meals.firstIndex(where: { $0.id == id }) else { return }
        change(&week!.meals[index])
    }
}

enum MealWeekDay {
    static func date(_ key: String) -> Date? { DayKey.date(key) }

    static func title(_ key: String) -> String {
        guard let date = date(key) else { return key }
        if Calendar.current.isDateInToday(date) { return "Aujourd'hui" }
        if Calendar.current.isDateInTomorrow(date) { return "Demain" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
    }
}
