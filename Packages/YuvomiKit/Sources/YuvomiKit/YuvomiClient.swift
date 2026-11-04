import Foundation

/// Authenticated client for `/api/v1`, used once the device holds a credential.
public struct YuvomiClient: Sendable {
    let http: HTTP

    public init(credential: DeviceCredential, session: URLSession = .shared) {
        http = HTTP(server: credential.server, session: session, bearer: credential.token)
    }

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
