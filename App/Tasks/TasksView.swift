import SwiftUI
import YuvomiKit

struct TasksView: View {
    @State private var model: TasksModel
    @State private var newTask = ""
    @State private var showUndated = true
    @FocusState private var addFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

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
        .animation(.default, value: model.tasks)
        .overlay { if model.isLoading && model.tasks.isEmpty { ProgressView() } }
        .navigationTitle("Tâches")
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

private struct TaskRow: View {
    let task: TaskItem
    let showDate: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let flag = PriorityFlag(task.priority), !task.isDone {
                            Image(systemName: "flag.fill").foregroundStyle(flag.color).font(.caption)
                                .accessibilityLabel(flag.label)
                        }
                        Text(task.title)
                            .strikethrough(task.isDone)
                            .foregroundStyle(task.isDone ? .secondary : .primary)
                    }
                    details
                }
                Spacer()
                if task.status == .inProgress && !task.isDone {
                    Text("En cours").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: .capsule)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: task.isDone) { _, done in done }
    }

    @ViewBuilder private var details: some View {
        let parts = detailParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailParts: [String] {
        var parts: [String] = []
        if showDate, let date = task.dueDate { parts.append(Self.shortDate(date)) }
        if let time = task.dueTime { parts.append(time) }
        if !task.subtasks.isEmpty { parts.append("\(task.subtasksDone)/\(task.subtasks.count)") }
        let names = task.assignedUsers.compactMap(\.displayName)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts
    }

    private static func shortDate(_ key: String) -> String {
        guard let date = try? Date(key, strategy: .iso8601.year().month().day()) else { return key }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct PriorityFlag {
    let color: Color
    let label: String

    init?(_ priority: TaskItem.Priority) {
        switch priority {
        case .urgent: color = .red; label = "Urgent"
        case .high: color = .orange; label = "Priorité haute"
        case .medium: color = .yellow; label = "Priorité moyenne"
        case .low, .none: return nil
        }
    }
}
