import Foundation
import Security

/// Keychain-backed storage for keystore passphrases and the on-disk agent-wallet keystore.
///
/// - The **user keystore password** is stored in a `ThisDeviceOnly` Keychain item so the
///   biometric signing path can retrieve the *real* password after a successful Touch ID
///   prompt (the Keychain read itself is gated behind the app's own biometric check).
///   It is only written when the user confirms a transaction with the master passcode.
/// - The **agent wallet keystore** (Web3 v3 encrypted JSON) is persisted under
///   `~/Library/Application Support/notch-agent/` and its passphrase in the Keychain,
///   so the runtime subprocess can be unlocked with `agent.unlock` after authentication.
public final class KeystorePasswordStore: @unchecked Sendable {

    public static let userPasswordKey = "notch.user.keystore.password"
    public static let agentPassphraseKey = "notch.agent.wallet.passphrase"

    private let keychain: KeychainServiceProtocol
    public let agentKeystoreURL: URL
    public let userKeystoreURL: URL

    public init(
        keychain: KeychainServiceProtocol = KeychainService(),
        applicationSupportDirectory: URL? = nil
    ) {
        self.keychain = keychain
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("notch-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.agentKeystoreURL = dir.appendingPathComponent("agent-keystore.json")
        self.userKeystoreURL = dir.appendingPathComponent("user-keystore.json")
        
        migrateToBiometricsIfNeeded()
    }

    private func migrateToBiometricsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "notch.keychain.biometric.migrated.v2"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // Read legacy unprotected credentials and re-save them with user presence protection.
        // If they don't exist yet, this is a clean installation and is a no-op.
        if let userPass = loadUserPassword() {
            try? saveUserPassword(userPass)
        }
        if let agentPass = loadAgentPassphrase() {
            try? saveAgentPassphrase(agentPass)
        }

        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - User Keystore Password

    public func saveUserPassword(_ password: String) throws {
        guard let data = password.data(using: .utf8), !data.isEmpty else {
            throw KeystoreError.invalidPassword
        }
        try keychain.saveSecret(key: Self.userPasswordKey, data: data, requireBiometrics: true)
    }

    public func loadUserPassword() -> String? {
        guard let data = try? keychain.loadSecret(key: Self.userPasswordKey),
              let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            return nil
        }
        return password
    }

    public func deleteUserPassword() {
        try? keychain.deleteSecret(key: Self.userPasswordKey)
    }

    public var hasUserPassword: Bool {
        (try? keychain.exists(key: Self.userPasswordKey)) ?? false
    }

    // MARK: - Agent Wallet Passphrase

    public func saveAgentPassphrase(_ passphrase: String) throws {
        guard let data = passphrase.data(using: .utf8), !data.isEmpty else {
            throw KeystoreError.invalidPassword
        }
        try keychain.saveSecret(key: Self.agentPassphraseKey, data: data, requireBiometrics: true)
    }

    public func loadAgentPassphrase() -> String? {
        guard let data = try? keychain.loadSecret(key: Self.agentPassphraseKey),
              let passphrase = String(data: data, encoding: .utf8), !passphrase.isEmpty else {
            return nil
        }
        return passphrase
    }

    public func deleteAgentPassphrase() {
        try? keychain.deleteSecret(key: Self.agentPassphraseKey)
    }

    // MARK: - Agent Wallet Keystore File

    public struct AgentWalletRecord: Codable, Equatable, Sendable {
        public let address: String
        public let keystoreJson: String
        public let createdAt: Date

        public init(address: String, keystoreJson: String, createdAt: Date = Date()) {
            self.address = address
            self.keystoreJson = keystoreJson
            self.createdAt = createdAt
        }
    }

    public var agentWalletExists: Bool {
        FileManager.default.fileExists(atPath: agentKeystoreURL.path)
    }

    public func saveAgentWallet(_ record: AgentWalletRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: agentKeystoreURL, options: [.atomic])
    }

    public func loadAgentWallet() -> AgentWalletRecord? {
        guard let data = try? Data(contentsOf: agentKeystoreURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentWalletRecord.self, from: data)
    }

    public func deleteAgentWallet() {
        try? FileManager.default.removeItem(at: agentKeystoreURL)
        deleteAgentPassphrase()
    }

    // MARK: - Greenfield Encryption Key

    public static let greenfieldKeyKey = "notch.greenfield.aes.key"

    /// Returns the persistent 32-byte Greenfield AES key, creating it with
    /// SecRandomCopyBytes on first use. The key never leaves the Keychain.
    public func getOrCreateGreenfieldEncryptionKey() throws -> Data {
        if let existing = try? keychain.loadSecret(key: Self.greenfieldKeyKey), existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
        let key = Data(bytes)
        try keychain.saveSecret(key: Self.greenfieldKeyKey, data: key)
        return key
    }

    // MARK: - User Wallet Keystore File

    public struct UserWalletRecord: Codable, Equatable, Sendable {
        public let address: String
        public let keystoreJson: String
        public let createdAt: Date

        public init(address: String, keystoreJson: String, createdAt: Date = Date()) {
            self.address = address
            self.keystoreJson = keystoreJson
            self.createdAt = createdAt
        }
    }

    public var userWalletExists: Bool {
        FileManager.default.fileExists(atPath: userKeystoreURL.path)
    }

    public func saveUserWallet(_ record: UserWalletRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: userKeystoreURL, options: [.atomic])
    }

    public func loadUserWallet() -> UserWalletRecord? {
        guard let data = try? Data(contentsOf: userKeystoreURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UserWalletRecord.self, from: data)
    }

    public func deleteUserWallet() {
        try? FileManager.default.removeItem(at: userKeystoreURL)
        deleteUserPassword()
    }
}
