import Foundation
import Observation
import WidgetKit
import YuvomiKit

/// Today's open tasks. A task ticked here stays visible (struck through) until the next refresh,
/// so a mis-tap can be undone in place.
@MainActor @Observable
final class TasksModel {
    enum Scope: String, CaseIterable, Identifiable {
        case mine = "Moi"
        case household = "Tout le foyer"
        var id: Self { self }
    }

    private let client: YuvomiClient
    private let userID: Int?

    private(set) var tasks: [TaskItem] = []
    private(set) var isLoading = false
    private(set) var todayKey = TodayBuckets.dayKey()
    var scope: Scope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "tasks.scope") }
    }
    var errorMessage: String?

    init(client: YuvomiClient, userID: Int?) {
        self.client = client
        self.userID = userID
        scope = UserDefaults.standard.string(forKey: "tasks.scope").flatMap(Scope.init) ?? .household
    }

    var buckets: TodayBuckets {
        let visible = scope == .mine && userID != nil
            ? tasks.filter { $0.assignedUsers.contains { $0.id == userID } }
            : tasks
        return TodayBuckets(visible, today: todayKey)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        todayKey = TodayBuckets.dayKey()
        do {
            tasks = try await client.tasks()
            publish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ task: TaskItem) async {
        let target: TaskItem.Status = task.isDone ? .open : .done
        let previous = task.status
        update(task.id) { $0.status = target }
        do {
            let change = try await client.setTaskStatus(task.id, target)
            // A recurring task spawned its next occurrence: fetch it.
            if change.nextDueDate != nil { await reloadKeepingDone() }
            publish()
        } catch {
            update(task.id) { $0.status = previous }
            errorMessage = error.localizedDescription
        }
    }

    func add(_ rawTitle: String) async {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            tasks.append(try await client.addTask(title: title, dueDate: todayKey))
            publish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadKeepingDone() async {
        let done = tasks.filter(\.isDone)
        guard let fresh = try? await client.tasks() else { return }
        tasks = fresh + done.filter { d in !fresh.contains { $0.id == d.id } }
    }

    /// Hands the current state to the widget.
    private func publish() {
        let open = tasks.filter { !$0.isDone }
        SnapshotStore.update { $0.tasks = open }
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
    }

    private func update(_ id: Int, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }
}
