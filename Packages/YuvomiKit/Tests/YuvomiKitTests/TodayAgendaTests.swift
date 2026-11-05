import Foundation
import Testing
@testable import YuvomiKit

private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}

@Test func remainingKeepsAllDayAndUnfinishedEvents() {
    let now = paris.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
    let events = [
        CalendarEvent(eventID: 1, title: "Réunion", start: EventTime("2026-11-05T09:00")!, end: EventTime("2026-11-05T10:00")!),
        CalendarEvent(eventID: 2, title: "Dentiste", start: EventTime("2026-11-05T17:00")!, end: EventTime("2026-11-05T17:30")!),
        CalendarEvent(eventID: 3, title: "Vacances", start: .day(year: 2026, month: 11, day: 4), end: .day(year: 2026, month: 11, day: 8)),
        CalendarEvent(eventID: 4, title: "Déjeuner", start: EventTime("2026-11-05T11:30")!, end: EventTime("2026-11-05T13:00")!),
        CalendarEvent(eventID: 5, title: "Demain", start: EventTime("2026-11-06T09:00")!),
    ]
    #expect(TodayAgenda.remaining(events, now: now, calendar: paris).map(\.title) == ["Vacances", "Déjeuner", "Dentiste"])
}

@Test func mealSentenceFollowsTheTimeOfDay() {
    let meals = [MealSummary(title: "Salade", kind: .lunch), MealSummary(title: "Lasagnes", kind: .dinner)]
    #expect(TodayAgenda.mealSentence(meals, hour: 11) == "Ce midi : Salade. Ce soir : Lasagnes.")
    #expect(TodayAgenda.mealSentence(meals, hour: 18) == "Ce soir : Lasagnes.")
    #expect(TodayAgenda.mealSentence([], hour: 18) == "Aucun repas prévu aujourd'hui.")
}

@Test func oldSnapshotsStillDecode() throws {
    let old = #"{"savedAt":0,"tasks":[],"shoppingListName":"Courses","shoppingOpenCount":3}"#
    let snapshot = try JSONDecoder().decode(TodaySnapshot.self, from: Data(old.utf8))
    #expect(snapshot.agenda == nil)
    #expect(snapshot.shoppingOpenCount == 3)
}
