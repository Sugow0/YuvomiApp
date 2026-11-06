import Foundation

// MARK: - Models (server/routes/budget/*.js)

/// One booking. Amounts are signed: negative = expense, positive = income.
public struct BudgetEntry: Sendable, Hashable, Identifiable, Decodable {
    /// Subscription payments projected by the server have no row yet (`id: null`).
    public let serverID: Int?
    public var title: String?
    public var amount: Double
    public var category: String
    public var subcategory: String?
    /// `YYYY-MM-DD`.
    public var date: String
    public let isRecurring: Bool
    /// Booked later (`is_pending`) or projected from a subscription (`expected`).
    public let isPending: Bool
    public let isTransfer: Bool
    public let creatorName: String?

    public var id: String { serverID.map(String.init) ?? "expected-\(date)-\(title ?? "")-\(amount)" }
    public var isExpense: Bool { amount < 0 }
    /// Only real, non-transfer rows: the rest is managed on the web.
    public var isEditable: Bool { serverID != nil && !isTransfer }

    enum CodingKeys: String, CodingKey {
        case id, title, amount, category, subcategory, date, isRecurring, isPending, expected, transferEntryId, creatorName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try c.decodeIfPresent(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        amount = try c.decode(Double.self, forKey: .amount)
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        subcategory = try c.decodeIfPresent(String.self, forKey: .subcategory)
        date = try c.decode(String.self, forKey: .date)
        isRecurring = c.flag(.isRecurring)
        isPending = c.flag(.isPending) || c.flag(.expected)
        isTransfer = (try? c.decodeIfPresent(Int.self, forKey: .transferEntryId)) != nil
        creatorName = try c.decodeIfPresent(String.self, forKey: .creatorName)
    }

    public init(serverID: Int?, title: String?, amount: Double, category: String, date: String,
                isRecurring: Bool = false, isPending: Bool = false) {
        self.serverID = serverID; self.title = title; self.amount = amount; self.category = category
        self.subcategory = nil; self.date = date; self.isRecurring = isRecurring
        self.isPending = isPending; self.isTransfer = false; self.creatorName = nil
    }
}

extension KeyedDecodingContainer {
    /// SQLite 0/1 or a JSON bool; absent means false.
    func flag(_ key: Key) -> Bool {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        return ((try? decode(Int.self, forKey: key)) ?? 0) != 0
    }
}

public struct BudgetCategory: Sendable, Hashable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Decodable { case income, expense }

    public let key: String
    public let label: String
    public let type: Kind
    public var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, label, type }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        let name = try c.decode(String.self, forKey: .name)
        label = (try? c.decode(String.self, forKey: .label)) ?? name
        type = (try? c.decode(Kind.self, forKey: .type)) ?? .expense
    }

    public init(key: String, label: String, type: Kind) {
        self.key = key; self.label = label; self.type = type
    }

    /// SF Symbol for the built-in keys.
    public var symbol: String { Self.symbol(for: key) }

    public static func symbol(for key: String) -> String {
        switch key {
        case "housing": "house"
        case "food": "cart"
        case "transport": "car"
        case "personal_health": "heart"
        case "leisure": "theatermasks"
        case "shopping_clothing": "tshirt"
        case "education": "graduationcap"
        case "subscriptions": "repeat"
        case "financial_other", "savings": "banknote"
        case "Erwerbseinkommen": "briefcase"
        case "Kapitalerträge": "chart.line.uptrend.xyaxis"
        default: "eurosign.circle"
        }
    }
}

public struct BudgetSummary: Sendable, Hashable, Decodable {
    public struct CategoryTotal: Sendable, Hashable, Decodable, Identifiable {
        public let category: String
        public let income: Double
        public let expenses: Double
        public var id: String { category }
    }

    public struct Pending: Sendable, Hashable, Decodable {
        public let count: Int
        public let income: Double
        public let expenses: Double
    }

    /// `YYYY-MM`.
    public let month: String
    public let income: Double
    /// Negative.
    public let expenses: Double
    public let balance: Double
    public let byCategory: [CategoryTotal]
    public let pending: Pending?

    /// Spending per category, biggest first (amounts made positive).
    public var spending: [(category: String, amount: Double)] {
        byCategory.filter { $0.expenses < 0 }
            .map { ($0.category, -$0.expenses) }
            .sorted { $0.1 > $1.1 }
    }
}

public struct BudgetDraft: Sendable, Equatable, Encodable {
    public var title: String
    /// Signed like the server stores it.
    public var amount: Double
    public var category: String
    /// `YYYY-MM-DD`.
    public var date: String

    public init(title: String, amount: Double, category: String, date: String) {
        self.title = title; self.amount = amount; self.category = category; self.date = date
    }

    public init(_ entry: BudgetEntry) {
        self.init(title: entry.title ?? "", amount: entry.amount, category: entry.category, date: entry.date)
    }

    /// Reads "12,50", "12.5", "1 234,00 €" → 12.5 / 1234. Nil when it isn't a positive amount.
    public static func parseAmount(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard !cleaned.isEmpty else { return nil }
        // The last separator is the decimal one; others group thousands.
        let separators = cleaned.indices.filter { cleaned[$0] == "," || cleaned[$0] == "." }
        var normalized = cleaned
        if let last = separators.last, cleaned.distance(from: last, to: cleaned.endIndex) <= 3 {
            let whole = cleaned[..<last].filter(\.isNumber)
            let fraction = cleaned[cleaned.index(after: last)...]
            normalized = "\(whole).\(fraction)"
        } else {
            normalized = cleaned.filter(\.isNumber)
        }
        guard let value = Double(normalized), value > 0 else { return nil }
        return (value * 100).rounded() / 100
    }

    /// `YYYY-MM` of a date in the device's calendar.
    public static func monthKey(_ date: Date = .now, calendar: Calendar = .current) -> String {
        String(TodayBuckets.dayKey(date, calendar: calendar).prefix(7))
    }
}

// MARK: - Endpoints

extension YuvomiClient {
    public func budgetSummary(month: String) async throws -> BudgetSummary {
        try await http.send("GET", "api/v1/budget/summary", query: [URLQueryItem(name: "month", value: month)],
                            as: DataEnvelope<BudgetSummary>.self).data
    }

    /// Newest first, including bookings the server projects from subscriptions.
    public func budgetEntries(month: String) async throws -> [BudgetEntry] {
        try await http.send("GET", "api/v1/budget", query: [URLQueryItem(name: "month", value: month)],
                            as: DataEnvelope<[BudgetEntry]>.self).data
    }

    public func budgetCategories() async throws -> [BudgetCategory] {
        try await http.send("GET", "api/v1/budget/categories", query: [URLQueryItem(name: "lang", value: "fr")],
                            as: DataEnvelope<[BudgetCategory]>.self).data
    }

    public func createBudgetEntry(_ draft: BudgetDraft) async throws -> BudgetEntry {
        try await http.send("POST", "api/v1/budget", body: draft,
                            headers: ["Idempotency-Key": UUID().uuidString],
                            as: DataEnvelope<BudgetEntry>.self).data
    }

    public func updateBudgetEntry(_ id: Int, _ draft: BudgetDraft) async throws -> BudgetEntry {
        try await http.send("PUT", "api/v1/budget/\(id)", body: draft, as: DataEnvelope<BudgetEntry>.self).data
    }

    public func deleteBudgetEntry(_ id: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/budget/\(id)", as: Empty.self)
    }
}
