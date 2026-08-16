import SwiftUI
import AppKit

// MARK: - Sale Record Item

/// Display model for settled HTTP 402 on-chain micro-payment sales.
public struct MPPSaleItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let txHash: String
    public let payer: String
    public let recipient: String
    public let amount: String
    public let token: String
    public let endpoint: String
    public let timestamp: Date
    public let status: String

    public init(
        id: String? = nil,
        txHash: String,
        payer: String,
        recipient: String,
        amount: String,
        token: String = "tBNB",
        endpoint: String,
        timestamp: Date = Date(),
        status: String = "settled"
    ) {
        self.id = id ?? txHash
        self.txHash = txHash
        self.payer = payer
        self.recipient = recipient
        self.amount = amount
        self.token = token
        self.endpoint = endpoint
        self.timestamp = timestamp
        self.status = status
    }

    public var formattedPayer: String {
        guard payer.count >= 10 else { return payer }
        return "\(payer.prefix(6))...\(payer.suffix(4))"
    }

    public var formattedTxHash: String {
        guard txHash.count >= 12 else { return txHash }
        return "\(txHash.prefix(6))...\(txHash.suffix(4))"
    }

    public var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    public var formattedAmount: String {
        "+\(amount) \(token)"
    }
}

// MARK: - Endpoint Info Model

public struct MPPEndpointInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let method: String
    public let priceTBNB: String
    public let description: String

    public init(path: String, method: String = "POST", priceTBNB: String, description: String) {
        self.path = path
        self.method = method
        self.priceTBNB = priceTBNB
        self.description = description
    }
}

// MARK: - Maker Mode View Model

/// View model driving the Agent Maker Mode (MPP HTTP 402 Server) dashboard, live earnings, and endpoint sales history.
@MainActor
public final class MakerModeViewModel: ObservableObject {
    @Published public var isRunning: Bool = false
    @Published public var port: Int = 4020
    @Published public var host: String = "127.0.0.1"
    @Published public var recipientAddress: String
    @Published public var totalSalesCount: Int = 0
    @Published public var totalRevenueTBNB: String = "0.00"
    @Published public var activeEndpoints: [String] = ["/v1/ask", "/v1/audit", "/v1/search"]
    @Published public var salesHistory: [MPPSaleItem] = []
    @Published public var isBusy: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var copiedToast: String? = nil
    /// Live JSON-RPC client to the agent runtime's mpp.* methods.
    public var rpcClient: JSONRPCClient? = nil

    public let availableEndpointInfos: [MPPEndpointInfo] = [
        MPPEndpointInfo(path: "/v1/ask", method: "POST", priceTBNB: "0.001", description: "AI Question Answering & Reasoning"),
        MPPEndpointInfo(path: "/v1/audit", method: "POST", priceTBNB: "0.005", description: "Smart Contract Static Security Audit"),
        MPPEndpointInfo(path: "/v1/search", method: "POST", priceTBNB: "0.002", description: "BNB Ecosystem Docs Semantic Search")
    ]

    public var serverUrlString: String {
        "http://\(host):\(port)"
    }

    public init(
        isRunning: Bool = false,
        port: Int = 4020,
        host: String = "127.0.0.1",
        recipientAddress: String = "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7",
        salesHistory: [MPPSaleItem] = [],
        rpcClient: JSONRPCClient? = nil
    ) {
        self.isRunning = isRunning
        self.port = port
        self.host = host
        self.recipientAddress = recipientAddress
        self.rpcClient = rpcClient
        self.salesHistory = salesHistory

        if !salesHistory.isEmpty {
            self.totalSalesCount = salesHistory.count
            let total = salesHistory.reduce(0.0) { sum, item in
                sum + (Double(item.amount) ?? 0.0)
            }
            self.totalRevenueTBNB = String(format: "%.4f", total)
        }
    }

    // MARK: - Server Control Actions (real mpp.* JSON-RPC)

    /// Starts the MPP HTTP 402 server via `mpp.startServer`. Fails honestly
    /// when the runtime is unreachable — the status is never faked.
    public func startServer(port: Int? = nil) async {
        guard let client = rpcClient else {
            errorMessage = "Agent runtime unavailable — cannot start the MPP server."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            struct StartParams: Codable, Sendable {
                let port: Int?
                let recipient: String?
            }
            let params = StartParams(
                port: port,
                recipient: recipientAddress.isEmpty ? nil : recipientAddress
            )
            let result: MPPServerStatus = try await client.sendRequest(
                method: "mpp.startServer",
                params: params
            )
            applyStatus(result)
        } catch {
            errorMessage = "Failed to start MPP server: \(error.localizedDescription)"
        }
    }

    /// Stops the running MPP server via `mpp.stopServer`.
    public func stopServer() async {
        guard let client = rpcClient else {
            errorMessage = "Agent runtime unavailable — cannot stop the MPP server."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let _: MPPStopResult = try await client.sendRequest(method: "mpp.stopServer")
            self.isRunning = false
        } catch {
            errorMessage = "Failed to stop MPP server: \(error.localizedDescription)"
        }
    }

    /// Toggles the running status of the server.
    public func toggleServer() async {
        if isRunning {
            await stopServer()
        } else {
            await startServer()
        }
    }

