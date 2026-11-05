import Foundation
import UserNotifications
import YuvomiKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Mirrors the server's upcoming reminders into local notifications. Nothing leaves the
/// household: no push relay, the device asks its own server and schedules locally.
@MainActor @Observable
final class ReminderScheduler {
    nonisolated static let refreshTaskID = "fr.sugow.yuvomi.reminders"
    nonisolated static let taskCategory = LocalReminders.taskCategory
    nonisolated static let completeAction = LocalReminders.completeAction

    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var scheduledCount = LocalReminders.scheduledCount
    private(set) var lastSync = LocalReminders.lastSync
    /// What the server has coming, for the list in Settings.
    private(set) var upcoming: [UpcomingReminder] = []
    var lastError: String?

    var isEnabled: Bool {
        get { LocalReminders.isEnabled }
        set { LocalReminders.isEnabled = newValue }
    }

    init() {
        let complete = UNNotificationAction(identifier: Self.completeAction, title: "Terminer", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.taskCategory, actions: [complete], intentIdentifiers: []),
        ])
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        // The widgets may have synced meanwhile.
        scheduledCount = LocalReminders.scheduledCount
        lastSync = LocalReminders.lastSync
    }

    /// Asks once; afterwards the person changes it in system Settings.
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func sync(using credential: DeviceCredential) async {
        let client = YuvomiClient(credential: credential)
        do {
            try await LocalReminders.sync(client)
            upcoming = (try? await client.upcomingReminders()) ?? upcoming
            lastError = nil
        } catch {
            // Offline: keep what is scheduled, it was right at the last sync.
            lastError = error.userMessage
        }
        await refreshAuthorization()
        scheduleBackgroundRefresh()
    }

    func removeAll() async {
        await LocalReminders.removeAll()
        upcoming = []
        scheduledCount = 0
    }

    /// Deletes on the server, then reschedules.
    func delete(_ reminder: UpcomingReminder, using credential: DeviceCredential) async {
        upcoming.removeAll { $0.id == reminder.id }
        do {
            try await YuvomiClient(credential: credential).deleteReminder(reminder.id)
        } catch {
            lastError = error.userMessage
        }
        await sync(using: credential)
    }

    /// iOS wakes the app now and then (at best every ~15 min) to pick up reminders added elsewhere.
    func scheduleBackgroundRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}

/// Foreground banners, taps (open the right screen) and the "Terminer" action.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationHandler()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let type = info["entityType"] as? String else { return }
        let entityID = info["entityId"] as? Int

        if response.actionIdentifier == ReminderScheduler.completeAction, type == "task", let entityID {
            guard let credential = try? AppGroup.credentialStore().load() else { return }
            _ = try? await YuvomiClient(credential: credential).setTaskStatus(entityID, .done)
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let url = URL(string: type == "shopping_move_returned" ? "yuvomi://shopping" : "yuvomi://tasks")!
            await MainActor.run { AppModel.shared?.handle(url: url) }
        }
    }
}
