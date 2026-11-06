import SwiftUI
import YuvomiKit

struct ActualBudgetView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transactions = "Transactions"
        case envelopes = "Enveloppes"
        case accounts = "Comptes"
        var id: Self { self }
    }

    @State private var model: ActualModel
    @State private var tab: Tab = .transactions
    @State private var editor: EditorRoute?
    @State private var loaded = false
    @Environment(\.scenePhase) private var scenePhase

    init(config: ActualConfig) {
        _model = State(initialValue: ActualModel(config: config))
    }

    struct EditorRoute: Identifiable {
        let transaction: ActualTransaction?
        var id: String { transaction?.id ?? "new" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader("Budget", eyebrow: "Synchronisé avec Actual") {
                    Button {
                        Task { await model.bankSync() }
                    } label: {
                        RoundIcon(systemImage: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, isActive: model.isSyncing)
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    .accessibilityLabel("Synchroniser la banque")
                    .disabled(model.isSyncing)
                    RoundIconButton(title: "Nouvelle transaction", systemImage: "plus", prominent: true) {
                        editor = EditorRoute(transaction: nil)
                    }
                    .keyboardShortcut("n")
                    .disabled(model.accounts.isEmpty)
                }
                MonthSwitcher(title: model.monthTitle, isCurrent: model.isCurrentMonth) { months in
                    Task { await model.move(by: months) }
                } today: {
                    Task { await model.goToCurrentMonth() }
                }
                if let summary = model.summary {
                    MonthTray(summary: summary, uncategorized: model.uncategorizedCount).riseIn()
                }
                PillPicker(options: Tab.allCases.map { (value: $0, label: $0.rawValue) }, selection: $tab)
                switch tab {
                case .transactions: transactionTrays
                case .envelopes: envelopeTrays
                case .accounts: accountTray
                }
                if model.isLoading && model.summary == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.ySnappy, value: tab)
            .animation(.ySnappy, value: model.transactions)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenChrome(title: model.monthTitle)
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .keyboardShortcut("r")
            }
        }
        #endif
        .sheet(item: $editor) { route in
            NavigationStack { ActualTransactionEditor(model: model, transaction: route.transaction) }
                #if os(macOS)
                .frame(minWidth: 440, minHeight: 460)
                #endif
        }
        .refreshable { await model.load() }
        .task {
            await model.load()
            loaded = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Actual Budget", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Transactions

    @ViewBuilder private var transactionTrays: some View {
        Tray {
            TrayField(placeholder: "Rechercher une transaction", text: $model.search, systemImage: "magnifyingglass")
        }
        if model.transactions.isEmpty && !model.isLoading && loaded {
            EmptyTray(title: "Aucune transaction", systemImage: "tray", message: "Rien ce mois-ci pour l'instant.")
        } else if !model.transactions.isEmpty && model.days.isEmpty {
            EmptyTray(title: "Aucun résultat", systemImage: "magnifyingglass",
                      message: "Aucune transaction ne correspond à « \(model.search) ».")
        }
        ForEach(Array(model.days.enumerated()), id: \.element.day) { index, day in
            Tray {
                TrayHeader(BudgetView.dayTitle(day.day)) {
                    Text(Cents.format(day.items.reduce(0) { $0 + $1.amount }, sign: true))
                        .monospacedDigit()
                }
                ForEach(day.items) { t in
                    Button { editor = EditorRoute(transaction: t) } label: { TransactionTrayRow(t: t, model: model) }
                        .buttonStyle(.pressable)
                        .disabled(t.isSplit)
                        .opacity(t.isSplit ? 0.6 : 1)
                        .contextMenu { categorizeMenu(t) }
                        .accessibilityAction(named: "Supprimer") { Task { await model.delete(t) } }
                }
            }
            .riseIn(delay: 0.06 + Double(min(index, 5)) * 0.04)
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
        if !t.isSplit {
            Button("Modifier", systemImage: "pencil") { editor = EditorRoute(transaction: t) }
        }
        Button("Supprimer", systemImage: "trash", role: .destructive) { Task { await model.delete(t) } }
    }

    // MARK: Enveloppes

    @ViewBuilder private var envelopeTrays: some View {
        let groups = model.summary?.expenseGroups ?? []
        if groups.isEmpty && !model.isLoading && loaded {
            EmptyTray(title: "Aucune enveloppe", systemImage: "tray.full")
        }
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            Tray {
                TrayHeader(group.name) {
                    Text(Cents.format(group.balance)).monospacedDigit()
                }
                ForEach(group.categories.filter { !$0.hidden }) { EnvelopeTrayRow(category: $0) }
            }
            .riseIn(delay: Double(min(index, 5)) * 0.04)
        }
    }

    // MARK: Comptes

    private var accountTray: some View {
        Tray {
            TrayHeader("Comptes") { Text("Soldes non pointés inclus") }
            ForEach(model.visibleAccounts) { account in
                HStack(spacing: 14) {
                    Image(systemName: account.offbudget ? "building.columns" : "creditcard")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Palette.tray, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).font(Typo.body).lineLimit(1)
                        if account.offbudget {
                            Text("Hors budget").font(Typo.caption).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let balance = account.workingBalance {
                        Text(Cents.format(balance))
                            .font(Typo.body)
                            .monospacedDigit()
                            .foregroundStyle(balance < 0 ? Color.red : Palette.ink)
                    }
                }
                .trayRow(minHeight: 60, leading: 12)
                .accessibilityElement(children: .combine)
            }
        }
        .riseIn()
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Le plateau noir : ce qu'il reste à budgéter, puis revenus, dépensé et budgété.
private struct MonthTray: View {
    let summary: ActualMonth
    let uncategorized: Int

    var body: some View {
        Tray(style: .active) {
            Text(summary.toBudget >= 0 ? "À BUDGÉTER" : "TROP BUDGÉTÉ")
                .font(Typo.eyebrow)
                .tracking(0.8)
                .foregroundStyle(Palette.onActiveSecondary)
            Text(Cents.format(summary.toBudget))
                .font(Typo.screenTitle)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(summary.toBudget)))
            HStack(spacing: 8) {
                figure("Revenus", summary.totalIncome, symbol: "arrow.down.left")
                figure("Dépensé", -summary.totalSpent, symbol: "arrow.up.right")
                figure("Budgété", abs(summary.totalBudgeted), symbol: "tray.full")
            }
            .padding(.top, 4)
            if uncategorized > 0 {
                Label("\(uncategorized) transaction\(uncategorized > 1 ? "s" : "") à catégoriser",
                      systemImage: "tray.and.arrow.down")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Palette.accent, in: .capsule)
                    .padding(.top, 4)
            }
        }
    }

    private func figure(_ title: String, _ cents: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(Typo.eyebrow)
                .foregroundStyle(Palette.onActiveSecondary)
                .lineLimit(1)
            Text(Cents.format(cents))
                .font(Typo.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.activeTrayInset, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

private struct TransactionTrayRow: View {
    let t: ActualTransaction
    let model: ActualModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.payeeName(t))
                    .font(Typo.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let category = model.categoryName(t) {
                        Text(category)
                            .foregroundStyle(t.category == nil && !t.isSplit ? Palette.accentSoftText : Palette.inkSecondary)
                    }
                    Text("· \(model.accountName(t.account))")
                    if !t.cleared { Image(systemName: "clock").accessibilityLabel("Non pointée") }
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Cents.format(t.amount, sign: true))
                .font(Typo.body)
                .monospacedDigit()
                .foregroundStyle(t.amount > 0 ? Palette.accentSoftText : Palette.ink)
        }
        .trayRow(minHeight: 60)
        .contentShape(.rect(cornerRadius: Radius.row))
    }
}

private struct EnvelopeTrayRow: View {
    let category: ActualCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.name).font(Typo.body).lineLimit(1)
                Spacer(minLength: 8)
                Text(Cents.format(category.balance))
                    .font(Typo.body)
                    .monospacedDigit()
                    .foregroundStyle(category.balance < 0 ? Color.red : (category.balance == 0 ? Palette.inkSecondary : Palette.ink))
            }
            if let progress = category.progress {
                ProgressCapsule(value: progress, warnsAbove: 0.85)
                Text("\(Cents.format(-category.spent)) sur \(Cents.format(category.budgeted))")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else if category.spent != 0 {
                Text("\(Cents.format(-category.spent)) dépensés, rien de budgété")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.vertical, 12)
        .trayRow(minHeight: 60)
        .accessibilityElement(children: .combine)
    }
}
