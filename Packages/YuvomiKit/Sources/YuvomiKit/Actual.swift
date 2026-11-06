import Foundation

// Actual Budget through actual-http-api (github.com/jhonderson/actual-http-api).
// Amounts are integer cents, negative for money going out.

// MARK: - Configuration

public struct ActualConfig: Sendable, Codable, Equatable {
    public var server: ServerURL
    public var apiKey: String
    /// The budget's sync id (`groupId` in `GET /v1/budgets`).
    public var budgetID: String
    public var budgetName: String
    /// Only for end-to-end encrypted budgets.
    public var encryptionPassword: String?

    public init(server: ServerURL, apiKey: String, budgetID: String, budgetName: String, encryptionPassword: String? = nil) {
        self.server = server; self.apiKey = apiKey; self.budgetID = budgetID
        self.budgetName = budgetName; self.encryptionPassword = encryptionPassword
    }
}

/// Keeps the configuration in the shared keychain (it holds the API key).
public enum ActualStore {
    private static let account = "actual"

    public static func load() -> ActualConfig? {
        guard let data = try? AppGroup.credentialStore().secret(account) else { return nil }
        return try? JSONDecoder().decode(ActualConfig.self, from: data)
    }

    public static func save(_ config: ActualConfig) throws {
        try AppGroup.credentialStore().setSecret(account, JSONEncoder().encode(config))
    }

    public static func clear() {
        try? AppGroup.credentialStore().removeSecret(account)
    }
}

// MARK: - Models

public struct ActualBudgetFile: Sendable, Hashable, Identifiable, Decodable {
    public let groupId: String?
    public let cloudFileId: String?
    public let name: String
    public var id: String { groupId ?? cloudFileId ?? name }
}

public struct ActualAccount: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let offbudget: Bool
    public let closed: Bool
    /// Cents, with `include_balances=true`.
    public let workingBalance: Int?

    enum CodingKeys: String, CodingKey { case id, name, offbudget, closed, workingBalance, balance }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        offbudget = c.flag(.offbudget)
        closed = c.flag(.closed)
        workingBalance = (try? c.decodeIfPresent(Int.self, forKey: .workingBalance))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .balance))
    }

    public init(id: String, name: String, offbudget: Bool = false, closed: Bool = false, workingBalance: Int? = nil) {
        self.id = id; self.name = name; self.offbudget = offbudget; self.closed = closed; self.workingBalance = workingBalance
    }
}

public struct ActualCategory: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let isIncome: Bool
    public let hidden: Bool
    /// This month, cents. `spent` is negative.
    public let budgeted: Int
    public let spent: Int
    public let balance: Int

    enum CodingKeys: String, CodingKey { case id, name, isIncome, hidden, budgeted, spent, balance }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isIncome = c.flag(.isIncome)
        hidden = c.flag(.hidden)
        budgeted = (try? c.decode(Int.self, forKey: .budgeted)) ?? 0
        spent = (try? c.decode(Int.self, forKey: .spent)) ?? 0
        balance = (try? c.decode(Int.self, forKey: .balance)) ?? 0
    }

    /// Share of the budgeted amount already spent; nil without a budget.
    public var progress: Double? {
        budgeted > 0 ? min(Double(-spent) / Double(budgeted), 1.5) : nil
    }
}

public struct ActualCategoryGroup: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let isIncome: Bool
    public let hidden: Bool
    public let budgeted: Int
    public let spent: Int
    public let balance: Int
    public let categories: [ActualCategory]

    enum CodingKeys: String, CodingKey { case id, name, isIncome, hidden, budgeted, spent, balance, categories }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isIncome = c.flag(.isIncome)
        hidden = c.flag(.hidden)
        budgeted = (try? c.decode(Int.self, forKey: .budgeted)) ?? 0
        spent = (try? c.decode(Int.self, forKey: .spent)) ?? 0
        balance = (try? c.decode(Int.self, forKey: .balance)) ?? 0
        categories = (try? c.decode([ActualCategory].self, forKey: .categories)) ?? []
    }
}

public struct ActualMonth: Sendable, Hashable, Decodable {
    /// `YYYY-MM`.
    public let month: String
    public let toBudget: Int
    public let totalBudgeted: Int
    public let totalIncome: Int
    /// Negative.
    public let totalSpent: Int
    public let totalBalance: Int
    public let categoryGroups: [ActualCategoryGroup]

