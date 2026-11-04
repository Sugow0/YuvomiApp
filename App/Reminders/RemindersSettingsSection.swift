import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

struct RemindersSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let reminders: ReminderScheduler

    var body: some View {
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
            Text("Les rappels des 14 prochains jours sont programmés sur l'appareil. Rien ne passe par un service tiers.")
        }
        .task { await reminders.refreshAuthorization() }
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
