import Foundation

/// Authenticated client for `/api/v1`, used once the device holds a credential.
public struct YuvomiClient: Sendable {
    let http: HTTP

    public init(credential: DeviceCredential, session: URLSession = YuvomiClient.session) {
        http = HTTP(server: credential.server, session: session, bearer: credential.token)
    }

    /// Gives up after 15 s instead of 60 s, so a bad network falls back to offline mode quickly.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public struct User: Sendable, Decodable, Hashable {
        public let id: Int
        public let username: String
        public let displayName: String?
        public let avatarColor: String?
        public let role: String?
    }

    public func me() async throws -> User {
        struct Response: Decodable { let user: User }
        return try await http.send("GET", "api/v1/auth/me", as: Response.self).user
    }
}
