import Foundation
import Observation
import WidgetKit
import YuvomiKit

/// Upcoming household events, from today, 30 days at a time.
@MainActor @Observable
final class CalendarModel {
    let client: YuvomiClient
    private static let page = 30

    private(set) var events: [CalendarEvent] = []
    private(set) var members: [HouseholdMember] = []
    private(set) var windowStart = Calendar.current.startOfDay(for: .now)
    private(set) var windowEnd = Calendar.current.date(byAdding: .day, value: page, to: .now)!
    private(set) var isLoading = false
    var errorMessage: String?

    init(client: YuvomiClient) { self.client = client }

    var agenda: [AgendaDay] { AgendaDay.group(events, from: windowStart, to: windowEnd) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        windowStart = Calendar.current.startOfDay(for: .now)
        if windowEnd < windowStart { windowEnd = Calendar.current.date(byAdding: .day, value: Self.page, to: windowStart)! }
        async let members = try? client.householdMembers()
        do {
            events = try await client.events(from: windowStart, to: windowEnd)
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
        } catch {
            errorMessage = error.userMessage
        }
        self.members = await members ?? self.members
    }

    func loadMore() async {
        let from = Calendar.current.date(byAdding: .day, value: 1, to: windowEnd)!
        let to = Calendar.current.date(byAdding: .day, value: Self.page, to: windowEnd)!
        do {
            let more = try await client.events(from: from, to: to)
            let known = Set(events.map(\.id))
            events += more.filter { !known.contains($0.id) }
            windowEnd = to
        } catch {
            errorMessage = error.userMessage
        }
    }

    func create(_ draft: EventDraft) async -> Bool {
        do {
            _ = try await client.createEvent(draft)
            await load() // the server may expand or reformat; reread the window
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func update(_ event: CalendarEvent, with draft: EventDraft) async -> Bool {
        do {
            _ = try await client.updateEvent(event.eventID, draft)
            await load()
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func delete(_ event: CalendarEvent) async -> Bool {
        let backup = events
        events.removeAll { $0.eventID == event.eventID }
        do {
            try await client.deleteEvent(event.eventID)
            WidgetCenter.shared.reloadTimelines(ofKind: "fr.sugow.yuvomi.agenda")
            return true
        } catch {
            events = backup
            errorMessage = error.userMessage
            return false
        }
    }
}
