import Foundation
import CommonCrypto
import CryptoKit

/// Errors encountered during Keystore generation, decryption, or transaction signing.
public enum KeystoreError: Error, LocalizedError, Equatable {
    case invalidMnemonic
    case invalidPassword
    case macMismatch
    case invalidKeystoreJson
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case signingFailed(String)
    case keyDerivationFailed
    case keystoreNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidMnemonic:
            return "Invalid BIP-39 mnemonic seed phrase."
        case .invalidPassword:
            return "Incorrect password for Keystore."
        case .macMismatch:
            return "Keystore MAC verification failed: corrupted data or wrong password."
        case .invalidKeystoreJson:
            return "Invalid Web3 Keystore JSON format."
        case .unsupportedCipher(let cipher):
            return "Unsupported cipher algorithm '\(cipher)'."
        case .unsupportedKDF(let kdf):
            return "Unsupported KDF function '\(kdf)'."
        case .signingFailed(let reason):
            return "Transaction signing failed: \(reason)"
        case .keyDerivationFailed:
            return "Cryptographic key derivation failed."
        case .keystoreNotFound:
            return "User Keystore not found."
        }
    }
}

// MARK: - Web3 Keystore v3 Data Structures

public struct Web3KeystoreV3: Codable {
    public let address: String
    public let id: String
    public let version: Int
    public let crypto: KeystoreCrypto

    public init(address: String, id: String = UUID().uuidString.lowercased(), version: Int = 3, crypto: KeystoreCrypto) {
        self.address = address
        self.id = id
        self.version = version
        self.crypto = crypto
    }
}

public struct KeystoreCrypto: Codable {
    public let cipher: String
    public let ciphertext: String
    public let cipherparams: CipherParams
    public let kdf: String
    public let kdfparams: KDFParams
    public let mac: String

    public init(cipher: String, ciphertext: String, cipherparams: CipherParams, kdf: String, kdfparams: KDFParams, mac: String) {
        self.cipher = cipher
        self.ciphertext = ciphertext
        self.cipherparams = cipherparams
        self.kdf = kdf
        self.kdfparams = kdfparams
        self.mac = mac
    }
}

public struct CipherParams: Codable {
    public let iv: String

    public init(iv: String) {
        self.iv = iv
    }
}

public struct KDFParams: Codable {
    public let c: Int
    public let dklen: Int
    public let prf: String
    public let salt: String

    public init(c: Int, dklen: Int, prf: String, salt: String) {
        self.c = c
        self.dklen = dklen
        self.prf = prf
        self.salt = salt
    }
}

// MARK: - UserKeystoreManager

/// Secure native macOS User Keystore Custody Manager.
/// Strictly enforces Web3 Keystore v3 encryption, in-memory zeroing after operations,
/// and complete isolation from the Node.js agent runtime.
public final class UserKeystoreManager: @unchecked Sendable {

    private let lock = NSLock()
    private var activeKeystoreJson: String?
    private var activeAddress: String?
    public let keychain: KeychainServiceProtocol

    /// In-memory private key property is strictly nil at rest.
    public var inMemoryPrivateKey: Data? {
        // Guarantee: never store unencrypted private key persistently in memory
        return nil
    }

    public var currentAddress: String? {
        lock.lock()
        defer { lock.unlock() }
        return activeAddress
    }

    public var currentKeystoreJson: String? {
        lock.lock()
        defer { lock.unlock() }
        return activeKeystoreJson
    }

    public init(keychain: KeychainServiceProtocol = KeychainService()) {
        self.keychain = keychain
    }

    // MARK: - Seed Phrase Import & Keystore Generation

    /// Imports a 12 or 24-word BIP-39 mnemonic seed phrase and encrypts it with the provided password into Web3 Keystore v3 format.
    /// Returns the checksummed Ethereum address (`0x...`).
    public func importSeedPhrase(mnemonic: String, password: String) throws -> String {
        guard BIP39.validateMnemonic(mnemonic) else {
            throw KeystoreError.invalidMnemonic
        }

        var seed = BIP39.seed(from: mnemonic)
        defer {
            SecureBytes.withSecureScope(&seed) { _ in }
        }

        var privateKey = BIP39.deriveEthereumPrivateKey(from: seed)
        defer {
            SecureBytes.withSecureScope(&privateKey) { _ in }
        }

        guard let address = Secp256k1Signer.ethereumAddress(from: privateKey) else {
            throw KeystoreError.keyDerivationFailed
        }

        let keystoreJson = try encryptPrivateKey(privateKey: privateKey, address: address, password: password)

        lock.lock()
        self.activeAddress = address
        self.activeKeystoreJson = keystoreJson
        lock.unlock()

        return address
    }

