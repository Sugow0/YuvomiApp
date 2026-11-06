import Foundation

// MARK: - Models (server/routes/recipes.js)

/// A recipe of the household, typed in Yuvomi or mirrored from Mealie/Tandoor.
public struct Recipe: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public let title: String
    public let recipeURL: String?
    /// Meals the recipe is meant for. Empty means "never pick it automatically" (upstream #750).
    public let mealTypes: [Meal.Kind]
    public let ingredients: [RecipeIngredient]
    /// Portions the ingredient amounts are for (Mealie's `recipeServings`); nil when not stated.
    public let servings: Int?
    /// The recipe's slug at its provider (Mealie), nil for a recipe typed in Yuvomi.
    public let providerSlug: String?

    enum CodingKeys: String, CodingKey { case id, title, recipeUrl, mealTypes, ingredients, servings, providerSlug }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        recipeURL = try? c.decodeIfPresent(String.self, forKey: .recipeUrl)
        let raw = (try? c.decodeIfPresent([String].self, forKey: .mealTypes)) ?? nil
        // Missing means "not asked" and the server's default is all four meals.
        mealTypes = raw.map { $0.compactMap(Meal.Kind.init(rawValue:)) } ?? Meal.Kind.allCases
        ingredients = (try? c.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients)) ?? []
        servings = ((try? c.decodeIfPresent(Int.self, forKey: .servings)) ?? nil).flatMap { $0 > 0 ? $0 : nil }
        providerSlug = (try? c.decodeIfPresent(String.self, forKey: .providerSlug)) ?? nil
    }

    public init(id: Int, title: String, recipeURL: String? = nil, mealTypes: [Meal.Kind],
                servings: Int? = nil, ingredients: [RecipeIngredient] = [], providerSlug: String? = nil) {
        self.id = id; self.title = title; self.recipeURL = recipeURL; self.mealTypes = mealTypes
        self.servings = servings; self.ingredients = ingredients; self.providerSlug = providerSlug
    }
}

/// One slot of an automatic plan.
public struct PlannedMeal: Sendable, Hashable {
    public let date: String
    public let kind: Meal.Kind
    public let recipe: Recipe
    /// Eaten from an earlier cooking: nothing to buy for it.
    public let isLeftover: Bool

    public static let leftoverSuffix = " · restes"

    public var title: String { isLeftover ? recipe.title + Self.leftoverSuffix : recipe.title }

    public init(date: String, kind: Meal.Kind, recipe: Recipe, isLeftover: Bool = false) {
        self.date = date; self.kind = kind; self.recipe = recipe; self.isLeftover = isLeftover
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Planning

/// How far one run plans ahead: as far as one shopping trip goes.
public enum PlanSpan: String, Sendable, CaseIterable {
    /// Today and the six days after it.
    case week
    /// Up to the 15th, or from the 16th to the month's end, so runs on the 1st and 16th meet.
    case halfMonth
    /// Up to the month's last day.
    case month

    /// Same value for every day of one period: a rerun in the same period tops the list up
    /// instead of starting a new one.
    public func periodID(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear], from: date)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        return switch self {
        case .week: String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        case .halfMonth: "\(month)-\((c.day ?? 1) <= 15 ? "a" : "b")"
        case .month: month
        }
    }
}

/// Choices of the automatic plan, kept on the device in the App Group (the server has no place
/// for them: mirrored Mealie recipes are read-only there).
public struct AutoPlanSettings {
    private let defaults: UserDefaults
    private static let excludedKey = "autoPlan.excludedRecipes"
    private static let periodKey = "autoPlan.lastPeriod"
    private static let dessertKey = "autoPlan.dessertRecipes"
    private static let peopleKey = "autoPlan.people"
    private static let runKey = "autoPlan.lastRun"

    public init(defaults: UserDefaults = AppGroup.defaults) { self.defaults = defaults }

    /// Recipes the automatic plan never picks (a cake is not a dinner).
    public var excludedRecipeIDs: Set<Int> {
        Set((defaults.array(forKey: Self.excludedKey) as? [Int]) ?? [])
    }

    public mutating func setExcluded(_ excluded: Bool, recipeID: Int) {
        var ids = excludedRecipeIDs
        if excluded { ids.insert(recipeID) } else { ids.remove(recipeID) }
        defaults.set(ids.sorted(), forKey: Self.excludedKey)
    }

    /// Recipes planned as desserts (snack slot) rather than lunch or dinner.
    public var dessertRecipeIDs: Set<Int> {
        Set((defaults.array(forKey: Self.dessertKey) as? [Int]) ?? [])
    }

