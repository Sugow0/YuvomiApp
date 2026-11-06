import SwiftUI
import UserNotifications

@main
struct YuvomiApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.restore() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.flushOutbox(); await model.syncReminders() } }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #else
        .backgroundTask(.appRefresh(ReminderScheduler.refreshTaskID)) {
            await AppModel.shared?.flushOutbox()
            await AppModel.shared?.syncReminders()
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn(let credential, let user):
            HomeView(credential: credential, user: user)
        }
    }
}
