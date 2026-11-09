import SwiftUI
import YuvomiKit

struct TasksView: View {
    @State private var model: TasksModel
    @State private var newTask = ""
    @State private var showUndated = true
    @FocusState private var addFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app

    init(client: YuvomiClient, userID: Int?) {
        _model = State(initialValue: TasksModel(client: client, userID: userID))
    }

    var body: some View {
        let buckets = model.buckets
        List {
            Section {
                TextField("Nouvelle tâche pour aujourd'hui", text: $newTask)
                    .focused($addFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(addTask)
            }

            if !buckets.overdue.isEmpty {
                Section {
                    rows(buckets.overdue, showDate: true)
                } header: {
                    Label("En retard", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }

            Section {
                if buckets.today.isEmpty {
                    Text("Rien de prévu aujourd'hui.").foregroundStyle(.secondary)
                } else {
                    rows(buckets.today, showDate: false)
                }
            } header: {
                Label("Aujourd'hui", systemImage: "sun.max")
            }

            if !buckets.undated.isEmpty {
                Section("Sans échéance", isExpanded: $showUndated) {
                    rows(buckets.undated, showDate: false)
                }
            }
        }
        .clearsTabBar()
        .animation(.default, value: model.tasks)
        .overlay { if model.isLoading && model.tasks.isEmpty { ProgressView() } }
        .navigationTitle("Aujourd'hui")
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
        }
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

    private func rows(_ tasks: [TaskItem], showDate: Bool) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: task, showDate: showDate) { Task { await model.toggle(task) } }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func addTask() {
        let text = newTask
        newTask = ""
        addFieldFocused = true
        Task { await model.add(text) }
    }
}
