import AppIntents
import WidgetKit
import YuvomiKit

// Siri, Shortcuts, Spotlight and the Action button. Each intent runs without opening the app,
// with the device credential the app saved in the shared keychain.

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case noShoppingList

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Connectez-vous d'abord dans l'app Yuvomi."
        case .noShoppingList: "Aucune liste de courses sur votre serveur."
        }
    }
}

private func signedInClient() throws -> YuvomiClient {
    guard let credential = try AppGroup.credentialStore().load() else { throw IntentFailure.signedOut }
    return YuvomiClient(credential: credential)
}

private func reloadWidget() {
    WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
}

// MARK: - Shopping lists as entities ("Ajoute à Drive dans Yuvomi")

struct ShoppingListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Liste de courses"
    static let defaultQuery = ShoppingListQuery()

    let id: Int
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ShoppingListQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [ShoppingListEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ShoppingListEntity] {
        try await signedInClient().shoppingLists().map { ShoppingListEntity(id: $0.id, name: $0.name) }
    }

    /// The list last opened in the app, else the first one.
    func defaultResult() async -> ShoppingListEntity? {
        guard let lists = try? await suggestedEntities() else { return nil }
        let selected = AppGroup.defaults.object(forKey: "shopping.selectedList") as? Int
        return lists.first { $0.id == selected } ?? lists.first
    }
}

// MARK: - Intents

struct AddShoppingItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Ajouter aux courses"
    static let description = IntentDescription("Ajoute un ou plusieurs articles à une liste de courses.")

    @Parameter(title: "Articles", requestValueDialog: "Qu'est-ce que j'ajoute ?")
    var items: String

    @Parameter(title: "Liste")
    var list: ShoppingListEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ajouter \(\.$items) à \(\.$list)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let client = try signedInClient()
        guard let target = try await resolvedList() else { throw IntentFailure.noShoppingList }
        let entries = ShoppingEntry.parse(items)
        guard !entries.isEmpty else { throw $items.needsValueError("Qu'est-ce que j'ajoute ?") }

        var added: [String] = []
        for entry in entries {
            _ = try await client.addShoppingItem(listID: target.id, name: entry.name, quantity: entry.quantity)
            added.append([entry.quantity, entry.name].compactMap(\.self).joined(separator: " "))
        }
        SnapshotStore.update { snapshot in
            if snapshot.shoppingListName == target.name {
                snapshot.shoppingOpenCount = (snapshot.shoppingOpenCount ?? 0) + added.count
            }
        }
        reloadWidget()
        let names = added.formatted(.list(type: .and)).lowercased()
        return .result(value: added, dialog: "C'est ajouté à \(target.name) : \(names).")
    }

    private func resolvedList() async throws -> ShoppingListEntity? {
        if let list { return list }
        return await ShoppingListQuery().defaultResult()
    }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ajouter une tâche"
    static let description = IntentDescription("Crée une tâche pour le foyer, prévue aujourd'hui sauf autre date.")

    @Parameter(title: "Tâche", requestValueDialog: "Quelle tâche ?")
    var title: String

    @Parameter(title: "Échéance", kind: .date)
    var dueDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Ajouter \(\.$title) pour \(\.$dueDate)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $title.needsValueError("Quelle tâche ?") }
        let day = TodayBuckets.dayKey(dueDate ?? .now)
        let name = text.prefix(1).uppercased() + text.dropFirst()
        _ = try await signedInClient().createTask(TaskDraft(title: name, dueDate: day))
        reloadWidget()
        let when = day == TodayBuckets.dayKey() ? "pour aujourd'hui"
            : "pour le \((dueDate ?? .now).formatted(.dateTime.weekday(.wide).day().month(.wide)))"
        return .result(dialog: "Tâche « \(name) » ajoutée \(when).")
    }
}

