import Foundation
import Security

public protocol CredentialStore: Sendable {
    func load() throws -> DeviceCredential?
    func save(_ credential: DeviceCredential) throws
    func clear() throws
    /// Stable per install; survives sign-out so a re-sign-in replaces the old credential.
    func deviceID() throws -> String
}

public struct KeychainError: Error, Sendable, Equatable { public let status: OSStatus }

/// Keychain-backed store. Pass an `accessGroup` later to share it with widgets.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "fr.sugow.yuvomi", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load() throws -> DeviceCredential? {
        guard let data = try readMigrating("credential") else { return nil }
        return try JSONDecoder().decode(DeviceCredential.self, from: data)
    }

    public func save(_ credential: DeviceCredential) throws {
        try write("credential", JSONEncoder().encode(credential))
    }

    public func clear() throws {
        try delete("credential")
    }

    public func deviceID() throws -> String {
        if let data = try readMigrating("device-id"), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString
        try write("device-id", Data(id.utf8))
        return id
    }

    // MARK: - Keychain primitives

    private func query(_ account: String, group: Bool = true) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if group, let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    /// Items saved before the App Group existed live in the app's default group:
    /// move them so the widget can read them.
    private func readMigrating(_ account: String) throws -> Data? {
        if let data = try read(account) { return data }
        guard accessGroup != nil, let legacy = try read(account, group: false) else { return nil }
        try? delete(account, group: false)
        try write(account, legacy)
        return legacy
    }

    private func read(_ account: String, group: Bool = true) throws -> Data? {
        var q = query(account, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    private func write(_ account: String, _ data: Data) throws {
        let q = query(account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func delete(_ account: String, group: Bool = true) throws {
        let status = SecItemDelete(query(account, group: group) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For previews and tests.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: DeviceCredential?
    private let id = UUID().uuidString

    public init(_ credential: DeviceCredential? = nil) { self.credential = credential }

    public func load() throws -> DeviceCredential? { lock.withLock { credential } }
    public func save(_ credential: DeviceCredential) throws { lock.withLock { self.credential = credential } }
    public func clear() throws { lock.withLock { credential = nil } }
    public func deviceID() throws -> String { id }
}
