import Foundation
import Observation
import YuvomiKit

/// Ce qui accompagne les tâches sur l'écran Aujourd'hui : les repas du jour et ce qu'il reste
/// de l'agenda. En cas d'échec réseau, on garde ce qu'on avait (ou le snapshot des widgets).
@MainActor @Observable
final class TodayExtrasModel {
    private let client: YuvomiClient

    private(set) var agenda: [AgendaItem] = []
    private(set) var meals: [MealSummary] = []

    init(client: YuvomiClient) {
        self.client = client
        // Le snapshot des widgets n'est pas daté par jour : on ne garde que les évènements qui
        // commencent aujourd'hui. Les repas, eux, arrivent avec le premier chargement.
        let todays = (SnapshotStore.load()?.agenda ?? []).filter { item in
            item.start.map(Calendar.current.isDateInToday) ?? false
        }
        agenda = TodayAgenda.remainingItems(todays)
    }

    func load() async {
        let todayKey = TodayBuckets.dayKey()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let client = self.client
        async let events = try? client.events(from: start, to: end)
        async let week = try? client.mealWeek(containing: todayKey)
        if let fetched = await events {
            agenda = TodayAgenda.remaining(fetched)
        } else {
            // Hors ligne : on retire au moins ce qui est terminé.
            agenda = TodayAgenda.remainingItems(agenda)
        }
        if let fetchedWeek = await week {
            meals = TodayAgenda.meals(fetchedWeek, on: todayKey)
        }
    }

    /// Le repas à mettre en avant : celui de midi le matin, celui du soir ensuite.
    var highlight: MealHighlight? {
        let hour = Calendar.current.component(.hour, from: .now)
        let lunch = meals.filter { $0.kind == .lunch }.map(\.title)
        let dinner = meals.filter { $0.kind == .dinner }.map(\.title)
        if hour < 14, !lunch.isEmpty {
            return MealHighlight(
                label: "Ce midi",
                title: lunch.formatted(.list(type: .and)),
                note: dinner.isEmpty ? nil : "Ce soir : " + dinner.formatted(.list(type: .and))
            )
        }
        if !dinner.isEmpty {
            return MealHighlight(label: "Ce soir", title: dinner.formatted(.list(type: .and)), note: nil)
        }
        return nil
    }
}

struct MealHighlight: Equatable {
    let label: String
    let title: String
    let note: String?
}

extension TodayAgenda {
    /// Les évènements du snapshot qui ne sont pas encore passés.
    static func remainingItems(_ items: [AgendaItem], now: Date = .now) -> [AgendaItem] {
        items.filter { item in
            if item.isAllDay { return true }
            return (item.end ?? item.start ?? now) > now
        }
    }
}
