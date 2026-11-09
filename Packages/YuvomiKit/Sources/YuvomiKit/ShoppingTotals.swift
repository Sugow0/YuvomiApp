import Foundation

/// One ingredient line of a recipe, as `GET /recipes` returns it.
public struct RecipeIngredient: Sendable, Hashable, Decodable {
    public let name: String
    public let quantity: String?
    public let category: String?

    public init(name: String, quantity: String?, category: String?) {
        self.name = name; self.quantity = quantity; self.category = category
    }
}

/// One shopping line for a whole plan: every use of an ingredient, added up.
public struct ShoppingTotal: Sendable, Hashable {
    public let name: String
    public let quantity: String?
    public let category: String?
}

/// Adds up the ingredients of many recipes, so a month of meals gives one line per ingredient
/// ("5" eggs) instead of the first recipe's amount.
///
/// Names match a little more loosely than the server's rule (trimmed, case-insensitive): plurals,
/// a note after a comma or in brackets, and "doux" do not make another ingredient. An amount
/// written in the name ("150 g Beurre", as Mealie sends lines not linked to a food) is read out.
/// Amounts add up when they share a unit (g/kg and ml/cl/l convert); anything else is kept
/// side by side ("2 + 400 g"), since guessing what "2 tomatoes" weigh would be wrong.
public enum ShoppingTotals {
    public static func combine(_ ingredients: [RecipeIngredient]) -> [ShoppingTotal] {
        var order: [String] = []
        var groups: [String: [RecipeIngredient]] = [:]
        for ingredient in ingredients.map(splittingAmountFromName) {
            let key = matchKey(ingredient.name)
            guard !key.isEmpty else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(ingredient)
        }
        return order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            return ShoppingTotal(
                name: first.name.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: total(group.compactMap(\.quantity)),
                category: group.lazy.compactMap(\.category).first { !$0.isEmpty }
            )
        }
    }

    /// The amount of an open list item once `more` of it is needed.
    public static func adding(_ more: String?, to existing: String?) -> String? {
        combine([RecipeIngredient(name: "x", quantity: existing, category: nil),
                 RecipeIngredient(name: "x", quantity: more, category: nil)]).first?.quantity
    }

    /// The amount for a recipe cooked `factor` times as big; words ("au goût") stay as they are.
    public static func scaled(_ quantity: String?, by factor: Int) -> String? {
        guard factor != 1 else { return quantity }
        let parts = pieces(quantity).map { text -> String in
            guard let amount = parse(text) else { return text }
            return format(amount.value * Double(factor), unitKey: amount.unitKey, label: amount.unitLabel)
        }
        return parts.isEmpty ? quantity : parts.joined(separator: " + ")
    }

    /// What is left of an open item once a recipe no longer needs `less` of it.
    public enum Remainder: Sendable, Equatable {
        case keep(String?)
        /// Its counted amount reached zero.
        case remove
    }

    /// Only counted amounts are taken off: "au goût", or an item with no amount, may still be
    /// needed by another meal, so it stays.
    public static func removing(_ less: String?, from existing: String?) -> Remainder {
        var parts: [(amount: Amount?, text: String)] = pieces(existing).map { (parse($0), $0) }
        var changed = false
        for text in pieces(less) {
            guard let minus = parse(text),
                  let i = parts.firstIndex(where: { $0.amount?.unitKey == minus.unitKey }),
                  let amount = parts[i].amount else { continue }
            let value = amount.value - minus.value
            let label = format(value, unitKey: amount.unitKey, label: amount.unitLabel)
            parts[i] = (Amount(value: value, unitKey: amount.unitKey, unitLabel: amount.unitLabel, original: label), label)
            changed = true
        }
        guard changed else { return .keep(existing) }
        let left = parts.filter { $0.amount.map { $0.value > 0.0001 } ?? true }
        return left.isEmpty ? .remove : .keep(left.map(\.text).joined(separator: " + "))
    }

    /// The key two names share when the shopping list treats them as one item.
    public static func matchKey(_ name: String) -> String {
        var text = name.lowercased().replacingOccurrences(of: "’", with: "'")
        if let cut = text.firstIndex(where: { $0 == "," || $0 == "(" }) { text = String(text[..<cut]) }
        return text.split(whereSeparator: \.isWhitespace)
            .filter { !neutralWords.contains(String($0)) }
            .map { word in
                // "oignons" and "oignon" are one; "riz" or "pois" keep their letter.
                word.count > 3 && (word.hasSuffix("s") || word.hasSuffix("x")) && !word.hasSuffix("ss")
                    ? String(word.dropLast()) : String(word)
            }
            .joined(separator: " ")
    }

    /// Words that say nothing about what to buy ("beurre doux" is the butter of every recipe).
    private static let neutralWords: Set<String> = ["doux"]

    // MARK: Amounts in names

    /// Spoon units as recipes write them, to one label each.
    private static let spoonUnits: [(variants: [String], label: String)] = [
        (["cuillères à soupe", "cuillère à soupe", "cuil. à soupe", "c. à soupe", "c à soupe", "c.à.s.", "c.à.s", "càs", "cs"], "c. à soupe"),
        (["cuillères à café", "cuillère à café", "cuil. à café", "c. à café", "c à café", "c.à.c.", "c.à.c", "càc", "cc"], "c. à café"),
    ]
    /// Units that may follow the number in a name, longest first.
    private static let nameUnits: [String] = (spoonUnits.flatMap(\.variants) + [
        "kg", "mg", "gr", "g", "ml", "cl", "dl", "l",
        "pincées", "pincée", "gousses", "gousse", "tranches", "tranche", "sachets", "sachet",
        "boîtes", "boîte", "brins", "brin", "feuilles", "feuille", "bottes", "botte",
        "poignées", "poignée", "verres", "verre", "tasses", "tasse", "pots", "pot",
    ]).sorted { $0.count > $1.count }

    /// "150 g Beurre" → name "Beurre", quantity "150 g", when the line has no quantity of its own.
    static func splittingAmountFromName(_ ingredient: RecipeIngredient) -> RecipeIngredient {
        guard (ingredient.quantity ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return ingredient }
        let text = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = text.prefixMatch(of: /[0-9]+(?:[.,][0-9]+)?(?:\s*\/\s*[0-9]+)?|[½¼¾⅓⅔]/) else { return ingredient }
        var amount = String(number.output)
        var rest = text[number.range.upperBound...].drop { $0 == " " }
        let lower = rest.lowercased()
        if let unit = nameUnits.first(where: { unit in
            lower.hasPrefix(unit) && (lower.count == unit.count || [" ", "'", "’"].contains(lower.dropFirst(unit.count).first.map(String.init) ?? ""))
        }) {
            amount += " " + (spoonUnits.first { $0.variants.contains(unit) }?.label ?? unit)
            rest = rest.dropFirst(unit.count).drop { $0 == " " }
        }
        // "de sucre", "d'huile"
        for connector in ["de ", "d'", "d’", "des "] where rest.lowercased().hasPrefix(connector) {
            rest = rest.dropFirst(connector.count)
            break
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return ingredient }
        return RecipeIngredient(name: name.prefix(1).uppercased() + name.dropFirst(), quantity: amount,
                                category: ingredient.category)
    }

    // MARK: Amounts

    private struct Amount { let value: Double; let unitKey: String; let unitLabel: String; let original: String }

    /// "2 + 400 g" (a line this type wrote) is two amounts.
    private static func pieces(_ quantity: String?) -> [String] {
        (quantity ?? "").components(separatedBy: " + ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func total(_ quantities: [String]) -> String? {
        let texts = quantities.flatMap { pieces($0) }
        guard !texts.isEmpty else { return nil }

        var unitOrder: [String] = []
        var byUnit: [String: [Amount]] = [:]
        var words: [String] = []
        for text in texts {
            if let amount = parse(text) {
                if byUnit[amount.unitKey] == nil { unitOrder.append(amount.unitKey) }
                byUnit[amount.unitKey, default: []].append(amount)
            } else if !words.contains(where: { $0.lowercased() == text.lowercased() }) {
                words.append(text)
            }
        }
        let parts = unitOrder.compactMap { key -> String? in
            guard let amounts = byUnit[key], let first = amounts.first else { return nil }
            if amounts.count == 1 { return first.original }
            return format(amounts.reduce(0) { $0 + $1.value }, unitKey: key, label: first.unitLabel)
        }
        return (parts + words).joined(separator: " + ")
    }

    private static let fractions: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1 / 3, "⅔": 2 / 3]
    /// Unit → (family, factor to the family's base unit).
    private static let conversions: [String: (String, Double)] = [
        "g": ("g", 1), "gr": ("g", 1), "kg": ("g", 1000), "mg": ("g", 0.001),
        "ml": ("ml", 1), "cl": ("ml", 10), "dl": ("ml", 100), "l": ("ml", 1000),
    ]

    private static func parse(_ text: String) -> Amount? {
        var rest = Substring(text)
        var value: Double?
        // "1 1/2", "1/2", "1,5", "3", "½", "1½"
        if let match = rest.prefixMatch(of: /([0-9]+(?:[.,][0-9]+)?)(?:\s+([0-9]+)\s*\/\s*([0-9]+)|\s*\/\s*([0-9]+))?/) {
            let whole = Double(match.1.replacingOccurrences(of: ",", with: ".")) ?? 0
            if let n = match.2, let d = match.3, let n = Double(n), let d = Double(d), d > 0 {
                value = whole + n / d
            } else if let d = match.4, let d = Double(d), d > 0 {
                value = whole / d
            } else {
                value = whole
            }
            rest = rest[match.range.upperBound...]
        }
        if let symbol = rest.first, let part = fractions[symbol] {
            value = (value ?? 0) + part
            rest = rest.dropFirst()
        }
        guard let value else { return nil }

        var label = rest.trimmingCharacters(in: .whitespaces)
        if let spoon = spoonUnits.first(where: { $0.variants.contains(label.lowercased()) }) { label = spoon.label }
        let lower = label.lowercased()
        if let (family, factor) = conversions[lower] {
            return Amount(value: value * factor, unitKey: family, unitLabel: family, original: text)
        }
        // "pincée" and "pincées" are one unit.
        let singular = lower.count > 2 && lower.hasSuffix("s") ? String(lower.dropLast()) : lower
        return Amount(value: value, unitKey: singular, unitLabel: singularLabel(label), original: text)
    }

    private static func singularLabel(_ label: String) -> String {
        label.count > 2 && label.lowercased().hasSuffix("s") ? String(label.dropLast()) : label
    }

    private static func format(_ value: Double, unitKey: String, label: String) -> String {
        switch unitKey {
        case "g" where value >= 1000: "\(number(value / 1000)) kg"
        case "g": "\(number(value)) g"
        case "ml" where value >= 1000: "\(number(value / 1000)) l"
        case "ml" where value >= 10: "\(number(value / 10)) cl"
        case "ml": "\(number(value)) ml"
        default: label.isEmpty ? number(value) : "\(number(value)) \(label)"
        }
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "fr_FR")))
    }
}
