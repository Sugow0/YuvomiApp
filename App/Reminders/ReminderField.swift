import SwiftUI
import YuvomiKit

/// "Me rappeler" on a task or an event. Changes are saved right away (like subtasks),
/// then the device reschedules its notifications.
struct ReminderField: View {
    let client: YuvomiClient
    /// `task` or `event`.
    let entityType: String
    let entityID: Int
    /// Due moment of the task / start of the event, for the presets.
    let anchor: Date?

    @State private var reminder: Reminder?
    @State private var enabled = false
    @State private var date = Date.now.addingTimeInterval(3600)
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Me rappeler", systemImage: "bell", isOn: Binding(get: { enabled }, set: toggle))
                .disabled(!loaded)
            if enabled {
                DatePicker("Le", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                if !presets.isEmpty {
                    Menu("Raccourcis") {
                        ForEach(presets, id: \.0) { label, value in
                            Button(label) { date = value }
                        }
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Rappel")
        } footer: {
            if enabled { Text("Une notification arrive sur vos appareils à l'heure choisie.") }
        }
        .task { await load() }
        // Debounced save while the date wheel turns.
        .task(id: enabled ? date : nil) {
            guard loaded, enabled, reminder?.remindAt != date else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private var presets: [(String, Date)] {
        guard let anchor else { return [] }
        let calendar = Calendar.current
        var items: [(String, Date)] = [
            ("À l'heure prévue", anchor),
            ("15 min avant", anchor.addingTimeInterval(-15 * 60)),
            ("1 h avant", anchor.addingTimeInterval(-3600)),
        ]
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: anchor),
           let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: dayBefore) {
            items.append(("La veille à 18:00", evening))
        }
        return items.filter { $0.1 > .now }
    }

    private func load() async {
        defer { loaded = true }
        guard let existing = try? await client.reminder(for: entityType, id: entityID) else {
            date = presets.first(where: { $0.0 == "15 min avant" })?.1 ?? date
            return
        }
        reminder = existing
        date = existing.remindAt
        enabled = existing.remindAt > .now
    }

    private func toggle(_ on: Bool) {
        enabled = on
        if !on, let reminder {
            Task {
                do {
                    try await client.deleteReminder(reminder.id)
                    self.reminder = nil
                    error = nil
                    await AppModel.shared?.syncReminders()
                } catch {
                    enabled = true
                    self.error = error.userMessage
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            reminder = try await client.setReminder(for: entityType, id: entityID, at: date)
            error = nil
            await AppModel.shared?.syncReminders()
        } catch {
            self.error = error.userMessage
        }
    }
}
