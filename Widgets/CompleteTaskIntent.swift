import AppIntents
import WidgetKit
import YuvomiKit

/// Ticks a task from the widget without opening the app.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Terminer la tâche"
    static let isDiscoverable = false

    @Parameter(title: "Tâche") var taskID: Int

    init() {}
    init(taskID: Int) { self.taskID = taskID }

    func perform() async throws -> some IntentResult {
        guard let credential = try AppGroup.credentialStore().load() else { return .result() }
        let client = YuvomiClient(credential: credential)
        do {
            if Outbox.count > 0 { await Outbox.flush(client) }
            if Outbox.count > 0 || taskID < 0 { throw URLError(.notConnectedToInternet) }
            _ = try await client.setTaskStatus(taskID, .done)
        } catch where error.isOffline {
            // No network: the app or the next widget reload sends it.
            Outbox.enqueue(.taskStatus(taskID: taskID, status: .done))
        }
        // Drop it from the snapshot so the reload shows it gone even if the refetch fails.
        SnapshotStore.update { snapshot in snapshot.tasks.removeAll { $0.id == taskID } }
        return .result()
    }
}
