import SwiftUI
import YuvomiKit

struct AllTasksView: View {
    @State private var model: AllTasksModel
    @State private var creating = false
    @State private var showUndated = true
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient, userID: Int?) {
        _model = State(initialValue: AllTasksModel(client: client, userID: userID))
    }

    private struct Route: Hashable { let id: Int }

    var body: some View {
        let groups = model.groups
        List {
            section("En retard", icon: "exclamationmark.circle", tint: .red, groups.overdue, showDate: true)
            section("Aujourd'hui", icon: "sun.max", tint: nil, groups.today, showDate: false)
            section("À venir", icon: "calendar", tint: nil, groups.upcoming, showDate: true)
            if !groups.undated.isEmpty {
                Section("Sans échéance", isExpanded: $showUndated) { rows(groups.undated, showDate: false) }
            }
        }
        .clearsTabBar()
        .overlay { emptyState(groups) }
        .animation(.default, value: model.tasks)
        .searchable(text: $model.search, prompt: "Rechercher une tâche")
        .navigationTitle("Tâches")
        .navigationDestination(for: Route.self) { route in
            if let task = model.task(route.id) {
                TaskEditorView(model: model, task: task)
            } else {
                ContentUnavailableView("Tâche introuvable", systemImage: "questionmark.circle")
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Afficher", selection: $model.scope) {
                    ForEach(TasksModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            #if os(macOS)
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .keyboardShortcut("r")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Nouvelle tâche", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { TaskEditorView(model: model, task: nil) }
                .environment(\.tabBarClearance, 0) // une feuille recouvre la barre
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
                #endif
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func section(_ title: String, icon: String, tint: Color?, _ tasks: [TaskItem], showDate: Bool) -> some View {
        if !tasks.isEmpty {
            Section {
                rows(tasks, showDate: showDate)
            } header: {
                Label(title, systemImage: icon).foregroundStyle(tint ?? .secondary)
            }
        }
    }

    private func rows(_ tasks: [TaskItem], showDate: Bool) -> some View {
        ForEach(tasks) { task in
            NavigationLink(value: Route(id: task.id)) {
                TaskRow(task: task, showDate: showDate, wholeRowToggles: false) {
                    Task { await model.toggle(task) }
                }
            }
            .swipeActions(edge: .leading) {
                Button(task.isDone ? "Rouvrir" : "Terminer", systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark") {
                    Task { await model.toggle(task) }
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing) {
                Button("Supprimer", systemImage: "trash", role: .destructive) {
                    Task { _ = await model.delete(task) }
                }
            }
            .contextMenu {
                Button(task.isDone ? "Rouvrir" : "Terminer", systemImage: "checkmark") { Task { await model.toggle(task) } }
                Button("Supprimer", systemImage: "trash", role: .destructive) { Task { _ = await model.delete(task) } }
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ groups: TodayBuckets) -> some View {
        if groups.isEmpty && groups.upcoming.isEmpty {
            if model.isLoading && model.tasks.isEmpty {
                ProgressView()
            } else if !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                ContentUnavailableView("Aucune tâche ouverte", systemImage: "checkmark.circle",
                                       description: Text("Ajoutez-en une avec +."))
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
