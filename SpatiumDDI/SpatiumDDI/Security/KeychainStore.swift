//
//  KeychainStore.swift
//  SpatiumDDI
//

import Foundation
import Security

/// Thin wrapper over the Keychain's generic-password items.
///
/// Trust decisions live here rather than in `UserDefaults` because a pin is a
/// security assertion — an attacker who can rewrite it can silently redirect the
/// app to a server the operator never approved. The API token has its own
/// store, `TokenStore`, because it needs what this one never does: a
/// this-device-only class that is unreadable while locked, and an optional
/// biometric or passcode access control on top.
nonisolated struct KeychainStore: Sendable {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "io.spatiumddi.SpatiumDDI") {
        self.service = service
    }

    enum StoreError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func data(forAccount account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw StoreError.unexpectedStatus(status)
        }
    }

    func set(_ data: Data, forAccount account: String) throws {
        let query = query(account: account)
        // Trust pins are needed before first unlock is irrelevant here, but they
        // must never sync to another device — this install's decisions are its own.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.unexpectedStatus(addStatus) }
        default:
            throw StoreError.unexpectedStatus(status)
        }
    }

    func removeItem(forAccount account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }
}
