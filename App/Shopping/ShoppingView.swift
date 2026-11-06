import SwiftUI
import YuvomiKit

struct ShoppingView: View {
    @State private var model: ShoppingModel
    @State private var newItem = ""
    /// Rayon affiché, nil = tous.
    @State private var aisle: String?
    @FocusState private var addFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app

    init(client: YuvomiClient) {
        _model = State(initialValue: ShoppingModel(client: client))
    }

    var body: some View {
        let groups = model.groups
        let shown = shownGroups(groups)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(model.selectedList?.name ?? "Courses", eyebrow: eyebrow) {
                    headerActions
                }
                if !model.items.isEmpty {
                    progressTray.riseIn()
                }
                if model.selectedList != nil {
                    Tray {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Palette.accent)
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            TextField("Ajouter : 2 L de lait, pain…", text: $newItem)
                                .textFieldStyle(.plain)
                                .font(Typo.body)
                                .focused($addFieldFocused)
                                .submitLabel(.done)
                                .onSubmit(addItem)
                        }
                        .trayRow()
                    }
                    .riseIn(delay: 0.04)
                }
                if groups.count > 1 {
                    PillPicker(options: aisleOptions(groups), selection: $aisle)
                        .riseIn(delay: 0.06)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                    aisleTray(group)
                        .riseIn(delay: 0.08 + Double(min(index, 6)) * 0.04)
                }
                emptyState
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.ySnappy, value: model.items)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenChrome(title: model.selectedList?.name ?? "Courses")
        .safeAreaInset(edge: .top, spacing: 0) { OfflineBanner(offline: model.isOffline) }
        .animation(.default, value: model.isOffline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.syncGeneration) { Task { await model.load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .onChange(of: model.selectedListID) { aisle = nil }
        .onChange(of: groups.map(\.id)) { _, ids in
            if let aisle, !ids.contains(aisle) { self.aisle = nil }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .keyboardShortcut("r")
            }
        }
        #endif
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - En-tête

    private var eyebrow: String {
        let open = model.items.filter { !$0.isChecked }.count
        if model.items.isEmpty { return "Liste du foyer" }
        return open == 0 ? "Tout est dans le panier" : (open == 1 ? "1 article à prendre" : "\(open) articles à prendre")
    }

    @ViewBuilder private var headerActions: some View {
        if model.lists.count > 1 {
            Menu {
                Picker("Liste", selection: listSelection) {
                    ForEach(model.lists) { list in
                        Text(list.name).badge(list.openCount).tag(Optional(list.id))
                    }
                }
            } label: {
                RoundIcon(systemImage: "list.bullet")
            }
            .headerMenuStyle()
            .accessibilityLabel("Listes")
        }
        RoundIconButton(title: "Retirer les cochés", systemImage: "checkmark.circle.badge.xmark") {
            Task { await model.clearChecked() }
        }
        .disabled(model.checkedIDs.isEmpty)
    }

    // MARK: - Progression

    private var progressTray: some View {
        let total = model.items.count
        let done = model.checkedIDs.count
        return Tray(style: .active) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(done)")
                        .contentTransition(.numericText(value: Double(done)))
                    Text("/\(total)")
                        .foregroundStyle(Palette.onActiveSecondary)
                }
                .font(Typo.screenTitle)
                .monospacedDigit()
                Text(done == total ? "tout est pris" : "dans le panier")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.onActiveSecondary)
                Spacer(minLength: 0)
            }
            SegmentedProgress(done: done, total: total)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) sur \(total) dans le panier")
    }

    // MARK: - Rayons

    private func aisleOptions(_ groups: [ShoppingModel.Group]) -> [(value: String?, label: String)] {
        [(value: nil, label: "Tout")] + groups.map { (value: Optional($0.category), label: $0.category) }
    }

    private func shownGroups(_ groups: [ShoppingModel.Group]) -> [ShoppingModel.Group] {
        guard let aisle else { return groups }
        let filtered = groups.filter { $0.category == aisle }
        return filtered.isEmpty ? groups : filtered
    }

    private func aisleTray(_ group: ShoppingModel.Group) -> some View {
        let open = group.items.filter { !$0.isChecked }.count
        return Tray {
            TrayHeader(group.category) {
                Text(open == 0 ? "Tout est pris" : (open == 1 ? "1 restant" : "\(open) restants"))
            }
            ForEach(group.items) { item in
                ShoppingTrayRow(item: item) { Task { await model.toggle(item) } }
                    .contextMenu {
                        Button("Supprimer", systemImage: "trash", role: .destructive) {
                            Task { await model.delete(item) }
                        }
                    }
                    .accessibilityAction(named: "Supprimer") { Task { await model.delete(item) } }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.lists.isEmpty && !model.isLoading {
            EmptyTray(title: "Aucune liste", systemImage: "cart",
                      message: "Créez une liste de courses dans l'app web.")
        } else if model.items.isEmpty && !model.isLoading && model.selectedList != nil {
            EmptyTray(title: "Rien à acheter", systemImage: "checkmark.circle",
                      message: "Ajoutez un article ci-dessus.")
        } else if model.isLoading && model.items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    // MARK: -

    private var listSelection: Binding<Int?> {
        Binding(get: { model.selectedListID }, set: { id in
            if let id { Task { await model.selectList(id) } }
        })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func addItem() {
        let text = newItem
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            addFieldFocused = false
            return
        }
        newItem = ""
        addFieldFocused = true
        Task { await model.add(text) }
    }
}

/// Un article posé dans son rayon. Toute la ligne coche ; appui long pour supprimer.
private struct ShoppingTrayRow: View {
    let item: ShoppingItem
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                CheckCircle(isOn: item.isChecked)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(Typo.body)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(item.isChecked ? Palette.inkSecondary : Palette.ink)
                        .multilineTextAlignment(.leading)
                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                Spacer(minLength: 8)
                if let quantity = item.quantity, !quantity.isEmpty {
                    Text(quantity)
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 30)
                        .background(Palette.tray, in: .capsule)
                }
            }
            .padding(.vertical, 8)
            .trayRow(minHeight: 56)
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.selection, trigger: item.isChecked)
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
    }
}

/// La progression en segments du plateau noir ; au-delà de 20 articles, chaque segment
/// représente une part de la liste.
struct SegmentedProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        let count = total > 20 ? 20 : max(total, 1)
        let filled = total > 20
            ? Int((Double(done) / Double(total) * 20).rounded())
            : done
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? Palette.onActive : Palette.activeTrayInset)
                    .frame(height: 8)
            }
        }
        .animation(.ySnappy, value: filled)
        .accessibilityHidden(true)
    }
}

/// The web app uses Lucide icon names; map the defaults to SF Symbols.
enum CategoryIcon {
    static func symbol(for lucide: String?) -> String {
        switch lucide {
        case "apple": "carrot"
        case "wheat": "birthday.cake"
        case "milk": "drop"
        case "beef": "fish"
        case "snowflake": "snowflake"
        case "cup-soda": "waterbottle"
        case "spray-can": "house"
        case "pill": "cross.case"
        default: "tag"
        }
    }
}
