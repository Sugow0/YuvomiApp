import Foundation

/// What the app and its widgets share through the App Group.
public enum AppGroup {
    public static let id = "group.fr.sugow.yuvomi"

    /// Shared preferences (e.g. the selected shopping list) the widget reads too.
    public static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    public static func credentialStore() -> KeychainCredentialStore {
        KeychainCredentialStore(accessGroup: id)
    }
}

/// Last data the app saw, so a widget has something to show offline.
public struct TodaySnapshot: Sendable, Codable, Equatable {
    public var savedAt: Date
    public var tasks: [TaskItem]
    public var shoppingListName: String?
    public var shoppingOpenCount: Int?
    /// Today's events and meals for the Agenda widget; nil until first fetched.
    public var agenda: [AgendaItem]?
    public var meals: [MealSummary]?

    public init(savedAt: Date = .now, tasks: [TaskItem] = [], shoppingListName: String? = nil, shoppingOpenCount: Int? = nil) {
        self.savedAt = savedAt
        self.tasks = tasks
        self.shoppingListName = shoppingListName
        self.shoppingOpenCount = shoppingOpenCount
    }
}

public enum SnapshotStore {
    private static var fileURL: URL? { AppGroup.containerURL?.appending(path: "today-snapshot.json") }

    public static func load() -> TodaySnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    public static func update(_ change: (inout TodaySnapshot) -> Void) {
        var snapshot = load() ?? TodaySnapshot()
        change(&snapshot)
        snapshot.savedAt = .now
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
