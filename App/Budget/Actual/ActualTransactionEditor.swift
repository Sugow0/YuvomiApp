import SwiftUI
import YuvomiKit

/// New transaction (amount, payee, category, account) or edit of an existing one.
struct ActualTransactionEditor: View {
    let model: ActualModel
    let transaction: ActualTransaction?

    @State private var isExpense: Bool
    @State private var amountText: String
    @State private var payee: String
    @State private var category: String?
    @State private var account: String
    @State private var notes: String
    @State private var date: Date
    @State private var saving = false
    @FocusState private var amountFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: ActualModel, transaction: ActualTransaction?) {
        self.model = model
        self.transaction = transaction
        _isExpense = State(initialValue: (transaction?.amount ?? -1) <= 0)
        _amountText = State(initialValue: transaction.map {
            (Double(abs($0.amount)) / 100).formatted(.number.precision(.fractionLength(2)))
        } ?? "")
        _payee = State(initialValue: transaction.map { model.payeeName($0) } ?? "")
        _category = State(initialValue: transaction?.category)
        _account = State(initialValue: transaction?.account
            ?? model.visibleAccounts.first { !$0.offbudget }?.id ?? model.visibleAccounts.first?.id ?? "")
        _notes = State(initialValue: transaction?.notes ?? "")
        _date = State(initialValue: transaction.flatMap { Self.date($0.date) } ?? .now)
    }

    private var cents: Int? {
        BudgetDraft.parseAmount(amountText).map { ActualTransactionDraft.cents(isExpense ? -$0 : $0) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Sens", selection: $isExpense) {
                    Text("Dépense").tag(true)
                    Text("Entrée").tag(false)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("0,00", text: $amountText)
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .focused($amountFocused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text("€").font(.title2).foregroundStyle(.secondary)
                }
                if transaction == nil {
                    TextField("Bénéficiaire (boulangerie, Amazon…)", text: $payee)
                } else {
                    LabeledContent("Bénéficiaire", value: payee)
                }
            }
            Section {
                if transaction?.isTransfer != true {
                    Picker("Catégorie", selection: $category) {
                        Text("À catégoriser").tag(String?.none)
                        ForEach(model.categoryGroups) { group in
                            Section(group.name) {
                                ForEach(group.categories.filter { !$0.hidden }) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                }
                if transaction == nil {
                    Picker("Compte", selection: $account) {
                        ForEach(model.visibleAccounts) { Text($0.name).tag($0.id) }
                    }
                } else {
                    LabeledContent("Compte", value: model.accountName(account))
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Note", text: $notes, axis: .vertical)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(transaction == nil ? "Nouvelle transaction" : "Transaction")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(transaction == nil ? "Ajouter" : "Enregistrer", action: save)
                    .disabled(cents == nil || account.isEmpty || saving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { if transaction == nil { amountFocused = true } }
    }

    private func save() {
        guard let cents else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = ActualTransactionDraft(
            date: TodayBuckets.dayKey(date), amount: cents,
            payeeName: trimmedPayee.isEmpty ? nil : trimmedPayee,
            category: category, notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )
        Task {
            saving = true
            let saved = if let transaction {
                await model.update(transaction, draft)
            } else {
                await model.add(account: account, draft)
            }
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
