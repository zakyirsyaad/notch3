import Foundation

// MARK: - JSON-RPC 2.0 Identifier

/// Represents a JSON-RPC 2.0 `id`, which may be a String, an Integer, or Null.
public enum JSONRPCId: Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case string(String)
    case int(Int)
    case null

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public var description: String {
        switch self {
        case .string(let str): return str
        case .int(let num): return String(num)
        case .null: return "null"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .int(let num):
            try container.encode(num)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - JSON-RPC 2.0 Request, Notification, Error, Response

public struct JSONRPCRequest<Params: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId
    public let method: String
    public let params: Params?

    public init(id: JSONRPCId, method: String, params: Params? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification<Params: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: Params?

    public init(method: String, params: Params? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorObject: Codable, Sendable, Error, Equatable {
    public let code: Int
    public let message: String
    public let data: String?

    public init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCResponse<Result: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let result: Result?
    public let error: JSONRPCErrorObject?

    public init(id: JSONRPCId?, result: Result? = nil, error: JSONRPCErrorObject? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct RawJSONRPCMessage: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let method: String?
    public let error: JSONRPCErrorObject?
}

// MARK: - Empty Parameters

public struct EmptyParams: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - Standard Error Codes

public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let unauthorized = -32001
    public static let walletLocked = -32002
    public static let insufficientFunds = -32003
    public static let paymentFailed = -32004
    public static let rateLimited = -32005
}

// MARK: - Client Errors

public enum JSONRPCClientError: Error, LocalizedError, Equatable {
    case remoteError(code: Int, message: String, data: String?)
    case processNotRunning
    case responseTimeout
    case invalidResponse
    case invalidRequestEncoding
    case transportClosed
    case decodingFailed(String)
    case methodNotHandled(String)

    public var errorDescription: String? {
        switch self {
        case .remoteError(let code, let msg, let data):
            return "JSON-RPC Error [\(code)]: \(msg)\(data != nil ? " (\(data!))" : "")"
        case .processNotRunning:
            return "Agent subprocess is not running."
        case .responseTimeout:
            return "JSON-RPC request timed out."
        case .invalidResponse:
            return "Invalid JSON-RPC response format."
        case .invalidRequestEncoding:
            return "Failed to encode JSON-RPC request."
        case .transportClosed:
            return "IPC transport stream is closed."
        case .decodingFailed(let msg):
            return "JSON-RPC response decoding failed: \(msg)"
        case .methodNotHandled(let method):
            return "No handler registered for method: \(method)"
        }
    }
}

// MARK: - Domain Models

public struct AgentConfig: Codable, Sendable, Equatable {
    public var apiKey: String?
    public var rpcUrl: String?
    public var agentAddress: String?
    public var network: String?
    public var autoPayMaxTBNB: String?

    public init(
        apiKey: String? = nil,
        rpcUrl: String? = nil,
        agentAddress: String? = nil,
        network: String? = "BSC Testnet",
        autoPayMaxTBNB: String? = "0.05"
    ) {
        self.apiKey = apiKey
        self.rpcUrl = rpcUrl
        self.agentAddress = agentAddress
        self.network = network
        self.autoPayMaxTBNB = autoPayMaxTBNB
    }
}

public struct AgentStatus: Codable, Sendable, Equatable {
    public let isUnlocked: Bool
    public let address: String?
    public let balanceTBNB: String?
    public let activeTools: [String]?
    public let erc8004Registered: Bool?

    public init(
        isUnlocked: Bool,
        address: String? = nil,
        balanceTBNB: String? = nil,
        activeTools: [String]? = nil,
        erc8004Registered: Bool? = nil
    ) {
        self.isUnlocked = isUnlocked
        self.address = address
        self.balanceTBNB = balanceTBNB
        self.activeTools = activeTools
        self.erc8004Registered = erc8004Registered
    }
}

public enum AgentLockState: String, Codable, Sendable {
    case locked
    case unlocked
    case paused
}

public struct X402PaymentChallenge: Codable, Sendable, Equatable {
    public let token: String
    public let amount: String
    public let recipient: String
    public let chainId: Int
    public let serviceUrl: String?

    public init(token: String, amount: String, recipient: String, chainId: Int, serviceUrl: String? = nil) {
        self.token = token
        self.amount = amount
        self.recipient = recipient
        self.chainId = chainId
        self.serviceUrl = serviceUrl
    }
}

public struct X402PaymentReceipt: Codable, Sendable, Equatable {
    public let txHash: String
    public let amount: String
    public let token: String
    public let recipient: String
    public let blockNumber: Int?
    public let timestamp: Int?

    public init(
        txHash: String,
        amount: String,
        token: String,
        recipient: String,
        blockNumber: Int? = nil,
        timestamp: Int? = nil
    ) {
        self.txHash = txHash
        self.amount = amount
        self.token = token
        self.recipient = recipient
        self.blockNumber = blockNumber
        self.timestamp = timestamp
    }
}

public struct TokenBalance: Codable, Sendable, Equatable {
    public let tokenAddress: String
    public let rawAmount: String
    public let uiAmount: String
    public let symbol: String
    public let decimals: Int

    public init(
        tokenAddress: String,
        rawAmount: String,
        uiAmount: String,
        symbol: String,
        decimals: Int
    ) {
        self.tokenAddress = tokenAddress
        self.rawAmount = rawAmount
        self.uiAmount = uiAmount
        self.symbol = symbol
        self.decimals = decimals
    }
}
