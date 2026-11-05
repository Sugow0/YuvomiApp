import Foundation

/// One row of `GET /api/v1/reminders/upcoming` (server/routes/reminders.js).
public struct UpcomingReminder: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    /// `task`, `event`, `subscription`, `waste_pickup`, …
    public let entityType: String
    public let entityId: Int
    public let entityTitle: String?
    public let firesAt: Date

    enum CodingKeys: String, CodingKey { case id, entityType, entityId, entityTitle, firesAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        entityType = try c.decode(String.self, forKey: .entityType)
        entityId = try c.decode(Int.self, forKey: .entityId)
        entityTitle = try c.decodeIfPresent(String.self, forKey: .entityTitle)
        // Always `YYYY-MM-DDTHH:MM:SSZ`, no fractional seconds.
        let raw = try c.decode(String.self, forKey: .firesAt)
        guard let date = try? Date(raw, strategy: .iso8601) else {
            throw DecodingError.dataCorruptedError(forKey: .firesAt, in: c, debugDescription: "Bad fires_at \(raw)")
        }
        firesAt = date
    }

    public init(id: Int, entityType: String, entityId: Int, entityTitle: String?, firesAt: Date) {
        self.id = id; self.entityType = entityType; self.entityId = entityId
        self.entityTitle = entityTitle; self.firesAt = firesAt
    }

    /// French label for the origin, used when there is no title and as the notification body.
    public var kindLabel: String {
        switch entityType {
        case "task": "Tâche"
        case "event": "Événement"
        case "subscription": "Abonnement"
        case "inventory_item", "inventory_tracked_date": "Inventaire"
        case "pantry_item": "Garde-manger"
        case "schedule_entry", "schedule_extra_entry": "Planning"
        case "waste_pickup": "Collecte des déchets"
        case "document_expiry": "Document"
        case "health_prevention_due", "cycle_period", "cycle_log_nudge": "Santé"
        case "fasting_goal", "fasting_next_start": "Jeûne"
        case "shopping_move_returned": "Courses"
        default: "Rappel"
        }
    }
}

extension YuvomiClient {
    /// Max window the server accepts.
    public static let upcomingWindow: TimeInterval = 14 * 24 * 3600

    public func upcomingReminders(from: Date = .now, to: Date? = nil) async throws -> [UpcomingReminder] {
        let end = to ?? from.addingTimeInterval(Self.upcomingWindow)
        let format = Date.ISO8601FormatStyle() // 2026-11-04T12:00:00Z
        return try await http.send(
            "GET", "api/v1/reminders/upcoming",
            query: [
                URLQueryItem(name: "from", value: from.formatted(format)),
                URLQueryItem(name: "to", value: end.formatted(format)),
            ],
            as: DataEnvelope<[UpcomingReminder]>.self
        ).data
    }
}

/// Decides which local notifications to add or remove. Pure, so it is tested without the OS.
public enum ReminderPlanner {
    public static let prefix = "yuvomi.reminder."
    /// iOS keeps at most 64 pending requests per app; leave headroom.
    public static let limit = 60

    /// The fire time is part of the id: a reminder moved on the server gets rescheduled.
    public static func identifier(for reminder: UpcomingReminder) -> String {
        "\(prefix)\(reminder.id).\(Int(reminder.firesAt.timeIntervalSince1970))"
    }

    public struct Plan: Sendable, Equatable {
        public var add: [UpcomingReminder]
        public var remove: [String]
    }

    public static func plan(upcoming: [UpcomingReminder], scheduled: [String], now: Date = .now,
                            limit: Int = limit) -> Plan {
        let wanted = upcoming
            .filter { $0.firesAt > now }
            .sorted { ($0.firesAt, $0.id) < ($1.firesAt, $1.id) }
            .prefix(limit)
        let wantedIDs = Set(wanted.map(identifier))
        let scheduledOurs = Set(scheduled.filter { $0.hasPrefix(prefix) })
        return Plan(
            add: wanted.filter { !scheduledOurs.contains(identifier(for: $0)) },
            remove: scheduledOurs.subtracting(wantedIDs).sorted()
        )
    }
}

// MARK: - Managing reminders (POST/GET/DELETE /api/v1/reminders)

/// A reminder row as the server stores it. One per entity and person for tasks.
public struct Reminder: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public let entityType: String
    public let entityId: Int
    public let remindAt: Date

    enum CodingKeys: String, CodingKey { case id, entityType, entityId, remindAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        entityType = try c.decode(String.self, forKey: .entityType)
        entityId = try c.decode(Int.self, forKey: .entityId)
        let raw = try c.decode(String.self, forKey: .remindAt)
        guard let date = Self.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .remindAt, in: c, debugDescription: "Bad remind_at \(raw)")
        }
        remindAt = date
    }

    /// Stored in UTC, usually without a zone suffix; older rows may carry one.
    static func parse(_ raw: String) -> Date? {
        var text = raw.replacingOccurrences(of: " ", with: "T")
        if text.count == 16 { text += ":00" }
        let hasZone = text.hasSuffix("Z") || text.dropFirst(19).contains("+") || text.dropFirst(19).contains("-")
        if !hasZone { text = String(text.prefix(19)) + "Z" }
        return try? Date(text, strategy: .iso8601)
    }
}

extension YuvomiClient {
    /// The caller's reminder on a task (or the first one on an event), or nil.
    public func reminder(for entityType: String, id: Int) async throws -> Reminder? {
        try await http.send(
            "GET", "api/v1/reminders",
            query: [URLQueryItem(name: "entity_type", value: entityType), URLQueryItem(name: "entity_id", value: "\(id)")],
            as: DataEnvelope<Reminder?>.self
        ).data
    }

    /// Creates or replaces the caller's reminder on an entity.
    @discardableResult
    public func setReminder(for entityType: String, id: Int, at date: Date) async throws -> Reminder {
        struct Body: Encodable, Sendable { let entityType: String; let entityId: Int; let remindAt: String }
        return try await http.send(
            "POST", "api/v1/reminders",
            body: Body(entityType: entityType, entityId: id, remindAt: date.formatted(Date.ISO8601FormatStyle())),
            as: DataEnvelope<Reminder>.self
        ).data
    }

    public func deleteReminder(_ id: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/reminders/\(id)", as: Empty.self)
    }
}
