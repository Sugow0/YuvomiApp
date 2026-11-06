import Foundation
import Observation
import WidgetKit
import YuvomiKit

/// State for one shopping list. Edits apply locally first, then sync; a failure reverts.
/// Without network, edits are queued in the `Outbox` and the cached list stays usable.
@MainActor @Observable
final class ShoppingModel {
    struct Group: Identifiable {
        let category: String
        let icon: String?
        var items: [ShoppingItem]
        var id: String { category }
    }

    private let client: YuvomiClient

    private(set) var lists: [ShoppingList] = []
    var selectedListID: Int? {
        didSet {
            guard selectedListID != oldValue else { return }
            AppGroup.defaults.set(selectedListID, forKey: "shopping.selectedList")
            items = []
        }
    }
    private(set) var items: [ShoppingItem] = []
    private(set) var categories: [ShoppingCategory] = []
    private(set) var isLoading = false
    /// The last request could not reach the server: showing the cached list.
    private(set) var isOffline = false
    var errorMessage: String?

    init(client: YuvomiClient) {
        self.client = client
        selectedListID = AppGroup.defaults.object(forKey: "shopping.selectedList") as? Int
        loadCached()
    }

    var selectedList: ShoppingList? { lists.first { $0.id == selectedListID } }
    var checkedIDs: [Int] { items.filter(\.isChecked).map(\.id) }

