import Testing
import Foundation
@testable import NotchAgentCore

@Suite("BIP-39 Recovery Phrase Generation Tests")
struct BIP39GenerationTests {
    @Test("Generates a checksum-valid 12-word recovery phrase")
    func generatesValidPhrase() throws {
        let phrase = try BIP39.generateMnemonic()
        let words = phrase.split(separator: " ")

        #expect(words.count == 12)
        #expect(BIP39.validateMnemonic(phrase))
        #expect(Set(words.map(String.init)).isSubset(of: BIP39.englishWordList))
    }

    @Test("Rejects unsupported recovery phrase lengths")
    func rejectsUnsupportedWordCount() {
        #expect(throws: BIP39.GenerationError.self) {
            try BIP39.generateMnemonic(wordCount: 13)
        }
    }

    @Test("Rejects a phrase with valid words but an invalid checksum")
    func rejectsInvalidChecksum() {
        #expect(!BIP39.validateMnemonic("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"))
    }

    @Test("Derives the standard Ethereum first account from the BIP-39 known vector")
    func derivesStandardEthereumFirstAccount() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let seed = BIP39.seed(from: mnemonic)

        let privateKey = try BIP39.deriveEthereumPrivateKey(from: seed)
        let expectedPrivateKey = Data([
            0x1a, 0xb4, 0x2c, 0xc4, 0x12, 0xb6, 0x18, 0xbd,
            0xea, 0x3a, 0x59, 0x9e, 0x3c, 0x9b, 0xae, 0x19,
            0x9e, 0xbf, 0x03, 0x08, 0x95, 0xb0, 0x39, 0xe9,
            0xdb, 0x1e, 0x30, 0xda, 0xfb, 0x12, 0xb7, 0x27
        ])
        let scalar = UInt256(data: privateKey)

        #expect(privateKey == expectedPrivateKey)
        #expect(privateKey.count == 32)
        #expect(scalar != nil)
        #expect(scalar! > .zero)
        #expect(scalar! < Secp256k1Signer.n)
    }

    @Test("Rejects an empty BIP-39 seed")
    func rejectsEmptySeed() {
        do {
            _ = try BIP39.deriveEthereumPrivateKey(from: Data())
            Issue.record("Expected empty seeds to be rejected")
        } catch let error as BIP39.DerivationError {
            #expect(error == .invalidSeed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
