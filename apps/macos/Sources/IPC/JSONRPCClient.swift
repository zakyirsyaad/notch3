import Foundation

/// Native Swift JSON-RPC 2.0 Client communicating over Stdin/Stdout pipes or custom stream transports.
public final class JSONRPCClient: @unchecked Sendable {
    private let lock = NSLock()
    private var requestCounter: Int = 0
    private var pendingRequests: [JSONRPCId: CheckedContinuation<Data, Error>] = [:]
    private var notificationHandlers: [String: @Sendable (Data) -> Void] = [:]
    private var incomingBuffer = Data()

    public var transportWriter: (@Sendable (Data) throws -> Void)?

    public init(transportWriter: (@Sendable (Data) throws -> Void)? = nil) {
        self.transportWriter = transportWriter
    }

    // MARK: - Transport Configuration

    public func setTransportWriter(_ writer: @escaping @Sendable (Data) throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.transportWriter = writer
    }

    // MARK: - Notification Registration

    /// Registers a callback for incoming JSON-RPC 2.0 notifications matching the specified method.
    public func onNotification(method: String, handler: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.notificationHandlers[method] = handler
    }

    /// Removes the callback for the specified notification method.
    public func removeNotificationHandler(for method: String) {
        lock.lock()
        defer { lock.unlock() }
        self.notificationHandlers.removeValue(forKey: method)
    }

    // MARK: - Request Encoding

    /// Encodes a strongly-typed request into JSON-RPC 2.0 message bytes.
    public func encodeRequest<T: Codable & Sendable>(id: JSONRPCId, method: String, params: T) throws -> Data {
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    /// Encodes a notification into JSON-RPC 2.0 message bytes without an ID.
    public func encodeNotification<T: Codable & Sendable>(method: String, params: T) throws -> Data {
        let notif = JSONRPCNotification(method: method, params: params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(notif)
    }

    // MARK: - Request & Notification Sending

    /// Sends a JSON-RPC 2.0 request and awaits the strongly-typed response.
    public func sendRequest<T: Codable & Sendable, R: Codable & Sendable>(
        method: String,
        params: T,
        timeoutSeconds: TimeInterval = 30.0
    ) async throws -> R {
        let requestId: JSONRPCId = nextRequestId()
        let requestData = try encodeRequest(id: requestId, method: method, params: params)

        guard let writer = getTransportWriter() else {
            throw JSONRPCClientError.processNotRunning
        }

        // Send line-delimited JSON
        var payload = requestData
        payload.append(contentsOf: [0x0A]) // \n

        return try await executeRequestContinuation(requestId: requestId, payload: payload, timeoutSeconds: timeoutSeconds, writer: writer)
    }

    /// Convenience overload for sending requests without custom parameters.
    public func sendRequest<R: Codable & Sendable>(
        method: String,
        timeoutSeconds: TimeInterval = 30.0
    ) async throws -> R {
        try await sendRequest(method: method, params: EmptyParams(), timeoutSeconds: timeoutSeconds)
    }

    /// Sends a fire-and-forget JSON-RPC 2.0 notification.
    public func sendNotification<T: Codable & Sendable>(method: String, params: T) throws {
        guard let writer = getTransportWriter() else {
            throw JSONRPCClientError.processNotRunning
        }
        var payload = try encodeNotification(method: method, params: params)
        payload.append(contentsOf: [0x0A]) // \n
        try writer(payload)
    }

    // MARK: - Incoming Message Stream Processing

    /// Appends incoming raw bytes from stdout/transport and parses newline-delimited JSON lines.
    public func handleIncomingData(_ data: Data) {
        lock.lock()
        incomingBuffer.append(data)
        var linesToProcess: [Data] = []

        while let newlineIndex = incomingBuffer.firstIndex(of: 0x0A) {
            let lineData = incomingBuffer.subdata(in: incomingBuffer.startIndex..<newlineIndex)
            incomingBuffer.removeSubrange(incomingBuffer.startIndex...newlineIndex)
            if !lineData.isEmpty {
                linesToProcess.append(lineData)
            }
        }
        lock.unlock()

        for lineData in linesToProcess {
            processMessage(lineData)
        }
    }

    /// Processes a single UTF-8 string line received from the transport.
    public func handleIncomingLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        processMessage(data)
    }

    private func processMessage(_ data: Data) {
        let decoder = JSONDecoder()

        // 1. Check if this is a response to an active request (has id)
        if let rawMsg = try? decoder.decode(RawJSONRPCMessage.self, from: data), let msgId = rawMsg.id {
            lock.lock()
            let continuation = pendingRequests.removeValue(forKey: msgId)
            lock.unlock()

            if let cont = continuation {
                if let errorObj = rawMsg.error {
                    cont.resume(throwing: JSONRPCClientError.remoteError(
                        code: errorObj.code,
                        message: errorObj.message,
                        data: errorObj.data
                    ))
                } else {
                    cont.resume(returning: data)
                }
                return
            }
        }

        // 2. Check if this is a notification (has method, no id)
        if let notif = try? decoder.decode(JSONRPCNotification<AnyCodableEmpty>.self, from: data) {
            lock.lock()
            let handler = notificationHandlers[notif.method]
            lock.unlock()

            if let handler = handler {
                handler(data)
            }
        }
    }

    // MARK: - Private Helpers

    private func nextRequestId() -> JSONRPCId {
        lock.lock()
        defer { lock.unlock() }
        requestCounter += 1
        return .string(String(requestCounter))
    }

    private func getTransportWriter() -> (@Sendable (Data) throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return transportWriter
    }

    private func failRequest(id: JSONRPCId, with error: Error) {
        lock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// Resets all active pending requests and clears internal state (e.g. on process termination).
    public func reset(with error: Error = JSONRPCClientError.transportClosed) {
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        incomingBuffer.removeAll()
        lock.unlock()

        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    private func executeRequestContinuation<R: Codable & Sendable>(
        requestId: JSONRPCId,
        payload: Data,
        timeoutSeconds: TimeInterval,
        writer: @Sendable (Data) throws -> Void
    ) async throws -> R {
        let rawData: Data = try await Swift.withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[requestId] = continuation
            lock.unlock()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if !Task.isCancelled {
                    self.failRequest(id: requestId, with: JSONRPCClientError.responseTimeout)
                }
            }

            do {
                try writer(payload)
            } catch {
                timeoutTask.cancel()
                self.failRequest(id: requestId, with: error)
            }
        }

        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(JSONRPCResponse<R>.self, from: rawData)
            if let error = response.error {
                throw JSONRPCClientError.remoteError(code: error.code, message: error.message, data: error.data)
            }
            guard let result = response.result else {
                throw JSONRPCClientError.invalidResponse
            }
            return result
        } catch let clientError as JSONRPCClientError {
            throw clientError
        } catch {
            throw JSONRPCClientError.decodingFailed(String(describing: error))
        }
    }
}

private struct AnyCodableEmpty: Codable, Sendable {}
