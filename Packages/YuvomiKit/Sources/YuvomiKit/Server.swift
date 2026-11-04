import Foundation

/// The origin of a Yuvomi instance (scheme + host + port, no path).
public struct ServerURL: Sendable, Hashable, Codable {
    public let origin: URL

    /// Accepts what a person types: `yuvomi.local:3000`, `https://home.example.com/`, …
    /// Defaults to https when no scheme is given.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty
        else { return nil }
        parts.scheme = scheme
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let url = parts.url else { return nil }
        origin = url
    }

    public func url(_ path: String) -> URL {
        origin.appending(path: path)
    }
}

/// What the server records about this device (`POST /api/v1/auth/devices`).
public struct DeviceInfo: Sendable, Hashable {
    public let id: String
    public let name: String
    public let platform: String

    /// - Parameters:
    ///   - id: stable per install, 8–128 of `[A-Za-z0-9._-]`.
    ///   - platform: short lowercase name, e.g. `ios`, `ipados`, `macos`.
    public init(id: String, name: String, platform: String) {
        self.id = id
        self.name = String(name.prefix(100))
        self.platform = platform
    }
}

/// A signed-in device: the server it belongs to and its bearer credential.
public struct DeviceCredential: Sendable, Hashable, Codable {
    public let server: ServerURL
    public let token: String
    /// Server-side id of the device row, needed to revoke it on sign-out.
    public let deviceRowID: Int

    public init(server: ServerURL, token: String, deviceRowID: Int) {
        self.server = server
        self.token = token
        self.deviceRowID = deviceRowID
    }
}

/// `yuvomi://pair?server=<origin>&code=<code>` as shown in the web app's QR code.
public struct PairingLink: Sendable, Hashable {
    public let server: ServerURL
    public let code: String

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "yuvomi", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawServer = items.first(where: { $0.name == "server" })?.value,
              let server = ServerURL(rawServer),
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        self.server = server
        self.code = code
    }
}
