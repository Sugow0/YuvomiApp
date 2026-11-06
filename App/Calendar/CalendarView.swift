import SwiftUI
import YuvomiKit

struct CalendarView: View {
    @State private var model: CalendarModel
    @State private var creating = false
    @State private var loaded = false
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient) {
        _model = State(initialValue: CalendarModel(client: client))
    }

    private struct Route: Hashable { let id: String }

    var body: some View {
        let days = model.agenda
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader("Agenda", eyebrow: Self.monthLine()) {
                    RoundIconButton(title: "Nouvel évènement", systemImage: "plus", prominent: true) {
                        creating = true
                    }
                    .keyboardShortcut("n")
                }
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    dayTray(day)
                        .riseIn(delay: Double(min(index, 6)) * 0.05)
                }
                if model.events.isEmpty {
                    if model.isLoading || !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        EmptyTray(title: "Rien de prévu", systemImage: "calendar",
                                  message: "Aucun évènement dans les 30 prochains jours.")
                    }
                }
                if loaded && (!model.events.isEmpty || !model.isLoading) {
                    loadMore
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.ySnappy, value: days)
        }
        .screenChrome(title: "Agenda")
        .navigationDestination(for: Route.self) { route in
            if let event = model.events.first(where: { $0.id == route.id }) {
                EventDetailView(model: model, event: event)
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .keyboardShortcut("r")
            }
        }
        #endif
        .sheet(isPresented: $creating) {
            NavigationStack { EventEditorView(model: model) }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 480)
                #endif
        }
        .refreshable { await model.load() }
        .task {
            await model.load()
            loaded = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Aujourd'hui dans le plateau noir, les jours suivants dans des plateaux blancs.
    private func dayTray(_ day: AgendaDay) -> some View {
        let isToday = Calendar.current.isDateInToday(day.day)
        return Tray(style: isToday ? .active : .plain, padding: Radius.trayPadding) {
            TrayHeader(Self.dayTitle(day.day)) {
                Text(day.events.count == 1 ? "1 évènement" : "\(day.events.count) évènements")
            }
            ForEach(day.events) { event in
                NavigationLink(value: Route(id: event.id)) {
                    AgendaEventRow(event: event, on: day.day, active: isToday)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private var loadMore: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.loadMore() }
            } label: {
                Label("Afficher les 30 jours suivants", systemImage: "chevron.down")
                    .font(Typo.caption)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Palette.tray, in: .capsule)
                    .elevation(.low)
            }
            .buttonStyle(.pressable)
            Text("Jusqu'au \(model.windowEnd.formatted(.dateTime.day().month(.wide)))")
                .font(Typo.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Aujourd'hui" }
        if calendar.isDateInTomorrow(day) { return "Demain" }
        let text = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func monthLine(_ date: Date = .now) -> String {
        let text = date.formatted(.dateTime.month(.wide).year())
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Un évènement : l'heure dans une pastille, le titre, puis l'horaire et le lieu.
/// Dans le plateau du jour (`active`), la pastille passe en Ube.
struct AgendaEventRow: View {
    let event: CalendarEvent
    let on: Date
    var active = false

    var body: some View {
        HStack(spacing: 14) {
            Text(timeLabel)
                .font(Typo.caption.weight(.heavy))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(active ? Palette.onAccent : Palette.accentSoftText)
                .padding(.horizontal, 12)
                .frame(minWidth: 64, minHeight: 40)
                .background(active ? Palette.accent : Palette.accentSoft, in: .capsule)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if event.birthdayKind != nil {
                        Image(systemName: "gift").font(.caption).accessibilityLabel("Anniversaire")
                    }
                    Text(event.title)
                        .font(Typo.body)
                        .lineLimit(1)
                    if event.isRecurring {
                        Image(systemName: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Récurrent")
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: event.displayColor) ?? Palette.accent)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !event.assignedUsers.isEmpty {
                HStack(spacing: -8) {
                    ForEach(event.assignedUsers.prefix(3), id: \.id) { person in
                        Text(String((person.displayName ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color(hex: person.color) ?? .gray, in: .circle)
                            .overlay(Circle().strokeBorder(active ? Palette.activeTrayInset : Palette.trayInset, lineWidth: 2))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pour " + event.assignedUsers.compactMap(\.displayName).joined(separator: ", "))
            }
        }
        .foregroundStyle(active ? Palette.onActive : Palette.ink)
        .trayRow(minHeight: 60, leading: 10, fill: active ? Palette.activeTrayInset : Palette.trayInset)
        .contentShape(.rect(cornerRadius: Radius.row))
    }

    private var timeLabel: String {
        if event.isAllDay { return "Journée" }
        guard let start = event.start.date() else { return "—" }
        if !Calendar.current.isDate(start, inSameDayAs: on) { return "Suite" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private var subtitle: String {
        var parts = [EventFormat.time(event, on: on)]
        if let location = event.location?.split(separator: "\n").first { parts.append(String(location)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
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
