import Foundation
import Observation
import WidgetKit
import YuvomiKit

/// Every open task of the household, plus what the editor needs (categories, members).
@MainActor @Observable
final class AllTasksModel {
    let client: YuvomiClient
    private let userID: Int?

    private(set) var tasks: [TaskItem] = []
    private(set) var categories: [TaskCategory] = []
    private(set) var members: [HouseholdMember] = []
    private(set) var isLoading = false
    private(set) var todayKey = TodayBuckets.dayKey()
    var search = ""
    var scope: TasksModel.Scope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "allTasks.scope") }
    }
    var errorMessage: String?

    init(client: YuvomiClient, userID: Int?) {
        self.client = client
        self.userID = userID
        scope = UserDefaults.standard.string(forKey: "allTasks.scope").flatMap(TasksModel.Scope.init) ?? .household
    }

    var groups: TodayBuckets {
        var visible = tasks
        if scope == .mine, let userID { visible = visible.filter { $0.assignedUsers.contains { $0.id == userID } } }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            visible = visible.filter {
                $0.title.localizedStandardContains(query) || ($0.description?.localizedStandardContains(query) ?? false)
            }
        }
        return TodayBuckets(visible, today: todayKey)
    }

    func task(_ id: Int) -> TaskItem? { tasks.first { $0.id == id } }

    func category(_ key: String?) -> TaskCategory? { categories.first { $0.key == key } }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        todayKey = TodayBuckets.dayKey()
        // Categories and members are optional: a restricted account may not read them.
        async let categories = try? client.taskCategories()
        async let members = try? client.householdMembers()
        do {
            let fresh = try await client.tasks(includeFuture: true)
            // Ticked here, kept visible (struck through) until the next pull, like the today screen.
            let done = tasks.filter { old in old.isDone && !fresh.contains { $0.id == old.id } }
            tasks = fresh + done
            publish()
        } catch {
            errorMessage = error.userMessage
        }
        self.categories = await categories ?? self.categories
        self.members = await members ?? self.members
    }

    func toggle(_ task: TaskItem) async {
        await setStatus(task, task.isDone ? .open : .done)
    }

    func setStatus(_ task: TaskItem, _ status: TaskItem.Status) async {
        guard task.status != status else { return }
        let previous = task.status
        update(task.id) { $0.status = status }
        do {
            let change = try await client.setTaskStatus(task.id, status)
            if change.nextDueDate != nil { await load() }
            publish()
        } catch {
            update(task.id) { $0.status = previous }
            errorMessage = error.userMessage
        }
    }

    /// Creates or updates; returns the saved task, or nil (with `errorMessage` set).
    func save(_ draft: TaskDraft, for id: Int?) async -> TaskItem? {
        do {
            if let id {
                var saved = try await client.updateTask(id, draft)
                // PUT answers with the bare row: keep the subtasks we already have.
                if saved.subtasks.isEmpty, let known = task(id) { saved.subtasks = known.subtasks }
                update(id) { $0 = saved }
                publish()
                return saved
            }
            let created = try await client.createTask(draft)
            tasks.append(created)
            await load() // the POST row has no joined assignees
            return task(created.id) ?? created
        } catch {
            errorMessage = error.userMessage
            return nil
        }
    }

    func delete(_ task: TaskItem) async -> Bool {
        let backup = tasks
        tasks.removeAll { $0.id == task.id }
        do {
            try await client.deleteTask(task.id)
            publish()
            return true
        } catch {
            tasks = backup
            errorMessage = error.userMessage
            return false
        }
    }

    /// Keeps the list row (subtask counter) in step with the detail screen.
    func replaceSubtasks(of id: Int, with subtasks: [TaskItem.Subtask]) {
        update(id) { $0.subtasks = subtasks }
    }

    private func publish() {
        SnapshotStore.update { $0.tasks = tasks.filter { !$0.isDone } }
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
    }

    private func update(_ id: Int, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }
}