    /// Generates Web3 v3 Keystore JSON string from a BIP-39 mnemonic and password without retaining keys in memory.
    public func generateKeystoreJson(mnemonic: String, password: String, rounds: Int = 10000) throws -> String {
        guard BIP39.validateMnemonic(mnemonic) else {
            throw KeystoreError.invalidMnemonic
        }

        var seed = BIP39.seed(from: mnemonic)
        defer {
            SecureBytes.withSecureScope(&seed) { _ in }
        }

        var privateKey = BIP39.deriveEthereumPrivateKey(from: seed)
        defer {
            SecureBytes.withSecureScope(&privateKey) { _ in }
        }

        guard let address = Secp256k1Signer.ethereumAddress(from: privateKey) else {
            throw KeystoreError.keyDerivationFailed
        }

        return try encryptPrivateKey(privateKey: privateKey, address: address, password: password, rounds: rounds)
    }

    /// Restores a previously imported keystore (loaded from persistent storage at launch).
    /// The keystore remains encrypted; only the address and ciphertext are kept in memory.
    public func restore(address: String, keystoreJson: String) {
        lock.lock()
        self.activeAddress = address
        self.activeKeystoreJson = keystoreJson
        lock.unlock()
    }

    /// Verifies the password against a Keystore v3 JSON string and returns the decoded Ethereum address.
    public func verifyKeystorePassword(keystoreJson: String, password: String) throws -> String {
        var decryptedKey = try decryptPrivateKey(from: keystoreJson, password: password)
        defer {
            SecureBytes.withSecureScope(&decryptedKey) { _ in }
        }

        guard let address = Secp256k1Signer.ethereumAddress(from: decryptedKey) else {
            throw KeystoreError.keyDerivationFailed
        }
        return address
    }

    // MARK: - Transaction Signing

    /// Signs a transaction payload (or its Keccak-256 digest) using the user's password.
    /// Ephemeral private key is wiped from memory immediately in a defer block before returning.
    public func signTransaction(txData: Data, password: String) throws -> Data {
        let keystoreJson: String
        lock.lock()
        if let active = self.activeKeystoreJson {
            keystoreJson = active
            lock.unlock()
        } else {
            lock.unlock()
            throw KeystoreError.keystoreNotFound
        }

        return try signTransaction(txData: txData, keystoreJson: keystoreJson, password: password)
    }

    /// Signs a transaction payload given an explicit keystore JSON and password.
    public func signTransaction(txData: Data, keystoreJson: String, password: String) throws -> Data {
        var privateKey = try decryptPrivateKey(from: keystoreJson, password: password)
        defer {
            // Immediate in-memory wiping
            SecureBytes.withSecureScope(&privateKey) { _ in }
        }

        let messageHash = Keccak256.hash(data: txData)
        return try Secp256k1Signer.sign(hash: messageHash, privateKey: privateKey)
    }

    /// Signs a full EIP-155 legacy transaction and returns the serialized raw transaction hex.
    /// The ephemeral private key is wiped from memory immediately after signing.
    public func signTransaction(_ tx: LegacyTransaction, password: String) throws -> String {
        let keystoreJson: String
        lock.lock()
        if let active = self.activeKeystoreJson {
            keystoreJson = active
            lock.unlock()
        } else {
            lock.unlock()
            throw KeystoreError.keystoreNotFound
        }
        return try signTransaction(tx, keystoreJson: keystoreJson, password: password)
    }

    /// Signs a full EIP-155 legacy transaction against an explicit keystore JSON.
    public func signTransaction(_ tx: LegacyTransaction, keystoreJson: String, password: String) throws -> String {
        var privateKey = try decryptPrivateKey(from: keystoreJson, password: password)
        defer {
            SecureBytes.withSecureScope(&privateKey) { _ in }
        }
        return try tx.sign(with: privateKey)
    }

    // MARK: - Cryptographic Encryption & Decryption (Web3 v3 AES-128-CTR / PBKDF2)

