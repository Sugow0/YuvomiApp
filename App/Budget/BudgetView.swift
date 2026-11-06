import SwiftUI
import YuvomiKit

struct BudgetView: View {
    @State private var model: BudgetModel
    @State private var editor: EditorRoute?
    @Environment(\.scenePhase) private var scenePhase
    /// Proposé dans le menu « … » tant qu'Actual Budget n'est pas connecté.
    let onConnectActual: (() -> Void)?

    init(client: YuvomiClient, onConnectActual: (() -> Void)? = nil) {
        _model = State(initialValue: BudgetModel(client: client))
        self.onConnectActual = onConnectActual
    }

    /// nil entry = new one.
    struct EditorRoute: Identifiable {
        let entry: BudgetEntry?
        var id: String { entry?.id ?? "new" }
    }

    var body: some View {
        let days = model.days
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader("Budget", eyebrow: "Opérations du foyer") {
                    if let onConnectActual {
                        Menu {
                            Button("Connecter Actual Budget", systemImage: "link", action: onConnectActual)
                        } label: {
                            RoundIcon(systemImage: "ellipsis")
                        }
                        .headerMenuStyle()
                        .accessibilityLabel("Plus d'options")
                    }
                    RoundIconButton(title: "Nouvelle opération", systemImage: "plus", prominent: true) {
                        editor = EditorRoute(entry: nil)
                    }
                    .keyboardShortcut("n")
                    .disabled(model.unavailable)
                }
                MonthSwitcher(title: model.monthTitle, isCurrent: model.isCurrentMonth) { months in
                    Task { await model.move(by: months) }
                } today: {
                    Task { await model.goToCurrentMonth() }
                }
                if let summary = model.summary {
                    SummaryTray(summary: summary).riseIn()
                    if !summary.spending.isEmpty {
                        SpendingTray(summary: summary, model: model).riseIn(delay: 0.05)
                    }
                }
                if !model.entries.isEmpty || !model.search.isEmpty {
                    Tray {
                        TrayField(placeholder: "Rechercher une opération", text: $model.search,
                                  systemImage: "magnifyingglass")
                    }
                }
                ForEach(Array(days.enumerated()), id: \.element.day) { index, day in
                    Tray {
                        TrayHeader(Self.dayTitle(day.day)) {
                            Text(Money.format(day.entries.reduce(0) { $0 + $1.amount }, sign: true))
                                .monospacedDigit()
                        }
                        ForEach(day.entries) { entry in
                            if entry.isEditable {
                                Button { editor = EditorRoute(entry: entry) } label: {
                                    EntryTrayRow(entry: entry, categoryLabel: model.label(entry.category))
                                }
                                .buttonStyle(.pressable)
                                .contextMenu {
                                    Button("Modifier", systemImage: "pencil") { editor = EditorRoute(entry: entry) }
                                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                                        Task { await model.delete(entry) }
                                    }
                                }
                                .accessibilityAction(named: "Supprimer") { Task { await model.delete(entry) } }
                            } else {
                                EntryTrayRow(entry: entry, categoryLabel: model.label(entry.category))
                            }
                        }
                    }
                    .riseIn(delay: 0.08 + Double(min(index, 5)) * 0.04)
                }
                emptyState
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.ySnappy, value: model.entries)
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
            EmptyTray(title: "Budget indisponible", systemImage: "eurosign.circle",
                      message: "Le module Budget est désactivé ou réservé à d'autres membres du foyer.")
        } else if model.isLoading && model.summary == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if model.entries.isEmpty && model.summary != nil {
            EmptyTray(title: "Aucune opération", systemImage: "tray",
                      message: "Ajoutez une dépense avec +.")
        } else if !model.entries.isEmpty && model.days.isEmpty {
            EmptyTray(title: "Aucun résultat", systemImage: "magnifyingglass",
                      message: "Aucune opération ne correspond à « \(model.search) ».")
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
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Le mois affiché, entre deux flèches ; « Ce mois-ci » apparaît quand on s'en éloigne.
struct MonthSwitcher: View {
    let title: String
    let isCurrent: Bool
    let move: (Int) -> Void
    let today: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Mois précédent")
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Text(title)
                .font(Typo.body)
                .frame(maxWidth: .infinity)

            if !isCurrent {
                Button(action: today) {
                    Text("Ce mois-ci")
                        .font(Typo.caption)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(Palette.trayInset, in: .capsule)
                }
                .buttonStyle(.pressable)
                .transition(.scale.combined(with: .opacity))
            }

            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Mois suivant")
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
        .padding(4)
        .background(Palette.tray, in: .capsule)
        .elevation(.low)
        .animation(.ySnappy, value: isCurrent)
    }
}

