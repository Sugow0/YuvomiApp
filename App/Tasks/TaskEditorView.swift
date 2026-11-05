import SwiftUI
import YuvomiKit

/// Create (`task == nil`, shown in a sheet) or edit (pushed from the list).
/// Field edits are saved together with "Enregistrer"; subtasks are saved one by one, right away.
struct TaskEditorView: View {
    let model: AllTasksModel
    let task: TaskItem?

    @State private var draft: TaskDraft
    @State private var status: TaskItem.Status
    @State private var hasDueDate: Bool
    @State private var dueDay: Date
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var subtasks: [TaskItem.Subtask]
    @State private var newSubtask = ""
    @State private var saving = false
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AllTasksModel, task: TaskItem?) {
        self.model = model
        self.task = task
        let draft = task.map(TaskDraft.init) ?? TaskDraft(dueDate: TodayBuckets.dayKey())
        _draft = State(initialValue: draft)
        _status = State(initialValue: task?.status ?? .open)
        _hasDueDate = State(initialValue: draft.dueDate != nil)
        _dueDay = State(initialValue: draft.dueDate.flatMap(DayKey.date) ?? .now)
        _hasTime = State(initialValue: draft.dueTime != nil)
        _time = State(initialValue: draft.dueTime.flatMap { DayKey.time($0) } ?? DayKey.time("09:00") ?? .now)
        _subtasks = State(initialValue: task?.subtasks ?? [])
    }

    private var isNew: Bool { task == nil }

    /// Due day at its time, or 09:00 without one: what "15 min avant" counts from.
    private var reminderAnchor: Date? {
        guard hasDueDate else { return nil }
        return hasTime ? DayKey.time(DayKey.timeKey(time), on: dueDay) : DayKey.time("09:00", on: dueDay)
    }

    /// What would be sent now, with the date toggles applied.
    private var currentDraft: TaskDraft {
        var d = draft
        d.dueDate = hasDueDate ? TodayBuckets.dayKey(dueDay) : nil
        d.dueTime = hasDueDate && hasTime ? DayKey.timeKey(time) : nil
        return d
    }

    private var canSave: Bool {
        let titled = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let changed = isNew || currentDraft != task.map(TaskDraft.init) || status != task?.status
        return titled && changed && !saving
    }

    var body: some View {
        Form {
            Section {
                TextField("Titre", text: $draft.title, axis: .vertical)
                    .font(.headline)
                    .focused($titleFocused)
                TextField("Notes", text: $draft.description, axis: .vertical)
                    .lineLimit(2...8)
            }

            Section {
                Toggle("Échéance", systemImage: "calendar", isOn: $hasDueDate.animation())
                if hasDueDate {
                    DatePicker("Jour", selection: $dueDay, displayedComponents: .date)
                    Toggle("Heure", systemImage: "clock", isOn: $hasTime.animation())
                    if hasTime {
                        DatePicker("À", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
            } footer: {
                if task?.isRecurring == true {
                    Label("Tâche récurrente : la règle de répétition se modifie sur le web.", systemImage: "repeat")
                }
            }

            Section {
                Picker("Priorité", systemImage: "flag", selection: $draft.priority) {
                    ForEach(Self.priorities, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Catégorie", systemImage: "folder", selection: $draft.category) {
                    ForEach(categoryOptions) { Text($0.label).tag($0.key) }
                }
                if !isNew {
                    Picker("Statut", systemImage: "circle.dashed", selection: $status) {
                        Text("À faire").tag(TaskItem.Status.open)
                        Text("En cours").tag(TaskItem.Status.inProgress)
                        Text("Terminée").tag(TaskItem.Status.done)
                    }
                }
            }

            if !model.members.isEmpty {
                Section("Pour") {
                    ForEach(model.members) { member in
                        Button { toggleAssignee(member.id) } label: {
                            HStack {
                                MemberDot(member: member)
                                Text(member.displayName ?? "Membre \(member.id)").foregroundStyle(.primary)
                                Spacer()
                                if draft.assignedTo.contains(member.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let task {
                ReminderField(client: model.client, entityType: "task", entityID: task.id, anchor: reminderAnchor)
                subtasksSection(task)
                Section {
                    Button("Supprimer la tâche", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "Nouvelle tâche" : "Tâche")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") { Task { await save() } }
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .confirmationDialog("Supprimer « \(draft.title) » ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task { if let task, await model.delete(task) { dismiss() } }
            }
        } message: {
            if !subtasks.isEmpty { Text("Ses \(subtasks.count) sous-tâches seront aussi supprimées.") }
        }
        .task {
            if isNew { titleFocused = true; return }
            await refreshDetail()
        }
    }

    // MARK: - Subtasks

    private func subtasksSection(_ task: TaskItem) -> some View {
        Section {
            ForEach(subtasks) { subtask in
                Button { Task { await toggleSubtask(subtask) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: subtask.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.status == .done ? Color.accentColor : .secondary)
                        Text(subtask.title)
                            .strikethrough(subtask.status == .done)
                            .foregroundStyle(subtask.status == .done ? .secondary : .primary)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                        Task { await deleteSubtask(subtask) }
                    }
                }
                .contextMenu {
                    Button("Supprimer", systemImage: "trash", role: .destructive) { Task { await deleteSubtask(subtask) } }
                }
            }
            TextField("Ajouter une sous-tâche", text: $newSubtask)
                .submitLabel(.done)
                .onSubmit { Task { await addSubtask(to: task.id) } }
        } header: {
            let done = subtasks.filter { $0.status == .done }.count
            Text(subtasks.isEmpty ? "Sous-tâches" : "Sous-tâches · \(done)/\(subtasks.count)")
        }
    }

    private func refreshDetail() async {
        guard let task, let fresh = try? await model.client.task(task.id) else { return }
        subtasks = fresh.subtasks
        model.replaceSubtasks(of: task.id, with: fresh.subtasks)
    }

    private func toggleSubtask(_ subtask: TaskItem.Subtask) async {
        guard let task, let index = subtasks.firstIndex(where: { $0.id == subtask.id }) else { return }
        let target: TaskItem.Status = subtask.status == .done ? .open : .done
        subtasks[index].status = target
        do {
            _ = try await model.client.setTaskStatus(subtask.id, target)
            model.replaceSubtasks(of: task.id, with: subtasks)
        } catch {
            subtasks[index].status = subtask.status
            model.errorMessage = error.userMessage
        }
    }

    private func addSubtask(to parentID: Int) async {
        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newSubtask = ""
        do {
            let created = try await model.client.addSubtask(to: parentID, title: title)
            subtasks.append(.init(id: created.id, title: created.title, status: created.status))
            model.replaceSubtasks(of: parentID, with: subtasks)
        } catch {
            newSubtask = title
            model.errorMessage = error.userMessage
        }
    }

    private func deleteSubtask(_ subtask: TaskItem.Subtask) async {
        guard let task else { return }
        let backup = subtasks
        subtasks.removeAll { $0.id == subtask.id }
        do {
            try await model.client.deleteTask(subtask.id)
            model.replaceSubtasks(of: task.id, with: subtasks)
        } catch {
            subtasks = backup
            model.errorMessage = error.userMessage
        }
    }

    // MARK: - Saving

    private func save() async {
        saving = true
        defer { saving = false }
        guard let saved = await model.save(currentDraft, for: task?.id) else { return }
        if let task, status != task.status {
            await model.setStatus(saved, status)
        }
        dismiss()
    }

    private func toggleAssignee(_ id: Int) {
        if let index = draft.assignedTo.firstIndex(of: id) {
            draft.assignedTo.remove(at: index)
        } else {
            draft.assignedTo.append(id)
        }
    }

    /// Server categories, plus the task's own if the list could not be read.
    private var categoryOptions: [TaskCategory] {
        var options = model.categories
        if !options.contains(where: { $0.key == draft.category }) {
            options.append(TaskCategory(key: draft.category))
        }
        return options
    }

    private static let priorities: [(TaskItem.Priority, String)] = [
        (.none, "Aucune"), (.low, "Basse"), (.medium, "Moyenne"), (.high, "Haute"), (.urgent, "Urgente"),
    ]
}

private struct MemberDot: View {
    let member: HouseholdMember

    var body: some View {
        Text(String((member.displayName ?? "?").prefix(1)).uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color(hex: member.avatarColor) ?? .gray, in: .circle)
    }
}

extension Color {
    /// `#RRGGBB` as the server stores avatar colours.
    init?(hex: String?) {
        guard var hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
