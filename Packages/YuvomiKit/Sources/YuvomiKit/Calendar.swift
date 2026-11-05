import Foundation

// MARK: - Times (server/openapi/schemas.js: CalendarDateOrDateTime)

/// A calendar value in one of the server's three forms: a day (`YYYY-MM-DD`), household
/// wall-clock time (`YYYY-MM-DDTHH:MM[:SS]`), or an instant (`…Z` / `…+02:00`).
/// Wall-clock values are read in the device's zone: the device lives in the household.
public enum EventTime: Sendable, Hashable {
    case day(year: Int, month: Int, day: Int)
    case wallClock(DateComponents)
    case instant(Date)

    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let datePart = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard datePart.count == 3 else { return nil }
        if text.count == 10 {
            self = .day(year: datePart[0], month: datePart[1], day: datePart[2])
            return
        }
        let rest = text.dropFirst(11) // after "T" or " "
        if rest.hasSuffix("Z") || rest.contains("+") || rest.dropFirst(5).contains("-") {
            let normalized = text.replacingOccurrences(of: " ", with: "T")
            let withSeconds = normalized.count == 16 || (normalized.count > 16 && normalized[normalized.index(normalized.startIndex, offsetBy: 16)] != ":")
                ? normalized.prefix(16) + ":00" + normalized.dropFirst(16) : Substring(normalized)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = iso.date(from: String(withSeconds)) ?? isoFractional.date(from: String(withSeconds))
            else { return nil }
            self = .instant(date)
            return
        }
        let clock = rest.split(separator: ":").compactMap { Int($0.prefix(2)) }
        guard clock.count >= 2 else { return nil }
        self = .wallClock(DateComponents(year: datePart[0], month: datePart[1], day: datePart[2],
                                         hour: clock[0], minute: clock[1], second: clock.count > 2 ? clock[2] : 0))
    }

    public var isDayOnly: Bool { if case .day = self { true } else { false } }

    /// Start of the day for `.day`, the moment otherwise.
    public func date(in calendar: Calendar = .current) -> Date? {
        switch self {
        case let .day(y, m, d): calendar.date(from: DateComponents(year: y, month: m, day: d))
        case let .wallClock(components): calendar.date(from: components)
        case let .instant(date): date
        }
    }
}

// MARK: - Event

public struct CalendarEvent: Sendable, Hashable, Identifiable, Decodable {
    public let eventID: Int
    public let title: String
    public let description: String?
    public let location: String?
    public let start: EventTime
    /// Inclusive last day for all-day events, the end moment for timed ones.
    public let end: EventTime?
    public let isAllDay: Bool
    public let recurrenceRule: String?
    public let externalSource: String?
    public let assignedUsers: [TaskItem.Assignee]
    /// `#RRGGBB`, resolved the way the web app does: own, then assignee, then calendar.
    public let displayColor: String?
    public let calendarName: String?
    public let birthdayKind: String?
    /// Raw start, part of the identity: occurrences of a series share `eventID`.
    let rawStart: String

    public var id: String { "\(eventID)@\(rawStart)" }
    public var isRecurring: Bool { recurrenceRule != nil }
    /// Only plain local events are edited from the app; series and synced ones stay on the web.
    public var isEditable: Bool { !isRecurring && (externalSource ?? "local") == "local" && birthdayKind == nil }

    enum CodingKeys: String, CodingKey {
        case id, title, description, location, startDatetime, endDatetime, allDay, recurrenceRule, externalSource
        case assignedUsers, color, calColor, localCalendarColor, sourceCalendarColor, calName, localCalendarName
        case birthdayEventKind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        rawStart = try c.decode(String.self, forKey: .startDatetime)
        guard let start = EventTime(rawStart) else {
            throw DecodingError.dataCorruptedError(forKey: .startDatetime, in: c, debugDescription: "Bad start \(rawStart)")
        }
        self.start = start
        end = try c.decodeIfPresent(String.self, forKey: .endDatetime).flatMap(EventTime.init)
        isAllDay = ((try? c.decode(Int.self, forKey: .allDay)) ?? ((try? c.decode(Bool.self, forKey: .allDay)) == true ? 1 : 0)) != 0
            || start.isDayOnly
        recurrenceRule = try c.decodeIfPresent(String.self, forKey: .recurrenceRule)
        externalSource = try c.decodeIfPresent(String.self, forKey: .externalSource)
        assignedUsers = (try? c.decodeIfPresent([TaskItem.Assignee].self, forKey: .assignedUsers)) ?? []
        let own = try? c.decodeIfPresent(String.self, forKey: .color)
        let calendarColor = (try? c.decodeIfPresent(String.self, forKey: .sourceCalendarColor))
            ?? (try? c.decodeIfPresent(String.self, forKey: .calColor))
            ?? (try? c.decodeIfPresent(String.self, forKey: .localCalendarColor))
        displayColor = own ?? assignedUsers.first?.color ?? calendarColor ?? nil
        calendarName = (try? c.decodeIfPresent(String.self, forKey: .calName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .localCalendarName)) ?? nil
        birthdayKind = try? c.decodeIfPresent(String.self, forKey: .birthdayEventKind)
    }

