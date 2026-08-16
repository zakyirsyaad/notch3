import Foundation

/// The unsigned transaction a confirmation modal will sign, expressed in exact on-chain terms.
/// Built from runtime data (`wallet.buildSwapTx`, transfer parameters) — never fabricated locally.
public struct TransactionProposal: Codable, Sendable, Equatable {
    public let toAddress: String
    public let valueWei: String
    public let dataHex: String?
    public let chainId: Int
    public let gasLimit: UInt64

    public init(
        toAddress: String,
        valueWei: String,
        dataHex: String? = nil,
        chainId: Int,
        gasLimit: UInt64 = 250_000
    ) {
        self.toAddress = toAddress
        self.valueWei = valueWei
        self.dataHex = dataHex
        self.chainId = chainId
        self.gasLimit = gasLimit
    }
}

/// Signs a transaction with the user keystore after explicit user authentication.
public protocol TransactionSigning: Sendable {
    /// Returns the serialized EIP-155 raw transaction (0x-prefixed hex).
    func signTransaction(_ tx: LegacyTransaction, password: String) throws -> String
}

extension UserKeystoreManager: TransactionSigning {}

/// Broadcasts a signed raw transaction and returns the network transaction hash.
public protocol TransactionBroadcasting: Sendable {
    func broadcast(signedTx: String) async throws -> String
}

/// Fetches nonce and gas price for an address from the active network.
public protocol TransactionContextProviding: Sendable {
    func context(for address: String) async throws -> TransactionContext
}

public struct TransactionContext: Codable, Sendable, Equatable {
    public let nonce: UInt64
    public let gasPriceWei: String
    public let chainId: Int

    public init(nonce: UInt64, gasPriceWei: String, chainId: Int) {
        self.nonce = nonce
        self.gasPriceWei = gasPriceWei
        self.chainId = chainId
    }
}

/// Runtime-backed implementations speaking the agent runtime's JSON-RPC surface.
public struct RuntimeTransactionPipeline {
    public let client: JSONRPCClient

    public init(client: JSONRPCClient) {
        self.client = client
    }
}

extension RuntimeTransactionPipeline: TransactionBroadcasting {
    public func broadcast(signedTx: String) async throws -> String {
        struct BroadcastResult: Codable, Sendable { let txHash: String }
        let result: BroadcastResult = try await client.sendRequest(
            method: "wallet.sendRawTransaction",
            params: ["signedTx": signedTx]
        )
        return result.txHash
    }
}

extension RuntimeTransactionPipeline: TransactionContextProviding {
    public func context(for address: String) async throws -> TransactionContext {
        try await client.sendRequest(
            method: "wallet.getTxContext",
            params: ["address": address]
        )
    }
}

/// Exact string-based UI-amount → wei conversion (no floating point).
public enum WeiConverter {

    /// Converts a decimal UI amount ("1.5") into an integer wei string at the given decimals.
    /// Returns nil for malformed input or more fractional digits than the token supports.
    public static func wei(fromUIAmount amount: String, decimals: Int = 18) -> String? {
        let trimmed = amount.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }

        let intPart = parts.count > 0 ? String(parts[0]) : "0"
        let fracPart = parts.count > 1 ? String(parts[1]) : ""

        guard !intPart.isEmpty, intPart.allSatisfy(\.isNumber), fracPart.allSatisfy(\.isNumber) else {
            return nil
        }
        guard fracPart.count <= decimals else { return nil }

        let paddedFrac = fracPart + String(repeating: "0", count: decimals - fracPart.count)
        let combined = (intPart == "0" && paddedFrac.allSatisfy { $0 == "0" })
            ? "0"
            : intPart + paddedFrac

        // Strip leading zeros of a non-zero value
        var stripped = combined
        while stripped.count > 1 && stripped.hasPrefix("0") {
            stripped.removeFirst()
        }
        return stripped
    }

    /// Compares two non-negative decimal integer strings. Returns nil if either is malformed.
    public static func compare(_ a: String, _ b: String) -> Int? {
        func normalize(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.allSatisfy(\.isNumber) else { return nil }
            var v = t
            while v.count > 1 && v.hasPrefix("0") { v.removeFirst() }
            return v
        }
        guard let x = normalize(a), let y = normalize(b) else { return nil }
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        if x == y { return 0 }
        return x < y ? -1 : 1
    }
}

/// Response of `wallet.getAllowance`.
public struct AllowanceResult: Codable, Sendable, Equatable {
    public let allowanceWei: String
    public let token: String
    public let owner: String
    public let spender: String

    public init(allowanceWei: String, token: String, owner: String, spender: String) {
        self.allowanceWei = allowanceWei
        self.token = token
        self.owner = owner
        self.spender = spender
    }
}

/// Bundle of everything the confirmation modal needs to sign and broadcast for real.
/// Assembled once by the AppDelegate from the live process runner and keystore.
public struct TransactionDependencies: Sendable {
    public let signer: TransactionSigning?
    public let broadcaster: TransactionBroadcasting?
    public let contextProvider: TransactionContextProviding?
    public let passwordStore: KeystorePasswordStore?
    public let authenticator: TouchIDAuthenticatorProtocol
    /// Raw JSON-RPC client for quote building (wallet.estimateSwapQuote / wallet.buildSwapTx).
    public let rpcClient: JSONRPCClient?

    public init(
        signer: TransactionSigning?,
        broadcaster: TransactionBroadcasting?,
        contextProvider: TransactionContextProviding?,
        passwordStore: KeystorePasswordStore?,
        authenticator: TouchIDAuthenticatorProtocol = TouchIDAuthenticator(),
        rpcClient: JSONRPCClient? = nil
    ) {
        self.signer = signer
        self.broadcaster = broadcaster
        self.contextProvider = contextProvider
        self.passwordStore = passwordStore
        self.authenticator = authenticator
        self.rpcClient = rpcClient
    }
}
