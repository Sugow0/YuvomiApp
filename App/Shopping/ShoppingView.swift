import SwiftUI
import YuvomiKit

struct ShoppingView: View {
    @State private var model: ShoppingModel
    @State private var newItem = ""
    @FocusState private var addFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app

    init(client: YuvomiClient) {
        _model = State(initialValue: ShoppingModel(client: client))
    }

    var body: some View {
        List {
            Section {
                TextField("Ajouter un article", text: $newItem)
                    .focused($addFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(addItem)
            }

            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ShoppingRow(item: item) { Task { await model.toggle(item) } }
                            .swipeActions {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(item) }
                                }
                            }
                            .contextMenu {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(item) }
                                }
                            }
                    }
                } header: {
                    Label(group.category, systemImage: CategoryIcon.symbol(for: group.icon))
                }
            }
        }
        .animation(.default, value: model.items)
        .overlay { emptyState }
        .navigationTitle(model.selectedList?.name ?? "Courses")
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) { OfflineBanner(offline: model.isOffline) }
        .animation(.default, value: model.isOffline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: app.syncGeneration) { Task { await model.load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.lists.isEmpty && !model.isLoading {
            ContentUnavailableView("Aucune liste", systemImage: "cart",
                                   description: Text("Créez une liste de courses dans l'app web."))
        } else if model.items.isEmpty && !model.isLoading && model.selectedList != nil {
            ContentUnavailableView("Liste vide", systemImage: "checkmark.circle",
                                   description: Text("Ajoutez un article ci-dessus."))
                .allowsHitTesting(false)
        } else if model.isLoading && model.items.isEmpty {
            ProgressView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.lists.count > 1 {
            ToolbarItem {
                Menu("Listes", systemImage: "list.bullet") {
                    Picker("Liste", selection: listSelection) {
                        ForEach(model.lists) { list in
                            Text(list.name).badge(list.openCount).tag(Optional(list.id))
                        }
                    }
                }
            }
        }
        ToolbarItem {
            Button("Retirer les cochés", systemImage: "checkmark.circle.badge.xmark") {
                Task { await model.clearChecked() }
            }
            .disabled(model.checkedIDs.isEmpty)
        }
        #if os(macOS)
        ToolbarItem {
            Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                .keyboardShortcut("r")
        }
        #endif
    }

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
        newItem = ""
        addFieldFocused = true
        Task { await model.add(text) }
    }
}

private struct ShoppingRow: View {
    let item: ShoppingItem
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isChecked ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(item.isChecked ? .secondary : .primary)
                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let quantity = item.quantity, !quantity.isEmpty {
                    Text(quantity).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: item.isChecked)
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
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