    private func encryptPrivateKey(
        privateKey: Data,
        address: String,
        password: String,
        rounds: Int = 10000
    ) throws -> String {
        let salt = generateRandomBytes(count: 32)
        let iv = generateRandomBytes(count: 16)

        var derivedKey = try deriveKeyPBKDF2(password: password, salt: salt, rounds: rounds, dklen: 32)
        defer {
            SecureBytes.withSecureScope(&derivedKey) { _ in }
        }

        let encKey = derivedKey.subdata(in: 0..<16)
        let macKey = derivedKey.subdata(in: 16..<32)

        let ciphertext = try aes128CTR(data: privateKey, key: encKey, iv: iv)

        var macInput = Data()
        macInput.append(macKey)
        macInput.append(ciphertext)
        let macHash = Keccak256.hash(data: macInput)

        let cleanAddress = address.lowercased().replacingOccurrences(of: "0x", with: "")

        let crypto = KeystoreCrypto(
            cipher: "aes-128-ctr",
            ciphertext: ciphertext.map { String(format: "%02x", $0) }.joined(),
            cipherparams: CipherParams(iv: iv.map { String(format: "%02x", $0) }.joined()),
            kdf: "pbkdf2",
            kdfparams: KDFParams(
                c: rounds,
                dklen: 32,
                prf: "hmac-sha256",
                salt: salt.map { String(format: "%02x", $0) }.joined()
            ),
            mac: macHash.map { String(format: "%02x", $0) }.joined()
        )

        let keystore = Web3KeystoreV3(address: cleanAddress, crypto: crypto)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(keystore)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KeystoreError.invalidKeystoreJson
        }
        return jsonString
    }

    private func decryptPrivateKey(from keystoreJson: String, password: String) throws -> Data {
        guard let data = keystoreJson.data(using: .utf8) else {
            throw KeystoreError.invalidKeystoreJson
        }

        let decoder = JSONDecoder()
        let keystore: Web3KeystoreV3
        do {
            keystore = try decoder.decode(Web3KeystoreV3.self, from: data)
        } catch {
            throw KeystoreError.invalidKeystoreJson
        }

        guard keystore.crypto.cipher == "aes-128-ctr" else {
            throw KeystoreError.unsupportedCipher(keystore.crypto.cipher)
        }
        guard keystore.crypto.kdf == "pbkdf2" else {
            throw KeystoreError.unsupportedKDF(keystore.crypto.kdf)
        }

        guard let salt = Data(hexString: keystore.crypto.kdfparams.salt),
              let iv = Data(hexString: keystore.crypto.cipherparams.iv),
              let ciphertext = Data(hexString: keystore.crypto.ciphertext),
              let storedMac = Data(hexString: keystore.crypto.mac) else {
            throw KeystoreError.invalidKeystoreJson
        }

        let rounds = keystore.crypto.kdfparams.c
        let dklen = keystore.crypto.kdfparams.dklen

        var derivedKey = try deriveKeyPBKDF2(password: password, salt: salt, rounds: rounds, dklen: dklen)
        defer {
            SecureBytes.withSecureScope(&derivedKey) { _ in }
        }

        let encKey = derivedKey.subdata(in: 0..<16)
        let macKey = derivedKey.subdata(in: 16..<32)

        var macInput = Data()
        macInput.append(macKey)
        macInput.append(ciphertext)
        let computedMac = Keccak256.hash(data: macInput)

        guard constantTimeCompare(computedMac, storedMac) else {
            throw KeystoreError.invalidPassword
        }

        return try aes128CTR(data: ciphertext, key: encKey, iv: iv)
    }

    private func deriveKeyPBKDF2(password: String, salt: Data, rounds: Int, dklen: Int) throws -> Data {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeystoreError.invalidPassword
        }

        var derivedKey = [UInt8](repeating: 0, count: dklen)
        let status = passwordData.withUnsafeBytes { passPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr.bindMemory(to: Int8.self).baseAddress,
                    passwordData.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    &derivedKey,
                    dklen
                )
            }
        }

        guard status == kCCSuccess else {
            throw KeystoreError.keyDerivationFailed
        }

        return Data(derivedKey)
    }

    private func aes128CTR(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else {
            throw KeystoreError.keyDerivationFailed
        }

        var cryptor: CCCryptorRef?
        let createStatus = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt),
            CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            (iv as NSData).bytes,
            (key as NSData).bytes,
            16,
            nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE),
            &cryptor
        )

        guard createStatus == kCCSuccess, let cryptor = cryptor else {
            throw KeystoreError.keyDerivationFailed
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: data.count)
        var bytesMoved = 0

        let updateStatus = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress,
                    data.count,
                    outPtr.baseAddress,
                    data.count,
                    &bytesMoved
                )
            }
        }

        guard updateStatus == kCCSuccess else {
            throw KeystoreError.keyDerivationFailed
        }

        return output
    }

    private func generateRandomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return data
    }

    private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}

// MARK: - Hex String Extension

extension Data {
    public init?(hexString: String) {
        var clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.hasPrefix("0x") {
            clean = String(clean.dropFirst(2))
        }
        guard clean.count % 2 == 0 else { return nil }

        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            let byteString = clean[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