    public mutating func setDessert(_ dessert: Bool, recipeID: Int) {
        var ids = dessertRecipeIDs
        if dessert { ids.insert(recipeID) } else { ids.remove(recipeID) }
        defaults.set(ids.sorted(), forKey: Self.dessertKey)
    }

    /// People at each meal; how many meals a recipe's portions cover depends on it.
    public var people: Int {
        get { max(1, defaults.integer(forKey: Self.peopleKey).nonZero ?? 2) }
        nonmutating set { defaults.set(max(1, newValue), forKey: Self.peopleKey) }
    }

    /// What the last run created, so it can be taken back.
    public var lastRun: AutoPlanRun? {
        get { defaults.data(forKey: Self.runKey).flatMap { try? JSONDecoder().decode(AutoPlanRun.self, from: $0) } }
        nonmutating set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.runKey) }
    }

    /// After an undo: the next run plans its period afresh.
    public func forgetLastRun() {
        lastRun = nil
        lastPeriodID = nil
    }

    /// The period (`PlanSpan.periodID`) the last successful run planned.
    public var lastPeriodID: String? {
        get { defaults.string(forKey: Self.periodKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.periodKey) }
    }
}

public enum MonthPlanner {
    /// `YYYY-MM-DD` keys of the days one run plans, starting with `date`.
    public static func days(_ span: PlanSpan, from date: Date, calendar: Calendar = .current) -> [String] {
        let start = calendar.startOfDay(for: date)
        guard let month = calendar.dateInterval(of: .month, for: start) else { return [] }
        let end: Date? = switch span {
        case .week: calendar.date(byAdding: .day, value: 7, to: start)
        case .halfMonth where calendar.component(.day, from: start) <= 15:
            calendar.date(byAdding: .day, value: 15, to: month.start)
        case .halfMonth, .month: month.end
        }
        return dayKeys(from: start, before: end ?? month.end, calendar: calendar)
    }

    /// `YYYY-MM-DD` keys from `date` to the last day of its month, both included.
    public static func remainingDays(of date: Date, calendar: Calendar = .current) -> [String] {
        days(.month, from: date, calendar: calendar)
    }

    private static func dayKeys(from start: Date, before end: Date, calendar: Calendar) -> [String] {
        var days: [String] = []
        var day = start
        while day < end {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            days.append(String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// Fills every (day, kind) slot with a recipe meant for that meal.
    ///
    /// Each pick takes one of the least used recipes so far, never the one of the slot just before,
    /// so ten recipes over sixty slots are used six times each and no meal follows itself.
    /// `history` (recipe ids of recent meals, oldest first) counts as earlier uses, so what was
    /// eaten lately comes back last.
    public static func plan(
        days: [String], kinds: [Meal.Kind], recipes: [Recipe], history: [Int] = [],
        using rng: inout some RandomNumberGenerator
    ) -> [PlannedMeal] {
        var uses = history.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        var previous = history.last
        var plan: [PlannedMeal] = []
        for day in days {
            for kind in kinds {
                let fitting = recipes.filter { $0.mealTypes.contains(kind) }
                let others = fitting.filter { $0.id != previous }
                let pool = others.isEmpty ? fitting : others
                guard let least = pool.map({ uses[$0.id, default: 0] }).min(),
                      let pick = pool.filter({ uses[$0.id, default: 0] == least }).randomElement(using: &rng)
                else { continue }
                uses[pick.id, default: 0] += 1
                previous = pick.id
                plan.append(PlannedMeal(date: day, kind: kind, recipe: pick))
            }
        }
        return plan
    }
}

// MARK: - Endpoints

extension YuvomiClient {
    public func recipes() async throws -> [Recipe] {
        try await http.send("GET", "api/v1/recipes", as: DataEnvelope<[Recipe]>.self).data
    }

    /// Creates the plan in one transaction. Slots that already hold a meal are left alone,
    /// so running it twice adds nothing. Returns only the meals it created.
    public func applyPlan(_ plan: [PlannedMeal]) async throws -> [Meal] {
        struct Assignment: Encodable, Sendable {
            let date: String; let mealType: Meal.Kind; let title: String; let recipeUrl: String?; let recipeId: Int
        }
        struct Body: Encodable, Sendable { let assignments: [Assignment]; let skipOccupied: Bool }
        guard !plan.isEmpty else { return [] }
        let body = Body(
            assignments: plan.map {
                Assignment(date: $0.date, mealType: $0.kind, title: $0.title,
                           recipeUrl: $0.recipe.recipeURL, recipeId: $0.recipe.id)
            },
            skipOccupied: true
        )
        return try await http.send(
            "POST", "api/v1/meals/apply-plan", body: body,
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<[Meal]>.self
        ).data
    }
}