    /// Refreshes server status and sales history from the runtime.
    public func refreshStatus() async {
        guard let client = rpcClient else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let status: MPPServerStatus = try await client.sendRequest(method: "mpp.getStatus")
            applyStatus(status)

            let receipts: [MPPSaleReceipt] = try await client.sendRequest(method: "mpp.getSalesHistory")
            self.salesHistory = receipts.map { receipt in
                MPPSaleItem(
                    txHash: receipt.txHash,
                    payer: receipt.payer,
                    recipient: receipt.recipient,
                    amount: receipt.amount,
                    token: receipt.token,
                    endpoint: receipt.endpoint,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(receipt.timestamp) / 1000),
                    status: receipt.status
                )
            }
            self.totalSalesCount = status.totalSales ?? receipts.count
            if let revenue = status.totalRevenue {
                self.totalRevenueTBNB = revenue
            }
        } catch {
            errorMessage = "Failed to refresh MPP status: \(error.localizedDescription)"
        }
    }

    private func applyStatus(_ status: MPPServerStatus) {
        self.isRunning = status.running
        if let p = status.port { self.port = p }
        if let h = status.host { self.host = h }
        if let endpoints = status.activeEndpoints, !endpoints.isEmpty {
            self.activeEndpoints = endpoints
        }
    }

    /// Local helper for tests: records a sale item directly.
    /// Sales without a real on-chain hash are rejected — no fabricated receipts.
    public func recordSale(payer: String, amount: String, endpoint: String, txHash: String? = nil) {
        guard let hash = txHash else { return }
        let sale = MPPSaleItem(
            txHash: hash,
            payer: payer,
            recipient: recipientAddress,
            amount: amount,
            token: "tBNB",
            endpoint: endpoint,
            timestamp: Date(),
            status: "settled"
        )

        salesHistory.insert(sale, at: 0)
        totalSalesCount += 1
    }

    /// Clears the recorded sales history and resets stats.
    public func clearHistory() {
        salesHistory.removeAll()
        totalSalesCount = 0
        totalRevenueTBNB = "0.00"
    }

    /// Copies an endpoint full URL to clipboard.
    public func copyEndpointUrl(path: String) {
        let fullUrl = "\(serverUrlString)\(path)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullUrl, forType: .string)

        self.copiedToast = path
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedToast = nil
        }
    }
}

/// Response payload of `mpp.stopServer`.
public struct MPPStopResult: Codable, Sendable, Equatable {
    public let stopped: Bool

    public init(stopped: Bool) {
        self.stopped = stopped
    }
}

// MARK: - Maker Mode Dashboard View

/// SwiftUI View for the Agent Maker Mode HTTP 402 server dashboard, revenue metrics, and paid endpoint calls.
public struct MakerModeDashboardView: View {
    @ObservedObject public var viewModel: MakerModeViewModel

    public init(viewModel: MakerModeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            // MARK: - Server Status Header
            serverStatusHeader

            // MARK: - Live Revenue & Sales Metrics
            revenueMetricsCards

            // MARK: - Active Monetized Endpoints Section
            monetizedEndpointsSection

            // MARK: - Live Sales History Section
            salesHistorySection
        }
        .padding(14)
        .background(Color.clear)
    }

    // MARK: - Status Header
    private var serverStatusHeader: some View {
        HStack(spacing: 10) {
            // Status Dot & Title
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: (viewModel.isRunning ? Color.green : Color.red).opacity(0.6), radius: 3)

                Text(viewModel.isRunning ? "Maker Server Running" : "Maker Server Stopped")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Spacer()

            // Host & Port Badge
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 9))
                Text(viewModel.serverUrlString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            // Toggle Button
            Button(action: {
                Task {
                    await viewModel.toggleServer()
                }
            }) {
                HStack(spacing: 4) {
                    if viewModel.isBusy {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 9))
                    }
                    Text(viewModel.isRunning ? "Stop" : "Start")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(viewModel.isRunning ? Color.red.opacity(0.3) : Color.green.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(viewModel.isRunning ? Color.red.opacity(0.5) : Color.green.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
        }
    }

    // MARK: - Revenue Metrics Cards
    private var revenueMetricsCards: some View {
        HStack(spacing: 10) {
            // Revenue Card
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.yellow)
                    Text("Total Revenue")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(viewModel.totalRevenueTBNB)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("tBNB")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.yellow)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
                    )
            )

            // Total Sales Card
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                    Text("Paid Queries")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(viewModel.totalSalesCount)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("settled")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.green.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Monetized Endpoints Section
    private var monetizedEndpointsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Monetized Endpoints (HTTP 402)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text("\(viewModel.availableEndpointInfos.count) Active")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
            }

            VStack(spacing: 5) {
                ForEach(viewModel.availableEndpointInfos) { ep in
                    HStack(spacing: 8) {
                        Text(ep.method)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.cyan.opacity(0.15)))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(ep.path)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                            Text(ep.description)
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.5))
                        }

                        Spacer()

                        Text("\(ep.priceTBNB) tBNB")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.yellow)

                        Button(action: {
                            viewModel.copyEndpointUrl(path: ep.path)
                        }) {
                            Image(systemName: viewModel.copiedToast == ep.path ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(viewModel.copiedToast == ep.path ? .green : .white.opacity(0.7))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help("Copy full endpoint URL")
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.03))
                    )
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.3))
        )
    }

    // MARK: - Sales History Section
    private var salesHistorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Settled Sales History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                if !viewModel.salesHistory.isEmpty {
                    Button(action: {
                        viewModel.clearHistory()
                    }) {
                        Text("Clear")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.salesHistory.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "tray")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.3))
                        Text("No sales yet. External agents pay tBNB to access endpoints.")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(viewModel.salesHistory) { sale in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sale.endpoint)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.white)

                                    HStack(spacing: 4) {
                                        Text("From: \(sale.formattedPayer)")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.5))
                                        Text("• \(sale.relativeTime)")
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(sale.formattedAmount)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.green)

                                    Text(sale.status.uppercased())
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.green.opacity(0.15)))
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.03))
                            )
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.3))
        )
    }
}
