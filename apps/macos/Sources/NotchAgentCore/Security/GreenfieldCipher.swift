import Foundation
import CryptoKit

public enum GreenfieldCipherError: Error, LocalizedError {
    case keyUnavailable
    case invalidPayload
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable:
            return "Greenfield encryption key unavailable (Keychain)."
        case .invalidPayload:
            return "Not an encrypted Notch AEAD payload."
        case .decryptionFailed:
            return "Decryption failed — wrong key or tampered data."
        }
    }
}

/// Real client-side AES-256-GCM for Greenfield uploads and chat backups.
///
/// Payload format: `aead-aes-256-gcm::` + base64(nonce ‖ ciphertext ‖ tag)
/// using CryptoKit's combined sealed box. The symmetric key is generated once
/// with SecRandomCopyBytes and lives only in the macOS Keychain — it is never
/// transmitted alongside the ciphertext.
public enum GreenfieldCipher {

    public static let payloadPrefix = "aead-aes-256-gcm::"

    public static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = box.combined else {
            throw GreenfieldCipherError.decryptionFailed
        }
        return payloadPrefix + combined.base64EncodedString()
    }

    public static func decrypt(_ payload: String, key: SymmetricKey) throws -> String {
        guard payload.hasPrefix(payloadPrefix) else {
            throw GreenfieldCipherError.invalidPayload
        }
        guard let combined = Data(base64Encoded: String(payload.dropFirst(payloadPrefix.count))) else {
            throw GreenfieldCipherError.invalidPayload
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let data = try AES.GCM.open(box, using: key)
            guard let text = String(data: data, encoding: .utf8) else {
                throw GreenfieldCipherError.decryptionFailed
            }
            return text
        } catch {
            throw GreenfieldCipherError.decryptionFailed
        }
    }

    public static func isEncryptedPayload(_ content: String) -> Bool {
        content.hasPrefix(payloadPrefix)
    }
}
