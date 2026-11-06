import Foundation
import Network
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

    /// Network reachability, for the offline banner and to resend queued edits.
    private(set) var isOnline = true
    /// Edits made offline that the server has not seen yet.
    private(set) var pendingChanges = Outbox.count
    /// Bumped when queued edits reached the server; screens reload on change.
    private(set) var syncGeneration = 0
    private let pathMonitor = NWPathMonitor()

    /// Set when the Budget section reads Actual Budget instead of Yuvomi's budget.
    var actualConfig: ActualConfig? = ActualStore.load() {
        didSet {
            if let actualConfig { try? ActualStore.save(actualConfig) } else { ActualStore.clear() }
        }
    }

    init(store: CredentialStore = AppGroup.credentialStore()) {
        self.store = store
        Self.shared = self
        pathMonitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in AppModel.shared?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: .main)
    }

    // MARK: - Offline edits

    /// Sends what was queued offline.
    /// - Parameter notify: bump `syncGeneration` so open screens reload. Screens that
    ///   flush right before fetching pass false.
    func flushOutbox(notify: Bool = true) async {
        refreshPending()
        guard let credential, pendingChanges > 0 else { return }
        let result = await Outbox.flush(YuvomiClient(credential: credential))
        refreshPending()
        guard result.sent + result.dropped > 0 else { return }
        WidgetCenter.shared.reloadAllTimelines()
        if notify { syncGeneration += 1 }
    }

    func refreshPending() {
        pendingChanges = Outbox.count
    }

    private func networkChanged(online: Bool) {
        let regained = online && !isOnline
        isOnline = online
        if regained { Task { await flushOutbox() } }
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
        await flushOutbox()
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
        Outbox.clear()
        OfflineCache.clear()
        actualConfig = nil
        refreshPending()
        WidgetCenter.shared.reloadAllTimelines()
        state = .signedOut
    }

    func handle(url: URL) {
        switch url.host() {
        case "tasks": requestedSection = .today; return
        case "shopping": requestedSection = .shopping; return
        case "calendar": requestedSection = .calendar; return
        case "meals": requestedSection = .meals; return
        case "notes": requestedSection = .notes; return
        case "budget": requestedSection = .budget; return
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
