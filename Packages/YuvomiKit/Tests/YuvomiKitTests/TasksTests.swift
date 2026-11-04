import Foundation
import Testing
@testable import YuvomiKit

@Test func bucketsSplitByDueDate() {
    let tasks = [
        TaskItem(id: 1, title: "Retard", dueDate: "2026-11-01"),
        TaskItem(id: 2, title: "Soir", dueDate: "2026-11-04", dueTime: "19:00"),
        TaskItem(id: 3, title: "Matin", dueDate: "2026-11-04", dueTime: "08:00"),
        TaskItem(id: 4, title: "Sans date"),
        TaskItem(id: 5, title: "Demain", dueDate: "2026-11-05"),
    ]
    let buckets = TodayBuckets(tasks, today: "2026-11-04")
    #expect(buckets.overdue.map(\.id) == [1])
    #expect(buckets.today.map(\.id) == [3, 2])
    #expect(buckets.undated.map(\.id) == [4])
}

@Test func dayKeyIsISO() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23, minute: 30)))
    #expect(TodayBuckets.dayKey(date, calendar: calendar) == "2026-11-04")
}

extension StubbedNetwork { @Suite struct TasksTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func listingSendsRepeatedStatusAndDecodes() async throws {
        StubProtocol.routes = ["GET /api/v1/tasks": (200, """
            {"data":[{"id":1,"title":"Sortir les poubelles","status":"in_progress","priority":"high",
                      "category":"household","due_date":"2026-11-04","due_time":null,
                      "assigned_users":[{"id":2,"display_name":"Alex","color":"#f00"}],
                      "subtasks":[{"id":5,"title":"Verre","status":"done"},{"id":6,"title":"Carton","status":"open"}]}]}
            """)]
        let tasks = try await client.tasks()
        #expect(tasks.first?.status == .inProgress)
        #expect(tasks.first?.priority == .high)
        #expect(tasks.first?.assignedUsers.first?.displayName == "Alex")
        #expect(tasks.first?.subtasksDone == 1)
        let query = StubProtocol.seen.first?.url?.query()
        #expect(query == "status=open&status=in_progress")
    }

    @Test func createdTaskDecodesWithoutJoins() async throws {
        StubProtocol.routes = ["POST /api/v1/tasks": (201, """
            {"data":{"id":9,"title":"Appeler le plombier","status":"open","priority":"none","due_date":"2026-11-04"}}
            """)]
        let task = try await client.addTask(title: "Appeler le plombier", dueDate: "2026-11-04")
        #expect(task.assignedUsers.isEmpty)
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["title": "Appeler le plombier", "due_date": "2026-11-04"])
    }

    @Test func completingReturnsNextOccurrence() async throws {
        StubProtocol.routes = ["PATCH /api/v1/tasks/1/status": (200, """
            {"data":{"id":1,"status":"done","archived_at":null,"next_due_date":"2026-11-11"}}
            """)]
        let change = try await client.setTaskStatus(1, .done)
        #expect(change.nextDueDate == "2026-11-11")
    }
}
}
