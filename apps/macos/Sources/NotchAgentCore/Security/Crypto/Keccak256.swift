import Foundation
import CommonCrypto

/// Pure Swift implementation of Keccak-256 (the standard Ethereum hashing algorithm).
public enum Keccak256 {

    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ]

    private static let rhoOffsets: [Int] = [
         0,  1, 62, 28, 27,
        36, 44,  6, 55, 20,
         3, 10, 43, 25, 39,
        41, 45, 15, 21,  8,
        18,  2, 61, 56, 14
    ]

    private static let piPermutation: [Int] = [
         0, 10, 20,  5, 15,
        16,  1, 11, 21,  6,
         7, 17,  2, 12, 22,
        23,  8, 18,  3, 13,
        14, 24,  9, 19,  4
    ]

    private static func rotateLeft(_ value: UInt64, by amount: Int) -> UInt64 {
        let shift = amount % 64
        if shift == 0 { return value }
        return (value << shift) | (value >> (64 - shift))
    }

    private static func keccakF1600(_ state: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var d = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)

        for round in 0..<24 {
            // Theta step
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotateLeft(c[(x + 1) % 5], by: 1)
            }
            for i in 0..<25 {
                state[i] ^= d[i % 5]
            }

            // Rho and Pi steps
            for i in 0..<25 {
                b[piPermutation[i]] = rotateLeft(state[i], by: rhoOffsets[i])
            }

            // Chi step
            for y in 0..<5 {
                let row = y * 5
                for x in 0..<5 {
                    state[row + x] = b[row + x] ^ ((~b[row + ((x + 1) % 5)]) & b[row + ((x + 2) % 5)])
                }
            }

            // Iota step
            state[0] ^= roundConstants[round]
        }
    }

    /// Computes the Keccak-256 hash of the given data.
    public static func hash(data: Data) -> Data {
        let rate = 136 // 1088 bits / 8
        var state = [UInt64](repeating: 0, count: 25)
        var buffer = [UInt8](data)

        // Keccak padding (0x01 ... 0x80)
        let padLen = rate - (buffer.count % rate)
        if padLen == 1 {
            buffer.append(0x81)
        } else {
            buffer.append(0x01)
            buffer.append(contentsOf: [UInt8](repeating: 0x00, count: padLen - 2))
            buffer.append(0x80)
        }

        // Process blocks
        let blockCount = buffer.count / rate
        for b in 0..<blockCount {
            let offset = b * rate
            for i in 0..<17 {
                let laneOffset = offset + (i * 8)
                var lane: UInt64 = 0
                for byteIdx in 0..<8 {
                    lane |= UInt64(buffer[laneOffset + byteIdx]) << (byteIdx * 8)
                }
                state[i] ^= lane
            }
            keccakF1600(&state)
        }

        // Squeeze 256 bits (32 bytes = 4 lanes)
        var output = Data(capacity: 32)
        for i in 0..<4 {
            let lane = state[i]
            for byteIdx in 0..<8 {
                output.append(UInt8((lane >> (byteIdx * 8)) & 0xFF))
            }
        }
        return output
    }

    /// Computes Keccak-256 hash of UTF-8 string.
    public static func hash(string: String) -> Data {
        guard let data = string.data(using: .utf8) else { return Data() }
        return hash(data: data)
    }

    /// Formats an Ethereum address from an uncompressed 64-byte or 65-byte public key.
    public static func ethereumAddress(fromPublicKey pubKeyData: Data) -> String {
        let rawKey: Data
        if pubKeyData.count == 65 && pubKeyData[0] == 0x04 {
            rawKey = pubKeyData.subdata(in: 1..<65)
        } else if pubKeyData.count == 64 {
            rawKey = pubKeyData
        } else {
            return "0x" + String(repeating: "0", count: 40)
        }

        let hashed = hash(data: rawKey)
        let addressBytes = hashed.suffix(20)
        let hexAddress = addressBytes.map { String(format: "%02x", $0) }.joined()
        return toChecksumAddress(hexAddress)
    }

    /// Converts a 40-character hex string into EIP-55 mixed-case checksum address.
    public static func toChecksumAddress(_ hexAddress: String) -> String {
        let lower = hexAddress.lowercased().replacingOccurrences(of: "0x", with: "")
        guard lower.count == 40 else { return "0x" + lower }

        let hashHex = hash(string: lower).map { String(format: "%02x", $0) }.joined()
        var result = "0x"
        for (i, char) in lower.enumerated() {
            let hashChar = hashHex[hashHex.index(hashHex.startIndex, offsetBy: i)]
            if let hashDigit = Int(String(hashChar), radix: 16), hashDigit >= 8 {
                result.append(char.uppercased())
            } else {
                result.append(char)
            }
        }
        return result
    }
}
