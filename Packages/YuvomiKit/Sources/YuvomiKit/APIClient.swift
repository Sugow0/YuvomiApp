import Foundation

/// Error body the server sends: `{ error, code, reason? }`.
public struct APIError: Error, Sendable, Equatable, Decodable, LocalizedError {
    public let error: String
    public let code: Int
    public let reason: String?

    public var errorDescription: String? { error }

    public init(error: String, code: Int, reason: String? = nil) {
        self.error = error
        self.code = code
        self.reason = reason
    }
}

public enum ClientError: Error, Sendable, Equatable, LocalizedError {
    case notHTTP
    case unexpectedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .notHTTP: "Réponse invalide du serveur."
        case .unexpectedStatus(let status): "Le serveur a répondu \(status)."
        }
    }
}

/// Thin JSON transport. `bearer` is set once the device holds a credential.
struct HTTP: Sendable {
    let server: ServerURL
    let session: URLSession
    var bearer: String?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable & Sendable)? = Optional<Empty>.none,
        headers: [String: String] = [:],
        as: Response.Type = Response.self
    ) async throws -> Response {
        var url = server.url(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? Self.decoder.decode(APIError.self, from: data) { throw apiError }
            throw ClientError.unexpectedStatus(http.statusCode)
        }
        return try Self.decoder.decode(Response.self, from: data)
    }
}

struct Empty: Codable, Sendable {}
