import Foundation
import Testing
@testable import YuvomiKit

// MARK: - ServerURL / PairingLink

@Test(arguments: [
    ("yuvomi.local:3000", "https://yuvomi.local:3000"),
    ("  http://192.168.1.10:3000/app/ ", "http://192.168.1.10:3000"),
    ("HTTPS://home.example.com", "https://home.example.com"),
])
func serverURLNormalizes(raw: String, expected: String) throws {
    #expect(try #require(ServerURL(raw)).origin.absoluteString == expected)
}

@Test(arguments: ["", "ftp://x.com", "https://"])
func serverURLRejects(raw: String) {
    #expect(ServerURL(raw) == nil)
}

@Test func pairingLinkParses() throws {
    let url = try #require(URL(string: "yuvomi://pair?server=https%3A%2F%2Fhome.example.com&code=ABCD-1234"))
    let link = try #require(PairingLink(url))
    #expect(link.server.origin.absoluteString == "https://home.example.com")
    #expect(link.code == "ABCD-1234")
}

@Test func pairingLinkRejectsOtherHosts() throws {
    let otherHost = try #require(URL(string: "yuvomi://other?server=https://a.com&code=X"))
    let noCode = try #require(URL(string: "yuvomi://pair?server=https://a.com"))
    #expect(PairingLink(otherHost) == nil)
    #expect(PairingLink(noCode) == nil)
}

// MARK: - Auth flow against a stubbed server

/// Records requests and answers from a per-path table. Serialized: global state.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            recorded.httpBody = data
        }
        Self.seen.append(recorded)
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        let (status, body) = Self.routes[key] ?? (404, #"{"error":"Not found","code":404}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

extension StubbedNetwork { @Suite struct AuthFlowTests {
    let server = ServerURL("https://home.example.com")!
    let device = DeviceInfo(id: "device-12345678", name: "iPhone de test", platform: "ios")
    var auth: AuthService { AuthService(device: device, makeSession: { StubProtocol.session() }) }

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func passwordSignInIssuesDeviceCredential() async throws {
        StubProtocol.routes = [
            "POST /api/v1/auth/login": (200, #"{"user":{"id":1},"csrfToken":"abc"}"#),
            "POST /api/v1/auth/devices": (201, #"{"data":{"id":7,"name":"x","platform":"ios"},"credential":"yuv_secret"}"#),
            "POST /api/v1/auth/logout": (200, #"{"ok":true}"#),
        ]
        guard case .signedIn(let credential) = try await auth.signIn(server: server, username: "me", password: "pw") else {
            Issue.record("expected signedIn"); return
        }
        #expect(credential == DeviceCredential(server: server, token: "yuv_secret", deviceRowID: 7))

        let devices = try #require(StubProtocol.seen.first { $0.url?.path() == "/api/v1/auth/devices" })
        #expect(devices.value(forHTTPHeaderField: "X-CSRF-Token") == "abc")
        let body = try #require(devices.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["name": "iPhone de test", "platform": "ios", "device_id": "device-12345678"])
        #expect(StubProtocol.seen.last?.url?.path() == "/api/v1/auth/logout")
    }

    @Test func passwordSignInStopsForSecondFactor() async throws {
        StubProtocol.routes = ["POST /api/v1/auth/login": (200, #"{"twoFactorRequired":true,"recoveryAvailable":true}"#)]
        guard case .twoFactorRequired(let pending) = try await auth.signIn(server: server, username: "me", password: "pw") else {
            Issue.record("expected twoFactorRequired"); return
        }
        #expect(pending.recoveryAvailable)
    }

    @Test func badPasswordSurfacesServerError() async {
        StubProtocol.routes = ["POST /api/v1/auth/login": (401, #"{"error":"Invalid credentials.","code":401}"#)]
        await #expect(throws: APIError(error: "Invalid credentials.", code: 401)) {
            try await auth.signIn(server: server, username: "me", password: "bad")
        }
    }

    @Test func pairingRedeemsCode() async throws {
        StubProtocol.routes = [
            "POST /api/v1/auth/devices/pair/redeem": (201, #"{"data":{"id":9},"credential":"yuv_paired"}"#),
        ]
        let url = try #require(URL(string: "yuvomi://pair?server=https://home.example.com&code=C0DE"))
        let link = try #require(PairingLink(url))
        let credential = try await auth.redeemPairing(link)
        #expect(credential.token == "yuv_paired")
        #expect(credential.deviceRowID == 9)
    }
}
}

/// Every suite that uses `StubProtocol` lives here: its routes are global state.
@Suite(.serialized) enum StubbedNetwork {}
