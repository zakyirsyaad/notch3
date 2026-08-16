import Testing
import Foundation
@testable import NotchAgentCore

@Suite("JSON-RPC 2.0 Client & Subprocess IPC Tests")
struct JSONRPCClientTests {

    // MARK: - Serialization & Deserialization Tests

    @Test("Request serialization encodes correct JSON-RPC 2.0 structure")
    func testRequestSerialization() throws {
        let client = JSONRPCClient()
        let requestData = try client.encodeRequest(id: "1", method: "agent.getStatus", params: EmptyParams())
        let jsonString = String(data: requestData, encoding: .utf8)!
        #expect(jsonString.contains("\"jsonrpc\":\"2.0\""))
        #expect(jsonString.contains("\"method\":\"agent.getStatus\""))
        #expect(jsonString.contains("\"id\":\"1\""))
    }

    @Test("Notification serialization encodes correct structure without ID")
    func testNotificationSerialization() throws {
        let client = JSONRPCClient()
        let notifData = try client.encodeNotification(method: "agent.heartbeat", params: ["timestamp": 1234567890])
        let jsonString = String(data: notifData, encoding: .utf8)!
        #expect(jsonString.contains("\"jsonrpc\":\"2.0\""))
        #expect(jsonString.contains("\"method\":\"agent.heartbeat\""))
        #expect(!jsonString.contains("\"id\""))
    }

    @Test("JSONRPCId supports String, Int, and Null representations")
    func testJSONRPCIdRepresentations() throws {
        let idString: JSONRPCId = "req-42"
        let idInt: JSONRPCId = 101
        let idNull: JSONRPCId = .null

        #expect(idString.description == "req-42")
        #expect(idInt.description == "101")
        #expect(idNull.description == "null")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encodedStr = try encoder.encode(idString)
        let decodedStr = try decoder.decode(JSONRPCId.self, from: encodedStr)
        #expect(decodedStr == idString)

        let encodedInt = try encoder.encode(idInt)
        let decodedInt = try decoder.decode(JSONRPCId.self, from: encodedInt)
        #expect(decodedInt == idInt)
    }

    @Test("Models decode AgentStatus and X402 payment types correctly")
    func testModelDecoding() throws {
        let statusJson = """
        {
            "jsonrpc": "2.0",
            "id": "1",
            "result": {
                "isUnlocked": true,
                "address": "0x1111111111111111111111111111111111111111",
                "balanceTBNB": "0.50",
                "activeTools": ["pay_x402_service"],
                "erc8004Registered": true
            }
        }
        """
        let data = statusJson.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(JSONRPCResponse<AgentStatus>.self, from: data)

        #expect(response.result?.isUnlocked == true)
        #expect(response.result?.address == "0x1111111111111111111111111111111111111111")
        #expect(response.result?.balanceTBNB == "0.50")
        #expect(response.result?.activeTools?.contains("pay_x402_service") == true)
    }

    // MARK: - Async Request & Response Roundtrip Tests

    @Test("Async request and response roundtrip succeeds")
    func testAsyncRequestResponseRoundtrip() async throws {
        let client = JSONRPCClient()

        client.setTransportWriter { [weak client] payload in
            // Mock server: decode incoming request ID and reply with AgentStatus
            Task {
                let decoder = JSONDecoder()
                guard let rawReq = try? decoder.decode(RawJSONRPCMessage.self, from: payload),
                      let reqId = rawReq.id else { return }

                let responseJson = """
                {"jsonrpc":"2.0","id":"\(reqId.description)","result":{"isUnlocked":true,"address":"0xTestAddress","balanceTBNB":"1.25"}}
                \n
                """
                client?.handleIncomingData(responseJson.data(using: .utf8)!)
            }
        }

        let status: AgentStatus = try await client.sendRequest(method: "agent.getStatus", params: EmptyParams())
        #expect(status.isUnlocked == true)
        #expect(status.address == "0xTestAddress")
        #expect(status.balanceTBNB == "1.25")
    }

