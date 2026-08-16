import Foundation

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
    }

    // MARK: - User Keystore Password

    public func saveUserPassword(_ password: String) throws {
        guard let data = password.data(using: .utf8), !data.isEmpty else {
            throw KeystoreError.invalidPassword
        }
        try keychain.saveSecret(key: Self.userPasswordKey, data: data)
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
        try keychain.saveSecret(key: Self.agentPassphraseKey, data: data)
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
}
