import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case badData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        case .badData:
            "Keychain returned unexpected data."
        }
    }
}

struct KeychainRecord {
    let account: String
    let label: String?
    let generic: Data?
}

enum Keychain {
    static let service = "dev.keyfob.token"

    private static func query(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func list() throws -> [KeychainRecord] {
        var q = query()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let items = result as? [[String: Any]] else { throw KeychainError.badData }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return KeychainRecord(
                account: account,
                label: item[kSecAttrLabel as String] as? String,
                generic: item[kSecAttrGeneric as String] as? Data
            )
        }
    }

    static func read(account: String) throws -> Data {
        var q = query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data else { throw KeychainError.badData }
        return data
    }

    static func add(account: String, label: String, generic: Data, secret: Data) throws {
        var q = query(account)
        q[kSecAttrLabel as String] = label
        q[kSecAttrGeneric as String] = generic
        q[kSecAttrDescription as String] = "keyfob token"
        q[kSecValueData as String] = secret
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func update(account: String, label: String, generic: Data, secret: Data?) throws {
        var attrs: [String: Any] = [
            kSecAttrLabel as String: label,
            kSecAttrGeneric as String: generic,
        ]
        if let secret { attrs[kSecValueData as String] = secret }
        let status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
