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
