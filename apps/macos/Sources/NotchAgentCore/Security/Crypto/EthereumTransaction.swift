import Foundation

/// RLP (Recursive Length Prefix) encoding for Ethereum transaction serialization.
public enum RLP {

    public enum RLPItem {
        case bytes(Data)
        case list([RLPItem])

        public var encoded: Data {
            switch self {
            case .bytes(let data):
                return RLP.encodeBytes(data)
            case .list(let items):
                let payload = items.reduce(into: Data()) { $0.append($1.encoded) }
                return RLP.encodeLength(prefix: 0xc0, payload)
            }
        }
    }

    /// Encodes a length section with the given offset (0x80 for strings, 0xc0 for lists).
    static func encodeLength(prefix: UInt8, _ payload: Data) -> Data {
        var out = Data()
        if payload.count <= 55 {
            out.append(prefix + UInt8(payload.count))
        } else {
            let lenBytes = minimalBytes(UInt64(payload.count))
            out.append(prefix + 55 + UInt8(lenBytes.count))
            out.append(lenBytes)
        }
        out.append(payload)
        return out
    }

    static func encodeBytes(_ data: Data) -> Data {
        if data.count == 1 && data[0] < 0x80 {
            return data
        }
        return encodeLength(prefix: 0x80, data)
    }

    /// Minimal big-endian representation of an integer (empty for zero).
    public static func encodeUInt(_ value: UInt64) -> Data {
        return minimalBytes(value)
    }

    static func minimalBytes(_ value: UInt64) -> Data {
        if value == 0 { return Data() }
        var v = value
        var bytes = [UInt8]()
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return Data(bytes)
    }
}

/// Legacy (pre-EIP-2718) EIP-155 signed Ethereum transaction.
public struct LegacyTransaction: Equatable, Sendable {
    public let nonce: UInt64
    public let gasPriceWei: String   // decimal wei string
    public let gasLimit: UInt64
    public let to: Data              // 20-byte recipient
    public let valueWei: String      // decimal wei string
    public let data: Data
    public let chainId: Int

    public init(
        nonce: UInt64,
        gasPriceWei: String,
        gasLimit: UInt64,
        to: Data,
        valueWei: String,
        data: Data = Data(),
        chainId: Int
    ) {
        self.nonce = nonce
        self.gasPriceWei = gasPriceWei
        self.gasLimit = gasLimit
        self.to = to
        self.valueWei = valueWei
        self.data = data
        self.chainId = chainId
    }

    public init?(
        nonce: UInt64,
        gasPriceWei: String,
        gasLimit: String,
        toAddress: String,
        valueWei: String,
        dataHex: String?,
        chainId: Int
    ) {
        guard let to = Data(hexString: toAddress), to.count == 20 else { return nil }
        let gas = UInt64(gasLimit) ?? 250_000
        let data = dataHex.flatMap { Data(hexString: $0) } ?? Data()
        self.init(
            nonce: nonce,
            gasPriceWei: gasPriceWei,
            gasLimit: gas,
            to: to,
            valueWei: valueWei,
            data: data,
            chainId: chainId
        )
    }

    var unsignedItems: [RLP.RLPItem] {
        [
            .bytes(RLP.encodeUInt(nonce)),
            .bytes(Self.bigIntBytes(gasPriceWei)),
            .bytes(RLP.encodeUInt(gasLimit)),
            .bytes(to),
            .bytes(Self.bigIntBytes(valueWei)),
            .bytes(data),
            .bytes(RLP.encodeUInt(UInt64(chainId))),
            .bytes(Data()),
            .bytes(Data()),
        ]
    }

    /// keccak256(rlp([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]))
    public var signingHash: Data {
        let encoded = RLP.RLPItem.list(unsignedItems).encoded
        return Keccak256.hash(data: encoded)
    }

    /// Signs the EIP-155 signing hash and returns the fully serialized raw transaction (0x-prefixed hex).
    public func sign(with privateKey: Data) throws -> String {
        let signature = try Secp256k1Signer.sign(hash: signingHash, privateKey: privateKey)
        let r = signature.prefix(32)
        let s = signature.subdata(in: 32..<64)
        let recoveryId = signature[64] - 27   // 0 or 1
        let eip155V = UInt64(chainId) * 2 + 35 + UInt64(recoveryId)

        let signedItems: [RLP.RLPItem] = [
            .bytes(RLP.encodeUInt(nonce)),
            .bytes(Self.bigIntBytes(gasPriceWei)),
            .bytes(RLP.encodeUInt(gasLimit)),
            .bytes(to),
            .bytes(Self.bigIntBytes(valueWei)),
            .bytes(data),
            .bytes(RLP.encodeUInt(eip155V)),
            .bytes(r),
            .bytes(s),
        ]
        let raw = RLP.RLPItem.list(signedItems).encoded
        return "0x" + raw.map { String(format: "%02x", $0) }.joined()
    }

    /// keccak256 of the serialized signed transaction — matches the hash returned by the network.
    public static func transactionHash(ofRawTransaction rawHex: String) -> Data? {
        guard let raw = Data(hexString: rawHex), !raw.isEmpty else { return nil }
        return Keccak256.hash(data: raw)
    }

    /// Parses a non-negative decimal string into minimal big-endian bytes (empty for zero).
    /// Handles arbitrary precision — UInt64 would overflow above ~18.4 tokens at 18 decimals.
    static func bigIntBytes(_ decimal: String) -> Data {
        let chars = decimal.trimmingCharacters(in: .whitespaces)
        guard !chars.isEmpty, chars.allSatisfy({ $0.isNumber }) else { return Data() }

        var digits = chars.compactMap { $0.wholeNumberValue }
        var bytes: [UInt8] = []

        while !digits.isEmpty {
            var quotient: [Int] = []
            var remainder = 0
            for d in digits {
                let current = remainder * 10 + d
                quotient.append(current / 256)
                remainder = current % 256
            }
            bytes.insert(UInt8(remainder), at: 0)
            while let first = quotient.first, first == 0 { quotient.removeFirst() }
            digits = quotient
        }

        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if bytes == [0] { return Data() }
        return Data(bytes)
    }
}
