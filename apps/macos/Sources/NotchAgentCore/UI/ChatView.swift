import SwiftUI
import AppKit

/// Role of a message in the chat conversation.
public enum ChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// Structured citation or reference link from AI responses (e.g., BNB Greenfield Docs, BSCScan, Dev Portal).
public struct CitationLink: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let urlString: String?
    public let snippet: String?
    public let badge: String?

    public init(
        id: UUID = UUID(),
        title: String,
        urlString: String? = nil,
        snippet: String? = nil,
        badge: String? = "Doc"
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.snippet = snippet
        self.badge = badge
    }

    public var url: URL? {
        guard let urlString = urlString else { return nil }
        return URL(string: urlString)
    }
}

/// Message model for the AI chat feed.
public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let role: ChatMessageRole
    public var content: String
    public let timestamp: Date
    public var isStreaming: Bool
    public var receipt: X402PaymentReceipt?
    public var citations: [CitationLink]

    public init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        receipt: X402PaymentReceipt? = nil,
        citations: [CitationLink] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.receipt = receipt
        self.citations = citations
    }
}

/// Raised when chat is attempted without a connected agent runtime.
public struct ChatUnavailableError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? {
        "Agent runtime unavailable — connect the runtime to chat."
    }
}

/// Wire type of the runtime's `agent.executePrompt` response
/// (mirrors AgentExecutionResult in @notch/shared-types).
public struct AgentExecutionResultDTO: Codable, Sendable, Equatable {
    public let response: String
    public let toolCallsExecuted: [ToolCallExecutionDTO]?
    public let receipts: [X402PaymentReceipt]?
    public let citations: [String]?

    public init(
        response: String,
        toolCallsExecuted: [ToolCallExecutionDTO]? = nil,
        receipts: [X402PaymentReceipt]? = nil,
        citations: [String]? = nil
    ) {
        self.response = response
        self.toolCallsExecuted = toolCallsExecuted
        self.receipts = receipts
        self.citations = citations
    }
}

public struct ToolCallExecutionDTO: Codable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// View model driving the interactive chat interface, streaming assistant messages, citations, and receipts.
@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var inputText: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var errorMessage: String? = nil

    public var onSendMessage: ((String) async throws -> Void)?
    /// Live runtime client — chat requires it; without a runtime the assistant
    /// reports an honest error instead of streaming a fabricated answer.
    public var rpcClient: JSONRPCClient?

    public init(messages: [ChatMessage] = [], rpcClient: JSONRPCClient? = nil) {
        if messages.isEmpty {
            self.messages = [Self.welcomeMessage()]
        } else {
            self.messages = messages
        }
        self.rpcClient = rpcClient
    }

    // MARK: - Message Handling

    /// Sends current user input or explicit text.
    public func sendMessage(_ explicitText: String? = nil) {
        let textToSend = (explicitText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSend.isEmpty, !isStreaming else { return }

        // Clear input
        self.inputText = ""
        self.errorMessage = nil

        // Add user message
        let userMsg = ChatMessage(role: .user, content: textToSend)
        self.messages.append(userMsg)

        // Add placeholder streaming assistant message
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        self.messages.append(assistantMsg)
        self.isStreaming = true

        Task { [weak self] in
            guard let self = self else { return }
            do {
                if let handler = self.onSendMessage {
                    try await handler(textToSend)
                } else if let client = self.rpcClient {
                    let result: AgentExecutionResultDTO = try await client.sendRequest(
                        method: "agent.executePrompt",
                        params: ["prompt": textToSend],
                        timeoutSeconds: 120.0
                    )
                    self.updateLastAssistantMessage(
                        content: result.response,
                        isStreaming: false,
                        receipt: result.receipts?.first,
                        citations: Self.citationLinks(from: result.citations)
                    )
                } else {
                    throw ChatUnavailableError()
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.updateLastAssistantMessage(content: "Error: \(error.localizedDescription)", isStreaming: false)
                self.isStreaming = false
            }
        }
    }

    /// Maps runtime citation URL strings to display links.
    private static func citationLinks(from urls: [String]?) -> [CitationLink] {
        guard let urls else { return [] }
        return urls.map { url in
            let host = URL(string: url)?.host ?? url
            return CitationLink(title: host, urlString: url, badge: "Source")
        }
    }

    /// Appends incoming streaming token chunk to the active assistant message.
    public func appendStreamingChunk(_ chunk: String) {
        guard let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant else {
            return
        }
        messages[lastIndex].content.append(chunk)
    }

    /// Completes the active streaming assistant response with optional receipt and citations.
    public func completeStreamingResponse(
        receipt: X402PaymentReceipt? = nil,
        citations: [CitationLink]? = nil
    ) {
        guard let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant else {
            self.isStreaming = false
            return
        }

        messages[lastIndex].isStreaming = false
        if let r = receipt {
            messages[lastIndex].receipt = r
        }
        if let c = citations {
            messages[lastIndex].citations = c
        }
        self.isStreaming = false
    }

    /// Directly updates the content and metadata of the latest assistant message.
    public func updateLastAssistantMessage(
        content: String,
        isStreaming: Bool = false,
        receipt: X402PaymentReceipt? = nil,
        citations: [CitationLink] = []
    ) {
        guard let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant else {
            let msg = ChatMessage(role: .assistant, content: content, isStreaming: isStreaming, receipt: receipt, citations: citations)
            messages.append(msg)
            self.isStreaming = isStreaming
            return
        }

        messages[lastIndex].content = content
        messages[lastIndex].isStreaming = isStreaming
        messages[lastIndex].receipt = receipt
        messages[lastIndex].citations = citations
        self.isStreaming = isStreaming
    }

    /// Clears the chat history back to welcome state.
    public func clearMessages() {
        self.messages = [Self.welcomeMessage()]
        self.inputText = ""
        self.isStreaming = false
        self.errorMessage = nil
    }

    private static func welcomeMessage() -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: "Hello! I'm your **Notch AI Companion**. How can I help you interact with BNB Smart Chain today?",
            citations: [
                CitationLink(title: "Ask BNB AI", urlString: "https://docs.bnbchain.org", badge: "Help")
            ]
        )
    }
}

