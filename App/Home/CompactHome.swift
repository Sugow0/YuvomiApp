import SwiftUI
import YuvomiKit

#if os(iOS)
/// L'iPhone : un onglet par module principal, une barre en verre flottante, et l'îlot « + »
/// qui grandit en plateau d'ajout (storyboard de la piste C).
struct CompactHome: View {
    @Binding var selection: HomeView.Section?
    let credential: DeviceCredential
    let user: YuvomiClient.User?

    @State private var tab: HomeTab = .today
    @State private var morePath: [HomeView.Section] = []
    @State private var isAdding = false
    @State private var focusNewTask = false
    @Namespace private var addSpace

    private var client: YuvomiClient { YuvomiClient(credential: credential) }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .environment(\.usesScreenHeaders, true)
                // Place pour la barre : le contenu défile dessous, visible à travers le verre.
                .safeAreaPadding(.bottom, 76)
                .scaleEffect(isAdding ? 0.94 : 1, anchor: .top)
                .allowsHitTesting(!isAdding)
                .accessibilityHidden(isAdding)

            GlassTabBar(tab: $tab, isAdding: isAdding, addSpace: addSpace) {
                withAnimation(.yTray) { isAdding = true }
            }
            // Le clavier passe par-dessus la barre au lieu de la pousser.
            .ignoresSafeArea(.keyboard)
            .accessibilityHidden(isAdding)

            if isAdding {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture(perform: closeAdd)
                    .transition(.opacity)
                    .accessibilityHidden(true)

                AddTray(addSpace: addSpace, choose: choose, close: closeAdd)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape, closeAdd)
            }
        }
        .background(Palette.porcelain)
        .sensoryFeedback(.impact(weight: .light), trigger: isAdding)
        .onChange(of: selection, initial: true) { _, section in route(section) }
        .onChange(of: tab) { _, newTab in
            selection = newTab.section ?? morePath.last
        }
        // Sans ça, rouvrir le même module depuis un widget après un retour ne ferait rien.
        .onChange(of: morePath) { _, path in
            if tab == .more { selection = path.last }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .today:
            NavigationStack {
                TodayView(client: client, userID: user?.id, focusNewTask: $focusNewTask) { section in
                    selection = section
                }
            }
        case .calendar:
            NavigationStack { CalendarView(client: client) }
        case .shopping:
            NavigationStack { ShoppingView(client: client) }
        case .meals:
            NavigationStack { MealsView(client: client) }
        case .more:
            NavigationStack(path: $morePath) {
                MoreView()
                    .navigationDestination(for: HomeView.Section.self) { destination($0) }
            }
        }
    }

    @ViewBuilder private func destination(_ section: HomeView.Section) -> some View {
        switch section {
        case .notes: NotesView(client: client)
        case .budget: BudgetRootView(client: client)
        case .tasks: AllTasksView(client: client, userID: user?.id)
        case .settings: SettingsView(credential: credential, user: user)
        case .today: TasksView(client: client, userID: user?.id)
        case .calendar: CalendarView(client: client)
        case .shopping: ShoppingView(client: client)
        case .meals: MealsView(client: client)
        }
    }

    /// Un lien de widget, une notification ou un choix dans le plateau d'ajout.
    private func route(_ section: HomeView.Section?) {
        guard let section else { return }
        if let main = HomeTab(section) {
            tab = main
        } else {
            morePath = [section]
            tab = .more
        }
    }

    private func choose(_ kind: AddKind) {
        closeAdd()
        selection = kind.section
        route(kind.section)
        if kind == .task { focusNewTask = true }
    }

    private func closeAdd() {
        withAnimation(.yTray) { isAdding = false }
    }
}

/// Ce que l'on peut ajouter depuis l'îlot.
enum AddKind: CaseIterable, Identifiable {
    case task, shopping, meal, event, expense, note

    var id: Self { self }

    var title: String {
        switch self {
        case .task: "Tâche"
        case .shopping: "Courses"
        case .meal: "Repas"
        case .event: "Évènement"
        case .expense: "Dépense"
        case .note: "Note"
        }
    }

    var icon: String {
        switch self {
        case .task: "checkmark.circle"
        case .shopping: "cart"
        case .meal: "fork.knife"
        case .event: "calendar"
        case .expense: "eurosign.circle"
        case .note: "note.text"
        }
    }

    var section: HomeView.Section {
        switch self {
        case .task: .today
        case .shopping: .shopping
        case .meal: .meals
        case .event: .calendar
        case .expense: .budget
        case .note: .notes
        }
    }
}

/// L'îlot ouvert : un plateau noir dont les tuiles arrivent en cascade.
struct AddTray: View {
    let addSpace: Namespace.ID
    let choose: (AddKind) -> Void
    let close: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Palette.onActiveSecondary.opacity(0.5))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            HStack {
                Text("Ajouter au foyer").font(Typo.trayTitle)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Palette.activeTrayInset, in: .circle)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Fermer")
            }
            .padding(.horizontal, 6)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(AddKind.allCases.enumerated()), id: \.element) { index, kind in
                    Button { choose(kind) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: kind.icon).font(.system(size: 18, weight: .semibold))
                            Text(kind.title).font(Typo.body)
                        }
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .padding(.horizontal, 14)
                        .background(Palette.activeTrayInset, in: .rect(cornerRadius: Radius.tile, style: .continuous))
                        .contentShape(.rect(cornerRadius: Radius.tile))
                    }
                    .buttonStyle(.pressable)
                    .riseIn(delay: 0.08 + Double(index) * 0.03)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .foregroundStyle(Palette.onActive)
        .background {
            // Même forme que le bouton « + » : c'est elle qui grandit, le contenu apparaît en fondu.
            RoundedRectangle(cornerRadius: Radius.tray, style: .continuous)
                .fill(Palette.activeTray)
                .matchedGeometryEffect(id: "add", in: addSpace)
        }
        .elevation(.high)
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height > 60 { close() }
            }
        )
    }
}

/// « Plus » : les modules qui n'ont pas d'onglet.
struct MoreView: View {
    private let sections: [HomeView.Section] = [.notes, .budget, .tasks, .settings]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Plus")
                    .font(Typo.screenTitle)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                Tray {
                    ForEach(sections) { section in
                        NavigationLink(value: section) {
                            HStack(spacing: 14) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 28)
                                Text(section.rawValue).font(Typo.body)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                            .trayRow()
                            .contentShape(.rect(cornerRadius: Radius.row))
                        }
                        .buttonStyle(.pressable)
                        .riseIn()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.porcelain)
        .toolbarVisibility(.hidden, for: .navigationBar)
    }
}
#endif
