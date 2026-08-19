import Testing
import Foundation
import LocalAuthentication
@testable import NotchAgentCore

@Suite("Keystore, Keychain, and Biometric Security Tests")
struct KeystoreSecurityTests {

    // MARK: - In-Memory Key Separation & Zeroing Tests

    @Test("Keystore separation guarantees inMemoryPrivateKey is nil at rest")
    func testKeystoreSeparationAndZeroing() throws {
        let manager = UserKeystoreManager()
        #expect(manager.inMemoryPrivateKey == nil)
    }

    // MARK: - Mnemonic & Keystore Generation Tests

    @Test("Import 12-word seed phrase generates valid checksummed address")
    func testImportSeedPhraseAndKeystoreGeneration() throws {
        let manager = UserKeystoreManager()
        let mnemonic = "test test test test test test test test test test test junk"
        let testPassphrase = "mock-auth-key-12345"

        let address = try manager.importSeedPhrase(mnemonic: mnemonic, password: testPassphrase)
        #expect(!address.isEmpty)
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
        #expect(manager.currentAddress == address)
        #expect(manager.currentKeystoreJson != nil)

        // Ensure private key is not retained in memory
        #expect(manager.inMemoryPrivateKey == nil)
    }

    @Test("Import 24-word seed phrase succeeds")
    func testImport24WordSeedPhrase() throws {
        let manager = UserKeystoreManager()
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        let testPassphrase = "mock-auth-key-67890"

        let address = try manager.importSeedPhrase(mnemonic: mnemonic, password: testPassphrase)
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
        #expect(manager.inMemoryPrivateKey == nil)
    }

    @Test("Import invalid mnemonic throws validation error")
    func testImportInvalidMnemonicThrows() throws {
        let manager = UserKeystoreManager()
        let invalidWords = "invalid words not in bip39 dictionary at all"
        let testPassphrase = "mock-auth-key-sample"

        #expect(throws: KeystoreError.invalidMnemonic) {
            try manager.importSeedPhrase(mnemonic: invalidWords, password: testPassphrase)
        }

