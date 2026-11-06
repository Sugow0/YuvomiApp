import Foundation
import Observation
import YuvomiKit

/// One month of the household budget.
@MainActor @Observable
final class BudgetModel {
    private let client: YuvomiClient

    /// `YYYY-MM`.
    private(set) var month = BudgetDraft.monthKey()
    private(set) var summary: BudgetSummary?
    private(set) var entries: [BudgetEntry] = []
    private(set) var categories: [BudgetCategory] = []
    private(set) var isLoading = false
    /// The module is switched off or this account may not see it.
    private(set) var unavailable = false
    var search = ""
    var errorMessage: String?

    init(client: YuvomiClient) {
        self.client = client
    }

    var isCurrentMonth: Bool { month == BudgetDraft.monthKey() }

    var monthTitle: String {
        guard let date = Self.date(month) else { return month }
        return date.formatted(.dateTime.month(.wide).year()).capitalized
    }

    func label(_ key: String) -> String {
        categories.first { $0.key == key }?.label ?? (key == "savings" ? "Épargne" : key)
    }

    var expenseCategories: [BudgetCategory] { categories.filter { $0.type == .expense } }
    var incomeCategories: [BudgetCategory] { categories.filter { $0.type == .income } }

    /// Entries grouped by day, newest first, filtered by the search field.
    var days: [(day: String, entries: [BudgetEntry])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? entries : entries.filter {
            ($0.title ?? "").localizedStandardContains(query) || label($0.category).localizedStandardContains(query)
        }
        return Dictionary(grouping: shown, by: \.date)
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if categories.isEmpty { categories = try await client.budgetCategories() }
            async let summary = client.budgetSummary(month: month)
            async let entries = client.budgetEntries(month: month)
            let (s, e) = try await (summary, entries)
            guard s.month == month else { return } // moved to another month meanwhile
            self.summary = s
            self.entries = e
            unavailable = false
        } catch let error as APIError where error.code == 403 || error.code == 404 {
            unavailable = true
        } catch {
            errorMessage = error.userMessage
        }
    }

    func move(by months: Int) async {
        guard let date = Self.date(month),
              let moved = Calendar.current.date(byAdding: .month, value: months, to: date) else { return }
        month = BudgetDraft.monthKey(moved)
        summary = nil
        entries = []
        await load()
    }

    func goToCurrentMonth() async {
        guard !isCurrentMonth else { return }
        month = BudgetDraft.monthKey()
        await load()
    }

    /// - Returns: true once saved.
    func save(id: Int?, _ draft: BudgetDraft) async -> Bool {
        do {
            if let id {
                _ = try await client.updateBudgetEntry(id, draft)
            } else {
                _ = try await client.createBudgetEntry(draft)
            }
            await load()
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func delete(_ entry: BudgetEntry) async {
        guard let id = entry.serverID else { return }
        entries.removeAll { $0.id == entry.id }
        do {
            try await client.deleteBudgetEntry(id)
            await load()
        } catch {
            errorMessage = error.userMessage
            await load()
        }
    }

    private static func date(_ month: String) -> Date? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }
}

enum Money {
    /// The household currency is EUR for this instance; amounts show with the device's locale.
    static func format(_ amount: Double, sign: Bool = false) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "EUR")
        return sign && amount > 0 ? "+" + amount.formatted(style) : amount.formatted(style)
    }
}
