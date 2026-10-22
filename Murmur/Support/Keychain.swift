import Foundation
import Observation
import Security

/// Stores the OpenAI API key as a generic password in the user's login Keychain.
/// The item's access control list is bound to Murmur's code signature, so other
/// apps cannot read it without the user's explicit approval.
enum Keychain {
    private static let service = "com.leonardohaddad.Murmur.openai"
    private static let account = "api-key"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Keychain: \(message)"
            }
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.app.error("Keychain read failed with status \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Murmur — OpenAI API Key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func deleteAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory cache in front of the Keychain so dictation never waits on a Keychain read.
@MainActor
@Observable
final class APIKeyStore {
    private(set) var hasKey: Bool
    @ObservationIgnored private var cachedKey: String?

    init(key: String? = Keychain.readAPIKey()) {
        cachedKey = key
        hasKey = key?.isEmpty == false
    }

    var key: String? { cachedKey }

    /// The last four characters, for display ("sk-…AB12"). Never show more than that.
    var maskedKey: String? {
        guard let key = cachedKey, key.count > 8 else { return nil }
        return "sk-…" + key.suffix(4)
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.saveAPIKey(trimmed)
        cachedKey = trimmed
        hasKey = !trimmed.isEmpty
    }

    func remove() {
        Keychain.deleteAPIKey()
        cachedKey = nil
        hasKey = false
    }
}
