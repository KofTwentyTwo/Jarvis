import Foundation
import Security

public struct SystemKeychainStore: KeychainStore {
    public init() {}

    public func set(_ value: String, for item: KeychainItem) throws {
        let data = Data(value.utf8)
        // SEC-01 / D-10 / CR-01: "never leaves this device". Every write is
        // pinned to device-only, non-synchronizable attributes:
        //   - kSecAttrAccessibleWhenUnlockedThisDeviceOnly: readable only on
        //     this unlocked device; never migrated to a new device via
        //     Time Machine / Migration Assistant / iCloud Backup.
        //   - kSecAttrSynchronizable = false: excluded from iCloud Keychain
        //     sync regardless of user settings.
        // On the legacy file-based macOS keychain `kSecAttrAccessible` is
        // accepted on write but not readback-queryable; we still pass it so
        // that any future migration to the data-protection keychain (which
        // does enforce the attribute) inherits the correct class.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func get(_ item: KeychainItem) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let s = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedStatus(status)
            }
            return s
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ item: KeychainItem) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
