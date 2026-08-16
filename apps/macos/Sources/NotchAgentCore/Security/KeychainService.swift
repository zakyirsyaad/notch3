import Foundation
import Security

/// Errors encountered during Keychain operations.
public enum KeychainError: Error, LocalizedError, Equatable {
    case duplicateItem
    case itemNotFound
    case unexpectedData
    case accessControlCreationFailed
    case unhandledError(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "Item already exists in Keychain."
        case .itemNotFound:
            return "Item not found in Keychain."
        case .unexpectedData:
            return "Keychain returned unexpected data format."
        case .accessControlCreationFailed:
            return "Failed to create biometric SecAccessControl."
        case .unhandledError(let status):
            return "Keychain operation failed with OSStatus code \(status)."
        }
    }
}

/// Protocol defining Keychain access operations.
public protocol KeychainServiceProtocol: Sendable {
    func saveSecret(key: String, data: Data) throws
    func saveSecret(key: String, data: Data, requireBiometrics: Bool) throws
    func loadSecret(key: String) throws -> Data?
    func deleteSecret(key: String) throws
    func exists(key: String) throws -> Bool
}

/// Production implementation of Keychain operations using macOS Security framework.
public final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
    public let serviceName: String
    public let accessGroup: String?

    public init(serviceName: String = "com.notch.agent.security", accessGroup: String? = nil) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
    }

    public func saveSecret(key: String, data: Data) throws {
        try saveSecret(key: key, data: data, requireBiometrics: false)
    }

    public func saveSecret(key: String, data: Data, requireBiometrics: Bool) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        if requireBiometrics {
            var error: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .biometryAny,
                &error
            ) else {
                throw KeychainError.accessControlCreationFailed
            }
            query[kSecAttrAccessControl as String] = accessControl
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            var updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ]
            if let accessGroup = accessGroup {
                updateQuery[kSecAttrAccessGroup as String] = accessGroup
            }

            var attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            if requireBiometrics {
                var error: Unmanaged<CFError>?
                if let accessControl = SecAccessControlCreateWithFlags(
                    kCFAllocatorDefault,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    .biometryAny,
                    &error
                ) {
                    attributesToUpdate[kSecAttrAccessControl as String] = accessControl
                }
            }

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func loadSecret(key: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }

        return data
    }

    public func deleteSecret(key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func exists(key: String) throws -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

/// Thread-safe in-memory mock implementation of Keychain operations for unit testing and offline environments.
public final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func saveSecret(key: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    public func saveSecret(key: String, data: Data, requireBiometrics: Bool) throws {
        try saveSecret(key: key, data: data)
    }

    public func loadSecret(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func deleteSecret(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func exists(key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] != nil
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
