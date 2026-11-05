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
    /// Not a Yuvomi server, or one older than 2.84 (no device sign-in yet).
    case unsupportedServer

    public var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            "Ce serveur Yuvomi est trop ancien pour l'app. Mettez-le à jour en version 2.84 ou plus récente."
        case .notHTTP: "Réponse invalide du serveur."
        case .unexpectedStatus(let status): "Le serveur a répondu \(status)."
        }
    }
}

/// A body whose keys go out exactly as written, not snake_cased.
protocol VerbatimKeys {}

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

    /// For the few routes that read camelCase keys (e.g. `listId` in /meals).
    static let verbatimEncoder = JSONEncoder()

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
            request.httpBody = try (body is any VerbatimKeys ? Self.verbatimEncoder : Self.encoder).encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? Self.decoder.decode(APIError.self, from: data) { throw apiError }
            throw ClientError.unexpectedStatus(http.statusCode)
        }
        // 204 No Content (e.g. DELETE /calendar/:id).
        if data.isEmpty, let empty = Empty() as? Response { return empty }
        return try Self.decoder.decode(Response.self, from: data)
    }
}

struct Empty: Codable, Sendable {}

extension Error {
    /// True when a request stopped because its task went away (screen left, pull-to-refresh
    /// restarted, …) rather than because something failed.
    public var isCancellation: Bool {
        if self is CancellationError { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        return (self as NSError).domain == NSURLErrorDomain && (self as NSError).code == NSURLErrorCancelled
    }

    /// What to show the person, or nil when there is nothing to tell (cancellation).
    public var userMessage: String? { isCancellation ? nil : localizedDescription }
}
