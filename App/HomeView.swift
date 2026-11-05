import SwiftUI
import YuvomiKit

/// Sidebar on iPad/Mac, stack on iPhone — `NavigationSplitView` adapts by itself.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let credential: DeviceCredential
    let user: YuvomiClient.User?

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case today = "Aujourd'hui"
        case shopping = "Courses"
        case tasks = "Tâches"
        case settings = "Réglages"

        var id: Self { self }
        var icon: String {
            switch self {
            case .today: "sun.max"
            case .shopping: "cart"
            case .tasks: "checklist"
            case .settings: "gearshape"
            }
        }
    }

    @State private var selection: Section? = .shopping

    private var client: YuvomiClient { YuvomiClient(credential: credential) }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Yuvomi")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            #endif
        } detail: {
            NavigationStack {
                switch selection ?? .today {
                case .shopping: ShoppingView(client: client)
                case .today: TasksView(client: client, userID: user?.id)
                case .tasks: AllTasksView(client: client, userID: user?.id)
                case .settings: SettingsView(credential: credential, user: user)
                }
            }
        }
        .onChange(of: model.requestedSection, initial: true) { _, section in
            guard let section else { return }
            selection = section
            model.requestedSection = nil
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let credential: DeviceCredential
    let user: YuvomiClient.User?

    var body: some View {
        Form {
            Section("Compte") {
                LabeledContent("Utilisateur", value: user?.displayName ?? user?.username ?? "…")
                LabeledContent("Serveur", value: credential.server.origin.host() ?? credential.server.origin.absoluteString)
            }
            RemindersSettingsSection(reminders: model.reminders)
            Section {
                Button("Se déconnecter de cet appareil", role: .destructive) {
                    Task { await model.signOut() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Réglages")
    }
}
