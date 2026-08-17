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
    /// Runtime lock state: "locked" or "unlocked" — mirrors `lockState` from agent.getStatus.
    public let lockState: String
    /// Aggregate state: "locked" or "active" — mirrors `state` from agent.getStatus.
    public let state: String?
    public let address: String?
    /// Native balance as a UI-amount string — mirrors `balance` from agent.getStatus.
    public let balance: String?
    public let activeTasks: Int?
    public let lastActivity: Int?
    public let autoPayMaxTBNB: String?

    public init(
        lockState: String,
        state: String? = nil,
        address: String? = nil,
        balance: String? = nil,
        activeTasks: Int? = nil,
        lastActivity: Int? = nil,
        autoPayMaxTBNB: String? = nil
    ) {
        self.lockState = lockState
        self.state = state
        self.address = address
        self.balance = balance
        self.activeTasks = activeTasks
        self.lastActivity = lastActivity
        self.autoPayMaxTBNB = autoPayMaxTBNB
    }

    /// Convenience derived flag matching the runtime's lockState field.
    public var isUnlocked: Bool {
        lockState.lowercased() == "unlocked"
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

// MARK: - PancakeSwap & Swap Models

public struct SwapQuoteParams: Codable, Sendable, Equatable {
    public let tokenIn: String
    public let tokenOut: String
    public let amountIn: String
    public let slippageTolerancePercent: Double?
    public let recipient: String?
    public let route: [String]?
    public let chainId: Int?

    public init(
        tokenIn: String,
        tokenOut: String,
        amountIn: String,
        slippageTolerancePercent: Double? = nil,
        recipient: String? = nil,
        route: [String]? = nil,
        chainId: Int? = nil
    ) {
        self.tokenIn = tokenIn
        self.tokenOut = tokenOut
        self.amountIn = amountIn
        self.slippageTolerancePercent = slippageTolerancePercent
        self.recipient = recipient
        self.route = route
        self.chainId = chainId
    }
}

public struct SwapQuoteResult: Codable, Sendable, Equatable {
    public let tokenIn: String
    public let tokenOut: String
    public let amountIn: String
    public let amountOut: String
    public let amountOutMin: String
    public let slippageTolerancePercent: Double
    public let route: [String]
    public let priceImpactPercent: Double?
    public let executionPrice: String?
    public let estimatedGas: String?

    public init(
        tokenIn: String,
        tokenOut: String,
        amountIn: String,
        amountOut: String,
        amountOutMin: String,
        slippageTolerancePercent: Double,
        route: [String],
        priceImpactPercent: Double? = nil,
        executionPrice: String? = nil,
        estimatedGas: String? = nil
    ) {
        self.tokenIn = tokenIn
        self.tokenOut = tokenOut
        self.amountIn = amountIn
        self.amountOut = amountOut
        self.amountOutMin = amountOutMin
        self.slippageTolerancePercent = slippageTolerancePercent
        self.route = route
        self.priceImpactPercent = priceImpactPercent
        self.executionPrice = executionPrice
        self.estimatedGas = estimatedGas
    }
}

public struct BuildSwapParams: Codable, Sendable, Equatable {
    public let tokenIn: String
    public let tokenOut: String
    public let amountIn: String
    public let amountOutMin: String
    public let recipient: String
    public let deadline: Int?
    public let slippageTolerancePercent: Double?
    public let route: [String]?
    public let chainId: Int?

    public init(
        tokenIn: String,
        tokenOut: String,
        amountIn: String,
        amountOutMin: String,
        recipient: String,
        deadline: Int? = nil,
        slippageTolerancePercent: Double? = nil,
        route: [String]? = nil,
        chainId: Int? = nil
    ) {
        self.tokenIn = tokenIn
        self.tokenOut = tokenOut
        self.amountIn = amountIn
        self.amountOutMin = amountOutMin
        self.recipient = recipient
        self.deadline = deadline
        self.slippageTolerancePercent = slippageTolerancePercent
        self.route = route
        self.chainId = chainId
    }
}

public struct UnsignedTransactionPayload: Codable, Sendable, Equatable {
    public let to: String
    public let value: String
    public let data: String
    public let chainId: Int?
    public let gasLimit: String?
    public let gasPrice: String?
    public let nonce: Int?
    public let description: String?

    public init(
        to: String,
        value: String,
        data: String,
        chainId: Int? = nil,
        gasLimit: String? = nil,
        gasPrice: String? = nil,
        nonce: Int? = nil,
        description: String? = nil
    ) {
        self.to = to
        self.value = value
        self.data = data
        self.chainId = chainId
        self.gasLimit = gasLimit
        self.gasPrice = gasPrice
        self.nonce = nonce
        self.description = description
    }
}

// MARK: - Maker Mode / MPP Models

public struct MPPServerStatus: Codable, Sendable, Equatable {
    public let running: Bool
    public let port: Int?
    public let host: String?
    public let recipient: String?
    public let chainId: Int?
    public let totalSales: Int?
    public let totalRevenue: String?
    public let uptime: Double?
    public let activeEndpoints: [String]?

    public init(
        running: Bool,
        port: Int? = nil,
        host: String? = nil,
        recipient: String? = nil,
        chainId: Int? = nil,
        totalSales: Int? = nil,
        totalRevenue: String? = nil,
        uptime: Double? = nil,
        activeEndpoints: [String]? = nil
    ) {
        self.running = running
        self.port = port
        self.host = host
        self.recipient = recipient
        self.chainId = chainId
        self.totalSales = totalSales
        self.totalRevenue = totalRevenue
        self.uptime = uptime
        self.activeEndpoints = activeEndpoints
    }
}

public struct MPPSaleReceipt: Codable, Sendable, Equatable {
    public let txHash: String
    public let payer: String
    public let recipient: String
    public let amount: String
    public let token: String
    public let chainId: Int
    public let endpoint: String
    public let timestamp: Int
    public let blockNumber: Int?
    public let status: String

    public init(
        txHash: String,
        payer: String,
        recipient: String,
        amount: String,
        token: String,
        chainId: Int,
        endpoint: String,
        timestamp: Int,
        blockNumber: Int? = nil,
        status: String = "settled"
    ) {
        self.txHash = txHash
        self.payer = payer
        self.recipient = recipient
        self.amount = amount
        self.token = token
        self.chainId = chainId
        self.endpoint = endpoint
        self.timestamp = timestamp
        self.blockNumber = blockNumber
        self.status = status
    }
}

// MARK: - Multi-Chain Network Switcher Models

public struct NetworkConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { chainId }
    public let chainId: Int
    public let name: String
    public let nativeSymbol: String
    public let rpcUrl: String
    public let explorerUrl: String
    public let isTestnet: Bool

    public init(
        chainId: Int,
        name: String,
        nativeSymbol: String,
        rpcUrl: String,
        explorerUrl: String,
        isTestnet: Bool
    ) {
        self.chainId = chainId
        self.name = name
        self.nativeSymbol = nativeSymbol
        self.rpcUrl = rpcUrl
        self.explorerUrl = explorerUrl
        self.isTestnet = isTestnet
    }
}

