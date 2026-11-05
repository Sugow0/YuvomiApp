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

    public struct Subtask: Sendable, Hashable, Codable, Identifiable {
        public let id: Int
        public var title: String
        public var status: Status

        public init(id: Int, title: String, status: Status = .open) {
            self.id = id; self.title = title; self.status = status
        }
    }

    public let id: Int
    public var title: String
    public var status: Status
    public var priority: Priority
    public var category: String?
    public var description: String?
    /// The rule is server-owned (RRULE); the app shows it, editing stays on the web.
    public let isRecurring: Bool
    /// `YYYY-MM-DD` in the household's time zone.
    public var dueDate: String?
    /// `HH:MM`, only with a due date.
    public var dueTime: String?
    public var assignedUsers: [Assignee]
    public var subtasks: [Subtask]

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, category, description, isRecurring, dueDate, dueTime, assignedUsers, subtasks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(Status.self, forKey: .status)
        priority = (try? c.decode(Priority.self, forKey: .priority)) ?? .none
        category = try c.decodeIfPresent(String.self, forKey: .category)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        // SQLite hands back 0/1; the widget snapshot stores a Bool.
        isRecurring = (try? c.decode(Int.self, forKey: .isRecurring)).map { $0 != 0 }
            ?? (try? c.decode(Bool.self, forKey: .isRecurring)) ?? false
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        dueTime = try c.decodeIfPresent(String.self, forKey: .dueTime)
        // POST returns the bare row: no joined people or subtasks.
        assignedUsers = (try? c.decodeIfPresent([Assignee].self, forKey: .assignedUsers)) ?? []
        subtasks = (try? c.decodeIfPresent([Subtask].self, forKey: .subtasks)) ?? []
    }

    public init(id: Int, title: String, status: Status = .open, priority: Priority = .none,
                category: String? = nil, description: String? = nil, isRecurring: Bool = false,
                dueDate: String? = nil, dueTime: String? = nil,
                assignedUsers: [Assignee] = [], subtasks: [Subtask] = []) {
        self.id = id; self.title = title; self.status = status; self.priority = priority
        self.category = category; self.description = description; self.isRecurring = isRecurring
        self.dueDate = dueDate; self.dueTime = dueTime
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
    /// Dated after today. Not part of `isEmpty`: a "today" screen ignores them.
    public var upcoming: [TaskItem] = []

    /// - Parameter today: `YYYY-MM-DD`; ISO dates compare correctly as strings.
    public init(_ tasks: [TaskItem], today todayKey: String) {
        for task in tasks {
            switch task.dueDate {
            case nil: undated.append(task)
            case let date? where date < todayKey: overdue.append(task)
            case let date? where date == todayKey: today.append(task)
            default: upcoming.append(task)
            }
        }
        today = today.sorted { ($0.dueTime ?? "99:99", $0.priority) < ($1.dueTime ?? "99:99", $1.priority) }
        overdue.sort { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
        upcoming.sort { ($0.dueDate ?? "", $0.dueTime ?? "99:99") < ($1.dueDate ?? "", $1.dueTime ?? "99:99") }
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
    /// - Parameter includeFuture: also tasks whose start date is still ahead.
    public func tasks(statuses: [TaskItem.Status] = [.open, .inProgress],
                      includeFuture: Bool = false) async throws -> [TaskItem] {
        var query = statuses.map { URLQueryItem(name: "status", value: $0.rawValue) }
        if includeFuture { query.append(URLQueryItem(name: "include_future", value: "1")) }
        return try await http.send(
            "GET", "api/v1/tasks",
            query: query,
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

// MARK: - Editing

public struct TaskCategory: Sendable, Hashable, Identifiable, Decodable {
    public let key: String
    /// Set for household-made categories; built-in ones only carry a translation key.
    public let name: String?
    public var id: String { key }

    public init(key: String, name: String? = nil) { self.key = key; self.name = name }

    public var label: String {
        if let name, !name.isEmpty { return name }
        return switch key {
        case "household": "Maison"
        case "school": "École"
        case "shopping": "Courses"
        case "repair": "Réparations"
        case "health": "Santé"
        case "finance": "Finances"
        case "leisure": "Loisirs"
        case "misc": "Divers"
        default: key.capitalized
        }
    }
}

/// `GET /api/v1/family/members`: who a task can be assigned to.
public struct HouseholdMember: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public let displayName: String?
    public let avatarColor: String?

    public init(id: Int, displayName: String?, avatarColor: String? = nil) {
        self.id = id; self.displayName = displayName; self.avatarColor = avatarColor
    }
}

/// The editable fields of a task, sent whole on save. Recurrence, tags, visibility and
/// points are left out on purpose: the server keeps what it has when a field is absent.
public struct TaskDraft: Sendable, Equatable, Encodable {
    public var title: String
    public var description: String
    public var category: String
    public var priority: TaskItem.Priority
    public var dueDate: String?
    public var dueTime: String?
    public var assignedTo: [Int]

    public init(title: String = "", description: String = "", category: String = "misc",
                priority: TaskItem.Priority = .none, dueDate: String? = nil, dueTime: String? = nil,
                assignedTo: [Int] = []) {
        self.title = title; self.description = description; self.category = category
        self.priority = priority; self.dueDate = dueDate; self.dueTime = dueTime; self.assignedTo = assignedTo
    }

    public init(_ task: TaskItem) {
        self.init(title: task.title, description: task.description ?? "", category: task.category ?? "misc",
                  priority: task.priority, dueDate: task.dueDate, dueTime: task.dueTime,
                  assignedTo: task.assignedUsers.map(\.id))
    }

    enum CodingKeys: String, CodingKey { case title, description, category, priority, dueDate, dueTime, assignedTo }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .title)
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(text.isEmpty ? nil : text, forKey: .description)
        try c.encode(category, forKey: .category)
        try c.encode(priority, forKey: .priority)
        // Explicit nulls: on PUT an absent field means "unchanged", null clears it.
        try c.encode(dueDate, forKey: .dueDate)
        try c.encode(dueDate == nil ? nil : dueTime, forKey: .dueTime)
        try c.encode(assignedTo, forKey: .assignedTo)
    }
}

extension YuvomiClient {
    /// One task with its subtasks, as the detail screen needs it.
    public func task(_ id: Int) async throws -> TaskItem {
        try await http.send("GET", "api/v1/tasks/\(id)", as: DataEnvelope<TaskItem>.self).data
    }

    public func createTask(_ draft: TaskDraft) async throws -> TaskItem {
        try await http.send(
            "POST", "api/v1/tasks", body: draft,
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<TaskItem>.self
        ).data
    }

    public func updateTask(_ id: Int, _ draft: TaskDraft) async throws -> TaskItem {
        try await http.send("PUT", "api/v1/tasks/\(id)", body: draft, as: DataEnvelope<TaskItem>.self).data
    }

    /// Also removes its subtasks.
    public func deleteTask(_ id: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/tasks/\(id)", as: Empty.self)
    }

    public func addSubtask(to parentID: Int, title: String) async throws -> TaskItem {
        struct Body: Encodable, Sendable { let title: String; let parentTaskId: Int }
        return try await http.send(
            "POST", "api/v1/tasks", body: Body(title: title, parentTaskId: parentID),
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<TaskItem>.self
        ).data
    }

    public func taskCategories() async throws -> [TaskCategory] {
        try await http.send("GET", "api/v1/tasks/categories", as: DataEnvelope<[TaskCategory]>.self).data
    }

    public func householdMembers() async throws -> [HouseholdMember] {
        try await http.send("GET", "api/v1/family/members", as: DataEnvelope<[HouseholdMember]>.self).data
    }
}
