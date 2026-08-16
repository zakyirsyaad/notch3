import Foundation

/// A secure memory wrapper that guarantees in-memory byte zeroing upon deallocation.
public final class SecureBytes {
    private var buffer: [UInt8]
    private var isZeroed: Bool = false

    public init(_ bytes: [UInt8]) {
        self.buffer = bytes
    }

    public init(count: Int, repeating: UInt8 = 0) {
        self.buffer = [UInt8](repeating: repeating, count: count)
    }

    public init(data: Data) {
        self.buffer = [UInt8](data)
    }

    deinit {
        zero()
    }

    /// Access underlying bytes securely.
    public var bytes: [UInt8] {
        return buffer
    }

    /// Access as Data.
    public var data: Data {
        return Data(buffer)
    }

    public var count: Int {
        return buffer.count
    }

    /// Zeros the internal buffer immediately using memset_s / volatile write.
    public func zero() {
        guard !isZeroed else { return }
        isZeroed = true
        buffer.withUnsafeMutableBufferPointer { ptr in
            if let baseAddress = ptr.baseAddress {
                #if os(macOS) || os(iOS)
                memset_s(baseAddress, ptr.count, 0, ptr.count)
                #else
                for i in 0..<ptr.count {
                    baseAddress[i] = 0
                }
                #endif
            }
        }
        buffer.removeAll(keepingCapacity: false)
    }

    /// Executes a closure with a temporary pointer to the raw bytes, securely zeroing immediately afterward.
    public static func withSecureScope<R>(_ data: inout Data, _ body: (inout Data) throws -> R) rethrows -> R {
        defer {
            data.withUnsafeMutableBytes { rawPtr in
                if let baseAddress = rawPtr.baseAddress {
                    #if os(macOS) || os(iOS)
                    memset_s(baseAddress, rawPtr.count, 0, rawPtr.count)
                    #else
                    for i in 0..<rawPtr.count {
                        baseAddress.storeBytes(of: 0 as UInt8, toByteOffset: i, as: UInt8.self)
                    }
                    #endif
                }
            }
            data.removeAll(keepingCapacity: false)
        }
        return try body(&data)
    }
}
