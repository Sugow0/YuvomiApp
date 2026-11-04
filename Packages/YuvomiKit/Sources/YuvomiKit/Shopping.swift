import Foundation

// MARK: - Models (server/routes/shopping.js, server/db.js)

public struct ShoppingList: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public let name: String
    /// `COUNT` / `SUM` in `GET /shopping`; absent elsewhere, `null` for an empty list.
    public let itemTotal: Int?
    public let itemChecked: Int?

    public var openCount: Int { (itemTotal ?? 0) - (itemChecked ?? 0) }
}

public struct ShoppingItem: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public let listId: Int
    public var name: String
    public var quantity: String?
    public var category: String
    public var isChecked: Bool
    public var notes: String?

    enum CodingKeys: String, CodingKey { case id, listId, name, quantity, category, isChecked, notes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        listId = try c.decode(Int.self, forKey: .listId)
        name = try c.decode(String.self, forKey: .name)
        quantity = try c.decodeIfPresent(String.self, forKey: .quantity)
        category = try c.decode(String.self, forKey: .category)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // SQLite hands back 0/1.
        if let flag = try? c.decode(Bool.self, forKey: .isChecked) {
            isChecked = flag
        } else {
            isChecked = try c.decode(Int.self, forKey: .isChecked) != 0
        }
    }

    public init(id: Int, listId: Int, name: String, quantity: String? = nil, category: String,
                isChecked: Bool = false, notes: String? = nil) {
        self.id = id; self.listId = listId; self.name = name; self.quantity = quantity
        self.category = category; self.isChecked = isChecked; self.notes = notes
    }
}

public struct ShoppingCategory: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public let name: String
    /// Lucide icon name from the web app (`apple`, `milk`, …).
    public let icon: String
    public let sortOrder: Int
}

public struct ShoppingListContents: Sendable, Hashable {
    public let list: ShoppingList
    /// Already in aisle order: category, then unchecked first.
    public let items: [ShoppingItem]
    public let categories: [ShoppingCategory]
}

// MARK: - Endpoints

extension YuvomiClient {
    public func shoppingLists() async throws -> [ShoppingList] {
        try await http.send("GET", "api/v1/shopping", as: DataEnvelope<[ShoppingList]>.self).data
    }

    public func shoppingItems(listID: Int) async throws -> ShoppingListContents {
        struct Response: Decodable {
            let data: [ShoppingItem]
            let list: ShoppingList
            let categories: [ShoppingCategory]
        }
        let r = try await http.send("GET", "api/v1/shopping/\(listID)/items", as: Response.self)
        return ShoppingListContents(list: r.list, items: r.data, categories: r.categories)
    }

    /// - Parameter category: `nil` lets the server pick its default ("Sonstiges").
    public func addShoppingItem(listID: Int, name: String, quantity: String? = nil,
                                category: String? = nil) async throws -> ShoppingItem {
        struct Body: Encodable, Sendable { let name: String; let quantity: String?; let category: String? }
        return try await http.send(
            "POST", "api/v1/shopping/\(listID)/items",
            body: Body(name: name, quantity: quantity, category: category),
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<ShoppingItem>.self
        ).data
    }

    public func setShoppingItem(_ itemID: Int, checked: Bool) async throws -> ShoppingItem {
        struct Body: Encodable, Sendable { let isChecked: Bool }
        return try await http.send(
            "PATCH", "api/v1/shopping/items/\(itemID)", body: Body(isChecked: checked),
            as: DataEnvelope<ShoppingItem>.self
        ).data
    }

    public func deleteShoppingItem(_ itemID: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/shopping/items/\(itemID)", as: Empty.self)
    }

    /// Removes only the given checked items, so one ticked by someone else meanwhile stays.
    public func clearCheckedShoppingItems(listID: Int, ids: [Int]) async throws {
        struct Body: Encodable, Sendable { let ids: [Int] }
        _ = try await http.send("DELETE", "api/v1/shopping/\(listID)/items/checked", body: Body(ids: ids), as: Empty.self)
    }
}

struct DataEnvelope<T: Decodable>: Decodable { let data: T }
