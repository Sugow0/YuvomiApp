import SwiftUI
import YuvomiKit

struct CalendarView: View {
    @State private var model: CalendarModel
    @State private var creating = false
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient) {
        _model = State(initialValue: CalendarModel(client: client))
    }

    private struct Route: Hashable { let id: String }

    var body: some View {
        List {
            ForEach(model.agenda) { day in
                Section {
                    ForEach(day.events) { event in
                        NavigationLink(value: Route(id: event.id)) { EventRow(event: event, on: day.day) }
                    }
                } header: {
                    DayHeader(day: day.day)
                }
            }
            if !model.events.isEmpty || !model.isLoading {
                Section {
                    Button("Afficher les 30 jours suivants", systemImage: "chevron.down") {
                        Task { await model.loadMore() }
                    }
                } footer: {
                    Text("Jusqu'au \(model.windowEnd.formatted(.dateTime.day().month(.wide)))")
                }
            }
        }
        .overlay {
            if model.events.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Rien de prévu", systemImage: "calendar",
                                           description: Text("Aucun événement dans les 30 prochains jours."))
                }
            }
        }
        .navigationTitle("Agenda")
        .navigationDestination(for: Route.self) { route in
            if let event = model.events.first(where: { $0.id == route.id }) {
                EventDetailView(model: model, event: event)
            }
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .keyboardShortcut("r")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Nouvel événement", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { NewEventView(model: model) }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 480)
                #endif
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct DayHeader: View {
    let day: Date

    var body: some View {
        let calendar = Calendar.current
        let label = calendar.isDateInToday(day) ? "Aujourd'hui"
            : calendar.isDateInTomorrow(day) ? "Demain"
            : day.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
        Text(label)
            .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : .secondary)
    }
}

struct EventRow: View {
    let event: CalendarEvent
    let on: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: event.displayColor) ?? .accentColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if event.birthdayKind != nil { Image(systemName: "gift").foregroundStyle(.pink) }
                    Text(event.title).font(.body.weight(.medium))
                    if event.isRecurring {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(EventFormat.time(event, on: on)).font(.caption).foregroundStyle(.secondary)
                if let location = event.location?.split(separator: "\n").first {
                    Label(String(location), systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !event.assignedUsers.isEmpty {
                HStack(spacing: -6) {
                    ForEach(event.assignedUsers.prefix(3), id: \.id) { person in
                        Text(String((person.displayName ?? "?").prefix(1)).uppercased())
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color(hex: person.color) ?? .gray, in: .circle)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum EventFormat {
    /// "Toute la journée", "18:00 – 19:30", or for a multi-day event the part on `day`.
    static func time(_ event: CalendarEvent, on day: Date? = nil) -> String {
        if event.isAllDay {
            guard let span = event.days(), span.lowerBound != span.upperBound else { return "Toute la journée" }
            return "Toute la journée · jusqu'au \(span.upperBound.formatted(.dateTime.day().month(.abbreviated)))"
        }
        guard let start = event.start.date() else { return "" }
        let calendar = Calendar.current
        let end = event.end?.date()
        if let day, !calendar.isDate(start, inSameDayAs: day) {
            return end.map { "Jusqu'à \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end, end > start else { return from }
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(from) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(from) – \(end.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}
