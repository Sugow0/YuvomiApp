import SwiftUI
import WidgetKit
import YuvomiKit

@main
struct YuvomiWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        AgendaWidget()
        ShoppingWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.sugow.yuvomi.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Aujourd'hui")
        .description("Les tâches du jour et la liste de courses.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.state {
        case .signedOut:
            ContentUnavailableView("Non connecté", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Ouvrez Yuvomi pour vous connecter."))
                .font(.caption)
        case .ready, .stale:
            content.widgetURL(URL(string: "yuvomi://tasks"))
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: 0) { Image(systemName: "checklist") } currentValueLabel: { Text("\(entry.tasks.count)") }
                .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("\(entry.tasks.count) tâche\(entry.tasks.count == 1 ? "" : "s")").font(.headline)
                ForEach(entry.tasks.prefix(2)) { Text($0.title).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        case .systemSmall:
            small
        default:
            list(limit: family == .systemLarge ? 8 : 3)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text("\(entry.tasks.count)").font(.system(.largeTitle, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
            Text(entry.tasks.count == 1 ? "tâche aujourd'hui" : "tâches aujourd'hui")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            shopping
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { header; Spacer(); shopping }
            if entry.tasks.isEmpty {
                Spacer()
                Label("Rien de prévu aujourd'hui", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(entry.tasks.prefix(limit)) { task in
                    TaskWidgetRow(task: task, overdue: entry.overdue.contains(task))
                }
                if entry.tasks.count > limit {
                    Text("+ \(entry.tasks.count - limit) autres").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Aujourd'hui").font(.headline)
            if entry.state == .stale {
                Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Hors ligne")
            }
        }
    }

    @ViewBuilder private var shopping: some View {
        if let count = entry.shoppingOpenCount {
            Link(destination: URL(string: "yuvomi://shopping")!) {
                Label("\(count)", systemImage: "cart").font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TaskWidgetRow: View {
    let task: TaskItem
    let overdue: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: CompleteTaskIntent(taskID: task.id)) {
                Image(systemName: "circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Terminer \(task.title)")
            Text(task.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            if overdue {
                Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
            } else if let time = task.dueTime {
                Text(time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

#if os(iOS)
#Preview(as: .systemMedium) { TodayWidget() } timeline: { TodayEntry.placeholder }
#endif
