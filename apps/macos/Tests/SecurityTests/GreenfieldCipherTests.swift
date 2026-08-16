import Testing
import Foundation
import CryptoKit
@testable import NotchAgentCore

@Suite("Greenfield Cipher Tests")
struct GreenfieldCipherTests {

    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    @Test("Encrypt/decrypt roundtrip preserves the plaintext exactly")
    func testRoundtrip() throws {
        let key = makeKey()
        let plaintext = #"{"messages":[{"role":"user","content":"secret balance question"}]}"#

        let payload = try GreenfieldCipher.encrypt(plaintext, key: key)
        #expect(payload.hasPrefix("aead-aes-256-gcm::"))
        #expect(GreenfieldCipher.isEncryptedPayload(payload))

        let decrypted = try GreenfieldCipher.decrypt(payload, key: key)
        #expect(decrypted == plaintext)
    }

    @Test("Ciphertext never contains the plaintext or a base64 of it")
    func testNoPlaintextLeak() throws {
        let key = makeKey()
        let plaintext = "top-secret-phrase-123456"

        let payload = try GreenfieldCipher.encrypt(plaintext, key: key)
        #expect(!payload.contains(plaintext))
        #expect(!payload.contains(Data(plaintext.utf8).base64EncodedString()))
    }

    @Test("Wrong key fails authentication")
    func testWrongKeyFails() throws {
        let payload = try GreenfieldCipher.encrypt("data", key: makeKey())
        #expect(throws: GreenfieldCipherError.decryptionFailed) {
            _ = try GreenfieldCipher.decrypt(payload, key: makeKey())
        }
    }

    @Test("Tampered ciphertext fails authentication")
    func testTamperFails() throws {
        let key = makeKey()
        var payload = try GreenfieldCipher.encrypt("data", key: key)

        // Flip a character in the base64 body
        var chars = Array(payload)
        let idx = chars.count - 3
        chars[idx] = chars[idx] == "A" ? "B" : "A"
        payload = String(chars)

        #expect(throws: GreenfieldCipherError.self) {
            _ = try GreenfieldCipher.decrypt(payload, key: key)
        }
    }

    @Test("Non-payload input is rejected with invalidPayload")
    func testInvalidPayloadRejected() {
        #expect(!GreenfieldCipher.isEncryptedPayload("aes256::aGVsbG8="))  // old fake format
        #expect(!GreenfieldCipher.isEncryptedPayload("plain text"))

        #expect(throws: GreenfieldCipherError.invalidPayload) {
            _ = try GreenfieldCipher.decrypt("hello", key: makeKey())
        }
    }

    @Test("Keychain-held key is generated once and reused")
    func testKeyPersistence() throws {
        let uniqueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-cipher-\(UUID().uuidString)", isDirectory: true)
        let store = KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: uniqueDir
        )

        let first = try store.getOrCreateGreenfieldEncryptionKey()
        #expect(first.count == 32)

        let second = try store.getOrCreateGreenfieldEncryptionKey()
        #expect(first == second)
    }

    @Test("Key survives across store instances (relaunch simulation)")
    func testKeyAcrossRelaunch() throws {
        let uniqueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-cipher-\(UUID().uuidString)", isDirectory: true)
        let keychain = MockKeychainService()

        let first = try KeystorePasswordStore(
            keychain: keychain,
            applicationSupportDirectory: uniqueDir
        ).getOrCreateGreenfieldEncryptionKey()

        let second = try KeystorePasswordStore(
            keychain: keychain,
            applicationSupportDirectory: uniqueDir
        ).getOrCreateGreenfieldEncryptionKey()

        #expect(first == second)
    }
}