public extension NetworkConfig {
    static let bscTestnet = NetworkConfig(
        chainId: 97,
        name: "BSC Testnet",
        nativeSymbol: "tBNB",
        rpcUrl: "https://data-seed-prebsc-1-s1.binance.org:8545/",
        explorerUrl: "https://testnet.bscscan.com",
        isTestnet: true
    )
    static let bscMainnet = NetworkConfig(
        chainId: 56,
        name: "BSC Mainnet",
        nativeSymbol: "BNB",
        rpcUrl: "https://bsc-dataseed.binance.org/",
        explorerUrl: "https://bscscan.com",
        isTestnet: false
    )
    static let opBnbTestnet = NetworkConfig(
        chainId: 5611,
        name: "opBNB Testnet",
        nativeSymbol: "tBNB",
        rpcUrl: "https://opbnb-testnet-rpc.bnbchain.org",
        explorerUrl: "https://testnet.opbnbscan.com",
        isTestnet: true
    )
    static let opBnbMainnet = NetworkConfig(
        chainId: 204,
        name: "opBNB Mainnet",
        nativeSymbol: "BNB",
        rpcUrl: "https://opbnb-mainnet-rpc.bnbchain.org",
        explorerUrl: "https://opbnbscan.com",
        isTestnet: false
    )

