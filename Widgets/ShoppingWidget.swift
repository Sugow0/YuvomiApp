import AppIntents
import SwiftUI
import WidgetKit
import YuvomiKit

struct ShoppingEntry: TimelineEntry {
    let date: Date
    let state: TodayEntry.State
    let listName: String?
    /// Unchecked items, aisle order.
    let items: [ShoppingItem]

    static let placeholder = ShoppingEntry(
        date: .now, state: .ready, listName: "Courses",
        items: [
            ShoppingItem(id: 1, listId: 1, name: "Lait", quantity: "2 L", category: "Milchprodukte"),
            ShoppingItem(id: 2, listId: 1, name: "Pain", category: "Backwaren"),
            ShoppingItem(id: 3, listId: 1, name: "Pommes", quantity: "6", category: "Obst & Gemüse"),
            ShoppingItem(id: 4, listId: 1, name: "Café", category: "Sonstiges"),
        ]
    )
}

struct ShoppingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShoppingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ShoppingEntry) -> Void) {
        if context.isPreview { return completion(.placeholder) }
        Task { completion(await Self.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ShoppingEntry>) -> Void) {
        Task {
            let entry = await Self.fetch()
            completion(Timeline(entries: [entry], policy: .after(TodayProvider.nextRefresh())))
        }
    }

    static func fetch() async -> ShoppingEntry {
        guard let credential = try? AppGroup.credentialStore().load() else {
            return ShoppingEntry(date: .now, state: .signedOut, listName: nil, items: [])
        }
        let client = YuvomiClient(credential: credential)
        await Outbox.flush(client)
        do {
            let lists = try await client.shoppingLists()
            let selectedID = AppGroup.defaults.object(forKey: "shopping.selectedList") as? Int
            guard let list = lists.first(where: { $0.id == selectedID }) ?? lists.first else {
                return ShoppingEntry(date: .now, state: .ready, listName: nil, items: [])
            }
            let contents = try await client.shoppingItems(listID: list.id)
            let items = Outbox.apply(to: contents.items, listID: list.id)
            OfflineCache.save(ShoppingListContents(list: list, items: items, categories: contents.categories),
                              as: OfflineCache.shoppingKey(list.id))
            let open = items.filter { !$0.isChecked }
            SnapshotStore.update { $0.shoppingListName = list.name; $0.shoppingOpenCount = open.count }
            return ShoppingEntry(date: .now, state: .ready, listName: list.name, items: open)
        } catch {
            return cached(state: .stale)
        }
    }

    /// The copy the app or the last reload left, with queued ticks applied.
    static func cached(state: TodayEntry.State) -> ShoppingEntry {
        let selectedID = AppGroup.defaults.object(forKey: "shopping.selectedList") as? Int
        let lists = OfflineCache.load([ShoppingList].self, key: OfflineCache.shoppingListsKey) ?? []
        guard let id = selectedID ?? lists.first?.id,
              let contents = OfflineCache.load(ShoppingListContents.self, key: OfflineCache.shoppingKey(id))
        else { return ShoppingEntry(date: .now, state: state, listName: nil, items: []) }
        let items = Outbox.apply(to: contents.items, listID: id).filter { !$0.isChecked }
        return ShoppingEntry(date: .now, state: state, listName: contents.list.name, items: items)
    }
}

/// Ticks an item from the widget. Works offline: the tick is queued and sent later.
struct CheckShoppingItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Cocher l'article"
    static let isDiscoverable = false

    @Parameter(title: "Article") var itemID: Int
    @Parameter(title: "Liste") var listID: Int

    init() {}
    init(itemID: Int, listID: Int) { self.itemID = itemID; self.listID = listID }

    func perform() async throws -> some IntentResult {
        guard let credential = try AppGroup.credentialStore().load() else { return .result() }
        let client = YuvomiClient(credential: credential)
        do {
            if Outbox.count > 0 { await Outbox.flush(client) }
            if Outbox.count > 0 || itemID < 0 { throw URLError(.notConnectedToInternet) }
            _ = try await client.setShoppingItem(itemID, checked: true)
        } catch where error.isOffline {
            Outbox.enqueue(.shoppingCheck(itemID: itemID, checked: true))
        }
        // Reflect it in the shared copy so the reload shows it gone, network or not.
        let key = OfflineCache.shoppingKey(listID)
        if let contents = OfflineCache.load(ShoppingListContents.self, key: key) {
            let items = contents.items.map { item in
                var item = item
                if item.id == itemID { item.isChecked = true }
                return item
            }
            OfflineCache.save(ShoppingListContents(list: contents.list, items: items, categories: contents.categories), as: key)
            SnapshotStore.update { $0.shoppingOpenCount = items.filter { !$0.isChecked }.count }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
        return .result()
    }
}

struct ShoppingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.sugow.yuvomi.shopping", provider: ShoppingProvider()) { entry in
            ShoppingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Courses")
        .description("La liste de courses, à cocher directement depuis l'écran d'accueil.")
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

struct ShoppingWidgetView: View {
    let entry: ShoppingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.state {
        case .signedOut:
            ContentUnavailableView("Non connecté", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Ouvrez Yuvomi pour vous connecter."))
                .font(.caption)
        case .ready, .stale:
            content.widgetURL(URL(string: "yuvomi://shopping"))
        }
    }

    private var limit: Int {
        switch family {
        case .systemSmall: 3
        case .systemLarge: 10
        default: 4
        }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Label("\(entry.items.count) à acheter", systemImage: "cart").font(.headline)
                ForEach(entry.items.prefix(2)) { Text($0.name).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            list
        }
        #else
        list
        #endif
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
            header
            if entry.items.isEmpty {
                Spacer(minLength: 0)
                Label("Tout est acheté", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.items.prefix(limit)) { item in
                    ShoppingWidgetRow(item: item, compact: family == .systemSmall)
                }
                if entry.items.count > limit {
                    Text("+ \(entry.items.count - limit) autre\(entry.items.count - limit > 1 ? "s" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "cart").foregroundStyle(.tint)
            Text(entry.listName ?? "Courses").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            if entry.state == .stale {
                Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Hors ligne")
            } else if !entry.items.isEmpty {
                Text("\(entry.items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct ShoppingWidgetRow: View {
    let item: ShoppingItem
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: CheckShoppingItemIntent(itemID: item.id, listID: item.listId)) {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cocher \(item.name)")
            Text(item.name).font(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            if !compact, let quantity = item.quantity, !quantity.isEmpty {
                Text(quantity).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
    }
}

#if os(iOS)
#Preview(as: .systemMedium) { ShoppingWidget() } timeline: { ShoppingEntry.placeholder }
#endif
