import Foundation
import Security

/// Stores connection passwords as generic-password items in the login
/// keychain.
///
/// The data-protection keychain (`kSecUseDataProtectionKeychain`) is
/// intentionally not used: it requires real code-signing entitlements, which an
/// ad-hoc signed development build does not have.
public struct KeychainService: Sendable {
    public static let service = "Widen"

    public init() {}

    static func account(for connectionID: UUID) -> String {
        "connection-\(connectionID.uuidString)"
    }

    public func savePassword(_ password: String, for connectionID: UUID) throws {
        // An empty password means "no stored secret" (e.g. local trust auth).
        guard !password.isEmpty else {
            try deletePassword(for: connectionID)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(for: connectionID),
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8)
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addQuery = query.merging(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AppError.keychainFailed(Self.message(for: status))
        }
    }

    public func loadPassword(for connectionID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(for: connectionID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.keychainFailed(Self.message(for: status))
        }
    }

    public func deletePassword(for connectionID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(for: connectionID),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainFailed(Self.message(for: status))
        }
    }

    static func message(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus \(status)"
    }
}
