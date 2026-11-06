import Foundation

/// One cooking: a recipe made once and eaten over a few meals of the same kind.
public struct Batch: Sendable, Hashable {
    public let recipe: Recipe
    /// How many times the recipe's amounts are cooked (2 when it is too small for two meals).
    public let factor: Int
    /// The cooking meal first, then its leftovers.
    public let meals: [PlannedMeal]

    /// What to buy for it: the recipe once, scaled.
    public var shopping: [RecipeIngredient] { recipe.shopping(factor: factor) }
}

extension Recipe {
    /// The ingredients for one cooking `factor` times as big.
    public func shopping(factor: Int) -> [RecipeIngredient] {
        ingredients.map {
            RecipeIngredient(name: $0.name, quantity: ShoppingTotals.scaled($0.quantity, by: factor), category: $0.category)
        }
    }

    /// How big one cooking is for `people`, as the planner sizes it for this kind of meal.
    public func cookingFactor(people: Int, for kind: Meal.Kind) -> Int {
        let range = kind == .snack ? 1...3 : 2...4
        return BatchPlanner.coverage(servings: servings, people: people, meals: range).factor
    }
}

/// Plans few big cookings instead of one recipe per meal: cheaper, less waste.
///
/// Lunch and dinner are two tracks. Each track eats one dish for as many meals as its portions
/// cover, then the next; the two tracks never hold the same dish, so no dish follows itself.
/// Desserts go on the snack slot, a few times a week, each lasting a few days.
public enum BatchPlanner {
    public struct Options: Sendable, Equatable {
        public var people: Int
        public var dessertsPerWeek: Int
        /// How many meals one cooking of a dish may cover.
        public var mealsPerDish: ClosedRange<Int>
        /// How many days one dessert may last.
        public var daysPerDessert: ClosedRange<Int>

        public init(people: Int, dessertsPerWeek: Int = 0, mealsPerDish: ClosedRange<Int> = 2...4,
                    daysPerDessert: ClosedRange<Int> = 1...3) {
            self.people = max(1, people)
            self.dessertsPerWeek = min(max(0, dessertsPerWeek), 7)
            self.mealsPerDish = mealsPerDish
            self.daysPerDessert = daysPerDessert
        }
    }

    public struct Coverage: Sendable, Equatable {
        public let meals: Int
        public let factor: Int
    }

    /// A recipe without portions counts as four.
    static let assumedServings = 4

    /// How many meals one cooking feeds, cooking the recipe bigger when it would not reach the minimum.
    public static func coverage(servings: Int?, people: Int, meals range: ClosedRange<Int>) -> Coverage {
        let portions = servings ?? assumedServings
        let people = max(1, people)
        let needed = range.lowerBound * people
        let factor = max(1, Int((Double(needed) / Double(portions)).rounded(.up)))
        let meals = min(max(portions * factor / people, range.lowerBound), range.upperBound)
        return Coverage(meals: meals, factor: factor)
    }

    /// `history`: recipe ids of recent cookings, oldest first; what was cooked lately comes back last.
    public static func plan(
        days: [String], dishes: [Recipe], desserts: [Recipe], options: Options,
        history: [Int] = [], using rng: inout some RandomNumberGenerator
    ) -> [Batch] {
        var uses = history.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        var batches = dishBatches(days: days, dishes: dishes, options: options, uses: &uses, rng: &rng)
        batches += dessertBatches(days: days, desserts: desserts, options: options, uses: &uses, rng: &rng)
        return batches.sorted { ($0.meals[0].date, order($0.meals[0].kind)) < ($1.meals[0].date, order($1.meals[0].kind)) }
    }

    private static func order(_ kind: Meal.Kind) -> Int { Meal.Kind.allCases.firstIndex(of: kind) ?? 0 }

    private static func pick(from recipes: [Recipe], avoiding: Set<Int>, uses: [Int: Int],
                             rng: inout some RandomNumberGenerator) -> Recipe? {
        let others = recipes.filter { !avoiding.contains($0.id) }
        let pool = others.isEmpty ? recipes : others
        guard let least = pool.map({ uses[$0.id, default: 0] }).min() else { return nil }
        return pool.filter { uses[$0.id, default: 0] == least }.randomElement(using: &rng)
    }

    private static func dishBatches(days: [String], dishes: [Recipe], options: Options,
                                    uses: inout [Int: Int], rng: inout some RandomNumberGenerator) -> [Batch] {
        let tracks: [Meal.Kind] = [.lunch, .dinner]
        var current: [Meal.Kind: (recipe: Recipe, factor: Int, left: Int, meals: [PlannedMeal])] = [:]
        var last: [Meal.Kind: Int] = [:]
        var done: [Batch] = []
        for day in days {
            for kind in tracks {
                if current[kind] == nil {
                    let fitting = dishes.filter { $0.mealTypes.contains(kind) }
                    let busy = Set(tracks.compactMap { current[$0]?.recipe.id } + [last[kind]].compactMap(\.self))
                    guard let recipe = pick(from: fitting, avoiding: busy, uses: uses, rng: &rng) else { continue }
                    let cover = coverage(servings: recipe.servings, people: options.people, meals: options.mealsPerDish)
                    uses[recipe.id, default: 0] += 1
                    current[kind] = (recipe, cover.factor, cover.meals, [])
                }
                guard var batch = current[kind] else { continue }
                batch.meals.append(PlannedMeal(date: day, kind: kind, recipe: batch.recipe, isLeftover: !batch.meals.isEmpty))
                batch.left -= 1
                if batch.left == 0 {
                    done.append(Batch(recipe: batch.recipe, factor: batch.factor, meals: batch.meals))
                    last[kind] = batch.recipe.id
                    current[kind] = nil
                } else {
                    current[kind] = batch
                }
            }
        }
        // Cookings the period cuts short are still bought whole: the leftovers go past its end.
        for kind in tracks {
            if let batch = current[kind], !batch.meals.isEmpty {
                done.append(Batch(recipe: batch.recipe, factor: batch.factor, meals: batch.meals))
            }
        }
        return done
    }

    private static func dessertBatches(days: [String], desserts: [Recipe], options: Options,
                                       uses: inout [Int: Int], rng: inout some RandomNumberGenerator) -> [Batch] {
        let count = min(days.count, Int((Double(options.dessertsPerWeek * days.count) / 7).rounded()))
        guard count > 0, !desserts.isEmpty else { return [] }
        let starts = (0..<count).map { $0 * days.count / count }
        var previous: Int?
        return starts.enumerated().compactMap { index, start in
            guard let recipe = pick(from: desserts, avoiding: Set([previous].compactMap(\.self)), uses: uses, rng: &rng)
            else { return nil }
            uses[recipe.id, default: 0] += 1
            previous = recipe.id
            let cover = coverage(servings: recipe.servings, people: options.people,
                                 meals: options.daysPerDessert.lowerBound...max(options.daysPerDessert.lowerBound, 99))
            let next = index + 1 < starts.count ? starts[index + 1] : days.count
            let length = min(min(cover.meals, options.daysPerDessert.upperBound), next - start)
            let meals = (0..<length).map {
                PlannedMeal(date: days[start + $0], kind: .snack, recipe: recipe, isLeftover: $0 > 0)
            }
            return Batch(recipe: recipe, factor: cover.factor, meals: meals)
        }
    }
}
