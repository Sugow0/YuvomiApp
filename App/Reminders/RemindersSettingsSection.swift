import SwiftUI
import UserNotifications
import YuvomiKit
#if canImport(UIKit)
import UIKit
#endif

struct RemindersSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let reminders: ReminderScheduler

    var body: some View {
        Group {
            Section {
                Toggle("Rappels sur cet appareil", isOn: enabledBinding)
                switch reminders.authorization {
                case .notDetermined:
                    Button("Autoriser les notifications") {
                        Task { await reminders.requestAuthorization(); await model.syncReminders() }
                    }
                case .denied:
                    Button("Notifications désactivées — ouvrir les Réglages") { openURL(Self.settingsURL) }
                default:
                    status
                }
            } header: {
                Text("Rappels")
            } footer: {
                Text("Les rappels des 14 prochains jours sont programmés sur l'appareil. Ils se mettent à jour à l'ouverture de l'app, en arrière-plan quand iOS le permet, et à chaque actualisation des widgets. Rien ne passe par un service tiers.")
            }

            if reminders.isEnabled && !reminders.upcoming.isEmpty {
                Section("Prochains rappels") {
                    ForEach(reminders.upcoming) { reminder in
                        UpcomingReminderRow(reminder: reminder)
                            .swipeActions {
                                Button("Supprimer", systemImage: "trash", role: .destructive) { delete(reminder) }
                            }
                            .contextMenu {
                                Button("Supprimer", systemImage: "trash", role: .destructive) { delete(reminder) }
                            }
                    }
                }
            }
        }
        .task {
            await reminders.refreshAuthorization()
            await model.syncReminders()
        }
    }

    @ViewBuilder private var status: some View {
        LabeledContent("Programmés", value: "\(reminders.scheduledCount)")
        if let lastSync = reminders.lastSync {
            LabeledContent("Dernière synchro") { Text(lastSync, style: .relative) }
        }
        if let error = reminders.lastError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        }
    }

    private func delete(_ reminder: UpcomingReminder) {
        guard let credential = model.credential else { return }
        Task { await reminders.delete(reminder, using: credential) }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { reminders.isEnabled }, set: { value in
            reminders.isEnabled = value
            Task { await model.syncReminders() }
        })
    }

    private static var settingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        #else
        URL(string: UIApplication.openNotificationSettingsURLString)!
        #endif
    }
}

private struct UpcomingReminderRow: View {
    let reminder: UpcomingReminder

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.entityTitle ?? reminder.kindLabel)
                Text(reminder.kindLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(when).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var when: String {
        let calendar = Calendar.current
        let time = reminder.firesAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(reminder.firesAt) { return time }
        if calendar.isDateInTomorrow(reminder.firesAt) { return "Demain \(time)" }
        return reminder.firesAt.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
    }
}
