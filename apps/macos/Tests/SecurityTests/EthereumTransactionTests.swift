import Testing
import Foundation
@testable import NotchAgentCore

@Suite("EIP-155 Legacy Transaction & RLP Tests")
struct EthereumTransactionTests {

    // Canonical EIP-155 example transaction.
    static let pk = Data(hexString: "0x4646464646464646464646464646464646464646464646464646464646464646")!
    static let tx = LegacyTransaction(
        nonce: 9,
        gasPriceWei: "20000000000",
        gasLimit: 21000,
        to: Data(hexString: "0x3535353535353535353535353535353535353535")!,
        valueWei: "1000000000000000000",
        data: Data(),
        chainId: 1
    )

    @Test("EIP-155 signing hash matches the canonical vector")
    func testSigningHashVector() {
        let hash = Self.tx.signingHash.map { String(format: "%02x", $0) }.joined()
        #expect(hash == "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53")
    }

    @Test("Signing hash stays stable across repeated computations")
    func testSigningHashDeterminism() {
        #expect(Self.tx.signingHash == Self.tx.signingHash)
        #expect(Self.tx.signingHash.count == 32)
    }

    @Test("Signed raw transaction has RLP envelope and keccak tx hash")
    func testSignedRawTransactionShape() throws {
        let raw = try Self.tx.sign(with: Self.pk)
        #expect(raw.hasPrefix("0xf8"))

        let txHash = LegacyTransaction.transactionHash(ofRawTransaction: raw)
        #expect(txHash?.count == 32)
    }

    @Test("ECDSA signature verifies against the signer public key")
    func testSignatureVerification() throws {
        let signature = try Secp256k1Signer.sign(hash: Self.tx.signingHash, privateKey: Self.pk)
        #expect(signature.count == 65)

        guard let publicKey = Secp256k1Signer.publicKey(from: Self.pk) else {
            Issue.record("public key derivation failed")
            return
        }
        #expect(Secp256k1Signer.verify(signature: signature, hash: Self.tx.signingHash, publicKey: publicKey))

        // Tampered hash must fail verification
        var tampered = Self.tx.signingHash
        tampered[0] ^= 0x01
        #expect(!Secp256k1Signer.verify(signature: signature, hash: tampered, publicKey: publicKey))
    }

    @Test("Canonical vector derives the expected sender address")
    func testVectorAddress() throws {
        let address = try Secp256k1Signer.ethereumAddress(from: Self.pk).unwrap()
        #expect(address == "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
    }

    @Test("Decimal wei strings encode to minimal big-endian bytes")
    func testBigIntEncoding() {
        let oneEth = LegacyTransaction.bigIntBytes("1000000000000000000")
        #expect(oneEth.map { String(format: "%02x", $0) }.joined() == "0de0b6b3a7640000")

        #expect(LegacyTransaction.bigIntBytes("0").isEmpty)
        #expect(LegacyTransaction.bigIntBytes("").isEmpty)
        #expect(LegacyTransaction.bigIntBytes("not-a-number").isEmpty)

        // 100 tBNB in wei = 1e20 — beyond UInt64; must still encode (17 bytes)
        let hundredBNB = LegacyTransaction.bigIntBytes("100000000000000000000")
        #expect(hundredBNB.count == 17)
        #expect(hundredBNB.map { String(format: "%02x", $0) }.joined() == "056bc75e2d63100000")
    }

    @Test("Convenience initializer accepts hex data and address strings")
    func testConvenienceInitializer() throws {
        let tx = LegacyTransaction(
            nonce: 0,
            gasPriceWei: "5000000000",
            gasLimit: "250000",
            toAddress: "0x3535353535353535353535353535353535353535",
            valueWei: "0",
            dataHex: "0x38ed1739",
            chainId: 97
        )
        let built = try tx.unwrap()
        #expect(built.gasLimit == 250_000)
        #expect(built.chainId == 97)
        #expect(built.data.map { String(format: "%02x", $0) }.joined() == "38ed1739")

        // Invalid recipient address is rejected
        let bad = LegacyTransaction(
            nonce: 0, gasPriceWei: "1", gasLimit: "21000",
            toAddress: "0x1234", valueWei: "0", dataHex: nil, chainId: 97
        )
        #expect(bad == nil)
    }
}

extension Optional {
    func unwrap() throws -> Wrapped {
        switch self {
        case .some(let value): return value
        case .none: throw NSError(domain: "unwrap", code: 1)
        }
    }
}
