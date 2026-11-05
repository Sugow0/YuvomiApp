import SwiftUI
import YuvomiKit

/// One task line. With `wholeRowToggles` the row is the checkbox (today screen); without it
/// only the circle toggles, so the row can sit in a `NavigationLink` (all-tasks screen).
struct TaskRow: View {
    let task: TaskItem
    let showDate: Bool
    var wholeRowToggles = true
    let toggle: () -> Void

    var body: some View {
        Group {
            if wholeRowToggles {
                Button(action: toggle) { content(checkbox: checkmark) }
                    .buttonStyle(.plain)
            } else {
                content(checkbox: Button(action: toggle) { checkmark }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(task.isDone ? "Rouvrir" : "Terminer"))
            }
        }
        .sensoryFeedback(.success, trigger: task.isDone) { _, done in done }
    }

    private var checkmark: some View {
        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
            .contentTransition(.symbolEffect(.replace))
    }

    private func content(checkbox: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let flag = PriorityFlag(task.priority), !task.isDone {
                        Image(systemName: "flag.fill").foregroundStyle(flag.color).font(.caption)
                            .accessibilityLabel(flag.label)
                    }
                    Text(task.title)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    if task.isRecurring {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Récurrente")
                    }
                }
                details
            }
            Spacer()
            if task.status == .inProgress && !task.isDone {
                Text("En cours").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var details: some View {
        let parts = detailParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailParts: [String] {
        var parts: [String] = []
        if showDate, let key = task.dueDate { parts.append(DayKey.short(key)) }
        if let time = task.dueTime { parts.append(time) }
        if !task.subtasks.isEmpty { parts.append("\(task.subtasksDone)/\(task.subtasks.count)") }
        let names = task.assignedUsers.compactMap(\.displayName)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts
    }
}

struct PriorityFlag {
    let color: Color
    let label: String

    init?(_ priority: TaskItem.Priority) {
        switch priority {
        case .urgent: color = .red; label = "Urgent"
        case .high: color = .orange; label = "Priorité haute"
        case .medium: color = .yellow; label = "Priorité moyenne"
        case .low, .none: return nil
        }
    }
}

/// `YYYY-MM-DD` / `HH:MM` ↔ `Date`, in the device's calendar (the server stores wall-clock values).
enum DayKey {
    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func time(_ value: String, on day: Date = .now) -> Date? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    static func timeKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func short(_ key: String) -> String {
        guard let date = date(key) else { return key }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
