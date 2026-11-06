import AppIntents
import WidgetKit
import YuvomiKit

// Siri, Shortcuts, Spotlight and the Action button. Each intent runs without opening the app,
// with the device credential the app saved in the shared keychain.

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case noShoppingList
    case noRecipe

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Connectez-vous d'abord dans l'app Yuvomi."
        case .noShoppingList: "Aucune liste de courses sur votre serveur."
        case .noRecipe: "Aucune recette classée « Plat » (Mealie) ou proposée dans le planning auto."
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

/// How far one run plans: one shopping trip.
enum PlanPeriod: String, AppEnum {
    case week, halfMonth, month

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Période"
    static let caseDisplayRepresentations: [PlanPeriod: DisplayRepresentation] = [
        .week: DisplayRepresentation(title: "la semaine", subtitle: "Aujourd'hui + 6 jours · automatisation chaque lundi"),
        .halfMonth: DisplayRepresentation(title: "la quinzaine", subtitle: "1–15 ou 16–fin du mois · automatisation le 1 et le 16"),
        .month: DisplayRepresentation(title: "le mois", subtitle: "Jusqu'à la fin du mois · automatisation le 1"),
    ]

    var span: PlanSpan {
        switch self {
        case .week: .week
        case .halfMonth: .halfMonth
        case .month: .month
        }
    }
}

/// Run by a Shortcuts automation at 00:00 (each Monday, the 1st and 16th, or the 1st): fills lunch
/// and dinner for the period with the household's recipes, then puts their ingredients on a list.
/// Slots already planned are kept, so running it again adds nothing.
struct PlanMonthMealsIntent: AppIntent {
    static let title: LocalizedStringResource = "Planifier les repas"
    static let description = IntentDescription(
        "Planifie quelques grosses recettes pour midi et soir (avec leurs restes) et des desserts, puis ajoute les ingrédients aux courses."
    )

    @Parameter(title: "Période", default: .month)
    var period: PlanPeriod

    @Parameter(title: "Liste")
    var list: ShoppingListEntity?

    @Parameter(title: "Personnes à chaque repas", default: 2, inclusiveRange: (1, 12))
    var people: Int

    @Parameter(title: "Desserts par semaine", default: 3, inclusiveRange: (0, 7))
    var dessertsPerWeek: Int

    @Parameter(title: "Vider aussi les articles non cochés", default: false)
    var clearUnchecked: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Planifier \(\.$period) et remplir \(\.$list)") {
            \.$people
            \.$dessertsPerWeek
            \.$clearUnchecked
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let client = try signedInClient()
        guard let target = try await resolvedList() else { throw IntentFailure.noShoppingList }

        let settings = AutoPlanSettings()
        settings.people = people // "Remplacer" in the app sizes cookings the same way
        let roles = try await RecipeRoles.load(for: client.recipes(), settings: settings)
        let dishes = roles.dishes
        let desserts = roles.desserts
        guard !dishes.isEmpty else { throw IntentFailure.noRecipe }

        let days = MonthPlanner.days(period.span, from: .now)
        let history = try await client.recipeHistory(around: days)
        var rng = SystemRandomNumberGenerator()
        let batches = BatchPlanner.plan(
            days: days, dishes: dishes, desserts: desserts,
            options: .init(people: people, dessertsPerWeek: dessertsPerWeek), history: history, using: &rng
        )
        let created = try await client.applyPlan(batches.flatMap(\.meals))

        let range = Self.range(days)
        guard !created.isEmpty else {
            return .result(value: 0, dialog: "Tout est déjà planifié \(range).")
        }
        // A rerun in the same period (a meal deleted, to be replaced) only tops the list up.
        let periodID = period.span.periodID(for: .now)
        let newPeriod = settings.lastPeriodID != periodID
        var open = try await clearList(target.id, emptyingOpenItems: newPeriod && clearUnchecked, client: client)

