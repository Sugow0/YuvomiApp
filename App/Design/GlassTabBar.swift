import SwiftUI

#if os(iOS)
/// Les onglets de l'iPhone. Les autres modules (notes, budget, tâches, réglages) vivent dans « Plus ».
enum HomeTab: String, CaseIterable, Identifiable {
    case today, calendar, shopping, meals, more

    var id: Self { self }

    init?(_ section: HomeView.Section) {
        switch section {
        case .today: self = .today
        case .calendar: self = .calendar
        case .shopping: self = .shopping
        case .meals: self = .meals
        default: return nil
        }
    }

    var section: HomeView.Section? {
        switch self {
        case .today: .today
        case .calendar: .calendar
        case .shopping: .shopping
        case .meals: .meals
        case .more: nil
        }
    }

    var title: String { section?.rawValue ?? "Plus" }
    var icon: String { section?.icon ?? "square.grid.2x2" }
}

/// Barre flottante en verre (Liquid Glass). L'onglet actif est une pastille qui glisse d'un
/// onglet à l'autre ; le bouton noir à droite est l'îlot qui s'ouvre en plateau d'ajout.
struct GlassTabBar: View {
    @Binding var tab: HomeTab
    let isAdding: Bool
    let addSpace: Namespace.ID
    let onAdd: () -> Void

    @Namespace private var pill

    /// Place à laisser sous le contenu : la barre (72 points avec sa marge) et un peu d'air.
    static let clearance: CGFloat = 84

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HomeTab.allCases) { item in
                tabButton(item)
            }
            Spacer(minLength: 4)
            addButton
        }
        .padding(.horizontal, 8)
        .frame(height: 68)
        .sensoryFeedback(.selection, trigger: tab)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func tabButton(_ item: HomeTab) -> some View {
        let selected = item == tab
        return Button {
            withAnimation(.ySnappy) { tab = item }
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .semibold))
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? Palette.ink : Palette.inkSecondary)
                .frame(width: selected ? 56 : 44, height: 52)
                .background {
                    if selected {
                        Capsule()
                            .fill(Palette.tray)
                            .elevation(.low)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
    }

    @ViewBuilder private var addButton: some View {
        if isAdding {
            // L'îlot est devenu le plateau d'ajout : on garde sa place.
            Color.clear.frame(width: 52, height: 52)
        } else {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.onActive)
                    .frame(width: 52, height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.tray, style: .continuous)
                            .fill(Palette.activeTray)
                            .matchedGeometryEffect(id: "add", in: addSpace)
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.92))
            .accessibilityLabel("Ajouter")
        }
    }
}
#endif