    enum CodingKeys: String, CodingKey { case month, toBudget, totalBudgeted, totalIncome, totalSpent, totalBalance, categoryGroups }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        toBudget = (try? c.decode(Int.self, forKey: .toBudget)) ?? 0
        totalBudgeted = (try? c.decode(Int.self, forKey: .totalBudgeted)) ?? 0
        totalIncome = (try? c.decode(Int.self, forKey: .totalIncome)) ?? 0
        totalSpent = (try? c.decode(Int.self, forKey: .totalSpent)) ?? 0
        totalBalance = (try? c.decode(Int.self, forKey: .totalBalance)) ?? 0
        categoryGroups = (try? c.decode([ActualCategoryGroup].self, forKey: .categoryGroups)) ?? []
    }

    /// Expense groups and categories worth showing.
    public var expenseGroups: [ActualCategoryGroup] {
        categoryGroups.filter { !$0.isIncome && !$0.hidden && !$0.categories.allSatisfy(\.hidden) }
    }

    public var categoriesByID: [String: ActualCategory] {
        Dictionary(categoryGroups.flatMap(\.categories).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

public struct ActualTransaction: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let account: String
    /// `YYYY-MM-DD`.
    public var date: String
    public var amount: Int
    public let payee: String?
    public let importedPayee: String?
    public var category: String?
    public var notes: String?
    public let transferId: String?
    public let isParent: Bool
    public let cleared: Bool
    public let subtransactions: [ActualTransaction]

    enum CodingKeys: String, CodingKey {
        case id, account, date, amount, payee, importedPayee, category, notes, transferId, isParent, cleared, subtransactions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        account = (try? c.decode(String.self, forKey: .account)) ?? ""
        date = try c.decode(String.self, forKey: .date)
        amount = (try? c.decode(Int.self, forKey: .amount)) ?? 0
        payee = try? c.decodeIfPresent(String.self, forKey: .payee)
        importedPayee = try? c.decodeIfPresent(String.self, forKey: .importedPayee)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        transferId = try? c.decodeIfPresent(String.self, forKey: .transferId)
        isParent = c.flag(.isParent)
        cleared = c.flag(.cleared)
        subtransactions = (try? c.decode([ActualTransaction].self, forKey: .subtransactions)) ?? []
    }

    public var isTransfer: Bool { transferId != nil }
    public var isSplit: Bool { isParent || !subtransactions.isEmpty }
}

public struct ActualPayee: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    /// Set for the payees Actual creates to stand for an account (transfers).
    public let transferAcct: String?
}

/// What the app sends to create or change a transaction.
public struct ActualTransactionDraft: Sendable, Equatable {
    public var date: String
    /// Cents, negative for an expense.
    public var amount: Int
    /// Only used on creation: Actual finds or creates the payee.
    public var payeeName: String?
    public var category: String?
    public var notes: String?

    public init(date: String, amount: Int, payeeName: String? = nil, category: String?, notes: String? = nil) {
        self.date = date; self.amount = amount; self.payeeName = payeeName; self.category = category; self.notes = notes
    }

    /// 12.5 → 1250.
    public static func cents(_ euros: Double) -> Int { Int((euros * 100).rounded()) }
}

// MARK: - Client

public enum ActualError: Error, Sendable, Equatable, LocalizedError {
    case rejectedKey
    case server(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .rejectedKey: "Clé API refusée par actual-http-api."
        case let .server(status, message?): "Actual (\(status)) : \(message)"
        case let .server(status, nil): "actual-http-api a répondu \(status)."
        }
    }
}

public struct ActualClient: Sendable {
    public let config: ActualConfig
    private let http: HTTP

    public init(config: ActualConfig, session: URLSession = YuvomiClient.session) {
        self.config = config
        http = HTTP(server: config.server, session: session, bearer: nil)
    }

    /// Budget files on the Actual server, to pick one during setup.
    public static func budgets(server: ServerURL, apiKey: String, session: URLSession = YuvomiClient.session) async throws -> [ActualBudgetFile] {
        let http = HTTP(server: server, session: session, bearer: nil)
        return try await call { try await http.send("GET", "v1/budgets", headers: ["x-api-key": apiKey], as: DataEnvelope<[ActualBudgetFile]>.self).data }
    }

    private var headers: [String: String] {
        var h = ["x-api-key": config.apiKey]
        if let password = config.encryptionPassword, !password.isEmpty { h["budget-encryption-password"] = password }
        return h
    }

    private func path(_ rest: String) -> String { "v1/budgets/\(config.budgetID)/\(rest)" }

