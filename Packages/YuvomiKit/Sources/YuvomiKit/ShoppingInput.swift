import Foundation

/// Turns dictated text ("2 baguettes, du lait et des œufs") into shopping items.
public struct ShoppingEntry: Sendable, Equatable {
    public let name: String
    public let quantity: String?

    public init(name: String, quantity: String? = nil) { self.name = name; self.quantity = quantity }

    public static func parse(_ raw: String) -> [ShoppingEntry] {
        raw.replacing(/\s+(et|and|puis)\s+/.ignoresCase(), with: ",")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .compactMap { entry(String($0)) }
    }

    static func entry(_ part: String) -> ShoppingEntry? {
        var text = part.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var quantity: String?
        let words = text.split(separator: " ", maxSplits: 1)
        if words.count == 2, let first = words.first, first.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) {
            quantity = String(first)
            text = String(words[1])
        }
        text = stripArticle(text)
        guard !text.isEmpty else { return nil }
        // Siri lowercases everything; keep what the person typed otherwise.
        return ShoppingEntry(name: text.prefix(1).uppercased() + text.dropFirst(), quantity: quantity)
    }

    private static let articles = ["de la ", "de l'", "de l’", "du ", "des ", "un ", "une ", "le ", "la ", "les ", "l'", "l’", "some "]

    private static func stripArticle(_ text: String) -> String {
        let lower = text.lowercased()
        guard let article = articles.first(where: { lower.hasPrefix($0) }), text.count > article.count else { return text }
        return String(text.dropFirst(article.count)).trimmingCharacters(in: .whitespaces)
    }
}
