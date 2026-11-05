import Foundation
import Testing
@testable import YuvomiKit

private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}

private func day(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
    paris.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

@Test func readsTheThreeTimeForms() throws {
    #expect(EventTime("2026-11-05") == .day(year: 2026, month: 11, day: 5))
    #expect(try #require(EventTime("2026-11-05T18:30")).date(in: paris) == day(5, 18, 30))
    #expect(try #require(EventTime("2026-11-05T18:30:00")).date(in: paris) == day(5, 18, 30))
    #expect(try #require(EventTime("2026-11-05T17:30:00Z")).date(in: paris) == day(5, 18, 30))
    #expect(try #require(EventTime("2026-11-05T19:30:00+02:00")).date(in: paris) == day(5, 18, 30))
    #expect(try #require(EventTime("2026-11-05T17:30Z")).date(in: paris) == day(5, 18, 30))
    #expect(EventTime("demain") == nil)
}

@Test func agendaRepeatsMultiDayEventsAndSortsAllDayFirst() {
    let trip = CalendarEvent(eventID: 1, title: "Vacances", start: .day(year: 2026, month: 11, day: 4),
                             end: .day(year: 2026, month: 11, day: 6))
    let dinner = CalendarEvent(eventID: 2, title: "Dîner", start: EventTime("2026-11-05T20:00")!,
                               end: EventTime("2026-11-05T22:00")!)
    let late = CalendarEvent(eventID: 3, title: "Soirée", start: EventTime("2026-11-07T21:00")!,
                             end: EventTime("2026-11-08T00:00")!)
    let agenda = AgendaDay.group([dinner, trip, late], from: day(5), to: day(10), calendar: paris)
    #expect(agenda.map(\.day) == [day(5), day(6), day(7)]) // starts at the window, midnight end stays on the 7th
    #expect(agenda.first?.events.map(\.title) == ["Vacances", "Dîner"])
}

@Test func draftSendsWallClockOrDays() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let timed = EventDraft(title: " Dentiste ", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600))
    let json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(timed)) as? [String: Any])
    #expect(json["title"] as? String == "Dentiste")
    #expect((json["start_datetime"] as? String)?.count == 16)
    #expect(json["location"] is NSNull)
    #expect(json["assigned_to"] == nil)
    #expect(EventDraft.format(day(5, 9), dayOnly: true, calendar: paris) == "2026-11-05")
    #expect(EventDraft.format(day(5, 9, 5), dayOnly: false, calendar: paris) == "2026-11-05T09:05")
}

extension StubbedNetwork { @Suite struct CalendarTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func listsEventsWithColourFallbackAndOccurrenceIdentity() async throws {
        StubProtocol.routes = ["GET /api/v1/calendar": (200, """
            {"data":[
              {"id":4,"title":"Piscine","start_datetime":"2026-11-05T17:00","end_datetime":"2026-11-05T18:00","all_day":0,
               "recurrence_rule":"FREQ=WEEKLY","color":null,"cal_color":"#00ff00",
               "assigned_users":[{"id":2,"display_name":"Léa","color":"#ff0000","avatar_data":null}]},
              {"id":4,"title":"Piscine","start_datetime":"2026-11-12T17:00","end_datetime":"2026-11-12T18:00","all_day":0,
               "recurrence_rule":"FREQ=WEEKLY","color":null,"cal_color":"#00ff00","assigned_users":[]}
            ],"from":"2026-11-05","to":"2026-12-05"}
            """)]
        let events = try await client.events(from: day(5), to: day(30))
        #expect(events.map(\.displayColor) == ["#ff0000", "#00ff00"])
        #expect(Set(events.map(\.id)).count == 2)
        #expect(events.first?.isEditable == false)
        #expect(StubProtocol.seen.first?.url?.query()?.hasPrefix("from=2026-11-05&to=") == true)
    }

    @Test func deleteAcceptsNoContent() async throws {
        StubProtocol.routes = ["DELETE /api/v1/calendar/4": (204, "")]
        try await client.deleteEvent(4)
    }
}
}