    @Test("Async request handles remote JSON-RPC error response")
    func testAsyncRequestRemoteError() async throws {
        let client = JSONRPCClient()

        client.setTransportWriter { [weak client] payload in
            Task {
                let decoder = JSONDecoder()
                guard let rawReq = try? decoder.decode(RawJSONRPCMessage.self, from: payload),
                      let reqId = rawReq.id else { return }

                let errorJson = """
                {"jsonrpc":"2.0","id":"\(reqId.description)","error":{"code":-32002,"message":"Wallet is locked","data":"AgentSession requires unlock"}}
                \n
                """
                client?.handleIncomingData(errorJson.data(using: .utf8)!)
            }
        }

        do {
            let _: AgentStatus = try await client.sendRequest(method: "agent.getStatus", params: EmptyParams())
            #expect(Bool(false), "Should have thrown remoteError")
        } catch let JSONRPCClientError.remoteError(code, message, data) {
            #expect(code == -32002)
            #expect(message == "Wallet is locked")
            #expect(data == "AgentSession requires unlock")
        }
    }

    @Test("Async request times out when no response is received")
    func testAsyncRequestTimeout() async throws {
        let client = JSONRPCClient()
        client.setTransportWriter { _ in
            // Never respond
        }

        do {
            let _: AgentStatus = try await client.sendRequest(
                method: "agent.getStatus",
                params: EmptyParams(),
                timeoutSeconds: 0.05
            )
            #expect(Bool(false), "Should have timed out")
        } catch let error as JSONRPCClientError {
            #expect(error == .responseTimeout)
        }
    }

    // MARK: - Notification Dispatch Tests

    @Test("Notification handler receives and dispatches notification payload")
    func testNotificationDispatch() async throws {
        let client = JSONRPCClient()
        let receivedData = ValueContainer<Data>()

        client.onNotification(method: "agent.chatStream") { data in
            receivedData.set(data)
        }

        let notifLine = "{\"jsonrpc\":\"2.0\",\"method\":\"agent.chatStream\",\"params\":{\"chunk\":\"Hello BSC\"}}\n"
        client.handleIncomingData(notifLine.data(using: .utf8)!)

        let result = receivedData.get()
        #expect(result != nil)
        if let result = result {
            let text = String(data: result, encoding: .utf8)!
            #expect(text.contains("Hello BSC"))
        }
    }

    // MARK: - Stream Chunking Tests

    @Test("Fragmented data stream correctly buffers and processes complete lines")
    func testFragmentedDataStream() async throws {
        let client = JSONRPCClient()

        client.setTransportWriter { [weak client] payload in
            Task {
                let decoder = JSONDecoder()
                guard let rawReq = try? decoder.decode(RawJSONRPCMessage.self, from: payload),
                      let reqId = rawReq.id else { return }

                let fullResponse = "{\"jsonrpc\":\"2.0\",\"id\":\"\(reqId.description)\",\"result\":{\"isUnlocked\":true}}\n"
                let data = fullResponse.data(using: .utf8)!

                // Split into 3 chunks
                let part1 = data.subdata(in: 0..<10)
                let part2 = data.subdata(in: 10..<30)
                let part3 = data.subdata(in: 30..<data.count)

                client?.handleIncomingData(part1)
                try? await Task.sleep(nanoseconds: 10_000_000)
                client?.handleIncomingData(part2)
                try? await Task.sleep(nanoseconds: 10_000_000)
                client?.handleIncomingData(part3)
            }
        }

        let status: AgentStatus = try await client.sendRequest(method: "agent.getStatus")
        #expect(status.isUnlocked == true)
    }

    // MARK: - Subprocess Execution Tests

    @Test("AgentProcessRunner spawns process and conducts Stdin/Stdout communication")
    func testRealProcessRunnerEcho() async throws {
        let runner = AgentProcessRunner()
        // Use /bin/cat which echoes stdin directly to stdout
        try runner.start(nodeBinaryPath: "/bin/cat", scriptPath: "")
        #expect(runner.isRunning == true)
        #expect(runner.processIdentifier != nil)

        let notificationReceived = ValueContainer<Data>()
        runner.client.onNotification(method: "echo.test") { data in
            notificationReceived.set(data)
        }

        // Send a notification through runner's client
        try runner.client.sendNotification(method: "echo.test", params: ["msg": "hello from cat"])

        // Wait briefly for echo from cat process
        for _ in 0..<20 {
            if notificationReceived.get() != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        let received = notificationReceived.get()
        #expect(received != nil)
        if let received = received {
            let str = String(data: received, encoding: .utf8)!
            #expect(str.contains("echo.test"))
            #expect(str.contains("hello from cat"))
        }

        runner.stop()
        #expect(runner.isRunning == false)
    }
}

// MARK: - Test Helpers

private final class ValueContainer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    init(_ initial: T? = nil) {
        self.value = initial
    }

    func set(_ val: T) {
        lock.lock()
        defer { lock.unlock() }
        self.value = val
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return self.value
    }
}
