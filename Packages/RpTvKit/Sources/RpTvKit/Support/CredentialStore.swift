// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security
import Synchronization

/// Stores secrets such as Xtream passwords outside the database.
public protocol CredentialStore: Sendable {
    func password(for key: String) throws -> String?
    func setPassword(_ password: String, for key: String) throws
    func deletePassword(for key: String) throws
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "RpTv.credentials") {
        self.service = service
    }

    public func password(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for key: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(baseQuery(for: key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(for: key)
            item[kSecValueData as String] = data
            // Readable after first unlock so background refreshes work while the device is locked.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deletePassword(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Keeps secrets in memory. For tests and previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let storage = Mutex<[String: String]>([:])

    public init(_ initial: [String: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    public func password(for key: String) throws -> String? {
        storage.withLock { $0[key] }
    }

    public func setPassword(_ password: String, for key: String) throws {
        storage.withLock { $0[key] = password }
    }

    public func deletePassword(for key: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}
