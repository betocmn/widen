import Foundation
import Security

/// Stores connection passwords and the Particle API key as generic-password
/// items in the login keychain.
///
/// The data-protection keychain (`kSecUseDataProtectionKeychain`) is
/// intentionally not used: it requires real code-signing entitlements, which an
/// ad-hoc signed development build does not have.
public struct KeychainService: Sendable {
    public static let service = "Widen"
    static let particleAccount = "particle-api-key"
    /// The retired OpenRouter key's account. It is only ever deleted; its
    /// value is never read, so it can never end up in the Particle slot.
    static let legacyOpenRouterAccount = "openrouter-api-key"

    private enum CachedSecret: Sendable {
        case missing
        case value(String)
    }

    private final class SecretCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: CachedSecret] = [:]

        func cachedSecret(for account: String) -> CachedSecret? {
            lock.withLock {
                entries[account]
            }
        }

        func store(_ secret: String?, for account: String) {
            lock.withLock {
                entries[account] = secret.map(CachedSecret.value) ?? .missing
            }
        }
    }

    private static let secretCache = SecretCache()

    public init() {}

    static func account(for connectionID: UUID) -> String {
        "connection-\(connectionID.uuidString)"
    }

    // MARK: - Connection passwords

    public func savePassword(_ password: String, for connectionID: UUID) throws {
        try saveSecret(password, account: Self.account(for: connectionID))
    }

    public func loadPassword(for connectionID: UUID) throws -> String? {
        try loadSecret(account: Self.account(for: connectionID))
    }

    public func deletePassword(for connectionID: UUID) throws {
        try deleteSecret(account: Self.account(for: connectionID))
    }

    // MARK: - Particle API key

    public func saveParticleAPIKey(_ key: String) throws {
        try saveSecret(key, account: Self.particleAccount)
    }

    public func loadParticleAPIKey() throws -> String? {
        try loadSecret(account: Self.particleAccount)
    }

    public func deleteParticleAPIKey() throws {
        try deleteSecret(account: Self.particleAccount)
    }

    // MARK: - Retired OpenRouter API key

    public func deleteLegacyOpenRouterAPIKey() throws {
        try deleteSecret(account: Self.legacyOpenRouterAccount)
    }

    // MARK: - Generic secrets

    private func saveSecret(_ secret: String, account: String) throws {
        // An empty secret means "no stored secret" (e.g. local trust auth).
        guard !secret.isEmpty else {
            try deleteSecret(account: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8)
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery = query.merging(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AppError.keychainFailed(Self.message(for: status))
        }
        Self.secretCache.store(secret, for: account)
    }

    private func loadSecret(account: String) throws -> String? {
        if let cached = Self.secretCache.cachedSecret(for: account) {
            switch cached {
            case .missing: return nil
            case .value(let secret): return secret
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            let secret = String(data: data, encoding: .utf8)
            Self.secretCache.store(secret, for: account)
            return secret
        case errSecItemNotFound:
            Self.secretCache.store(nil, for: account)
            return nil
        default:
            throw AppError.keychainFailed(Self.message(for: status))
        }
    }

    private func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainFailed(Self.message(for: status))
        }
        Self.secretCache.store(nil, for: account)
    }

    static func message(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus \(status)"
    }
}
