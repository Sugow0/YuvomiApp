import Foundation
import Testing
@testable import YuvomiKit

private func reminder(_ id: Int, at seconds: TimeInterval) -> UpcomingReminder {
    UpcomingReminder(id: id, entityType: "task", entityId: id, entityTitle: "T\(id)",
                     firesAt: Date(timeIntervalSince1970: seconds))
}

@Test func planAddsNewAndRemovesStale() {
    let now = Date(timeIntervalSince1970: 1_000)
    let keep = reminder(1, at: 2_000)
    let fresh = reminder(2, at: 3_000)
    let scheduled = [
        ReminderPlanner.identifier(for: keep),
        "yuvomi.reminder.9.5000",          // gone from the server
        "someone.else.notification",       // not ours: never touched
    ]
    let plan = ReminderPlanner.plan(upcoming: [fresh, keep], scheduled: scheduled, now: now)
    #expect(plan.add == [fresh])
    #expect(plan.remove == ["yuvomi.reminder.9.5000"])
}

@Test func movedReminderIsRescheduled() {
    let before = reminder(1, at: 2_000)
    let after = reminder(1, at: 2_600)
    let plan = ReminderPlanner.plan(upcoming: [after], scheduled: [ReminderPlanner.identifier(for: before)],
                                    now: Date(timeIntervalSince1970: 1_000))
    #expect(plan.add == [after])
    #expect(plan.remove == [ReminderPlanner.identifier(for: before)])
}

@Test func planKeepsOnlyTheSoonestWithinLimit() {
    let upcoming = (1...5).map { reminder($0, at: TimeInterval(10_000 - $0 * 100)) }
    let plan = ReminderPlanner.plan(upcoming: upcoming, scheduled: [], now: .distantPast, limit: 2)
    #expect(plan.add.map(\.id) == [5, 4])
}

@Test func planSkipsPastReminders() {
    let plan = ReminderPlanner.plan(upcoming: [reminder(1, at: 500)], scheduled: [],
                                    now: Date(timeIntervalSince1970: 1_000))
    #expect(plan.add.isEmpty)
}

extension StubbedNetwork { @Suite struct RemindersTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func upcomingSendsWindowAndDecodesFiresAt() async throws {
        StubProtocol.routes = ["GET /api/v1/reminders/upcoming": (200, """
            {"data":[{"id":3,"entity_type":"waste_pickup","entity_id":8,"entity_title":"Verre",
                      "remind_at":"2026-11-05T07:00","dismissed":0,"fires_at":"2026-11-05T06:00:00Z"}]}
            """)]
        let from = Date(timeIntervalSince1970: 1_793_800_000)
        let reminders = try await client.upcomingReminders(from: from)
        #expect(reminders.first?.kindLabel == "Collecte des déchets")
        #expect(reminders.first?.firesAt == (try Date("2026-11-05T06:00:00Z", strategy: .iso8601)))

        let items = URLComponents(url: try #require(StubProtocol.seen.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        let fromValue = items?.first { $0.name == "from" }?.value
        let toValue = items?.first { $0.name == "to" }?.value
        #expect(fromValue?.hasSuffix("Z") == true)
        let span = try Date(try #require(toValue), strategy: .iso8601).timeIntervalSince(try Date(try #require(fromValue), strategy: .iso8601))
        #expect(span == YuvomiClient.upcomingWindow)
    }
}
}

@Test func reminderRowsReadUTCWithOrWithoutZone() throws {
    let expected = try Date("2026-11-05T10:15:00Z", strategy: .iso8601)
    #expect(Reminder.parse("2026-11-05T10:15:00") == expected)
    #expect(Reminder.parse("2026-11-05 10:15") == expected)
    #expect(Reminder.parse("2026-11-05T11:15:00+01:00") == expected)
    #expect(Reminder.parse("2026-11-05T10:15:00.000Z") == nil || Reminder.parse("2026-11-05T10:15:00.000Z") == expected)
}

extension StubbedNetwork { @Suite struct ReminderCRUDTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func missingReminderIsNil() async throws {
        StubProtocol.routes = ["GET /api/v1/reminders": (200, #"{"data":null}"#)]
        #expect(try await client.reminder(for: "task", id: 3) == nil)
        #expect(StubProtocol.seen.first?.url?.query() == "entity_type=task&entity_id=3")
    }

    @Test func setSendsUTCInstant() async throws {
        StubProtocol.routes = ["POST /api/v1/reminders": (201,
            #"{"data":{"id":5,"entity_type":"task","entity_id":3,"remind_at":"2026-11-05T10:15:00","dismissed":0}}"#)]
        let at = try Date("2026-11-05T10:15:00Z", strategy: .iso8601)
        let saved = try await client.setReminder(for: "task", id: 3, at: at)
        #expect(saved.remindAt == at)
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["remind_at"] as? String == "2026-11-05T10:15:00Z")
        #expect(json["entity_id"] as? Int == 3)
    }
}
}
