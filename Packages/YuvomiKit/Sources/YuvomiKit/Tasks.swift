import Foundation

// MARK: - Models (server/routes/tasks.js, server/db.js)

public struct TaskItem: Sendable, Hashable, Identifiable, Codable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        case open, inProgress = "in_progress", done
    }

    public enum Priority: String, Sendable, Codable, Comparable {
        case none, low, medium, high, urgent

        private var rank: Int { [.none: 0, .low: 1, .medium: 2, .high: 3, .urgent: 4][self]! }
        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }

    public struct Assignee: Sendable, Hashable, Codable {
        public let id: Int
        public let displayName: String?
        public let color: String?
    }

    public struct Subtask: Sendable, Hashable, Codable {
        public let id: Int
        public let title: String
        public let status: Status
    }

    public let id: Int
    public var title: String
    public var status: Status
    public let priority: Priority
    public let category: String?
    /// `YYYY-MM-DD` in the household's time zone.
    public let dueDate: String?
    /// `HH:MM`, only with a due date.
    public let dueTime: String?
    public let assignedUsers: [Assignee]
    public let subtasks: [Subtask]

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, category, dueDate, dueTime, assignedUsers, subtasks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(Status.self, forKey: .status)
        priority = (try? c.decode(Priority.self, forKey: .priority)) ?? .none
        category = try c.decodeIfPresent(String.self, forKey: .category)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        dueTime = try c.decodeIfPresent(String.self, forKey: .dueTime)
        // POST returns the bare row: no joined people or subtasks.
        assignedUsers = (try? c.decodeIfPresent([Assignee].self, forKey: .assignedUsers)) ?? []
        subtasks = (try? c.decodeIfPresent([Subtask].self, forKey: .subtasks)) ?? []
    }

    public init(id: Int, title: String, status: Status = .open, priority: Priority = .none,
                category: String? = nil, dueDate: String? = nil, dueTime: String? = nil,
                assignedUsers: [Assignee] = [], subtasks: [Subtask] = []) {
        self.id = id; self.title = title; self.status = status; self.priority = priority
        self.category = category; self.dueDate = dueDate; self.dueTime = dueTime
        self.assignedUsers = assignedUsers; self.subtasks = subtasks
    }

    public var isDone: Bool { status == .done }
    public var subtasksDone: Int { subtasks.filter { $0.status == .done }.count }
}

/// Splits open tasks the way a "today" screen reads them.
public struct TodayBuckets: Sendable, Equatable {
    public var overdue: [TaskItem] = []
    public var today: [TaskItem] = []
    public var undated: [TaskItem] = []

    /// - Parameter today: `YYYY-MM-DD`; ISO dates compare correctly as strings.
    public init(_ tasks: [TaskItem], today todayKey: String) {
        for task in tasks {
            switch task.dueDate {
            case nil: undated.append(task)
            case let date? where date < todayKey: overdue.append(task)
            case let date? where date == todayKey: today.append(task)
            default: break // later: not today's business
            }
        }
        today = today.sorted { ($0.dueTime ?? "99:99", $0.priority) < ($1.dueTime ?? "99:99", $1.priority) }
        overdue.sort { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
    }

    public var isEmpty: Bool { overdue.isEmpty && today.isEmpty && undated.isEmpty }

    public static func dayKey(_ date: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

// MARK: - Endpoints

extension YuvomiClient {
    /// Top-level, unarchived tasks that have started (server's default scope).
    public func tasks(statuses: [TaskItem.Status] = [.open, .inProgress]) async throws -> [TaskItem] {
        try await http.send(
            "GET", "api/v1/tasks",
            query: statuses.map { URLQueryItem(name: "status", value: $0.rawValue) },
            as: DataEnvelope<[TaskItem]>.self
        ).data
    }

    public func addTask(title: String, dueDate: String?) async throws -> TaskItem {
        struct Body: Encodable, Sendable { let title: String; let dueDate: String? }
        return try await http.send(
            "POST", "api/v1/tasks", body: Body(title: title, dueDate: dueDate),
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<TaskItem>.self
        ).data
    }

    public struct StatusChange: Sendable, Decodable {
        public let id: Int
        public let status: TaskItem.Status
        /// Set when completing a recurring task spawned its next occurrence.
        public let nextDueDate: String?
    }

    public func setTaskStatus(_ taskID: Int, _ status: TaskItem.Status) async throws -> StatusChange {
        struct Body: Encodable, Sendable { let status: TaskItem.Status }
        return try await http.send(
            "PATCH", "api/v1/tasks/\(taskID)/status", body: Body(status: status),
            as: DataEnvelope<StatusChange>.self
        ).data
    }
}
