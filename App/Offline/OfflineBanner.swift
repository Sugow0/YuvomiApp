import SwiftUI

/// Strip under the title when the server is out of reach or edits are waiting to be sent.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var app
    /// The screen's own view: its last request could not reach the server.
    let offline: Bool

    var body: some View {
        let pending = app.pendingChanges
        let showOffline = offline || !app.isOnline
        if showOffline || pending > 0 {
            HStack(spacing: 8) {
                Image(systemName: showOffline ? "icloud.slash" : "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, isActive: !showOffline)
                Text(message(showOffline: showOffline, pending: pending))
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }

    private func message(showOffline: Bool, pending: Int) -> String {
        let changes = pending == 1 ? "1 modification" : "\(pending) modifications"
        if showOffline {
            return pending > 0 ? "Hors ligne · \(changes) en attente" : "Hors ligne · données enregistrées"
        }
        return "Envoi de \(changes)…"
    }
}