    public func accounts() async throws -> [ActualAccount] {
        try await Self.call {
            try await http.send("GET", path("accounts"),
                                query: [URLQueryItem(name: "include_balances", value: "true"),
                                        URLQueryItem(name: "exclude_closed", value: "true")],
                                headers: headers, as: DataEnvelope<[ActualAccount]>.self).data
        }
    }

    public func month(_ month: String) async throws -> ActualMonth {
        try await Self.call {
            try await http.send("GET", path("months/\(month)"), headers: headers, as: DataEnvelope<ActualMonth>.self).data
        }
    }

    public func payees() async throws -> [ActualPayee] {
        try await Self.call { try await http.send("GET", path("payees"), headers: headers, as: DataEnvelope<[ActualPayee]>.self).data }
    }

    /// - Parameters: dates `YYYY-MM-DD`, inclusive.
    public func transactions(account: String, from: String, to: String) async throws -> [ActualTransaction] {
        try await Self.call {
            try await http.send("GET", path("accounts/\(account)/transactions"),
                                query: [URLQueryItem(name: "since_date", value: from),
                                        URLQueryItem(name: "until_date", value: to)],
                                headers: headers, as: DataEnvelope<[ActualTransaction]>.self).data
        }
    }

    /// Every on-budget account's transactions in a month, newest first.
    public func transactions(month: String, accounts: [ActualAccount]) async throws -> [ActualTransaction] {
        let (from, to) = Self.range(month)
        return try await withThrowingTaskGroup(of: [ActualTransaction].self) { group in
            for account in accounts where !account.closed {
                group.addTask { try await transactions(account: account.id, from: from, to: to) }
            }
            var all: [ActualTransaction] = []
            for try await batch in group { all += batch }
            return all.sorted { $0.date > $1.date }
        }
    }

    public func addTransaction(account: String, _ draft: ActualTransactionDraft) async throws {
        struct Body: Encodable, Sendable, VerbatimKeys {
            let learnCategories = true
            let runTransfers = false
            let transaction: Fields
        }
        _ = try await Self.call {
            try await http.send("POST", path("accounts/\(account)/transactions"),
                                body: Body(transaction: Fields(draft, account: account, creating: true)),
                                headers: headers, as: Message.self)
        }
    }

    public func updateTransaction(_ id: String, _ draft: ActualTransactionDraft) async throws {
        struct Body: Encodable, Sendable, VerbatimKeys { let transaction: Fields }
        _ = try await Self.call {
            try await http.send("PATCH", path("transactions/\(id)"),
                                body: Body(transaction: Fields(draft, account: nil, creating: false)),
                                headers: headers, as: Message.self)
        }
    }

    public func deleteTransaction(_ id: String) async throws {
        _ = try await Self.call { try await http.send("DELETE", path("transactions/\(id)"), headers: headers, as: Message.self) }
    }

    /// Asks Actual to fetch new bank transactions (GoCardless / SimpleFIN). Returns once started.
    public func runBankSync() async throws {
        _ = try await Self.call { try await http.send("POST", path("accounts/banksync"), headers: headers, as: Message.self) }
    }

    // MARK: Helpers

    /// `YYYY-MM` → first and last day.
    public static func range(_ month: String) -> (String, String) {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
              let first = Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let days = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: first)
        else { return ("\(month)-01", "\(month)-31") }
        return ("\(month)-01", String(format: "%@-%02d", month, days.count))
    }

    /// Turns the plain-status errors `HTTP` throws into readable ones.
    private static func call<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch ClientError.unexpectedStatus(let status) {
            throw status == 403 || status == 401 ? ActualError.rejectedKey : ActualError.server(status, nil)
        }
    }

    struct Message: Decodable, Sendable { let message: String? }

    struct Fields: Encodable, Sendable {
        let draft: ActualTransactionDraft
        let account: String?
        let creating: Bool

        init(_ draft: ActualTransactionDraft, account: String?, creating: Bool) {
            self.draft = draft; self.account = account; self.creating = creating
        }

        enum CodingKeys: String, CodingKey { case account, date, amount, payee_name, category, notes }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(account, forKey: .account)
            try c.encode(draft.date, forKey: .date)
            try c.encode(draft.amount, forKey: .amount)
            if creating { try c.encodeIfPresent(draft.payeeName, forKey: .payee_name) }
            // Explicit null clears the category when editing.
            if let category = draft.category { try c.encode(category, forKey: .category) } else if !creating { try c.encodeNil(forKey: .category) }
            try c.encodeIfPresent(draft.notes, forKey: .notes)
        }
    }
}