    static let allNetworks: [NetworkConfig] = [
        .bscTestnet,
        .bscMainnet,
        .opBnbTestnet,
        .opBnbMainnet
    ]
}

public struct NetworkSwitchParams: Codable, Sendable, Equatable {
    public let chainId: Int

    public init(chainId: Int) {
        self.chainId = chainId
    }
}

public struct NetworkSwitchResult: Codable, Sendable, Equatable {
    public let success: Bool
    public let activeNetwork: NetworkConfig
    public let previousChainId: Int?

    public init(
        success: Bool,
        activeNetwork: NetworkConfig,
        previousChainId: Int? = nil
    ) {
        self.success = success
        self.activeNetwork = activeNetwork
        self.previousChainId = previousChainId
    }
}

// MARK: - BNB Greenfield Decentralized Storage Models

public struct GreenfieldUploadParams: Codable, Sendable, Equatable {
    public let bucket: String?
    public let objectName: String
    public let content: String
    public let contentType: String?
    public let isPrivate: Bool?

    public init(
        bucket: String? = nil,
        objectName: String,
        content: String,
        contentType: String? = nil,
        isPrivate: Bool? = nil
    ) {
        self.bucket = bucket
        self.objectName = objectName
        self.content = content
        self.contentType = contentType
        self.isPrivate = isPrivate
    }
}

public struct GreenfieldUploadResult: Codable, Sendable, Equatable {
    public let bucket: String
    public let objectName: String
    public let url: String
    public let objectId: String
    public let contentHash: String
    public let size: Int
    public let isPrivate: Bool

    public init(
        bucket: String,
        objectName: String,
        url: String,
        objectId: String,
        contentHash: String,
        size: Int,
        isPrivate: Bool
    ) {
        self.bucket = bucket
        self.objectName = objectName
        self.url = url
        self.objectId = objectId
        self.contentHash = contentHash
        self.size = size
        self.isPrivate = isPrivate
    }
}

public struct GreenfieldObjectMetadata: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(bucket)/\(objectName)" }
    public let bucket: String
    public let objectName: String
    public let objectId: String
    public let contentHash: String
    public let size: Int
    public let contentType: String
    public let isPrivate: Bool
    public let createdAt: Int?

    public init(
        bucket: String,
        objectName: String,
        objectId: String,
        contentHash: String,
        size: Int,
        contentType: String = "text/plain",
        isPrivate: Bool = false,
        createdAt: Int? = nil
    ) {
        self.bucket = bucket
        self.objectName = objectName
        self.objectId = objectId
        self.contentHash = contentHash
        self.size = size
        self.contentType = contentType
        self.isPrivate = isPrivate
        self.createdAt = createdAt
    }
}

public struct GreenfieldObjectResult: Codable, Sendable, Equatable {
    public let bucket: String
    public let objectName: String
    public let content: String
    public let contentType: String
    public let size: Int
    public let isPrivate: Bool

    public init(
        bucket: String,
        objectName: String,
        content: String,
        contentType: String,
        size: Int,
        isPrivate: Bool
    ) {
        self.bucket = bucket
        self.objectName = objectName
        self.content = content
        self.contentType = contentType
        self.size = size
        self.isPrivate = isPrivate
    }
}

public struct GreenfieldBackupParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let encryptedData: String?
    public let rawHistory: [ChatMessage]?
    public let encryptionKey: String?
    public let bucket: String?

    public init(
        sessionId: String,
        encryptedData: String? = nil,
        rawHistory: [ChatMessage]? = nil,
        encryptionKey: String? = nil,
        bucket: String? = nil
    ) {
        self.sessionId = sessionId
        self.encryptedData = encryptedData
        self.rawHistory = rawHistory
        self.encryptionKey = encryptionKey
        self.bucket = bucket
    }
}

public struct GreenfieldBackupResult: Codable, Sendable, Equatable {
    public let sessionId: String
    public let url: String
    public let objectId: String
    public let timestamp: Int

    public init(
        sessionId: String,
        url: String,
        objectId: String,
        timestamp: Int
    ) {
        self.sessionId = sessionId
        self.url = url
        self.objectId = objectId
        self.timestamp = timestamp
    }
}