    /// Aisle order from the server's categories; unchecked before checked inside each.
    var groups: [Group] {
        let order = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.name, $0) })
        let icons = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0.icon) })
        let grouped = Dictionary(grouping: items, by: \.category)
        return grouped.keys
            .sorted { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) }
            .map { name in
                let sorted = grouped[name, default: []].enumerated()
                    .sorted { ($0.element.isChecked ? 1 : 0, $0.offset) < ($1.element.isChecked ? 1 : 0, $1.offset) }
                    .map(\.element)
                return Group(category: name, icon: icons[name], items: sorted)
            }
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await AppModel.shared?.flushOutbox(notify: false)
        do {
            lists = try await client.shoppingLists()
            OfflineCache.save(lists, as: OfflineCache.shoppingListsKey)
            if selectedList == nil { selectedListID = lists.first?.id }
            try await loadItems()
            isOffline = false
        } catch where error.isOffline {
            isOffline = true
            loadCached()
        } catch {
            report(error)
        }
    }

    func loadItems() async throws {
        guard let id = selectedListID else { items = []; return }
        let contents = try await client.shoppingItems(listID: id)
        guard contents.list.id == selectedListID else { return } // switched list meanwhile
        // Edits still queued (partial flush) stay visible.
        items = Outbox.apply(to: contents.items, listID: id)
        categories = contents.categories
        publish()
    }

    func selectList(_ id: Int) async {
        selectedListID = id
        do {
            try await loadItems()
        } catch where error.isOffline {
            isOffline = true
            loadCached()
        } catch {
            report(error)
        }
    }

    /// Last known lists and items, with queued edits on top.
    private func loadCached() {
        if lists.isEmpty, let cached = OfflineCache.load([ShoppingList].self, key: OfflineCache.shoppingListsKey) {
            lists = cached
            if selectedList == nil { selectedListID = lists.first?.id }
        }
        guard let id = selectedListID,
              let cached = OfflineCache.load(ShoppingListContents.self, key: OfflineCache.shoppingKey(id))
        else { return }
        items = Outbox.apply(to: cached.items, listID: id)
        categories = cached.categories
    }

    // MARK: - Edits

    /// Earlier edits still wait in the queue: send this one after them, in order.
    private func mustQueue(_ id: Int? = nil) -> Bool {
        (id ?? 0) < 0 || AppModel.shared.map { $0.pendingChanges > 0 } ?? (Outbox.count > 0)
    }

    func toggle(_ item: ShoppingItem) async {
        let target = !item.isChecked
        update(item.id) { $0.isChecked = target }
        if mustQueue(item.id) { return queue(.shoppingCheck(itemID: item.id, checked: target)) }
        do {
            let saved = try await client.setShoppingItem(item.id, checked: target)
            update(item.id) { $0 = saved }
            publish()
        } catch where error.isOffline {
            queue(.shoppingCheck(itemID: item.id, checked: target))
        } catch {
            update(item.id) { $0.isChecked = !target }
            report(error)
        }
    }

    func add(_ rawName: String) async {
        let (name, quantity) = Self.split(rawName)
        guard !name.isEmpty, let listID = selectedListID else { return }
        if mustQueue() { return addOffline(listID: listID, name: name, quantity: quantity) }
        do {
            let item = try await client.addShoppingItem(listID: listID, name: name, quantity: quantity)
            items.append(item)
            publish()
        } catch where error.isOffline {
            addOffline(listID: listID, name: name, quantity: quantity)
        } catch {
            report(error)
        }
    }

    private func addOffline(listID: Int, name: String, quantity: String?) {
        let temp = Outbox.makeTempID()
        items.append(ShoppingItem(id: temp, listId: listID, name: name, quantity: quantity,
                                  category: Outbox.offlineCategory))
        queue(.shoppingAdd(tempID: temp, listID: listID, name: name, quantity: quantity))
    }

    func delete(_ item: ShoppingItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        if mustQueue(item.id) { return queue(.shoppingDelete(itemID: item.id)) }
        do {
            try await client.deleteShoppingItem(item.id)
            publish()
        } catch where error.isOffline {
            queue(.shoppingDelete(itemID: item.id))
        } catch {
            items.insert(item, at: min(index, items.count))
            report(error)
        }
    }

    func clearChecked() async {
        guard let listID = selectedListID else { return }
        let removed = items.filter(\.isChecked)
        guard !removed.isEmpty else { return }
        items.removeAll(where: \.isChecked)
        if mustQueue() || removed.contains(where: { $0.id < 0 }) { return queueDeletes(removed) }
        do {
            try await client.clearCheckedShoppingItems(listID: listID, ids: removed.map(\.id))
            publish()
        } catch where error.isOffline {
            queueDeletes(removed)
        } catch {
            items.append(contentsOf: removed)
            report(error)
        }
    }

    private func queueDeletes(_ removed: [ShoppingItem]) {
        for item in removed { Outbox.enqueue(.shoppingDelete(itemID: item.id)) }
        queued()
    }

    // MARK: - Helpers

    private func queue(_ change: PendingChange) {
        Outbox.enqueue(change)
        queued()
    }

    private func queued() {
        publish()
        AppModel.shared?.refreshPending()
        // Maybe the network is back already (e.g. queued only to keep the order).
        if AppModel.shared?.isOnline == true { Task { await AppModel.shared?.flushOutbox() } }
    }

    /// Hands the open count to the widget and keeps the offline copy current.
    private func publish() {
        let name = selectedList?.name
        let open = items.filter { !$0.isChecked }.count
        if let list = selectedList {
            OfflineCache.save(ShoppingListContents(list: list, items: items, categories: categories),
                              as: OfflineCache.shoppingKey(list.id))
        }
        SnapshotStore.update {
            $0.shoppingListName = name
            $0.shoppingOpenCount = open
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.today")
        WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.shopping")
    }

    private func update(_ id: Int, _ change: (inout ShoppingItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func report(_ error: any Error) {
        errorMessage = error.userMessage
    }

    /// "2 L lait" or "lait 2 L" stay as typed; a leading number becomes the quantity: "3 pommes" → ("pommes", "3").
    nonisolated static func split(_ raw: String) -> (name: String, quantity: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ", maxSplits: 1)
        if parts.count == 2, let first = parts.first, first.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) {
            return (String(parts[1]), String(first))
        }
        return (text, nil)
    }
}
