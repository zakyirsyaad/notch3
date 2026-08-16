import Foundation
import CryptoKit

/// Pure-Swift SECP256k1 Elliptic Curve and ECDSA Signer.
public enum Secp256k1Signer {

    // secp256k1 curve parameters
    // p = 2^256 - 2^32 - 977
    static let p = UInt256(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")!
    // n = order
    static let n = UInt256(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!
    // Generator point G
    static let Gx = UInt256(hex: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!
    static let Gy = UInt256(hex: "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")!

    public struct Point: Equatable {
        public let x: UInt256
        public let y: UInt256
        public let isInfinity: Bool

        public static let infinity = Point(x: .zero, y: .zero, isInfinity: true)

        public init(x: UInt256, y: UInt256, isInfinity: Bool = false) {
            self.x = x
            self.y = y
            self.isInfinity = isInfinity
        }
    }

    public static let G = Point(x: Gx, y: Gy)

    /// Computes public key (uncompressed 65 bytes starting with 0x04) from 32-byte private key.
    public static func publicKey(from privateKeyData: Data) -> Data? {
        guard privateKeyData.count == 32 else { return nil }
        guard let privInt = UInt256(data: privateKeyData), privInt > .zero, privInt < n else {
            return nil
        }
        let pubPoint = multiply(point: G, scalar: privInt)
        guard !pubPoint.isInfinity else { return nil }

        var result = Data(capacity: 65)
        result.append(0x04)
        result.append(pubPoint.x.data)
        result.append(pubPoint.y.data)
        return result
    }

    /// Derives the Ethereum checksum address for a 32-byte private key.
    public static func ethereumAddress(from privateKeyData: Data) -> String? {
        guard let pubKey = publicKey(from: privateKeyData) else { return nil }
        return Keccak256.ethereumAddress(fromPublicKey: pubKey)
    }

    /// Signs a 32-byte message hash using ECDSA (producing standard 65-byte [R (32) || S (32) || V (1)] signature).
    public static func sign(hash: Data, privateKey: Data) throws -> Data {
        guard hash.count == 32 else {
            throw KeystoreError.signingFailed("Message hash must be 32 bytes")
        }
        guard privateKey.count == 32, let d = UInt256(data: privateKey), d > .zero, d < n else {
            throw KeystoreError.signingFailed("Invalid private key")
        }
        let z = UInt256(data: hash) ?? .zero

        // Deterministic or secure random k derivation
        for _ in 0..<100 {
            var kData = Data(count: 32)
            let status = kData.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard status == errSecSuccess, let k = UInt256(data: kData), k > .zero, k < n else {
                continue
            }

            let R = multiply(point: G, scalar: k)
            if R.isInfinity { continue }

            let r = R.x % n
            if r == .zero { continue }

            guard let kInv = k.modInverse(mod: n) else { continue }
            // s = kInv * (z + r * d) % n
            let rd = mulMod(r, d, n)
            let z_plus_rd = addMod(z, rd, n)
            var s = mulMod(kInv, z_plus_rd, n)
            if s == .zero { continue }

            var v: UInt8 = R.y.isEven ? 27 : 28

            // Enforce low-s (EIP-2)
            let halfN = n / UInt256(2)
            if s > halfN {
                s = n - s
                v = (v == 27) ? 28 : 27
            }

            var sigData = Data()
            sigData.append(r.data)
            sigData.append(s.data)
            sigData.append(v)
            return sigData
        }

        throw KeystoreError.signingFailed("Could not generate valid signature")
    }

    // MARK: - Point Math
    private static func add(p1: Point, p2: Point) -> Point {
        if p1.isInfinity { return p2 }
        if p2.isInfinity { return p1 }

        if p1.x == p2.x {
            if (p1.y + p2.y) % p == .zero || p1.y != p2.y {
                return .infinity
            }
            // Point doubling: slope m = (3 * x1^2) / (2 * y1) mod p
            let three = UInt256(3)
            let two = UInt256(2)
            let num = mulMod(three, mulMod(p1.x, p1.x, p), p)
            guard let den = mulMod(two, p1.y, p).modInverse(mod: p) else { return .infinity }
            let m = mulMod(num, den, p)

            // x3 = m^2 - 2*x1 mod p
            let m2 = mulMod(m, m, p)
            let twoX = mulMod(two, p1.x, p)
            let x3 = subMod(m2, twoX, p)

            // y3 = m * (x1 - x3) - y1 mod p
            let y3 = subMod(mulMod(m, subMod(p1.x, x3, p), p), p1.y, p)
            return Point(x: x3, y: y3)
        } else {
            // Point addition: slope m = (y2 - y1) / (x2 - x1) mod p
            let num = subMod(p2.y, p1.y, p)
            guard let den = subMod(p2.x, p1.x, p).modInverse(mod: p) else { return .infinity }
            let m = mulMod(num, den, p)

            // x3 = m^2 - x1 - x2 mod p
            let m2 = mulMod(m, m, p)
            let x3 = subMod(subMod(m2, p1.x, p), p2.x, p)

            // y3 = m * (x1 - x3) - y1 mod p
            let y3 = subMod(mulMod(m, subMod(p1.x, x3, p), p), p1.y, p)
            return Point(x: x3, y: y3)
        }
    }

    private static func multiply(point: Point, scalar: UInt256) -> Point {
        var result = Point.infinity
        var current = point
        var k = scalar

        while k > .zero {
            if !k.isEven {
                result = add(p1: result, p2: current)
            }
            current = add(p1: current, p2: current)
            k = k >> 1
        }
        return result
    }

    private static func addMod(_ a: UInt256, _ b: UInt256, _ m: UInt256) -> UInt256 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow || sum >= m {
            let (diff, _) = sum.subtractingReportingOverflow(m)
            return diff % m
        }
        return sum % m
    }

    private static func subMod(_ a: UInt256, _ b: UInt256, _ m: UInt256) -> UInt256 {
        if a >= b {
            return (a - b) % m
        } else {
            return m - ((b - a) % m)
        }
    }

    private static func mulMod(_ a: UInt256, _ b: UInt256, _ m: UInt256) -> UInt256 {
        // High-precision modular multiplication
        return UInt256.mulMod(a, b, m)
    }
}

// MARK: - 256-Bit Integer Implementation
public struct UInt256: Equatable, Comparable, CustomStringConvertible {
    // 4 x 64-bit limbs, little-endian: w0 (lowest) ... w3 (highest)
    public var w0: UInt64
    public var w1: UInt64
    public var w2: UInt64
    public var w3: UInt64

    public static let zero = UInt256(0)
    public static let one = UInt256(1)

    public init(_ value: UInt64 = 0) {
        self.w0 = value
        self.w1 = 0
        self.w2 = 0
        self.w3 = 0
    }

    public init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    public init?(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.hasPrefix("0x") {
            clean = String(clean.dropFirst(2))
        }
        guard clean.count <= 64 else { return nil }
        let padded = String(repeating: "0", count: max(0, 64 - clean.count)) + clean

        func limb(_ start: Int, _ end: Int) -> UInt64? {
            let s = padded.index(padded.startIndex, offsetBy: start)
            let e = padded.index(padded.startIndex, offsetBy: end)
            return UInt64(padded[s..<e], radix: 16)
        }

        guard let l3 = limb(0, 16),
              let l2 = limb(16, 32),
              let l1 = limb(32, 48),
              let l0 = limb(48, 64) else {
            return nil
        }
        self.w3 = l3
        self.w2 = l2
        self.w1 = l1
        self.w0 = l0
    }

    public init?(data: Data) {
        guard data.count <= 32 else { return nil }
        var padded = [UInt8](repeating: 0, count: 32)
        let offset = 32 - data.count
        for (i, b) in data.enumerated() {
            padded[offset + i] = b
        }

        func read64(_ byteOffset: Int) -> UInt64 {
            var val: UInt64 = 0
            for i in 0..<8 {
                val = (val << 8) | UInt64(padded[byteOffset + i])
            }
            return val
        }

        self.w3 = read64(0)
        self.w2 = read64(8)
        self.w1 = read64(16)
        self.w0 = read64(24)
    }

    public var data: Data {
        var res = Data(capacity: 32)
        func write64(_ val: UInt64) {
            for i in (0..<8).reversed() {
                res.append(UInt8((val >> (i * 8)) & 0xFF))
            }
        }
        write64(w3)
        write64(w2)
        write64(w1)
        write64(w0)
        return res
    }

    public var isEven: Bool {
        return (w0 & 1) == 0
    }

    public var description: String {
        return String(format: "%016llx%016llx%016llx%016llx", w3, w2, w1, w0)
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        if lhs.w3 != rhs.w3 { return lhs.w3 < rhs.w3 }
        if lhs.w2 != rhs.w2 { return lhs.w2 < rhs.w2 }
        if lhs.w1 != rhs.w1 { return lhs.w1 < rhs.w1 }
        return lhs.w0 < rhs.w0
    }

    public static func == (lhs: UInt256, rhs: UInt256) -> Bool {
        return lhs.w0 == rhs.w0 && lhs.w1 == rhs.w1 && lhs.w2 == rhs.w2 && lhs.w3 == rhs.w3
    }

    public func addingReportingOverflow(_ rhs: UInt256) -> (partialValue: UInt256, overflow: Bool) {
        var carry: UInt64 = 0
        let (s0, o0) = self.w0.addingReportingOverflow(rhs.w0)
        carry = o0 ? 1 : 0

        let (s1_tmp, o1_1) = self.w1.addingReportingOverflow(rhs.w1)
        let (s1, o1_2) = s1_tmp.addingReportingOverflow(carry)
        carry = (o1_1 || o1_2) ? 1 : 0

        let (s2_tmp, o2_1) = self.w2.addingReportingOverflow(rhs.w2)
        let (s2, o2_2) = s2_tmp.addingReportingOverflow(carry)
        carry = (o2_1 || o2_2) ? 1 : 0

        let (s3_tmp, o3_1) = self.w3.addingReportingOverflow(rhs.w3)
        let (s3, o3_2) = s3_tmp.addingReportingOverflow(carry)
        let overflow = o3_1 || o3_2

        return (UInt256(w0: s0, w1: s1, w2: s2, w3: s3), overflow)
    }

    public static func + (lhs: UInt256, rhs: UInt256) -> UInt256 {
        return lhs.addingReportingOverflow(rhs).partialValue
    }

    public func subtractingReportingOverflow(_ rhs: UInt256) -> (partialValue: UInt256, overflow: Bool) {
        var borrow: UInt64 = 0
        let (d0, o0) = self.w0.subtractingReportingOverflow(rhs.w0)
        borrow = o0 ? 1 : 0

        let (d1_tmp, o1_1) = self.w1.subtractingReportingOverflow(rhs.w1)
        let (d1, o1_2) = d1_tmp.subtractingReportingOverflow(borrow)
        borrow = (o1_1 || o1_2) ? 1 : 0

        let (d2_tmp, o2_1) = self.w2.subtractingReportingOverflow(rhs.w2)
        let (d2, o2_2) = d2_tmp.subtractingReportingOverflow(borrow)
        borrow = (o2_1 || o2_2) ? 1 : 0

        let (d3_tmp, o3_1) = self.w3.subtractingReportingOverflow(rhs.w3)
        let (d3, o3_2) = d3_tmp.subtractingReportingOverflow(borrow)
        let overflow = o3_1 || o3_2

        return (UInt256(w0: d0, w1: d1, w2: d2, w3: d3), overflow)
    }

    public static func - (lhs: UInt256, rhs: UInt256) -> UInt256 {
        return lhs.subtractingReportingOverflow(rhs).partialValue
    }

    public static func >> (lhs: UInt256, shift: Int) -> UInt256 {
        if shift >= 256 { return .zero }
        if shift == 0 { return lhs }
        let limbShift = shift / 64
        let bitShift = shift % 64

        let limbs: [UInt64] = [lhs.w0, lhs.w1, lhs.w2, lhs.w3]
        var res = [UInt64](repeating: 0, count: 4)

        for i in 0..<4 {
            let src = i + limbShift
            if src < 4 {
                res[i] = limbs[src] >> bitShift
                if bitShift > 0 && src + 1 < 4 {
                    res[i] |= (limbs[src + 1] << (64 - bitShift))
                }
            }
        }
        return UInt256(w0: res[0], w1: res[1], w2: res[2], w3: res[3])
    }

    public static func << (lhs: UInt256, shift: Int) -> UInt256 {
        if shift >= 256 { return .zero }
        if shift == 0 { return lhs }
        let limbShift = shift / 64
        let bitShift = shift % 64

        let limbs: [UInt64] = [lhs.w0, lhs.w1, lhs.w2, lhs.w3]
        var res = [UInt64](repeating: 0, count: 4)

        for i in (0..<4).reversed() {
            let src = i - limbShift
            if src >= 0 {
                res[i] = limbs[src] << bitShift
                if bitShift > 0 && src - 1 >= 0 {
                    res[i] |= (limbs[src - 1] >> (64 - bitShift))
                }
            }
        }
        return UInt256(w0: res[0], w1: res[1], w2: res[2], w3: res[3])
    }

    public static func / (lhs: UInt256, rhs: UInt256) -> UInt256 {
        return lhs.dividedBy(rhs).quotient
    }

    public static func % (lhs: UInt256, rhs: UInt256) -> UInt256 {
        return lhs.dividedBy(rhs).remainder
    }

    public func dividedBy(_ divisor: UInt256) -> (quotient: UInt256, remainder: UInt256) {
        guard divisor > .zero else { return (.zero, .zero) }
        if self < divisor { return (.zero, self) }
        if self == divisor { return (UInt256(1), .zero) }

        var quotient = UInt256.zero
        var remainder = UInt256.zero

        for bit in (0..<256).reversed() {
            remainder = remainder << 1
            let limbIdx = bit / 64
            let bitIdx = bit % 64
            let limb = [w0, w1, w2, w3][limbIdx]
            if (limb & (1 << bitIdx)) != 0 {
                remainder = remainder + UInt256(1)
            }
            if remainder >= divisor {
                remainder = remainder - divisor
                let qLimbIdx = bit / 64
                let qBitIdx = bit % 64
                if qLimbIdx == 0 { quotient.w0 |= (1 << qBitIdx) }
                else if qLimbIdx == 1 { quotient.w1 |= (1 << qBitIdx) }
                else if qLimbIdx == 2 { quotient.w2 |= (1 << qBitIdx) }
                else { quotient.w3 |= (1 << qBitIdx) }
            }
        }
        return (quotient, remainder)
    }

    public static func mulMod(_ a: UInt256, _ b: UInt256, _ m: UInt256) -> UInt256 {
        guard m > .zero else { return .zero }
        var result = UInt256.zero
        var tempA = a % m
        var tempB = b

        while tempB > .zero {
            if !tempB.isEven {
                let (sum, ov) = result.addingReportingOverflow(tempA)
                if ov || sum >= m {
                    result = sum.subtractingReportingOverflow(m).partialValue % m
                } else {
                    result = sum
                }
            }
            let (doubled, ov) = tempA.addingReportingOverflow(tempA)
            if ov || doubled >= m {
                tempA = doubled.subtractingReportingOverflow(m).partialValue % m
            } else {
                tempA = doubled
            }
            tempB = tempB >> 1
        }
        return result
    }

    /// Modular exponentiation: (self^exp) % mod
    public func power(_ exp: UInt256, mod: UInt256) -> UInt256 {
        var base = self % mod
        var e = exp
        var result = UInt256.one % mod

        while e > .zero {
            if !e.isEven {
                result = UInt256.mulMod(result, base, mod)
            }
            base = UInt256.mulMod(base, base, mod)
            e = e >> 1
        }
        return result
    }

    /// Modular inverse using Fermat's Little Theorem: a^(m-2) % m (for prime m)
    public func modInverse(mod: UInt256) -> UInt256? {
        guard self > .zero, mod > .zero else { return nil }
        let exp = mod - UInt256(2)
        let inv = self.power(exp, mod: mod)
        if UInt256.mulMod(self, inv, mod) == UInt256.one {
            return inv
        }
        return nil
    }
}
