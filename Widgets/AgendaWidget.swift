import SwiftUI
import WidgetKit
import YuvomiKit

struct AgendaEntry: TimelineEntry {
    let date: Date
    let state: TodayEntry.State
    let events: [AgendaItem]
    let meals: [MealSummary]

    static let placeholder = AgendaEntry(
        date: .now, state: .ready,
        events: [
            AgendaItem(id: "1", title: "Piscine", start: .now.addingTimeInterval(3600),
                       end: .now.addingTimeInterval(7200), isAllDay: false, color: "#3b82f6"),
            AgendaItem(id: "2", title: "Dentiste", start: .now.addingTimeInterval(4 * 3600),
                       end: nil, isAllDay: false, color: "#ef4444", location: "Cabinet du centre"),
        ],
        meals: [MealSummary(title: "Lasagnes", kind: .dinner)]
    )
}

struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (AgendaEntry) -> Void) {
        if context.isPreview { return completion(.placeholder) }
        Task { completion(await Self.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<AgendaEntry>) -> Void) {
        Task {
            let entry = await Self.fetch()
            completion(Timeline(entries: [entry], policy: .after(TodayProvider.nextRefresh())))
        }
    }

    static func fetch() async -> AgendaEntry {
        guard let credential = try? AppGroup.credentialStore().load() else {
            return AgendaEntry(date: .now, state: .signedOut, events: [], meals: [])
        }
        let client = YuvomiClient(credential: credential)
        let today = TodayBuckets.dayKey()
        do {
            async let events = client.events(from: .now, to: .now)
            // Meals are optional: the module may be switched off.
            async let week = try? client.mealWeek(containing: today)
            let agenda = TodayAgenda.remaining(try await events)
            // Widgets reload every 15–60 min: a free chance to pick up new reminders.
            _ = try? await LocalReminders.sync(client)
            let meals = await week.map { TodayAgenda.meals($0, on: today) } ?? []
            SnapshotStore.update { $0.agenda = agenda; $0.meals = meals }
            return AgendaEntry(date: .now, state: .ready, events: agenda, meals: meals)
        } catch {
            let snapshot = SnapshotStore.load()
            // Drop what ended since the snapshot was taken.
            let events = (snapshot?.agenda ?? []).filter { $0.isAllDay || ($0.end ?? $0.start ?? .distantFuture) > .now }
            return AgendaEntry(date: .now, state: .stale, events: events, meals: snapshot?.meals ?? [])
        }
    }
}

struct AgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.sugow.yuvomi.agenda", provider: AgendaProvider()) { entry in
            AgendaWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agenda du jour")
        .description("Les prochains événements du foyer et les repas d'aujourd'hui.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct AgendaWidgetView: View {
    let entry: AgendaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.state {
        case .signedOut:
            ContentUnavailableView("Non connecté", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Ouvrez Yuvomi pour vous connecter."))
                .font(.caption)
        case .ready, .stale:
            content.widgetURL(URL(string: "yuvomi://calendar"))
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let next = entry.events.first {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(time(next)).font(.caption)
                } else {
                    Text("Rien de prévu").font(.headline)
                }
                if let meal = entry.meals.last { Label(meal.title, systemImage: "fork.knife").font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                header
                if let next = entry.events.first {
                    EventWidgetRow(item: next, time: time(next), compact: true)
                    if entry.events.count > 1 {
                        Text("+ \(entry.events.count - 1) autre\(entry.events.count > 2 ? "s" : "")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Rien de prévu").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                meals(limit: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            let limit = family == .systemLarge ? 7 : 3
            VStack(alignment: .leading, spacing: 8) {
                header
                if entry.events.isEmpty {
                    Label("Plus rien aujourd'hui", systemImage: "calendar.badge.checkmark")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(entry.events.prefix(limit)) { EventWidgetRow(item: $0, time: time($0), compact: false) }
                    if entry.events.count > limit {
                        Text("+ \(entry.events.count - limit) autres").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                meals(limit: family == .systemLarge ? 4 : 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day()).capitalized).font(.headline)
            if entry.state == .stale {
                Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Hors ligne")
            }
        }
    }

    @ViewBuilder private func meals(limit: Int) -> some View {
        let shown = Array(entry.meals.filter { $0.kind != .breakfast }.suffix(limit))
        if !shown.isEmpty {
            Link(destination: URL(string: "yuvomi://meals")!) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.self) { meal in
                        Label(meal.title, systemImage: meal.kind.symbol)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func time(_ item: AgendaItem) -> String {
        if item.isAllDay { return "Toute la journée" }
        guard let start = item.start else { return "" }
        if start < .now, let end = item.end { return "Jusqu'à \(end.formatted(date: .omitted, time: .shortened))" }
        return start.formatted(date: .omitted, time: .shortened)
    }
}

private struct EventWidgetRow: View {
    let item: AgendaItem
    let time: String
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(widgetColor(item.color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(compact ? 2 : 1)
                HStack(spacing: 4) {
                    Text(time).monospacedDigit()
                    if !compact, let place = item.location { Text("· \(place)").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private func widgetColor(_ hex: String?) -> Color {
    guard var hex, hex.hasPrefix("#") else { return .accentColor }
    hex.removeFirst()
    guard hex.count == 6, let value = Int(hex, radix: 16) else { return .accentColor }
    return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                 blue: Double(value & 0xFF) / 255)
}

#if os(iOS)
#Preview(as: .systemMedium) { AgendaWidget() } timeline: { AgendaEntry.placeholder }
#endif
