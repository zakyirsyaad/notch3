import Foundation

// MARK: - Process Runner Protocol

public protocol AgentProcessRunning: AnyObject, Sendable {
    var isRunning: Bool { get }
    var client: JSONRPCClient { get }
    func start(nodeBinaryPath: String, scriptPath: String, arguments: [String], environment: [String: String]) throws
    func start(nodeBinaryPath: String, scriptPath: String) throws
    func stop()
}

public extension AgentProcessRunning {
    func start(nodeBinaryPath: String, scriptPath: String) throws {
        try start(nodeBinaryPath: nodeBinaryPath, scriptPath: scriptPath, arguments: [], environment: [:])
    }
}

// MARK: - Native Subprocess IPC Runner

/// Manages the Node.js agent runtime child process and connects standard input/output pipes to JSONRPCClient.
open class AgentProcessRunner: AgentProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    public let client: JSONRPCClient
    public private(set) var isRunning: Bool = false
    public private(set) var processIdentifier: Int32?

    public var onProcessTerminated: (@Sendable (Int32) -> Void)?
    public var onErrorOutput: (@Sendable (String) -> Void)?

    public init(client: JSONRPCClient = JSONRPCClient()) {
        self.client = client
        self.client.setTransportWriter { [weak self] data in
            try self?.write(data)
        }
    }

    deinit {
        stop()
    }

    /// Spawns the Node.js agent runtime process with line-delimited Stdin/Stdout IPC pipes.
    open func start(
        nodeBinaryPath: String,
        scriptPath: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if isRunning {
            internalStop()
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeBinaryPath)
        
        var procArgs: [String] = []
        if !scriptPath.isEmpty {
            procArgs.append(scriptPath)
        }
        procArgs.append(contentsOf: arguments)
        proc.arguments = procArgs

        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in environment {
            mergedEnv[k] = v
        }
        proc.environment = mergedEnv

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe
        self.process = proc

        // Read output pipe asynchronously
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.client.handleIncomingData(data)
        }

        // Read error pipe for stderr logging
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onErrorOutput?(text)
        }

        proc.terminationHandler = { [weak self] p in
            self?.handleTermination(status: p.terminationStatus)
        }

        try proc.run()
        self.isRunning = true
        self.processIdentifier = proc.processIdentifier
    }

    /// Writes raw byte payload to the subprocess's standard input pipe.
    public func write(_ data: Data) throws {
        lock.lock()
        guard isRunning, let inPipe = self.inputPipe else {
            lock.unlock()
            throw JSONRPCClientError.processNotRunning
        }
        let handle = inPipe.fileHandleForWriting
        lock.unlock()

        try handle.write(contentsOf: data)
    }

    /// Terminates the child process and cleans up IPC pipes.
    open func stop() {
        lock.lock()
        defer { lock.unlock() }
        internalStop()
    }

    private func internalStop() {
        guard isRunning || process != nil else { return }

        // Remove handlers
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()

        if let proc = process, proc.isRunning {
            proc.terminate()
        }

        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false
        processIdentifier = nil

        client.reset(with: JSONRPCClientError.processNotRunning)
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        isRunning = false
        processIdentifier = nil
        lock.unlock()

        client.reset(with: JSONRPCClientError.processNotRunning)
        onProcessTerminated?(status)
    }
}
