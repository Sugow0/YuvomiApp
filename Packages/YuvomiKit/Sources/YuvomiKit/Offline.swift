import Foundation

// MARK: - Offline detection

extension Error {
    /// True when the server could not be reached at all (no network, DNS, timeout…),
    /// as opposed to the server answering with an error.
    public var isOffline: Bool {
        let codes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
            .callIsActive, .secureConnectionFailed,
        ]
        if let url = self as? URLError { return codes.contains(url.code) }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && codes.contains(URLError.Code(rawValue: ns.code))
    }
}

// MARK: - Cache

/// Last server state of the screens usable offline, in the App Group so widgets share it.
public enum OfflineCache {
    public static func save<T: Encodable>(_ value: T, as key: String) {
        guard let url = url(key), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let url = url(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func clear() {
        guard let dir = AppGroup.containerURL?.appending(path: "cache") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    public static func shoppingKey(_ listID: Int) -> String { "shopping-\(listID)" }
    public static let shoppingListsKey = "shopping-lists"
    public static let tasksKey = "tasks"

    private static func url(_ key: String) -> URL? {
        AppGroup.containerURL?.appending(path: "cache/\(key).json")
    }
}

// MARK: - Pending changes

/// An edit made while the server was unreachable. Items created offline carry a negative
/// temporary id until the server hands back the real one.
public enum PendingChange: Sendable, Codable, Equatable {
    case shoppingCheck(itemID: Int, checked: Bool)
    case shoppingAdd(tempID: Int, listID: Int, name: String, quantity: String?)
    case shoppingDelete(itemID: Int)
    case taskStatus(taskID: Int, status: TaskItem.Status)
    case taskAdd(tempID: Int, title: String, dueDate: String?)

    var tempID: Int? {
        switch self {
        case let .shoppingAdd(id, _, _, _), let .taskAdd(id, _, _): id
        default: nil
        }
    }

    /// The item or task this change is about.
    var subject: Subject {
        switch self {
        case let .shoppingCheck(id, _), let .shoppingDelete(id), let .shoppingAdd(id, _, _, _): .shopping(id)
        case let .taskStatus(id, _), let .taskAdd(id, _, _): .task(id)
        }
    }

    enum Subject: Hashable { case shopping(Int), task(Int) }

    func replacing(_ old: Int, with new: Int) -> PendingChange {
        switch self {
        case let .shoppingCheck(id, checked) where id == old: .shoppingCheck(itemID: new, checked: checked)
        case let .shoppingDelete(id) where id == old: .shoppingDelete(itemID: new)
        case let .taskStatus(id, status) where id == old: .taskStatus(taskID: new, status: status)
        default: self
        }
    }
}

/// Queue of offline edits, replayed in order once the server answers again.
/// Shared by the app and the widgets through the App Group.
public enum Outbox {
    public static var changes: [PendingChange] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingChange].self, from: data)) ?? []
    }

    public static var count: Int { changes.count }

    /// Adds a change, folding it into what is already queued for the same item.
    public static func enqueue(_ change: PendingChange) {
        write(merging(change, into: changes))
    }

    /// A fresh negative id for something created offline.
    public static func makeTempID() -> Int {
        let used = changes.compactMap(\.tempID)
        return min(used.min() ?? 0, 0) - 1 - Int.random(in: 0..<1000)
    }

    public static func clear() { write([]) }

    /// Pure folding rules, separate for tests.
    static func merging(_ change: PendingChange, into queue: [PendingChange]) -> [PendingChange] {
        var queue = queue
        switch change {
        case .shoppingCheck, .taskStatus:
            // Only the last state matters.
            queue.removeAll { $0.subject == change.subject && $0.tempID == nil && !isDelete($0) }
            queue.append(change)
        case let .shoppingDelete(id) where id < 0:
            // Never reached the server: forget it entirely.
            queue.removeAll { $0.subject == .shopping(id) }
        case let .shoppingDelete(id):
            queue.removeAll { $0.subject == .shopping(id) }
            queue.append(change)
        default:
            queue.append(change)
        }
        return queue
    }

    private static func isDelete(_ change: PendingChange) -> Bool {
        if case .shoppingDelete = change { true } else { false }
    }

    public struct FlushResult: Sendable, Equatable {
        public var sent = 0
        /// Refused by the server (e.g. the item was deleted elsewhere).
        public var dropped = 0
        public var remaining = 0
    }

    /// Sends queued changes in order. Stops at the first network failure and keeps the rest.
    @discardableResult
    public static func flush(_ client: YuvomiClient) async -> FlushResult {
        await Flusher.shared.run { await send(changes, with: client) }
    }

    static func send(_ queue: [PendingChange], with client: YuvomiClient) async -> FlushResult {
        var result = FlushResult()
        var pending = queue
        loop: while let change = pending.first {
            do {
                switch change {
                case let .shoppingCheck(id, checked):
                    _ = try await client.setShoppingItem(id, checked: checked)
                case let .shoppingDelete(id):
                    try await client.deleteShoppingItem(id)
                case let .taskStatus(id, status):
                    _ = try await client.setTaskStatus(id, status)
                case let .shoppingAdd(temp, listID, name, quantity):
                    let item = try await client.addShoppingItem(listID: listID, name: name, quantity: quantity)
                    pending = pending.map { $0.replacing(temp, with: item.id) }
                case let .taskAdd(temp, title, dueDate):
                    let task = try await client.addTask(title: title, dueDate: dueDate)
                    pending = pending.map { $0.replacing(temp, with: task.id) }
                }
                result.sent += 1
            } catch where error.isOffline || error.isCancellation || isTransient(error) {
                break loop
            } catch {
                result.dropped += 1
            }
            pending.removeFirst()
            // Persist progress so a crash or a parallel widget does not resend.
            write(pending)
        }
        result.remaining = pending.count
        return result
    }

    /// Worth retrying later: auth hiccup or server trouble, not a refusal of this change.
    private static func isTransient(_ error: any Error) -> Bool {
        if let api = error as? APIError { return api.code == 401 || api.code == 429 || api.code >= 500 }
        if case let ClientError.unexpectedStatus(status) = error { return status == 429 || status >= 500 }
        return false
    }

    private static var url: URL? { AppGroup.containerURL?.appending(path: "outbox.json") }

    private static func write(_ queue: [PendingChange]) {
        guard let url else { return }
        if queue.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Local overlay

    /// Shows queued edits on top of cached or freshly fetched items.
    public static func apply(to items: [ShoppingItem], listID: Int, queue: [PendingChange] = changes) -> [ShoppingItem] {
        var items = items
        for change in queue {
            switch change {
            case let .shoppingCheck(id, checked):
                if let i = items.firstIndex(where: { $0.id == id }) { items[i].isChecked = checked }
            case let .shoppingDelete(id):
                items.removeAll { $0.id == id }
            case let .shoppingAdd(temp, list, name, quantity) where list == listID:
                if !items.contains(where: { $0.id == temp }) {
                    items.append(ShoppingItem(id: temp, listId: list, name: name, quantity: quantity, category: offlineCategory))
                }
            default: break
            }
        }
        return items
    }

    public static func apply(to tasks: [TaskItem], queue: [PendingChange] = changes) -> [TaskItem] {
        var tasks = tasks
        for change in queue {
            switch change {
            case let .taskStatus(id, status):
                if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].status = status }
            case let .taskAdd(temp, title, dueDate):
                if !tasks.contains(where: { $0.id == temp }) {
                    tasks.append(TaskItem(id: temp, title: title, dueDate: dueDate))
                }
            default: break
            }
        }
        return tasks
    }

    /// The server's default category, so offline items land where the server will put them.
    public static let offlineCategory = "Sonstiges"
}

/// Serialises flushes inside one process.
private actor Flusher {
    static let shared = Flusher()
    private var running: Task<Outbox.FlushResult, Never>?

    func run(_ work: @escaping @Sendable () async -> Outbox.FlushResult) async -> Outbox.FlushResult {
        if let running { return await running.value }
        let task = Task { await work() }
        running = task
        let result = await task.value
        running = nil
        return result
    }
}