struct TodayTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Tâches du jour"
    static let description = IntentDescription("Lit les tâches prévues aujourd'hui et celles en retard.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let tasks = try await signedInClient().tasks()
        let buckets = TodayBuckets(tasks, today: TodayBuckets.dayKey())
        SnapshotStore.update { $0.tasks = tasks }
        let titles = (buckets.overdue + buckets.today).map(\.title)
        return .result(value: titles, dialog: IntentDialog(stringLiteral: Self.summary(buckets)))
    }

    static func summary(_ buckets: TodayBuckets) -> String {
        let today = buckets.today.map(\.title)
        let overdue = buckets.overdue.count
        var sentence = switch today.count {
        case 0: "Rien de prévu aujourd'hui."
        case 1: "Une tâche aujourd'hui : \(today[0])."
        case 2...5: "\(today.count) tâches aujourd'hui : \(today.formatted(.list(type: .and)))."
        default: "\(today.count) tâches aujourd'hui, dont \(today.prefix(3).formatted(.list(type: .and)))."
        }
        if overdue > 0 { sentence += overdue == 1 ? " Et une en retard." : " Et \(overdue) en retard." }
        return sentence
    }
}

struct TodayAgendaIntent: AppIntent {
    static let title: LocalizedStringResource = "Agenda du jour"
    static let description = IntentDescription("Lit les événements qui restent aujourd'hui.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let events = TodayAgenda.remaining(try await signedInClient().events(from: .now, to: .now))
        return .result(value: events.map(\.title), dialog: IntentDialog(stringLiteral: Self.summary(events)))
    }

    static func summary(_ events: [AgendaItem]) -> String {
        if events.isEmpty { return "Plus rien de prévu aujourd'hui." }
        let parts = events.prefix(4).map { item -> String in
            if item.isAllDay { return "\(item.title), toute la journée" }
            guard let start = item.start else { return item.title }
            if start < .now { return "\(item.title), en cours" }
            return "\(item.title) à \(start.formatted(date: .omitted, time: .shortened))"
        }
        let more = events.count > 4 ? ", et \(events.count - 4) autres" : ""
        return "Aujourd'hui : \(parts.formatted(.list(type: .and)))\(more)."
    }
}

struct TodayMealsIntent: AppIntent {
    static let title: LocalizedStringResource = "Repas du jour"
    static let description = IntentDescription("Dit ce qui est prévu à manger aujourd'hui.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let today = TodayBuckets.dayKey()
        let meals = TodayAgenda.meals(try await signedInClient().mealWeek(containing: today), on: today)
        let sentence = TodayAgenda.mealSentence(meals, hour: Calendar.current.component(.hour, from: .now))
        return .result(value: meals.map(\.title), dialog: IntentDialog(stringLiteral: sentence))
    }
}

struct OpenShoppingIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir les courses"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.requestedSection = .shopping
        return .result()
    }
}

struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir Aujourd'hui"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.requestedSection = .today
        return .result()
    }
}

// MARK: - Phrases Siri knows without any setup

struct YuvomiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddShoppingItemsIntent(),
            phrases: [
                "Ajoute aux courses dans \(.applicationName)",
                "Ajouter à la liste de courses \(.applicationName)",
                "Ajoute à \(\.$list) dans \(.applicationName)",
            ],
            shortTitle: "Ajouter aux courses",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Ajoute une tâche dans \(.applicationName)",
                "Nouvelle tâche \(.applicationName)",
            ],
            shortTitle: "Ajouter une tâche",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: TodayTasksIntent(),
            phrases: [
                "Mes tâches du jour dans \(.applicationName)",
                "Qu'est-ce que j'ai à faire aujourd'hui dans \(.applicationName)",
            ],
            shortTitle: "Tâches du jour",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: TodayAgendaIntent(),
            phrases: [
                "Qu'est-ce que j'ai aujourd'hui dans \(.applicationName)",
                "Mon agenda du jour dans \(.applicationName)",
            ],
            shortTitle: "Agenda du jour",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: TodayMealsIntent(),
            phrases: [
                "Qu'est-ce qu'on mange dans \(.applicationName)",
                "Qu'est-ce qu'on mange ce soir dans \(.applicationName)",
                "Le repas du jour dans \(.applicationName)",
            ],
            shortTitle: "Repas du jour",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: OpenShoppingIntent(),
            phrases: [
                "Ouvre les courses dans \(.applicationName)",
                "Montre la liste de courses \(.applicationName)",
            ],
            shortTitle: "Ouvrir les courses",
            systemImageName: "cart"
        )
    }
}
