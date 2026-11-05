import Foundation

/// Turns a sign-in (password or pairing code) into a device credential.
///
/// Server flow (`server/auth.js`):
/// - Password: `POST /auth/login` opens a cookie session → optional `POST /auth/2fa/verify`
///   → `POST /auth/devices` (session + `X-CSRF-Token`) issues the credential
///   → `POST /auth/logout` drops the temporary session.
/// - Pairing: `POST /auth/devices/pair/redeem` with the code from the web app's QR.
public struct AuthService: Sendable {
    private let device: DeviceInfo
    private let makeSession: @Sendable () -> URLSession

    /// - Parameter makeSession: a fresh session per sign-in so cookies never outlive it.
    public init(device: DeviceInfo, makeSession: @escaping @Sendable () -> URLSession = AuthService.ephemeralSession) {
        self.device = device
        self.makeSession = makeSession
    }

    public static let ephemeralSession: @Sendable () -> URLSession = {
        URLSession(configuration: .ephemeral)
    }

    public enum PasswordResult: Sendable {
        case signedIn(DeviceCredential)
        case twoFactorRequired(PendingTwoFactor)
    }

    /// Holds the half-open session between password and second factor.
    public struct PendingTwoFactor: Sendable {
        fileprivate let http: HTTP
        public let recoveryAvailable: Bool
    }

    public func signIn(server: ServerURL, username: String, password: String) async throws -> PasswordResult {
        let http = HTTP(server: server, session: makeSession())
        try await Self.requireNativeAPI(http)
        let response: LoginResponse = try await http.send(
            "POST", "api/v1/auth/login", body: LoginBody(username: username, password: password)
        )
        if response.twoFactorRequired == true {
            return .twoFactorRequired(PendingTwoFactor(http: http, recoveryAvailable: response.recoveryAvailable ?? false))
        }
        return .signedIn(try await issueCredential(http, csrf: response.csrfToken))
    }

    public func verifySecondFactor(_ pending: PendingTwoFactor, code: String) async throws -> DeviceCredential {
        let response: LoginResponse = try await pending.http.send(
            "POST", "api/v1/auth/2fa/verify", body: CodeBody(code: code)
        )
        return try await issueCredential(pending.http, csrf: response.csrfToken)
    }

    public func redeemPairing(_ link: PairingLink) async throws -> DeviceCredential {
        let http = HTTP(server: link.server, session: makeSession())
        try await Self.requireNativeAPI(http)
        let response: DeviceResponse = try await http.send(
            "POST", "api/v1/auth/devices/pair/redeem",
            body: RedeemBody(code: link.code, name: device.name, platform: device.platform, deviceId: device.id)
        )
        return DeviceCredential(server: link.server, token: response.credential, deviceRowID: response.data.id)
    }

    private func issueCredential(_ http: HTTP, csrf: String?) async throws -> DeviceCredential {
        let csrfToken: String
        if let csrf {
            csrfToken = csrf
        } else {
            csrfToken = try await http.send("GET", "api/v1/auth/me", as: MeSessionResponse.self).csrfToken
        }
        let headers = ["X-CSRF-Token": csrfToken]
        let response: DeviceResponse = try await http.send(
            "POST", "api/v1/auth/devices",
            body: DeviceBody(name: device.name, platform: device.platform, deviceId: device.id),
            headers: headers
        )
        // Best effort: the credential is already ours, the session is no longer needed.
        _ = try? await http.send("POST", "api/v1/auth/logout", body: Empty(), headers: headers, as: Empty.self)
        return DeviceCredential(server: http.server, token: response.credential, deviceRowID: response.data.id)
    }

    /// Revokes this device on the server. `POST /auth/logout` is a no-op for a token,
    /// so the device row itself is deleted.
    public static func signOut(_ credential: DeviceCredential, session: URLSession = .shared) async throws {
        let http = HTTP(server: credential.server, session: session, bearer: credential.token)
        _ = try await http.send("DELETE", "api/v1/auth/devices/\(credential.deviceRowID)", as: Empty.self)
    }

    /// Native-client contract version this app is built against (`client_api`, server 2.84+).
    public static let requiredClientAPI = 1

    /// `GET /api/v1/version` is public. Older servers answer without `client_api`:
    /// fail here with a clear message instead of a confusing 401/404 after the password.
    static func requireNativeAPI(_ http: HTTP) async throws {
        struct Version: Decodable { let product: String?; let clientApi: Int? }
        let version = try await http.send("GET", "api/v1/version", as: Version.self)
        guard (version.clientApi ?? 0) >= requiredClientAPI else { throw ClientError.unsupportedServer }
    }
}

// MARK: - Wire types

private struct LoginBody: Encodable, Sendable { let username: String; let password: String }
private struct CodeBody: Encodable, Sendable { let code: String }
private struct DeviceBody: Encodable, Sendable { let name: String; let platform: String; let deviceId: String }
private struct RedeemBody: Encodable, Sendable {
    let code: String; let name: String; let platform: String; let deviceId: String
}

private struct LoginResponse: Decodable {
    let twoFactorRequired: Bool?
    let recoveryAvailable: Bool?
    let csrfToken: String?
}

private struct MeSessionResponse: Decodable { let csrfToken: String }

private struct DeviceResponse: Decodable {
    struct Device: Decodable { let id: Int }
    let data: Device
    let credential: String
}