/// Le plateau noir : le solde du mois, puis revenus et dépenses.
private struct SummaryTray: View {
    let summary: BudgetSummary

    var body: some View {
        Tray(style: .active) {
            Text("SOLDE DU MOIS")
                .font(Typo.eyebrow)
                .tracking(0.8)
                .foregroundStyle(Palette.onActiveSecondary)
            Text(Money.format(summary.balance, sign: true))
                .font(Typo.screenTitle)
                .monospacedDigit()
                .contentTransition(.numericText(value: summary.balance))
            HStack(spacing: 8) {
                figure("Revenus", Money.format(summary.income), symbol: "arrow.down.left")
                figure("Dépenses", Money.format(-summary.expenses), symbol: "arrow.up.right")
            }
            .padding(.top, 4)
            if let pending = summary.pending, pending.count > 0 {
                Label("\(pending.count) à venir · \(Money.format(pending.income + pending.expenses, sign: true))",
                      systemImage: "clock")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.onActiveSecondary)
                    .padding(.top, 2)
            }
        }
    }

    private func figure(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(Typo.eyebrow)
                .foregroundStyle(Palette.onActiveSecondary)
            Text(value)
                .font(Typo.body)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.activeTrayInset, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

/// Les dépenses par catégorie : une barre par ligne, proportionnelle à la plus grosse.
private struct SpendingTray: View {
    let summary: BudgetSummary
    let model: BudgetModel

    var body: some View {
        let rows = Array(summary.spending.prefix(6))
        let top = rows.map(\.amount).max() ?? 1
        Tray {
            TrayHeader("Dépenses par catégorie")
            ForEach(rows, id: \.category) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.label(row.category)).font(Typo.body).lineLimit(1)
                        Spacer()
                        Text(Money.format(row.amount))
                            .font(Typo.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    ProgressCapsule(value: top > 0 ? row.amount / top : 0)
                }
                .padding(.vertical, 12)
                .trayRow(minHeight: 60)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Barre de progression arrondie. Avec `warnsAbove`, elle passe en encre au-delà du seuil
/// et en rouge au-delà de 100 %.
struct ProgressCapsule: View {
    let value: Double
    var warnsAbove: Double? = nil

    var body: some View {
        let clamped = min(max(value, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.inkSecondary.opacity(0.18))
                Capsule()
                    .fill(fill)
                    .frame(width: max(6, proxy.size.width * clamped))
            }
        }
        .frame(height: 6)
        .animation(.yTray, value: clamped)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        guard let warnsAbove else { return Palette.accent }
        if value > 1 { return .red }
        if value > warnsAbove { return Palette.ink }
        return Palette.accent
    }
}

private struct EntryTrayRow: View {
    let entry: BudgetEntry
    let categoryLabel: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: BudgetCategory.symbol(for: entry.category))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.isExpense ? Palette.ink : Palette.accentSoftText)
                .frame(width: 36, height: 36)
                .background(entry.isExpense ? Palette.tray : Palette.accentSoft, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title?.isEmpty == false ? entry.title! : categoryLabel)
                    .font(Typo.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(categoryLabel)
                    if entry.isPending { Text("· à venir") }
                    if entry.isRecurring { Image(systemName: "repeat").accessibilityLabel("Récurrente") }
                    if entry.isTransfer { Image(systemName: "arrow.left.arrow.right").accessibilityLabel("Virement") }
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.format(entry.amount, sign: true))
                .font(Typo.body)
                .monospacedDigit()
                .foregroundStyle(entry.isExpense ? Palette.ink : Palette.accentSoftText)
                .opacity(entry.isPending ? 0.6 : 1)
        }
        .trayRow(minHeight: 60, leading: 12)
        .contentShape(.rect(cornerRadius: Radius.row))
    }
}
