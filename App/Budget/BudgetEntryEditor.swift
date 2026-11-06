import SwiftUI
import YuvomiKit

/// Quick entry: amount first, then what and which category. Expense by default.
struct BudgetEntryEditor: View {
    let model: BudgetModel
    let entry: BudgetEntry?

    @State private var isExpense: Bool
    @State private var amountText: String
    @State private var title: String
    @State private var category: String
    @State private var date: Date
    @State private var saving = false
    @FocusState private var amountFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: BudgetModel, entry: BudgetEntry?) {
        self.model = model
        self.entry = entry
        _isExpense = State(initialValue: entry?.isExpense ?? true)
        _amountText = State(initialValue: entry.map { abs($0.amount).formatted(.number.precision(.fractionLength(2))) } ?? "")
        _title = State(initialValue: entry?.title ?? "")
        _category = State(initialValue: entry?.category ?? "")
        _date = State(initialValue: entry.flatMap { Self.date($0.date) } ?? .now)
    }

    private var amount: Double? { BudgetDraft.parseAmount(amountText) }
    private var choices: [BudgetCategory] { isExpense ? model.expenseCategories : model.incomeCategories }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $isExpense) {
                    Text("Dépense").tag(true)
                    Text("Revenu").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: isExpense) { pickDefaultCategory() }
                HStack {
                    TextField("0,00", text: $amountText)
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .focused($amountFocused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text("€").font(.title2).foregroundStyle(.secondary)
                }
                TextField(isExpense ? "Pour quoi ? (boulangerie, essence…)" : "D'où ? (salaire, remboursement…)",
                          text: $title)
            }
            Section("Catégorie") {
                Picker("Catégorie", selection: $category) {
                    ForEach(choices) { Label($0.label, systemImage: $0.symbol).tag($0.key) }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entry == nil ? "Nouvelle opération" : "Modifier l'opération")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(entry == nil ? "Ajouter" : "Enregistrer", action: save)
                    .disabled(amount == nil || category.isEmpty || saving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear {
            if category.isEmpty { pickDefaultCategory() }
            if entry == nil { amountFocused = true }
        }
    }

    private func pickDefaultCategory() {
        if !choices.contains(where: { $0.key == category }) {
            category = choices.first { $0.key == (isExpense ? "food" : "Erwerbseinkommen") }?.key ?? choices.first?.key ?? ""
        }
    }

    private func save() {
        guard let amount else { return }
        let draft = BudgetDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: isExpense ? -amount : amount,
            category: category,
            date: TodayBuckets.dayKey(date)
        )
        Task {
            saving = true
            let saved = await model.save(id: entry?.serverID, draft)
            saving = false
            if saved { dismiss() }
        }
    }

    private static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
