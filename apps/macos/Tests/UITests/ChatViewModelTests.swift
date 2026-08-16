import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Chat View Model Tests")
@MainActor
struct ChatViewModelTests {

    @Test("Default state initializes with welcome message")
    func testDefaultState() {
        let vm = ChatViewModel()

        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.role == .assistant)
        #expect(vm.inputText.isEmpty)
        #expect(!vm.isStreaming)
        #expect(vm.errorMessage == nil)
    }

    @Test("Sending a message adds user message and placeholder assistant message")
    func testSendMessage() {
        let vm = ChatViewModel()
        vm.inputText = "Hello Agent"

        vm.sendMessage()

        #expect(vm.messages.count == 3) // welcome + user + streaming assistant
        #expect(vm.messages[1].role == .user)
        #expect(vm.messages[1].content == "Hello Agent")
        #expect(vm.messages[2].role == .assistant)
        #expect(vm.messages[2].isStreaming)
        #expect(vm.isStreaming)
        #expect(vm.inputText.isEmpty)
    }

    @Test("Empty input does not send message")
    func testEmptyInputNotSent() {
        let vm = ChatViewModel()
        vm.inputText = "   "

        vm.sendMessage()

        #expect(vm.messages.count == 1)
        #expect(!vm.isStreaming)
    }

    @Test("Streaming chunks are appended to active assistant message")
    func testStreamingChunks() {
        let vm = ChatViewModel()
        vm.updateLastAssistantMessage(content: "Initial", isStreaming: true)

        vm.appendStreamingChunk(" chunk 1")
        vm.appendStreamingChunk(" chunk 2")

        #expect(vm.messages.last?.content == "Initial chunk 1 chunk 2")
    }

    @Test("Completing streaming response updates receipt and citations")
    func testCompleteStreaming() {
        let vm = ChatViewModel()
        vm.updateLastAssistantMessage(content: "Response ready", isStreaming: true)

        let receipt = X402PaymentReceipt(
            txHash: "0x1234567890abcdef1234567890abcdef12345678",
            amount: "0.001",
            token: "tBNB",
            recipient: "0x0000000000000000000000000000000000000000"
        )
        let citations = [
            CitationLink(title: "BNB Docs", urlString: "https://docs.bnbchain.org")
        ]

        vm.completeStreamingResponse(receipt: receipt, citations: citations)

        #expect(!vm.isStreaming)
        #expect(vm.messages.last?.isStreaming == false)
        #expect(vm.messages.last?.receipt?.txHash == "0x1234567890abcdef1234567890abcdef12345678")
        #expect(vm.messages.last?.citations.count == 1)
        #expect(vm.messages.last?.citations.first?.title == "BNB Docs")
    }

    @Test("Custom onSendMessage handler processes asynchronous response")
    func testCustomHandler() async {
        let vm = ChatViewModel()
        vm.onSendMessage = { text in
            vm.appendStreamingChunk("Handled: \(text)")
            vm.completeStreamingResponse()
        }

        vm.sendMessage("Custom Test")

        // Wait brief cycle for async task
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.messages.last?.content.contains("Handled: Custom Test") == true)
        #expect(!vm.isStreaming)
    }

    @Test("Clear messages resets chat history to welcome message")
    func testClearMessages() {
        let vm = ChatViewModel()
        vm.messages.append(ChatMessage(role: .user, content: "Test 1"))
        vm.messages.append(ChatMessage(role: .assistant, content: "Test 2"))

        #expect(vm.messages.count > 1)

        vm.clearMessages()

        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.role == .assistant)
        #expect(!vm.isStreaming)
    }
}
