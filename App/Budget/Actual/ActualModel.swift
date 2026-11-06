import Foundation
import Observation
import YuvomiKit

/// One month of an Actual Budget file: envelopes and bank transactions.
@MainActor @Observable
final class ActualModel {
    let client: ActualClient

    private(set) var month = BudgetDraft.monthKey()
    private(set) var summary: ActualMonth?
    private(set) var transactions: [ActualTransaction] = []
    private(set) var accounts: [ActualAccount] = []
    private(set) var payees: [String: ActualPayee] = [:]
    private(set) var isLoading = false
    private(set) var isSyncing = false
    var search = ""
    var errorMessage: String?

    init(config: ActualConfig) {
        client = ActualClient(config: config)
    }

    var isCurrentMonth: Bool { month == BudgetDraft.monthKey() }

    var monthTitle: String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return month }
        return date.formatted(.dateTime.month(.wide).year()).capitalized
    }

    private var categories: [String: ActualCategory] { summary?.categoriesByID ?? [:] }

    /// Categories offered when filing a transaction, grouped like in Actual.
    var categoryGroups: [ActualCategoryGroup] { summary?.categoryGroups.filter { !$0.hidden } ?? [] }

    func payeeName(_ t: ActualTransaction) -> String {
        if let id = t.payee, let payee = payees[id] {
            if let account = payee.transferAcct { return "Virement · \(accountName(account))" }
            return payee.name
        }
        return t.importedPayee ?? t.notes ?? "Sans bénéficiaire"
    }

    func categoryName(_ t: ActualTransaction) -> String? {
        if t.isSplit { return "Ventilée" }
        if t.isTransfer { return nil }
        guard let id = t.category else { return "À catégoriser" }
        return categories[id]?.name
    }

    func accountName(_ id: String) -> String { accounts.first { $0.id == id }?.name ?? "Compte" }

    var uncategorizedCount: Int {
        transactions.filter { $0.category == nil && !$0.isTransfer && !$0.isSplit && !isStartingBalance($0) }.count
    }

    private func isStartingBalance(_ t: ActualTransaction) -> Bool {
        t.payee.flatMap { payees[$0]?.name } == "Starting Balance"
    }

    var days: [(day: String, items: [ActualTransaction])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? transactions : transactions.filter {
            payeeName($0).localizedStandardContains(query)
                || (categoryName($0) ?? "").localizedStandardContains(query)
                || ($0.notes ?? "").localizedStandardContains(query)
        }
        return Dictionary(grouping: shown, by: \.date).sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    /// Budget accounts first; off-budget (savings, loans) after.
    var visibleAccounts: [ActualAccount] { accounts.sorted { ($0.offbudget ? 1 : 0, $0.name) < ($1.offbudget ? 1 : 0, $1.name) } }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let accounts = client.accounts()
            async let payees = client.payees()
            async let summary = client.month(month)
            let (a, p, s) = try await (accounts, payees, summary)
            guard s.month == month else { return }
            self.accounts = a
            self.payees = Dictionary(p.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            self.summary = s
            transactions = try await client.transactions(month: month, accounts: a.filter { !$0.offbudget })
        } catch {
            errorMessage = error.userMessage
        }
    }

    func move(by months: Int) async {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let moved = Calendar.current.date(byAdding: .month, value: months, to: date) else { return }
        month = BudgetDraft.monthKey(moved)
        summary = nil
        transactions = []
        await load()
    }

    func goToCurrentMonth() async {
        month = BudgetDraft.monthKey()
        await load()
    }

    /// Asks the bank for new transactions, then reloads once Actual had time to import them.
    func bankSync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await client.runBankSync()
            try? await Task.sleep(for: .seconds(4))
            await load()
        } catch {
            errorMessage = error.userMessage
        }
    }

    // MARK: - Edits

    func add(account: String, _ draft: ActualTransactionDraft) async -> Bool {
        do {
            try await client.addTransaction(account: account, draft)
            await load()
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func update(_ t: ActualTransaction, _ draft: ActualTransactionDraft) async -> Bool {
        do {
            try await client.updateTransaction(t.id, draft)
            await load()
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    /// One tap from the list: file a transaction under a category.
    func categorize(_ t: ActualTransaction, as category: String) async {
        if let i = transactions.firstIndex(where: { $0.id == t.id }) { transactions[i].category = category }
        let draft = ActualTransactionDraft(date: t.date, amount: t.amount, category: category, notes: t.notes)
        _ = await update(t, draft)
    }

    func delete(_ t: ActualTransaction) async {
        transactions.removeAll { $0.id == t.id }
        do {
            try await client.deleteTransaction(t.id)
        } catch {
            errorMessage = error.userMessage
        }
        await load()
    }
}

enum Cents {
    static func format(_ cents: Int, sign: Bool = false) -> String {
        Money.format(Double(cents) / 100, sign: sign)
    }
}
