import Foundation
import Testing
@testable import YuvomiKit

@Suite struct OutboxMergingTests {
    @Test func lastCheckWins() {
        var queue = Outbox.merging(.shoppingCheck(itemID: 1, checked: true), into: [])
        queue = Outbox.merging(.shoppingCheck(itemID: 1, checked: false), into: queue)
        #expect(queue == [.shoppingCheck(itemID: 1, checked: false)])
    }

    @Test func deletingAnOfflineItemForgetsIt() {
        var queue = Outbox.merging(.shoppingAdd(tempID: -5, listID: 1, name: "Lait", quantity: nil), into: [])
        queue = Outbox.merging(.shoppingCheck(itemID: -5, checked: true), into: queue)
        queue = Outbox.merging(.shoppingDelete(itemID: -5), into: queue)
        #expect(queue.isEmpty)
    }

    @Test func checkingAnOfflineItemKeepsItsCreation() {
        var queue = Outbox.merging(.shoppingAdd(tempID: -5, listID: 1, name: "Lait", quantity: nil), into: [])
        queue = Outbox.merging(.shoppingCheck(itemID: -5, checked: true), into: queue)
        #expect(queue.count == 2)
    }

    @Test func overlayShowsQueuedEdits() {
        let items = [ShoppingItem(id: 1, listId: 1, name: "Pain", category: "Backwaren"),
                     ShoppingItem(id: 2, listId: 1, name: "Œufs", category: "Sonstiges")]
        let queue: [PendingChange] = [
            .shoppingCheck(itemID: 1, checked: true),
            .shoppingDelete(itemID: 2),
            .shoppingAdd(tempID: -1, listID: 1, name: "Lait", quantity: "2"),
            .shoppingAdd(tempID: -2, listID: 9, name: "Autre liste", quantity: nil),
        ]
        let shown = Outbox.apply(to: items, listID: 1, queue: queue)
        #expect(shown.map(\.name) == ["Pain", "Lait"])
        #expect(shown.first?.isChecked == true)
        // Applying twice changes nothing (cache already holds the overlay).
        #expect(Outbox.apply(to: shown, listID: 1, queue: queue) == shown)
    }

    @Test func offlineErrorsAreRecognised() {
        #expect(URLError(.notConnectedToInternet).isOffline)
        #expect(URLError(.timedOut).isOffline)
        #expect(!APIError(error: "Introuvable", code: 404).isOffline)
    }
}

extension StubbedNetwork { @Suite struct OutboxFlushTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func replaysInOrderAndMapsTemporaryIDs() async {
        StubProtocol.routes = [
            "POST /api/v1/shopping/1/items": (201, #"{"data":{"id":42,"list_id":1,"name":"Lait","category":"Sonstiges","is_checked":0}}"#),
            "PATCH /api/v1/shopping/items/42": (200, #"{"data":{"id":42,"list_id":1,"name":"Lait","category":"Sonstiges","is_checked":1}}"#),
            "PATCH /api/v1/tasks/7/status": (200, #"{"data":{"id":7,"status":"done"}}"#),
        ]
        let result = await Outbox.send([
            .shoppingAdd(tempID: -3, listID: 1, name: "Lait", quantity: nil),
            .shoppingCheck(itemID: -3, checked: true),
            .taskStatus(taskID: 7, status: .done),
        ], with: client)
        #expect(result == Outbox.FlushResult(sent: 3, dropped: 0, remaining: 0))
        #expect(StubProtocol.seen.map { $0.url?.path() } == [
            "/api/v1/shopping/1/items", "/api/v1/shopping/items/42", "/api/v1/tasks/7/status",
        ])
    }

    @Test func dropsRefusedChangesAndKeepsGoing() async {
        StubProtocol.routes = [
            "PATCH /api/v1/shopping/items/1": (404, #"{"error":"Not found","code":404}"#),
            "PATCH /api/v1/tasks/7/status": (200, #"{"data":{"id":7,"status":"done"}}"#),
        ]
        let result = await Outbox.send([
            .shoppingCheck(itemID: 1, checked: true),
            .taskStatus(taskID: 7, status: .done),
        ], with: client)
        #expect(result == Outbox.FlushResult(sent: 1, dropped: 1, remaining: 0))
    }

    @Test func stopsOnServerTroubleAndKeepsTheRest() async {
        StubProtocol.routes = [
            "PATCH /api/v1/shopping/items/1": (503, #"{"error":"Down","code":503}"#),
        ]
        let result = await Outbox.send([
            .shoppingCheck(itemID: 1, checked: true),
            .taskStatus(taskID: 7, status: .done),
        ], with: client)
        #expect(result == Outbox.FlushResult(sent: 0, dropped: 0, remaining: 2))
    }
} }
