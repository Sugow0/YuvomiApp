import Charts
import SwiftUI
import YuvomiKit

struct BudgetView: View {
    @State private var model: BudgetModel
    @State private var editor: EditorRoute?
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient) {
        _model = State(initialValue: BudgetModel(client: client))
    }

    /// nil entry = new one.
    struct EditorRoute: Identifiable {
        let entry: BudgetEntry?
        var id: String { entry?.id ?? "new" }
    }

    var body: some View {
        List {
            if let summary = model.summary {
                Section { SummaryCard(summary: summary) }
                if !summary.spending.isEmpty {
                    Section("Dépenses par catégorie") { SpendingChart(summary: summary, model: model) }
                }
            }
            ForEach(model.days, id: \.day) { day in
                Section(Self.dayTitle(day.day)) {
                    ForEach(day.entries) { entry in
                        Button { if entry.isEditable { editor = EditorRoute(entry: entry) } } label: {
                            EntryRow(entry: entry, categoryLabel: model.label(entry.category))
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if entry.isEditable {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(entry) }
                                }
                            }
                        }
                        .contextMenu {
                            if entry.isEditable {
                                Button("Modifier", systemImage: "pencil") { editor = EditorRoute(entry: entry) }
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(entry) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay { emptyState }
        .searchable(text: $model.search, prompt: "Rechercher une opération")
        .navigationTitle(model.monthTitle)
        .toolbar { toolbar }
        .sheet(item: $editor) { route in
            NavigationStack { BudgetEntryEditor(model: model, entry: route.entry) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 420)
                #endif
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Budget", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.unavailable {
            ContentUnavailableView("Budget indisponible", systemImage: "eurosign.circle",
                                   description: Text("Le module Budget est désactivé ou réservé à d'autres membres du foyer."))
        } else if model.isLoading && model.summary == nil {
            ProgressView()
        } else if model.entries.isEmpty && model.summary != nil {
            ContentUnavailableView("Aucune opération", systemImage: "tray",
                                   description: Text("Ajoutez une dépense avec +."))
                .allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Mois précédent", systemImage: "chevron.left") { Task { await model.move(by: -1) } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Mois suivant", systemImage: "chevron.right") { Task { await model.move(by: 1) } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        if !model.isCurrentMonth {
            ToolbarItem {
                Button("Ce mois-ci") { Task { await model.goToCurrentMonth() } }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Nouvelle opération", systemImage: "plus") { editor = EditorRoute(entry: nil) }
                .keyboardShortcut("n")
                .disabled(model.unavailable)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    static func dayTitle(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return key }
        if Calendar.current.isDateInToday(date) { return "Aujourd'hui" }
        if Calendar.current.isDateInYesterday(date) { return "Hier" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
    }
}

private struct SummaryCard: View {
    let summary: BudgetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Solde du mois").font(.caption).foregroundStyle(.secondary)
                Text(Money.format(summary.balance, sign: true))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(summary.balance < 0 ? .red : .primary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 24) {
                figure("Revenus", summary.income, color: .green, symbol: "arrow.down.left")
                figure("Dépenses", -summary.expenses, color: .red, symbol: "arrow.up.right")
            }
            if let pending = summary.pending, pending.count > 0 {
                Label("\(pending.count) à venir · \(Money.format(pending.income + pending.expenses, sign: true))",
                      systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func figure(_ title: String, _ value: Double, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(Money.format(value)).font(.headline).monospacedDigit()
        }
    }
}

private struct SpendingChart: View {
    let summary: BudgetSummary
    let model: BudgetModel

    var body: some View {
        let rows = Array(summary.spending.prefix(6))
        Chart(rows, id: \.category) { row in
            BarMark(x: .value("Montant", row.amount), y: .value("Catégorie", model.label(row.category)))
                .foregroundStyle(.tint)
                .annotation(position: .trailing) {
                    Text(Money.format(row.amount)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: CGFloat(rows.count) * 34)
        .padding(.vertical, 4)
    }
}

private struct EntryRow: View {
    let entry: BudgetEntry
    let categoryLabel: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BudgetCategory.symbol(for: entry.category))
                .font(.body)
                .foregroundStyle(entry.isExpense ? Color.secondary : Color.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title?.isEmpty == false ? entry.title! : categoryLabel).lineLimit(1)
                HStack(spacing: 4) {
                    Text(categoryLabel)
                    if entry.isPending { Text("· à venir") }
                    if entry.isRecurring { Image(systemName: "repeat") }
                    if entry.isTransfer { Image(systemName: "arrow.left.arrow.right") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.format(entry.amount, sign: true))
                .monospacedDigit()
                .foregroundStyle(entry.isExpense ? Color.primary : Color.green)
                .opacity(entry.isPending ? 0.6 : 1)
        }
        .contentShape(.rect)
    }
}
