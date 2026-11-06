import SwiftUI
import YuvomiKit

/// Aujourd'hui, piste C : le plateau noir porte le repas du moment, les plateaux blancs
/// rangent les tâches et ce qu'il reste de l'agenda.
struct TodayView: View {
    @State private var model: TasksModel
    @State private var extras: TodayExtrasModel
    @State private var newTask = ""
    @FocusState private var addFieldFocused: Bool
    @Binding var focusNewTask: Bool
    let open: (HomeView.Section) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient, userID: Int?, focusNewTask: Binding<Bool>,
         open: @escaping (HomeView.Section) -> Void) {
        _model = State(initialValue: TasksModel(client: client, userID: userID))
        _extras = State(initialValue: TodayExtrasModel(client: client))
        _focusNewTask = focusNewTask
        self.open = open
    }

    var body: some View {
        let buckets = model.buckets
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let meal = extras.highlight {
                    mealTray(meal).riseIn()
                }
                tasksTray(buckets).riseIn(delay: 0.06)
                if !extras.agenda.isEmpty {
                    agendaTray.riseIn(delay: 0.12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.ySnappy, value: model.tasks)
            .animation(.ySmooth, value: extras.highlight)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.porcelain)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) { OfflineBanner(offline: model.isOffline) }
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: app.syncGeneration) { Task { await reload() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onChange(of: focusNewTask, initial: true) { _, wanted in
            guard wanted else { return }
            focusNewTask = false
            Task {
                // Laisse le plateau d'ajout se refermer avant de faire monter le clavier.
                try? await Task.sleep(for: .milliseconds(350))
                addFieldFocused = true
            }
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateLine())
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkSecondary)
                Text("Aujourd'hui")
                    .font(Typo.screenTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Menu {
                Picker("Afficher", selection: $model.scope) {
                    ForEach(TasksModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label(model.scope.rawValue, systemImage: model.scope == .mine ? "person" : "person.2")
                    .font(Typo.caption)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Palette.tray, in: .capsule)
                    .elevation(.low)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    /// « Vendredi 6 novembre ».
    private static func dateLine(_ date: Date = .now) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Repas

    private func mealTray(_ meal: MealHighlight) -> some View {
        Tray(style: .active) {
            HStack {
                Text(meal.label.uppercased())
                    .font(Typo.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Palette.onActiveSecondary)
                Spacer()
                Button { open(.meals) } label: {
                    Label("Repas", systemImage: "fork.knife")
                        .font(Typo.caption)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Palette.activeTrayInset, in: .capsule)
                }
                .buttonStyle(.pressable)
            }
            Text(meal.title)
                .font(Typo.hero)
                .lineLimit(2)
            if let note = meal.note {
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.onActiveSecondary)
            }
        }
    }

    // MARK: - Tâches

    private func tasksTray(_ buckets: TodayBuckets) -> some View {
        let remaining = buckets.overdue.count + buckets.today.filter { !$0.isDone }.count
        return Tray {
            TrayHeader("À faire") {
                if remaining > 0 { Text("\(remaining)") }
            }
            ForEach(buckets.overdue) { task in
                TrayTaskRow(task: task, overdue: true) { toggle(task) }
            }
            ForEach(buckets.today) { task in
                TrayTaskRow(task: task) { toggle(task) }
            }
            if buckets.overdue.isEmpty && buckets.today.isEmpty {
                Text(model.isLoading ? "Chargement…" : "Rien de prévu aujourd'hui.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.inkSecondary)
                    .trayRow()
            }
            if !buckets.undated.isEmpty {
                Text("Sans échéance")
                    .font(Typo.eyebrow)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                ForEach(buckets.undated) { task in
                    TrayTaskRow(task: task) { toggle(task) }
                }
            }
            newTaskRow
        }
    }

    private var newTaskRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            TextField("Nouvelle tâche pour aujourd'hui", text: $newTask)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit(addTask)
        }
        .trayRow()
    }

    private func toggle(_ task: TaskItem) {
        Task { await model.toggle(task) }
    }

    private func addTask() {
        let text = newTask
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            addFieldFocused = false
            return
        }
        newTask = ""
        addFieldFocused = true
        Task { await model.add(text) }
    }

    // MARK: - Agenda

    private var agendaTray: some View {
        Tray {
            TrayHeader("Agenda") {
                Text(extras.agenda.count == 1 ? "1 évènement" : "\(extras.agenda.count) évènements")
            }
            ForEach(extras.agenda) { item in
                Button { open(.calendar) } label: {
                    AgendaRow(item: item)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    // MARK: -

    private func reload() async {
        let model = self.model
        let extras = self.extras
        async let tasks: Void = model.load()
        async let more: Void = extras.load()
        _ = await (tasks, more)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Une tâche posée dans un plateau. Toute la ligne coche.
struct TrayTaskRow: View {
    let task: TaskItem
    var overdue = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                CheckCircle(isOn: task.isDone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(Typo.body)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? Palette.inkSecondary : Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(overdue && !task.isDone ? Color.red : Palette.inkSecondary)
                    }
                }
                Spacer(minLength: 8)
                if let flag = PriorityFlag(task.priority), !task.isDone {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(flag.color)
                        .accessibilityLabel(flag.label)
                }
            }
            .padding(.vertical, 10)
            .trayRow()
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.success, trigger: task.isDone) { _, done in done }
        .accessibilityValue(task.isDone ? "Terminée" : "À faire")
        .accessibilityHint(task.isDone ? "Rouvrir la tâche" : "Terminer la tâche")
    }

    private var detail: String? {
        var parts: [String] = []
        if overdue, let key = task.dueDate { parts.append("En retard · " + DayKey.short(key)) }
        if let time = task.dueTime { parts.append(time) }
        if !task.subtasks.isEmpty { parts.append("\(task.subtasksDone)/\(task.subtasks.count)") }
        let names = task.assignedUsers.compactMap(\.displayName)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Un évènement : l'heure dans une pastille Ube, le titre à côté.
struct AgendaRow: View {
    let item: AgendaItem

    var body: some View {
        HStack(spacing: 14) {
            Text(timeLabel)
                .font(Typo.caption.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(Palette.accentSoftText)
                .padding(.horizontal, 12)
                .frame(minWidth: 64, minHeight: 40)
                .background(Palette.accentSoft, in: .capsule)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Typo.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .trayRow(leading: 10)
        .contentShape(.rect(cornerRadius: Radius.row))
    }

    private var timeLabel: String {
        if item.isAllDay { return "Journée" }
        guard let start = item.start else { return "—" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private var subtitle: String? {
        if let location = item.location, !location.isEmpty { return location }
        guard !item.isAllDay, let start = item.start, let end = item.end, end > start else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest)"
    }
}
