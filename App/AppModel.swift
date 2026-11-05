import Foundation
import Observation
import WidgetKit
import YuvomiKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor @Observable
final class AppModel {
    enum State {
        case loading
        case signedOut
        case signedIn(DeviceCredential, YuvomiClient.User?)
    }

    private(set) var state: State = .loading
    /// Set when a `yuvomi://pair` link arrives, consumed by the sign-in screen.
    var pendingPairing: PairingLink?
    /// Set by `yuvomi://tasks` / `yuvomi://shopping` (widget taps).
    var requestedSection: HomeView.Section?

    /// For the notification delegate, which lives outside SwiftUI.
    static weak var shared: AppModel?

    let reminders = ReminderScheduler()
    private let store: CredentialStore

    init(store: CredentialStore = AppGroup.credentialStore()) {
        self.store = store
        Self.shared = self
    }

    var credential: DeviceCredential? {
        if case .signedIn(let credential, _) = state { credential } else { nil }
    }

    /// Re-reads upcoming reminders and reschedules local notifications.
    func syncReminders() async {
        guard let credential else { return }
        await reminders.sync(using: credential)
    }

    func restore() async {
        guard let credential = try? store.load() else {
            state = .signedOut
            return
        }
        state = .signedIn(credential, nil)
        await refreshUser(credential)
        await syncReminders()
    }

    func makeAuthService() throws -> AuthService {
        AuthService(device: DeviceInfo(id: try store.deviceID(), name: Self.deviceName, platform: Self.platform))
    }

    func didSignIn(_ credential: DeviceCredential) async {
        try? store.save(credential)
        WidgetCenter.shared.reloadAllTimelines()
        state = .signedIn(credential, nil)
        await refreshUser(credential)
        // First sign-in on this device: ask now, while the reason is obvious.
        await reminders.requestAuthorization()
        await syncReminders()
    }

    func signOut() async {
        if case .signedIn(let credential, _) = state {
            try? await AuthService.signOut(credential)
        }
        try? store.clear()
        await reminders.removeAll()
        SnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        state = .signedOut
    }

    func handle(url: URL) {
        switch url.host() {
        case "tasks": requestedSection = .today; return
        case "shopping": requestedSection = .shopping; return
        case "calendar": requestedSection = .calendar; return
        default: break
        }
        guard let link = PairingLink(url) else { return }
        if case .signedIn = state { return }
        pendingPairing = link
    }

    private func refreshUser(_ credential: DeviceCredential) async {
        do {
            let user = try await YuvomiClient(credential: credential).me()
            state = .signedIn(credential, user)
        } catch let error as APIError where error.code == 401 {
            // Credential revoked or expired (90 days unused).
            try? store.clear()
            state = .signedOut
        } catch {
            // Offline or server down: keep the credential, show cached UI.
        }
    }

    // MARK: - Device description

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
