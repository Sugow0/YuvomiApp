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
    nonisolated static let taskCategory = "yuvomi.task"
    nonisolated static let completeAction = "yuvomi.complete"

    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var scheduledCount = 0
    private(set) var lastSync: Date?
    var lastError: String?

    var isEnabled: Bool {
        get { AppGroup.defaults.object(forKey: "reminders.enabled") as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: "reminders.enabled") }
    }

    init() {
        let complete = UNNotificationAction(identifier: Self.completeAction, title: "Terminer", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.taskCategory, actions: [complete], intentIdentifiers: []),
        ])
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once; afterwards the person changes it in system Settings.
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func sync(using credential: DeviceCredential) async {
        await refreshAuthorization()
        guard isEnabled, authorization == .authorized || authorization == .provisional else {
            await removeAll()
            return
        }
        do {
            let upcoming = try await YuvomiClient(credential: credential).upcomingReminders()
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            let plan = ReminderPlanner.plan(upcoming: upcoming, scheduled: pending)
            center.removePendingNotificationRequests(withIdentifiers: plan.remove)
            for reminder in plan.add {
                try await center.add(Self.request(for: reminder))
            }
            scheduledCount = min(upcoming.filter { $0.firesAt > .now }.count, ReminderPlanner.limit)
            lastSync = .now
            lastError = nil
        } catch {
            // Offline: keep what is scheduled, it was right at the last sync.
            lastError = error.userMessage
        }
        scheduleBackgroundRefresh()
    }

    func removeAll() async {
        let ours = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ReminderPlanner.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        scheduledCount = 0
    }

    private static func request(for reminder: UpcomingReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.entityTitle ?? reminder.kindLabel
        content.body = reminder.kindLabel
        content.sound = .default
        content.threadIdentifier = reminder.entityType
        content.userInfo = ["entityType": reminder.entityType, "entityId": reminder.entityId]
        if reminder.entityType == "task" { content.categoryIdentifier = taskCategory }

        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.firesAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        return UNNotificationRequest(identifier: ReminderPlanner.identifier(for: reminder), content: content, trigger: trigger)
    }

    /// iOS wakes the app now and then to pick up reminders added on the server meanwhile.
    func scheduleBackgroundRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(60 * 60)
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
