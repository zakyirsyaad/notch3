import Foundation
import Security
import LocalAuthentication

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
    public static let agentWalletSetupCompleteKey = "notch.agent.wallet.setup.complete"
    public static let openAIAPIKeyKey = "notch.openai.api.key"
    public static let openAIBaseURLDefaultsKey = "notch.openai.base-url"
    public static let openAIModelDefaultsKey = "notch.openai.model"

    private let keychain: KeychainServiceProtocol
    private let userDefaults: UserDefaults
    public let agentKeystoreURL: URL
    public let userKeystoreURL: URL

    public init(
        keychain: KeychainServiceProtocol = KeychainService(),
        applicationSupportDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.userDefaults = userDefaults
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("notch-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.agentKeystoreURL = dir.appendingPathComponent("agent-keystore.json")
        self.userKeystoreURL = dir.appendingPathComponent("user-keystore.json")
        
        migrateToBiometricsIfNeeded()
    }

    private func migrateToBiometricsIfNeeded() {
        let defaults = userDefaults
        let migrationKey = "notch.keychain.biometric.migrated.v2"
        guard !defaults.bool(forKey: migrationKey) else { return }

        do {
            // Read legacy credentials passively without prompting for user presence (authContext = nil)
            let legacyUserPassData = try keychain.loadSecret(key: Self.userPasswordKey, authContext: nil)
            let legacyAgentPassData = try keychain.loadSecret(key: Self.agentPassphraseKey, authContext: nil)

            // Re-save them with biometric user presence protection
            if let userPassData = legacyUserPassData, let userPass = String(data: userPassData, encoding: .utf8), !userPass.isEmpty {
                try saveUserPassword(userPass)
            }
            if let agentPassData = legacyAgentPassData, let agentPass = String(data: agentPassData, encoding: .utf8), !agentPass.isEmpty {
                try saveAgentPassphrase(agentPass)
            }

            // Only mark migration complete if all writes succeeded
            defaults.set(true, forKey: migrationKey)
        } catch {
            NSLog("[Notch3] Keychain migration failed: \(error.localizedDescription). Will retry on next startup.")
        }
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

    // MARK: - OpenAI-Compatible Provider Settings

    /// Persists non-secret provider fields in local preferences and keeps the
    /// optional API key in its own Keychain record. The key is never written to
    /// UserDefaults or any runtime configuration file.
    public func saveOpenAIProvider(
        baseURL: String,
        model: String,
        apiKey: String? = nil
    ) throws {
        let configuration = try OpenAIProviderConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )

        if let apiKey = configuration.apiKey {
            guard let data = apiKey.data(using: .utf8), !data.isEmpty else {
                throw KeystoreError.invalidPassword
            }
            try keychain.saveSecret(key: Self.openAIAPIKeyKey, data: data)
        } else {
            // A blank API-key field explicitly selects a keyless provider. Do
            // not retain a stale remote credential when switching to local HTTP.
            try keychain.deleteSecret(key: Self.openAIAPIKeyKey)
        }

        userDefaults.set(configuration.baseURL, forKey: Self.openAIBaseURLDefaultsKey)
        userDefaults.set(configuration.model, forKey: Self.openAIModelDefaultsKey)
    }

    public func loadOpenAIBaseURL() -> String? {
        userDefaults.string(forKey: Self.openAIBaseURLDefaultsKey)
    }

    public func loadOpenAIModel() -> String? {
        userDefaults.string(forKey: Self.openAIModelDefaultsKey)
    }

    public func loadOpenAIAPIKey() -> String? {
        guard let data = try? keychain.loadSecret(key: Self.openAIAPIKeyKey, authContext: nil),
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            return nil
        }
        return apiKey
    }

    public func loadOpenAIProviderConfiguration() -> OpenAIProviderConfiguration? {
        guard let baseURL = loadOpenAIBaseURL(),
              let model = loadOpenAIModel() else {
            return nil
        }
        return try? OpenAIProviderConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: loadOpenAIAPIKey()
        )
    }

    public var hasOpenAIAPIKey: Bool {
        (try? keychain.exists(key: Self.openAIAPIKeyKey)) ?? false
    }

    public func clearOpenAIAPIKey() throws {
        try keychain.deleteSecret(key: Self.openAIAPIKeyKey)
    }

    // MARK: - Agent Wallet Passphrase

    public func saveAgentPassphrase(_ passphrase: String) throws {
        guard let data = passphrase.data(using: .utf8), !data.isEmpty else {
            throw KeystoreError.invalidPassword
        }
        try keychain.saveSecret(key: Self.agentPassphraseKey, data: data, requireBiometrics: true)
    }

    public func loadAgentPassphrase() -> String? {
        let context = LAContext()
        context.localizedReason = "Notch3 needs to access secure wallet credentials"
        return loadAgentPassphrase(authContext: context)
    }

    public func loadAgentPassphrase(authContext: LAContext?) -> String? {
        guard let data = try? keychain.loadSecret(key: Self.agentPassphraseKey, authContext: authContext),
              let passphrase = String(data: data, encoding: .utf8), !passphrase.isEmpty else {
            return nil
        }
        return passphrase
    }

    /// Checks setup readiness without reading the biometric-protected
    /// passphrase. The marker is deliberately non-secret; Keychain existence
    /// is enough to detect a stale marker without triggering Touch ID.
    public var agentWalletSetupComplete: Bool {
        guard agentWalletExists, hasAgentPassphrase else { return false }
        if !userDefaults.bool(forKey: Self.agentWalletSetupCompleteKey) {
            userDefaults.set(true, forKey: Self.agentWalletSetupCompleteKey)
        }
        return true
    }

    public var hasAgentPassphrase: Bool {
        (try? keychain.exists(key: Self.agentPassphraseKey)) ?? false
    }

    public func markAgentWalletSetupComplete() {
        userDefaults.set(true, forKey: Self.agentWalletSetupCompleteKey)
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
        userDefaults.removeObject(forKey: Self.agentWalletSetupCompleteKey)
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
