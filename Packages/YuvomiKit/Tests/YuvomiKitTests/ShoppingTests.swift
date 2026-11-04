import Foundation
import Testing
@testable import YuvomiKit

extension StubbedNetwork { @Suite struct ShoppingTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func listsDecodeNullCountsOfEmptyList() async throws {
        StubProtocol.routes = ["GET /api/v1/shopping": (200, """
            {"data":[{"id":1,"name":"Courses","item_total":3,"item_checked":1},
                     {"id":2,"name":"Vide","item_total":0,"item_checked":null}]}
            """)]
        let lists = try await client.shoppingLists()
        #expect(lists.map(\.openCount) == [2, 0])
        #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer yuv_t")
    }

    @Test func itemsDecodeSQLiteBooleans() async throws {
        StubProtocol.routes = ["GET /api/v1/shopping/1/items": (200, """
            {"data":[{"id":10,"list_id":1,"name":"Lait","quantity":"2 L","category":"Milchprodukte","is_checked":0,"notes":null},
                     {"id":11,"list_id":1,"name":"Pain","quantity":null,"category":"Backwaren","is_checked":1}],
             "list":{"id":1,"name":"Courses"},
             "categories":[{"id":1,"name":"Backwaren","icon":"wheat","sort_order":1}],
             "version":4}
            """)]
        let contents = try await client.shoppingItems(listID: 1)
        #expect(contents.items.map(\.isChecked) == [false, true])
        #expect(contents.items.first?.quantity == "2 L")
        #expect(contents.categories.first?.icon == "wheat")
    }

    @Test func checkingSendsSnakeCaseBool() async throws {
        StubProtocol.routes = ["PATCH /api/v1/shopping/items/10": (200, """
            {"data":{"id":10,"list_id":1,"name":"Lait","category":"Milchprodukte","is_checked":1}}
            """)]
        let item = try await client.setShoppingItem(10, checked: true)
        #expect(item.isChecked)
        let body = try #require(StubProtocol.seen.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"is_checked":true}"#)
    }

    @Test func addingSendsIdempotencyKey() async throws {
        StubProtocol.routes = ["POST /api/v1/shopping/1/items": (201, """
            {"data":{"id":12,"list_id":1,"name":"Œufs","category":"Sonstiges","is_checked":0}}
            """)]
        let item = try await client.addShoppingItem(listID: 1, name: "Œufs")
        #expect(item.id == 12)
        #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Idempotency-Key") != nil)
    }
}
}