/// SwiftUI View for the AI Assistant Chat Stream.
public struct ChatView: View {
    @ObservedObject public var viewModel: ChatViewModel

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            // MARK: - Chat Message Scroll Feed
            messageFeedSection

            // MARK: - Suggestion Chips
            if !viewModel.isStreaming && viewModel.messages.count <= 2 {
                suggestionChipsSection
            }

            // MARK: - Message Input Bar
            inputBarSection
        }
        .padding(12)
        .background(Color.clear)
    }

    // MARK: - Message Feed
    private var messageFeedSection: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        chatBubble(for: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = viewModel.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Chat Bubble
    private func chatBubble(for message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
            } else {
                avatarIcon(for: message.role)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Message Content Card
                VStack(alignment: .leading, spacing: 8) {
                    if message.content.isEmpty && message.isStreaming {
                        streamingLoadingDots
                    } else {
                        MarkdownContentView(content: message.content)
                    }

                    // Streaming Indicator Pill
                    if message.isStreaming && !message.content.isEmpty {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                            Text("Generating...")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.cyan)
                        }
                    }
                }
                .padding(10)
                .background(bubbleBackground(for: message.role))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(bubbleBorder(for: message.role), lineWidth: 0.8)
                )

                // Embedded x402 Payment Receipt Card
                if let receipt = message.receipt {
                    PaymentReceiptCardView(receipt: receipt)
                }

                // Citations / Reference Pills
                if !message.citations.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.citations) { citation in
                            CitationPillView(citation: citation)
                        }
                    }
                }
            }

            if message.role == .user {
                avatarIcon(for: .user)
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    private func avatarIcon(for role: ChatMessageRole) -> some View {
        Group {
            if role == .user {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.yellow)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.yellow.opacity(0.15))
                    )
            }
        }
        .padding(.top, 2)
    }

    private func bubbleBackground(for role: ChatMessageRole) -> Color {
        switch role {
        case .user:
            return Color.blue.opacity(0.25)
        case .assistant:
            return Color.white.opacity(0.06)
        case .system:
            return Color.black.opacity(0.4)
        }
    }

    private func bubbleBorder(for role: ChatMessageRole) -> Color {
        switch role {
        case .user:
            return Color.blue.opacity(0.4)
        case .assistant:
            return Color.white.opacity(0.1)
        case .system:
            return Color.orange.opacity(0.3)
        }
    }

    private var streamingLoadingDots: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.cyan)
                .frame(width: 5, height: 5)
            Circle()
                .fill(Color.cyan.opacity(0.7))
                .frame(width: 5, height: 5)
            Circle()
                .fill(Color.cyan.opacity(0.4))
                .frame(width: 5, height: 5)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Suggestion Chips
    private var suggestionChipsSection: some View {
        HStack(spacing: 6) {
            suggestionChip(title: "⚡️ Check Gas", prompt: "What is current gas price?")
            suggestionChip(title: "💳 x402 Auto-Pay", prompt: "Explain x402 auto-payments")
            suggestionChip(title: "📐 ERC-8056", prompt: "What is ERC-8056 Scaled UI Token?")
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func suggestionChip(title: String, prompt: String) -> some View {
        Button(action: {
            viewModel.sendMessage(prompt)
        }) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bar
    private var inputBarSection: some View {
        HStack(spacing: 8) {
            TextField("Ask BNB Agent or execute x402 query...", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .onSubmit {
                    viewModel.sendMessage()
                }

            if !viewModel.inputText.isEmpty {
                Button(action: {
                    viewModel.inputText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            Button(action: {
                viewModel.sendMessage()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.3) : .yellow)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

// MARK: - Markdown Content View

/// Renders markdown formatted text, code blocks with syntax styling, and lists.
public struct MarkdownContentView: View {
    public let content: String

    public init(content: String) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let blocks = parseBlocks(from: content)
            ForEach(0..<blocks.count, id: \.self) { idx in
                renderBlock(blocks[idx])
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let text, let level):
            Text(text)
                .font(.system(size: level == 1 ? 14 : 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        case .code(let code, let lang):
            CodeBlockCardView(code: code, language: lang)
        case .text(let text):
            Text(LocalizedStringKey(text))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.9))
                .textSelection(.enabled)
        }
    }

    private func parseBlocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeAccumulator: [String] = []
        var codeLang: String? = nil

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    inCodeBlock = false
                    blocks.append(.code(code: codeAccumulator.joined(separator: "\n"), language: codeLang))
                    codeAccumulator = []
                    codeLang = nil
                } else {
                    inCodeBlock = true
                    let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLang = lang.isEmpty ? nil : lang
                }
            } else if inCodeBlock {
                codeAccumulator.append(line)
            } else if line.hasPrefix("# ") {
                blocks.append(.header(text: String(line.dropFirst(2)), level: 1))
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                let cleaned = line.replacingOccurrences(of: "### ", with: "").replacingOccurrences(of: "## ", with: "")
                blocks.append(.header(text: cleaned, level: 2))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.text(line))
            }
        }

        if inCodeBlock && !codeAccumulator.isEmpty {
            blocks.append(.code(code: codeAccumulator.joined(separator: "\n"), language: codeLang))
        }

        return blocks
    }
}

private enum MarkdownBlock {
    case header(text: String, level: Int)
    case code(code: String, language: String?)
    case text(String)
}

// MARK: - Code Block View

public struct CodeBlockCardView: View {
    public let code: String
    public let language: String?
    @State private var isCopied = false

    public init(code: String, language: String?) {
        self.code = code
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    isCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        isCopied = false
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 8))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundColor(isCopied ? .green : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.5))
        )
    }
}

