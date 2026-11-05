import Foundation
import UserNotifications

/// Mirrors the server's upcoming reminders into local notifications. Shared by the app
/// (foreground, background refresh) and the widgets (each timeline reload), so reminders
/// added elsewhere arrive even when the app stays closed.
public enum LocalReminders {
    public static let taskCategory = "yuvomi.task"
    public static let completeAction = "yuvomi.complete"
    private static let enabledKey = "reminders.enabled"
    private static let lastSyncKey = "reminders.lastSync"
    private static let countKey = "reminders.count"

    public static var isEnabled: Bool {
        get { AppGroup.defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: enabledKey) }
    }

    public static var lastSync: Date? { AppGroup.defaults.object(forKey: lastSyncKey) as? Date }
    public static var scheduledCount: Int { AppGroup.defaults.integer(forKey: countKey) }

    public enum Outcome: Sendable, Equatable { case synced(Int), disabled, notAuthorized }

    /// Throws only when the server cannot be read; what is scheduled then stays.
    @discardableResult
    public static func sync(_ client: YuvomiClient,
                            center: UNUserNotificationCenter = .current()) async throws -> Outcome {
        let status = await center.notificationSettings().authorizationStatus
        guard isEnabled else { await removeAll(center: center); return .disabled }
        guard status == .authorized || status == .provisional else { return .notAuthorized }

        let upcoming = try await client.upcomingReminders()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let plan = ReminderPlanner.plan(upcoming: upcoming, scheduled: pending)
        center.removePendingNotificationRequests(withIdentifiers: plan.remove)
        for reminder in plan.add {
            try? await center.add(request(for: reminder))
        }
        let count = min(upcoming.filter { $0.firesAt > .now }.count, ReminderPlanner.limit)
        AppGroup.defaults.set(count, forKey: countKey)
        AppGroup.defaults.set(Date.now, forKey: lastSyncKey)
        return .synced(count)
    }

    public static func removeAll(center: UNUserNotificationCenter = .current()) async {
        let ours = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ReminderPlanner.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        AppGroup.defaults.set(0, forKey: countKey)
    }

    static func request(for reminder: UpcomingReminder) -> UNNotificationRequest {
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
}