        // Each cooking is bought once, scaled, when any of its meals was planned now; added to
        // what is still open on the list.
        let createdSlots = Set(created.map { "\($0.date)|\($0.kind.rawValue)" })
        let cooked = batches.filter { $0.meals.contains { createdSlots.contains("\($0.date)|\($0.kind.rawValue)") } }
        let items = try await open.put(cooked.flatMap(\.shopping), using: client)
        // Remember what this run made, so "Annuler le planning" can take it back.
        let earlier = newPeriod ? [] : (settings.lastRun.map { $0.listID == target.id ? $0.mealIDs : [] } ?? [])
        settings.lastRun = AutoPlanRun(mealIDs: earlier + created.map(\.id), firstDay: days.first ?? "",
                                       lastDay: days.last ?? "", listID: target.id)
        settings.lastPeriodID = periodID
        reloadWidget()

        let sentence = "\(created.count) repas planifiés \(range) avec \(cooked.count) recettes à cuisiner, "
            + "\(items) articles mis dans \(target.name)."
        return .result(value: created.count, dialog: IntentDialog(stringLiteral: sentence))
    }

    /// "du 16 au 30 novembre", "le 30 novembre".
    private static func range(_ days: [String]) -> String {
        func date(_ key: String?) -> Date? { key.flatMap(MealWeek.date) }
        guard let first = date(days.first), let last = date(days.last) else { return "" }
        let full = Date.FormatStyle.dateTime.day().month(.wide)
        if days.count == 1 { return "le \(first.formatted(full))" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        return "du \(first.formatted(sameMonth ? .dateTime.day() : full)) au \(last.formatted(full))"
    }

    /// Bought items always go; open ones only when asked. Returns the open items left, by match key.
    private func clearList(_ listID: Int, emptyingOpenItems: Bool,
                           client: YuvomiClient) async throws -> OpenShoppingItems {
        let items = try await client.shoppingItems(listID: listID).items
        let checked = items.filter(\.isChecked).map(\.id)
        if !checked.isEmpty { try await client.clearCheckedShoppingItems(listID: listID, ids: checked) }
        let open = items.filter { !$0.isChecked }
        guard emptyingOpenItems else { return OpenShoppingItems(listID: listID, items: open) }
        for item in open { try await client.deleteShoppingItem(item.id) }
        return OpenShoppingItems(listID: listID, items: [])
    }

    private func resolvedList() async throws -> ShoppingListEntity? {
        if let list { return list }
        return await ShoppingListQuery().defaultResult()
    }
}

/// Takes the last "Planifier les repas" run back: its meals go, and so do their ingredients
/// (or the whole list). Meals added by hand stay.
struct UndoMealPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Annuler le planning"
    static let description = IntentDescription(
        "Supprime les repas créés par le dernier « Planifier les repas » et retire leurs ingrédients des courses."
    )

    @Parameter(title: "Vider toute la liste", default: false)
    var emptyList: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Annuler le dernier planning") { \.$emptyList }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = AutoPlanSettings()
        guard let run = settings.lastRun, !run.mealIDs.isEmpty else {
            return .result(dialog: "Aucun planning automatique à annuler.")
        }
        try await requestConfirmation(dialog: "Supprimer les \(run.mealIDs.count) repas du dernier planning\(emptyList ? " et vider la liste" : "") ?")
        let result = try await signedInClient().undo(run, people: settings.people, emptyingList: emptyList)
        settings.forgetLastRun()
        reloadWidget()
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
        return .result(dialog: IntentDialog(stringLiteral: UndoMealPlanIntent.sentence(result, emptied: emptyList)))
    }

    static func sentence(_ result: YuvomiClient.UndoResult, emptied: Bool) -> String {
        let meals = "\(result.meals) repas supprimé\(result.meals > 1 ? "s" : "")"
        return emptied ? "\(meals), liste vidée (\(result.items) articles)."
                       : "\(meals), \(result.items) article\(result.items > 1 ? "s" : "") retiré\(result.items > 1 ? "s" : "") ou réduit\(result.items > 1 ? "s" : "")."
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
            intent: PlanMonthMealsIntent(),
            phrases: [
                "Planifie les repas du mois dans \(.applicationName)",
                "Planifie le mois dans \(.applicationName)",
            ],
            shortTitle: "Planifier les repas",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: UndoMealPlanIntent(),
            phrases: [
                "Annule le planning des repas dans \(.applicationName)",
                "Annule le planning dans \(.applicationName)",
            ],
            shortTitle: "Annuler le planning",
            systemImageName: "arrow.uturn.backward.circle"
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