// MARK: - Citation Pill View

public struct CitationPillView: View {
    public let citation: CitationLink

    public init(citation: CitationLink) {
        self.citation = citation
    }

    public var body: some View {
        Button(action: {
            if let url = citation.url {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 4) {
                if let badge = citation.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.yellow)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.yellow.opacity(0.2)))
                }

                Text(citation.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(citation.urlString ?? citation.title)
    }
}

// MARK: - Payment Receipt Card View

public struct PaymentReceiptCardView: View {
    public let receipt: X402PaymentReceipt
    @State private var isCopied = false

    public init(receipt: X402PaymentReceipt) {
        self.receipt = receipt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)

                Text("x402 Payment Settled")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Text("\(receipt.amount) \(receipt.token)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.yellow)
            }

            Divider()
                .background(Color.white.opacity(0.1))

            HStack {
                Text("Tx:")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                Text(shortenHash(receipt.txHash))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(receipt.txHash, forType: .string)
                    isCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        isCopied = false
                    }
                }) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundColor(isCopied ? .green : .white.opacity(0.6))
                }
                .buttonStyle(.plain)

                if let url = URL(string: "https://testnet.bscscan.com/tx/\(receipt.txHash)") {
                    Button(action: {
                        NSWorkspace.shared.open(url)
                    }) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                            .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help("View on BSCScan")
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.green.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func shortenHash(_ hash: String) -> String {
        guard hash.count >= 12 else { return hash }
        return "\(hash.prefix(6))...\(hash.suffix(4))"
    }
}
