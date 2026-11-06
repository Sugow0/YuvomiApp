import WidgetKit
import YuvomiKit

struct TodayEntry: TimelineEntry {
    enum State: Equatable { case ready, signedOut, stale }

    let date: Date
    let state: State
    let overdue: [TaskItem]
    let today: [TaskItem]
    let shoppingListName: String?
    let shoppingOpenCount: Int?

    var tasks: [TaskItem] { overdue + today }

    static let placeholder = TodayEntry(
        date: .now, state: .ready, overdue: [],
        today: [
            TaskItem(id: 1, title: "Sortir les poubelles", dueTime: "08:00"),
            TaskItem(id: 2, title: "Arroser les plantes"),
            TaskItem(id: 3, title: "Appeler le pédiatre", priority: .high),
        ],
        shoppingListName: "Courses", shoppingOpenCount: 6
    )
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (TodayEntry) -> Void) {
        if context.isPreview { return completion(.placeholder) }
        Task { completion(await Self.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<TodayEntry>) -> Void) {
        Task {
            let entry = await Self.fetch()
            completion(Timeline(entries: [entry], policy: .after(Self.nextRefresh())))
        }
    }

    /// Every 15 minutes, and right after midnight so "today" rolls over.
    static func nextRefresh(from now: Date = .now) -> Date {
        let soon = now.addingTimeInterval(15 * 60)
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(24 * 3600)).addingTimeInterval(60)
        return min(soon, midnight)
    }

    static func fetch() async -> TodayEntry {
        let todayKey = TodayBuckets.dayKey()
        guard let credential = try? AppGroup.credentialStore().load() else {
            return entry(state: .signedOut, tasks: [], todayKey: todayKey, snapshot: nil)
        }
        let client = YuvomiClient(credential: credential)
        await Outbox.flush(client)
        do {
            async let tasks = client.tasks()
            async let lists = client.shoppingLists()
            let (serverTasks, fetchedLists) = try await (tasks, lists)
            let fetchedTasks = Outbox.apply(to: serverTasks)
            // Widgets reload every 15–60 min: a free chance to pick up new reminders.
            _ = try? await LocalReminders.sync(client)
            let selectedID = AppGroup.defaults.object(forKey: "shopping.selectedList") as? Int
            let list = fetchedLists.first { $0.id == selectedID } ?? fetchedLists.first
            SnapshotStore.update {
                $0.tasks = fetchedTasks
                $0.shoppingListName = list?.name
                $0.shoppingOpenCount = list?.openCount
            }
            return entry(state: .ready, tasks: fetchedTasks, todayKey: todayKey, snapshot: SnapshotStore.load())
        } catch {
            let snapshot = SnapshotStore.load()
            return entry(state: .stale, tasks: Outbox.apply(to: snapshot?.tasks ?? []), todayKey: todayKey, snapshot: snapshot)
        }
    }

    private static func entry(state: TodayEntry.State, tasks: [TaskItem], todayKey: String,
                              snapshot: TodaySnapshot?) -> TodayEntry {
        let buckets = TodayBuckets(tasks.filter { !$0.isDone }, today: todayKey)
        return TodayEntry(
            date: .now, state: state, overdue: buckets.overdue, today: buckets.today,
            shoppingListName: snapshot?.shoppingListName, shoppingOpenCount: snapshot?.shoppingOpenCount
        )
    }
}