        let shortMnemonic = "abandon abandon abandon"
        #expect(throws: KeystoreError.invalidMnemonic) {
            try manager.importSeedPhrase(mnemonic: shortMnemonic, password: testPassphrase)
        }
    }

    // MARK: - Keystore Decryption & Password Verification Tests

    @Test("Keystore decryption with correct password succeeds and fails with wrong password")
    func testKeystoreDecryptionAndWrongPassword() throws {
        let manager = UserKeystoreManager()
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let correctAuthKey = "mock-auth-key-correct"
        let wrongAuthKey = "mock-auth-key-invalid"

        let keystoreJson = try manager.generateKeystoreJson(mnemonic: mnemonic, password: correctAuthKey, rounds: 1000)
        #expect(!keystoreJson.isEmpty)
        #expect(keystoreJson.contains("\"version\":3") || keystoreJson.contains("\"version\": 3"))
        #expect(keystoreJson.contains("aes-128-ctr"))
        #expect(keystoreJson.contains("pbkdf2"))

        // Decryption with correct password should succeed
        let unlockedAddress = try manager.verifyKeystorePassword(keystoreJson: keystoreJson, password: correctAuthKey)
        #expect(unlockedAddress.hasPrefix("0x"))

        // Decryption with wrong password must throw error
        #expect(throws: KeystoreError.self) {
            try manager.verifyKeystorePassword(keystoreJson: keystoreJson, password: wrongAuthKey)
        }

        // Sensitive memory must remain zeroed
        #expect(manager.inMemoryPrivateKey == nil)
    }

    @Test("Corrupted Keystore JSON throws invalidKeystoreJson")
    func testCorruptedKeystoreJson() throws {
        let manager = UserKeystoreManager()
        let dummyAuthKey = ["mock", "auth", "token"].joined(separator: "-")
        #expect(throws: KeystoreError.invalidKeystoreJson) {
            try manager.verifyKeystorePassword(keystoreJson: "{\"not_a_valid_keystore\": true}", password: dummyAuthKey)
        }
    }

    // MARK: - Transaction Signing Tests

    @Test("Sign transaction produces valid signature and zeroes memory")
    func testSignTransactionZeroesMemory() throws {
        let manager = UserKeystoreManager()
        let mnemonic = "test test test test test test test test test test test junk"
        let signingAuthKey = "mock-auth-key-signer"

        _ = try manager.importSeedPhrase(mnemonic: mnemonic, password: signingAuthKey)

        let mockTxData = "0x02f8708201...mockBscTxData".data(using: .utf8)!
        let signature = try manager.signTransaction(txData: mockTxData, password: signingAuthKey)

        #expect(!signature.isEmpty)
        #expect(signature.count == 65) // 32 bytes r + 32 bytes s + 1 byte v
        let v = signature.last!
        #expect(v == 27 || v == 28)

        // Memory check: private key is immediately zeroed in memory
        #expect(manager.inMemoryPrivateKey == nil)
    }

    @Test("Sign transaction with explicit keystore JSON and password")
    func testSignTransactionWithExplicitKeystore() throws {
        let manager = UserKeystoreManager()
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let customAuthKey = "mock-auth-key-custom"
        let invalidAuthKey = ["mock", "wrong", "token"].joined(separator: "-")

        let keystoreJson = try manager.generateKeystoreJson(mnemonic: mnemonic, password: customAuthKey, rounds: 1000)
        let mockTxData = "mock transaction payload".data(using: .utf8)!

        let signature = try manager.signTransaction(txData: mockTxData, keystoreJson: keystoreJson, password: customAuthKey)
        #expect(signature.count == 65)

        // Wrong password throws error
        #expect(throws: KeystoreError.self) {
            try manager.signTransaction(txData: mockTxData, keystoreJson: keystoreJson, password: invalidAuthKey)
        }
    }

    // MARK: - Keychain Service Tests

    @Test("Keychain save, load, update, and delete cycle")
    func testKeychainSaveLoadDeleteCycle() throws {
        let keychain = MockKeychainService()
        let testKey = "user.wallet.authKey"
        let secretData = "super_secret_payload_bytes".data(using: .utf8)!

        // Initially does not exist
        #expect(try keychain.loadSecret(key: testKey) == nil)
        #expect(try keychain.exists(key: testKey) == false)

        // Save secret
        try keychain.saveSecret(key: testKey, data: secretData)
        #expect(try keychain.exists(key: testKey) == true)

        // Load secret
        let loaded = try keychain.loadSecret(key: testKey)
        #expect(loaded == secretData)

        // Update secret
        let updatedData = "updated_payload_bytes".data(using: .utf8)!
        try keychain.saveSecret(key: testKey, data: updatedData)
        #expect(try keychain.loadSecret(key: testKey) == updatedData)

        // Delete secret
        try keychain.deleteSecret(key: testKey)
        #expect(try keychain.loadSecret(key: testKey) == nil)
        #expect(try keychain.exists(key: testKey) == false)

        // Deleting non-existent key succeeds idempotently
        try keychain.deleteSecret(key: testKey)
    }

    @Test("Keychain clearAll removes all keys")
    func testKeychainClearAll() throws {
        let keychain = MockKeychainService()
        try keychain.saveSecret(key: "k1", data: Data([1, 2]))
        try keychain.saveSecret(key: "k2", data: Data([3, 4]))
        #expect(try keychain.exists(key: "k1") == true)
        #expect(try keychain.exists(key: "k2") == true)

        keychain.clearAll()
        #expect(try keychain.exists(key: "k1") == false)
        #expect(try keychain.exists(key: "k2") == false)
    }

    // MARK: - Touch ID Authenticator Tests

    @Test("Touch ID authenticator mock handles success and cancellation")
    func testTouchIDMockAuthentication() async throws {
        let authenticator = MockTouchIDAuthenticator(shouldSucceed: true)
        let result = try await authenticator.authenticateUser(reason: "Authorize User Wallet transaction")
        #expect(result == true)

        let failingAuthenticator = MockTouchIDAuthenticator(shouldSucceed: false)
        do {
            _ = try await failingAuthenticator.authenticateUser(reason: "Authorize transaction")
            #expect(Bool(false), "Expected userCancelled error")
        } catch let error as AuthenticationError {
            #expect(error == .userCancelled)
            #expect(error.localizedDescription.contains("User cancelled"))
        }
    }

    @Test("AuthenticationError descriptions are informative")
    func testAuthenticationErrorDescriptions() {
        let errBiometrics = AuthenticationError.biometricsNotAvailable
        let errEnrolled = AuthenticationError.biometricsNotEnrolled
        let errCancel = AuthenticationError.userCancelled
        let errFailed = AuthenticationError.authenticationFailed("timeout")
        let errContext = AuthenticationError.contextInvalidated

        #expect(errBiometrics.errorDescription?.contains("not available") == true)
        #expect(errEnrolled.errorDescription?.contains("not enrolled") == true)
        #expect(errCancel.errorDescription?.contains("cancelled") == true)
        #expect(errFailed.errorDescription?.contains("timeout") == true)
        #expect(errContext.errorDescription?.contains("invalidated") == true)
    }

    // MARK: - Keccak256 Test Vectors

    @Test("Keccak256 matches standard Ethereum test vectors")
    func testKeccak256StandardVectors() {
        // Keccak-256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        let emptyHash = Keccak256.hash(data: Data())
        let emptyHex = emptyHash.map { String(format: "%02x", $0) }.joined()
        #expect(emptyHex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

        // Keccak-256("hello") = 1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
        let helloHash = Keccak256.hash(string: "hello")
        let helloHex = helloHash.map { String(format: "%02x", $0) }.joined()
        #expect(helloHex == "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }

    @Test("EIP-55 checksum address formatting produces correct casing")
    func testEIP55ChecksumAddress() {
        let raw = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
        let checksummed = Keccak256.toChecksumAddress(raw)
        #expect(checksummed == "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    }

    @Test("Keychain migration fails closed when saving protected item fails")
    func testKeychainMigrationFailsClosed() throws {
        let defaults = UserDefaults.standard
        let migrationKey = "notch.keychain.biometric.migrated.v2"
        defaults.removeObject(forKey: migrationKey)

        // Mock keychain service yang mengimplementasikan KeychainServiceProtocol secara langsung
        class FailingMockKeychain: KeychainServiceProtocol, @unchecked Sendable {
            private let mock = MockKeychainService()
            
            func saveSecret(key: String, data: Data) throws {
                try mock.saveSecret(key: key, data: data)
            }
            
            func saveSecret(key: String, data: Data, requireBiometrics: Bool) throws {
                if requireBiometrics {
                    throw KeychainError.accessControlCreationFailed
                }
                try mock.saveSecret(key: key, data: data, requireBiometrics: requireBiometrics)
            }
            
            func loadSecret(key: String) throws -> Data? {
                try mock.loadSecret(key: key)
            }
            
            func loadSecret(key: String, authContext: LAContext?) throws -> Data? {
                try mock.loadSecret(key: key, authContext: authContext)
            }
            
            func deleteSecret(key: String) throws {
                try mock.deleteSecret(key: key)
            }
            
            func exists(key: String) throws -> Bool {
                try mock.exists(key: key)
            }
        }

        let keychain = FailingMockKeychain()
        try keychain.saveSecret(key: KeystorePasswordStore.userPasswordKey, data: "legacy-pass".data(using: .utf8)!)

        let _ = KeystorePasswordStore(keychain: keychain)

        #expect(defaults.bool(forKey: migrationKey) == false)
    }
}
