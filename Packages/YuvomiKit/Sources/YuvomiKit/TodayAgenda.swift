import Foundation

/// A calendar event reduced to what a widget or Siri shows; Codable for the shared snapshot.
public struct AgendaItem: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date?
    public let end: Date?
    public let isAllDay: Bool
    public let color: String?
    public let location: String?

    public init(id: String, title: String, start: Date?, end: Date?, isAllDay: Bool,
                color: String? = nil, location: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.color = color; self.location = location
    }

    public init(_ event: CalendarEvent, calendar: Calendar = .current) {
        self.init(id: event.id, title: event.title, start: event.start.date(in: calendar),
                  end: event.end?.date(in: calendar), isAllDay: event.isAllDay, color: event.displayColor,
                  location: event.location?.split(separator: "\n").first.map(String.init))
    }
}

public struct MealSummary: Sendable, Hashable, Codable {
    public let title: String
    public let kind: Meal.Kind

    public init(title: String, kind: Meal.Kind) { self.title = title; self.kind = kind }
}

public enum TodayAgenda {
    /// What is left of today: all-day events touching today, then timed ones not over yet.
    public static func remaining(_ events: [CalendarEvent], now: Date = .now,
                                 calendar: Calendar = .current) -> [AgendaItem] {
        let today = calendar.startOfDay(for: now)
        return events
            .filter { event in
                guard let span = event.days(in: calendar), span.contains(today) else { return false }
                if event.isAllDay { return true }
                let start = event.start.date(in: calendar) ?? now
                let end = event.end?.date(in: calendar) ?? start
                return max(start, end) > now
            }
            .map { AgendaItem($0, calendar: calendar) }
            .reduce(into: [AgendaItem]()) { result, item in
                if !result.contains(where: { $0.id == item.id }) { result.append(item) }
            }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return (a.start ?? .distantPast, a.title) < (b.start ?? .distantPast, b.title)
            }
    }

    public static func meals(_ week: MealWeek, on day: String) -> [MealSummary] {
        week.meals(on: day).map { MealSummary(title: $0.title, kind: $0.kind) }
    }

    /// "Ce soir : Lasagnes." — what Siri says for "qu'est-ce qu'on mange".
    public static func mealSentence(_ meals: [MealSummary], hour: Int) -> String {
        if meals.isEmpty { return "Aucun repas prévu aujourd'hui." }
        let dinner = meals.filter { $0.kind == .dinner }
        let lunch = meals.filter { $0.kind == .lunch }
        let names: ([MealSummary]) -> String = { $0.map(\.title).formatted(.list(type: .and)) }
        if hour < 14, !lunch.isEmpty {
            var text = "Ce midi : \(names(lunch))."
            if !dinner.isEmpty { text += " Ce soir : \(names(dinner))." }
            return text
        }
        if !dinner.isEmpty { return "Ce soir : \(names(dinner))." }
        return meals.map { "\($0.kind.label) : \($0.title)" }.joined(separator: ". ") + "."
    }
}
