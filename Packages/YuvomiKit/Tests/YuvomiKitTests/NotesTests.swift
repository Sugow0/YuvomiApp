import Foundation
import Testing
@testable import YuvomiKit

@Test func checklistLinesKeepTheServersNumbering() {
    let content = "# Vacances\r\nÀ prendre :\n- [ ] Crème solaire\n  * [x] Passeports\n-[ ] pas une case\n\nMerci"
    let blocks = NoteBlock.parse(content)
    #expect(blocks.count == 4)
    guard case let .checklist(first) = blocks[1], case let .checklist(second) = blocks[2] else {
        Issue.record("expected two checklist items"); return
    }
    #expect(first.line == 2 && first.text == "Crème solaire" && !first.checked)
    #expect(second.line == 3 && second.checked && second.raw == "  * [x] Passeports")
    #expect(blocks[3] == .text("-[ ] pas une case\n\nMerci"))
}

@Test func previewAndProgress() {
    let note = Note(id: 1, content: "## Courses du week-end\n- [x] Pain\n- [ ] Lait")
    #expect(note.preview == "Courses du week-end")
    #expect(note.checklistProgress?.done == 1)
    #expect(note.checklistProgress?.total == 2)
    #expect(Note(id: 2, content: "- [ ] Appeler").preview == "☐ Appeler")
}

extension StubbedNetwork { @Suite struct NotesTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func listDecodesFlagsAndCheckSendsExpect() async throws {
        StubProtocol.routes = [
            "GET /api/v1/notes": (200, """
                {"data":[{"id":3,"title":null,"content":"- [ ] Pain","color":"#FFEB3B","pinned":1,"locked":0,
                          "visibility":"all","categories":[],"updated_at":"2026-11-05 10:00:00"}]}
                """),
            "PATCH /api/v1/notes/3/check": (200, #"{"data":{"id":3,"content":"- [x] Pain","pinned":1,"categories":[]}}"#),
        ]
        let note = try #require(try await client.notes().first)
        #expect(note.isPinned)
        #expect(note.updatedAt != nil)
        guard case let .checklist(item) = note.blocks.first else { Issue.record("no item"); return }
        let ticked = try await client.checkNoteItem(note.id, item, checked: true)
        #expect(ticked.checklistProgress?.done == 1)
        let body = try #require(StubProtocol.seen.last?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["expect"] as? String == "- [ ] Pain")
        #expect(json["line"] as? Int == 0)
    }

    @Test func updateSendsNullTitle() async throws {
        StubProtocol.routes = ["PUT /api/v1/notes/3": (200, #"{"data":{"id":3,"content":"x","pinned":0,"categories":[]}}"#)]
        _ = try await client.updateNote(3, title: "  ", content: "x", color: nil)
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["title"] is NSNull)
        #expect(json["color"] == nil)
    }
}
}