    public init(eventID: Int, title: String, start: EventTime, end: EventTime? = nil, isAllDay: Bool = false,
                location: String? = nil, rawStart: String? = nil) {
        self.eventID = eventID; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay || start.isDayOnly; self.location = location
        description = nil; recurrenceRule = nil; externalSource = "local"; assignedUsers = []
        displayColor = nil; calendarName = nil; birthdayKind = nil
        self.rawStart = rawStart ?? UUID().uuidString
    }

    /// Days (start of day) the event touches, from its first to its last.
    public func days(in calendar: Calendar = .current) -> ClosedRange<Date>? {
        guard let startDate = start.date(in: calendar) else { return nil }
        let first = calendar.startOfDay(for: startDate)
        guard let endDate = end?.date(in: calendar), endDate > startDate || end?.isDayOnly == true else {
            return first...first
        }
        var last = calendar.startOfDay(for: endDate)
        // A timed event ending at midnight belongs to the day before.
        if !(end?.isDayOnly ?? false), last == endDate, last > first {
            last = calendar.date(byAdding: .day, value: -1, to: last) ?? last
        }
        return first...max(first, last)
    }
}

/// The agenda: one entry per day that has something, multi-day events repeated on each day.
public struct AgendaDay: Sendable, Identifiable, Equatable {
    public let day: Date
    public let events: [CalendarEvent]
    public var id: Date { day }

    public static func group(_ events: [CalendarEvent], from: Date, to: Date,
                             calendar: Calendar = .current) -> [AgendaDay] {
        let windowStart = calendar.startOfDay(for: from)
        let windowEnd = calendar.startOfDay(for: to)
        var byDay: [Date: [CalendarEvent]] = [:]
        for event in events {
            guard let span = event.days(in: calendar) else { continue }
            var day = max(span.lowerBound, windowStart)
            let last = min(span.upperBound, windowEnd)
            while day <= last {
                if !(byDay[day]?.contains { $0.id == event.id } ?? false) { byDay[day, default: []].append(event) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return byDay.keys.sorted().map { day in
            let sorted = byDay[day, default: []].sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return (a.start.date(in: calendar) ?? .distantPast, a.title) < (b.start.date(in: calendar) ?? .distantPast, b.title)
            }
            return AgendaDay(day: day, events: sorted)
        }
    }
}

// MARK: - New event

public struct EventDraft: Sendable, Equatable, Encodable {
    public var title: String
    public var isAllDay: Bool
    public var start: Date
    public var end: Date
    public var location: String
    public var notes: String
    public var assignedTo: [Int]

    public init(title: String = "", isAllDay: Bool = false, start: Date, end: Date,
                location: String = "", notes: String = "", assignedTo: [Int] = []) {
        self.title = title; self.isAllDay = isAllDay; self.start = start; self.end = end
        self.location = location; self.notes = notes; self.assignedTo = assignedTo
    }

    /// Prefilled from an existing event, for editing.
    public init(_ event: CalendarEvent, calendar: Calendar = .current) {
        let start = event.start.date(in: calendar) ?? .now
        var end = event.end?.date(in: calendar) ?? start.addingTimeInterval(event.isAllDay ? 0 : 3600)
        if event.isAllDay, event.end?.isDayOnly == false {
            // A day event ending at midnight: show the last day it covers.
            end = event.days(in: calendar)?.upperBound ?? start
        }
        self.init(title: event.title, isAllDay: event.isAllDay, start: start, end: end,
                  location: event.location ?? "", notes: event.description ?? "",
                  assignedTo: event.assignedUsers.map(\.id))
    }

    enum CodingKeys: String, CodingKey { case title, allDay, startDatetime, endDatetime, location, description, assignedTo }

    /// Wall-clock values without offset: the server reads them as household time.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .title)
        try c.encode(isAllDay ? 1 : 0, forKey: .allDay)
        try c.encode(Self.format(start, dayOnly: isAllDay), forKey: .startDatetime)
        try c.encode(Self.format(max(end, start), dayOnly: isAllDay), forKey: .endDatetime)
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(place.isEmpty ? nil : place, forKey: .location)
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(text.isEmpty ? nil : text, forKey: .description)
        // Always sent: on PUT an empty list clears the people, an absent one would keep them.
        try c.encode(assignedTo, forKey: .assignedTo)
    }

    static func format(_ date: Date, dayOnly: Bool, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
        return dayOnly ? day : day + String(format: "T%02d:%02d", p.hour!, p.minute!)
    }
}

// MARK: - Endpoints

extension YuvomiClient {
    /// Events touching `from…to` (days, inclusive), series already expanded by the server.
    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await http.send(
            "GET", "api/v1/calendar",
            query: [
                URLQueryItem(name: "from", value: TodayBuckets.dayKey(from)),
                URLQueryItem(name: "to", value: TodayBuckets.dayKey(to)),
            ],
            as: DataEnvelope<[CalendarEvent]>.self
        ).data
    }

    public func createEvent(_ draft: EventDraft) async throws -> CalendarEvent {
        try await http.send(
            "POST", "api/v1/calendar", body: draft,
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<CalendarEvent>.self
        ).data
    }

    /// Only for plain local events (`CalendarEvent.isEditable`): series need occurrence scopes.
    public func updateEvent(_ eventID: Int, _ draft: EventDraft) async throws -> CalendarEvent {
        try await http.send("PUT", "api/v1/calendar/\(eventID)", body: draft, as: DataEnvelope<CalendarEvent>.self).data
    }

    public func deleteEvent(_ eventID: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/calendar/\(eventID)", as: Empty.self)
    }
}
