import SwiftUI
import YuvomiKit

struct ActualBudgetView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transactions = "Transactions"
        case envelopes = "Budget"
        case accounts = "Comptes"
        var id: Self { self }
    }

    @State private var model: ActualModel
    @State private var tab: Tab = .transactions
    @State private var editor: EditorRoute?
    @Environment(\.scenePhase) private var scenePhase

    init(config: ActualConfig) {
        _model = State(initialValue: ActualModel(config: config))
    }

    struct EditorRoute: Identifiable {
        let transaction: ActualTransaction?
        var id: String { transaction?.id ?? "new" }
    }

    var body: some View {
        List {
            Section {
                Picker("Vue", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let summary = model.summary { Section { MonthCard(summary: summary, uncategorized: model.uncategorizedCount) } }
            switch tab {
            case .transactions: transactionSections
            case .envelopes: envelopeSections
            case .accounts: accountSection
            }
        }
        .overlay {
            if model.isLoading && model.summary == nil { ProgressView() }
        }
        .searchable(text: $model.search, prompt: "Rechercher une transaction")
        .navigationTitle(model.monthTitle)
        .toolbar { toolbar }
        .sheet(item: $editor) { route in
            NavigationStack { ActualTransactionEditor(model: model, transaction: route.transaction) }
                #if os(macOS)
                .frame(minWidth: 440, minHeight: 460)
                #endif
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Actual Budget", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Sections

    @ViewBuilder private var transactionSections: some View {
        if model.transactions.isEmpty && !model.isLoading {
            Section { Text("Aucune transaction ce mois-ci.").foregroundStyle(.secondary) }
        }
        ForEach(model.days, id: \.day) { day in
            Section(BudgetView.dayTitle(day.day)) {
                ForEach(day.items) { t in
                    Button { editor = EditorRoute(transaction: t) } label: { TransactionRow(t: t, model: model) }
                        .buttonStyle(.plain)
                        .disabled(t.isSplit)
                        .swipeActions {
                            Button("Supprimer", systemImage: "trash", role: .destructive) { Task { await model.delete(t) } }
                        }
                        .contextMenu { categorizeMenu(t) }
                }
            }
        }
    }

    @ViewBuilder private func categorizeMenu(_ t: ActualTransaction) -> some View {
        if !t.isTransfer && !t.isSplit {
            Menu("Catégorie", systemImage: "folder") {
                ForEach(model.categoryGroups) { group in
                    Section(group.name) {
                        ForEach(group.categories.filter { !$0.hidden }) { category in
                            Button(category.name) { Task { await model.categorize(t, as: category.id) } }
                        }
                    }
                }
            }
        }
        Button("Modifier", systemImage: "pencil") { editor = EditorRoute(transaction: t) }
        Button("Supprimer", systemImage: "trash", role: .destructive) { Task { await model.delete(t) } }
    }

    @ViewBuilder private var envelopeSections: some View {
        ForEach(model.summary?.expenseGroups ?? []) { group in
            Section {
                ForEach(group.categories.filter { !$0.hidden }) { EnvelopeRow(category: $0) }
            } header: {
                HStack {
                    Text(group.name)
                    Spacer()
                    Text(Cents.format(group.balance)).monospacedDigit()
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            ForEach(model.visibleAccounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                        if account.offbudget { Text("Hors budget").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let balance = account.workingBalance {
                        Text(Cents.format(balance)).monospacedDigit()
                            .foregroundStyle(balance < 0 ? .red : .primary)
                    }
                }
            }
        } footer: {
            Text("Soldes incluant les opérations non pointées.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Mois précédent", systemImage: "chevron.left") { Task { await model.move(by: -1) } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Mois suivant", systemImage: "chevron.right") { Task { await model.move(by: 1) } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        ToolbarItem {
            Button {
                Task { await model.bankSync() }
            } label: {
                Label("Synchroniser la banque", systemImage: "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, isActive: model.isSyncing)
            }
            .disabled(model.isSyncing)
        }
        if !model.isCurrentMonth {
            ToolbarItem(placement: .secondaryAction) {
                Button("Ce mois-ci") { Task { await model.goToCurrentMonth() } }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Nouvelle transaction", systemImage: "plus") { editor = EditorRoute(transaction: nil) }
                .keyboardShortcut("n")
                .disabled(model.accounts.isEmpty)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct MonthCard: View {
    let summary: ActualMonth
    let uncategorized: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.toBudget >= 0 ? "À budgéter" : "Trop budgété").font(.caption).foregroundStyle(.secondary)
                Text(Cents.format(summary.toBudget))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(summary.toBudget < 0 ? .red : .primary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 24) {
                figure("Revenus", summary.totalIncome, color: .green, symbol: "arrow.down.left")
                figure("Dépensé", -summary.totalSpent, color: .red, symbol: "arrow.up.right")
                figure("Budgété", summary.totalBudgeted < 0 ? -summary.totalBudgeted : summary.totalBudgeted,
                       color: .secondary, symbol: "tray.full")
            }
            if uncategorized > 0 {
                Label("\(uncategorized) transaction\(uncategorized > 1 ? "s" : "") à catégoriser", systemImage: "tray.and.arrow.down")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func figure(_ title: String, _ cents: Int, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(Cents.format(cents)).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct TransactionRow: View {
    let t: ActualTransaction
    let model: ActualModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.payeeName(t)).lineLimit(1)
                HStack(spacing: 4) {
                    if let category = model.categoryName(t) {
                        Text(category).foregroundStyle(t.category == nil && !t.isSplit ? .orange : .secondary)
                    }
                    Text("· \(model.accountName(t.account))")
                    if !t.cleared { Image(systemName: "clock").accessibilityLabel("Non pointée") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Cents.format(t.amount, sign: true))
                .monospacedDigit()
                .foregroundStyle(t.amount > 0 ? Color.green : Color.primary)
        }
        .contentShape(.rect)
    }
}

private struct EnvelopeRow: View {
    let category: ActualCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(category.name)
                Spacer()
                Text(Cents.format(category.balance))
                    .monospacedDigit().font(.callout.weight(.semibold))
                    .foregroundStyle(category.balance < 0 ? .red : category.balance == 0 ? .secondary : .green)
            }
            if let progress = category.progress {
                ProgressView(value: min(progress, 1))
                    .tint(progress > 1 ? .red : progress > 0.85 ? .orange : .accentColor)
                Text("\(Cents.format(-category.spent)) sur \(Cents.format(category.budgeted))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if category.spent != 0 {
                Text("\(Cents.format(-category.spent)) dépensés, rien de budgété")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
