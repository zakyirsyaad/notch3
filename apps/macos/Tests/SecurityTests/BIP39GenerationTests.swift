import Testing
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
}
