import SwiftUI
import YuvomiKit

struct EventDetailView: View {
    let model: CalendarModel
    let event: CalendarEvent
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: event.displayColor) ?? .accentColor).frame(width: 12, height: 12)
                    Text(event.title).font(.title3.weight(.semibold))
                }
                LabeledContent("Quand") {
                    Text(when).multilineTextAlignment(.trailing)
                }
                if event.isRecurring {
                    LabeledContent("Répétition", value: "Oui")
                }
                if let name = event.calendarName {
                    LabeledContent("Calendrier", value: name)
                }
            }
            if let location = event.location, !location.isEmpty {
                Section("Lieu") {
                    Text(location).textSelection(.enabled)
                    if let url = mapsURL(location) {
                        Link(destination: url) { Label("Ouvrir dans Plans", systemImage: "map") }
                    }
                }
            }
            if !event.assignedUsers.isEmpty {
                Section("Pour") {
                    ForEach(event.assignedUsers, id: \.id) { Text($0.displayName ?? "Membre \($0.id)") }
                }
            }
            if let notes = event.description, !notes.isEmpty {
                Section("Notes") { Text(notes).textSelection(.enabled) }
            }
            Section {
                if event.isEditable {
                    Button("Supprimer l'événement", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } else {
                    Text(event.isRecurring
                         ? "Les événements récurrents se modifient sur le web."
                         : "Cet événement vient d'un calendrier synchronisé : modifiez-le à sa source.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Événement")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Supprimer « \(event.title) » ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task { if await model.delete(event) { dismiss() } }
            }
        }
    }

    private var when: String {
        guard let start = event.start.date() else { return "" }
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return "\(day.prefix(1).uppercased() + day.dropFirst())\n\(EventFormat.time(event))"
    }

    private func mapsURL(_ location: String) -> URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: location.replacingOccurrences(of: "\n", with: ", "))]
        return parts?.url
    }
}

struct NewEventView: View {
    let model: CalendarModel
    @State private var draft: EventDraft
    @State private var saving = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: CalendarModel) {
        self.model = model
        // Next full hour, one hour long.
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: .now)?.end ?? .now
        _draft = State(initialValue: EventDraft(start: hour, end: hour.addingTimeInterval(3600)))
    }

    var body: some View {
        Form {
            Section {
                TextField("Titre", text: $draft.title).font(.headline).focused($titleFocused)
                TextField("Lieu", text: $draft.location)
            }
            Section {
                Toggle("Toute la journée", isOn: $draft.isAllDay.animation())
                DatePicker("Début", selection: $draft.start,
                           displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
                DatePicker("Fin", selection: $draft.end, in: draft.start...,
                           displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
            }
            if !model.members.isEmpty {
                Section("Pour") {
                    ForEach(model.members) { member in
                        Button { toggle(member.id) } label: {
                            HStack {
                                Text(member.displayName ?? "Membre \(member.id)").foregroundStyle(.primary)
                                Spacer()
                                if draft.assignedTo.contains(member.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Nouvel événement")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: draft.start) { old, new in
            // Keep the duration when the start moves, like Calendar does.
            draft.end = new.addingTimeInterval(max(draft.end.timeIntervalSince(old), 0))
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Ajouter") {
                    Task {
                        saving = true
                        if await model.create(draft) { dismiss() }
                        saving = false
                    }
                }
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .task { titleFocused = true }
    }

    private func toggle(_ id: Int) {
        if let index = draft.assignedTo.firstIndex(of: id) { draft.assignedTo.remove(at: index) }
        else { draft.assignedTo.append(id) }
    }
}
