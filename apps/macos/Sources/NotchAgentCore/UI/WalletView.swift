import SwiftUI
import AppKit

/// Wallet account selector between User Wallet (Manual custody) and Agent Wallet (Autonomous session).
public enum WalletAccountType: String, CaseIterable, Identifiable, Sendable {
    case agent = "Agent Wallet"
    case user = "User Wallet"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .agent: return "bolt.shield.fill"
        case .user: return "person.crop.circle.fill"
        }
    }

    public var badgeTitle: String {
        switch self {
        case .agent: return "x402 Autonomous"
        case .user: return "Touch ID Protected"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .agent: return .green
        case .user: return .blue
        }
    }
}

/// Transaction record representing past or pending blockchain activities.
public struct WalletTransactionRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let type: TransactionOperationType
    public let title: String
    public let amount: String
    public let symbol: String
    public let fromAddress: String
    public let toAddress: String
    public let txHash: String
    public let timestamp: Date
    public let status: WalletTransactionStatus
    public let explorerUrlString: String?

    public init(
        id: String = UUID().uuidString,
        type: TransactionOperationType,
        title: String,
        amount: String,
        symbol: String,
        fromAddress: String,
        toAddress: String,
        txHash: String,
        timestamp: Date = Date(),
        status: WalletTransactionStatus = .confirmed,
        explorerUrlString: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.amount = amount
        self.symbol = symbol
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.txHash = txHash
        self.timestamp = timestamp
        self.status = status
        self.explorerUrlString = explorerUrlString ?? "https://testnet.bscscan.com/tx/\(txHash)"
    }

    public var formattedTxHash: String {
        guard txHash.count >= 12 else { return txHash }
        let start = txHash.prefix(6)
        let end = txHash.suffix(4)
        return "\(start)...\(end)"
    }

    public var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

public enum WalletTransactionStatus: String, Codable, Sendable {
    case confirmed = "Confirmed"
    case pending = "Pending"
    case failed = "Failed"

    public var color: Color {
        switch self {
        case .confirmed: return .green
        case .pending: return .yellow
        case .failed: return .red
        }
    }
}

/// View model driving the dual-wallet view, balances, token list (ERC-20/8056), and transfer/funding flows.
@MainActor
public final class WalletViewModel: ObservableObject {
    @Published public var selectedAccount: WalletAccountType = .agent
    @Published public var userAddress: String
    @Published public var agentAddress: String
    @Published public var nativeBalance: String = "0.05"
    @Published public var tokenBalances: [TokenBalance] = []
    @Published public var transactions: [WalletTransactionRecord] = []
    @Published public var isRefreshing: Bool = false
    @Published public var networkName: String = "BSC Testnet"
    @Published public var chainId: Int = 97
    @Published public var isShowingQRSheet: Bool = false
    @Published public var isShowingConfirmModal: Bool = false
    @Published public var isShowingSwapSheet: Bool = false
    @Published public var isShowingMakerSheet: Bool = false
    @Published public var pendingConfirmation: TransactionConfirmationDetails?
    @Published public var copiedAddressToast: Bool = false
    @Published public var swapViewModel: SwapViewModel
    @Published public var makerModeViewModel: MakerModeViewModel
    /// Live signer/broadcaster/context for the confirmation modal. nil in previews —
    /// the modal then fails honestly instead of simulating a signature.
    public var transactionDependencies: TransactionDependencies? = nil

    public var currentAddress: String {
        switch selectedAccount {
        case .agent: return agentAddress
        case .user: return userAddress
        }
    }

    public var formattedCurrentAddress: String {
        let addr = currentAddress
        guard addr.count >= 12 else { return addr }
        let start = addr.prefix(6)
        let end = addr.suffix(4)
        return "\(start)...\(end)"
    }

    public init(
        userAddress: String = "0x71C8401301F43F316568234664AC712927C5DD51",
        agentAddress: String = "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7",
        nativeBalance: String = "0.05",
        tokenBalances: [TokenBalance] = [],
        transactions: [WalletTransactionRecord] = [],
        networkName: String = "BSC Testnet",
        chainId: Int = 97,
        swapViewModel: SwapViewModel? = nil,
        makerModeViewModel: MakerModeViewModel? = nil,
        transactionDependencies: TransactionDependencies? = nil
    ) {
        self.userAddress = userAddress
        self.agentAddress = agentAddress
        self.nativeBalance = nativeBalance
        self.tokenBalances = tokenBalances.isEmpty ? Self.defaultTokenBalances() : tokenBalances
        self.transactions = transactions.isEmpty ? Self.defaultTransactions() : transactions
        self.networkName = networkName
        self.chainId = chainId
        self.transactionDependencies = transactionDependencies
        self.swapViewModel = swapViewModel ?? SwapViewModel(
            userAddress: userAddress,
            chainId: chainId,
            networkName: networkName,
            transactionDependencies: transactionDependencies
        )
        self.makerModeViewModel = makerModeViewModel ?? MakerModeViewModel(
            recipientAddress: agentAddress
        )
    }

    public func openSwapView() {
        self.isShowingSwapSheet = true
    }

    public func openMakerDashboard() {
        self.isShowingMakerSheet = true
    }

    // MARK: - Actions

    public func refreshBalances() async {
        isRefreshing = true
        // Simulate quick RPC balance refresh
        try? await Task.sleep(nanoseconds: 400_000_000)
        isRefreshing = false
    }

    public func copyAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentAddress, forType: .string)
        copiedAddressToast = true

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedAddressToast = false
        }
    }

    /// Prepares a modal request to fund the Agent Wallet from the User Wallet.
    public func requestFundAgent(amount: String = "0.05") {
        let details = TransactionConfirmationDetails(
            operationType: .fundAgent,
            title: "Fund Agent Session Key",
            fromAddress: userAddress,
            toAddress: agentAddress,
            assetSymbol: "tBNB",
            amount: amount,
            estimatedGasTBNB: "0.00021",
            networkName: networkName,
            chainId: chainId,
            txProposal: nativeTransferProposal(to: agentAddress, amount: amount)
        )
        self.pendingConfirmation = details
        self.isShowingConfirmModal = true
    }

    /// Prepares a standard token transfer modal request.
    public func requestTransfer(to: String, amount: String, symbol: String = "tBNB") {
        let details = TransactionConfirmationDetails(
            operationType: .transfer,
            title: "Transfer \(symbol)",
            fromAddress: userAddress,
            toAddress: to,
            assetSymbol: symbol,
            amount: amount,
            estimatedGasTBNB: "0.00035",
            networkName: networkName,
            chainId: chainId,
            txProposal: nativeTransferProposal(to: to, amount: amount)
        )
        self.pendingConfirmation = details
        self.isShowingConfirmModal = true
    }

    /// Builds an exact native-tBNB transfer proposal from the UI amount (no float math).
    private func nativeTransferProposal(to: String, amount: String) -> TransactionProposal? {
        guard let valueWei = WeiConverter.wei(fromUIAmount: amount) else { return nil }
        return TransactionProposal(
            toAddress: to,
            valueWei: valueWei,
            dataHex: nil,
            chainId: chainId,
            gasLimit: 21_000
        )
    }

    /// Prepares a PancakeSwap swap modal request.
    /// The real unsigned swap payload is attached by `SwapViewModel.reviewSwap()` when the
    /// runtime is reachable; this legacy entry intentionally carries no fabricated payload,
    /// so the modal fails honestly when nothing real is available to sign.
    public func requestSwap(fromToken: String = "tBNB", toToken: String = "USDT", amount: String = "0.1") {
        let details = TransactionConfirmationDetails(
            operationType: .swap,
            title: "Swap on PancakeSwap",
            fromAddress: userAddress,
            toAddress: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", // PancakeSwap V2 Router Testnet
            assetSymbol: fromToken,
            amount: amount,
            estimatedGasTBNB: "0.00085",
            networkName: networkName,
            chainId: chainId,
            slippageTolerance: "0.5%"
        )
        self.pendingConfirmation = details
        self.isShowingConfirmModal = true
    }

    /// Helper returning human-readable ERC-8056 scaled formatted display string.
    public func formatERC8056Display(for token: TokenBalance) -> String {
        return "\(token.uiAmount) \(token.symbol)"
    }

    // MARK: - Defaults

    public static func defaultTokenBalances() -> [TokenBalance] {
        [
            TokenBalance(
                tokenAddress: "0x0000000000000000000000000000000000000000",
                rawAmount: "50000000000000000",
                uiAmount: "0.05",
                symbol: "tBNB",
                decimals: 18
            ),
            TokenBalance(
                tokenAddress: "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd",
                rawAmount: "100000000000000000000",
                uiAmount: "100.00",
                symbol: "USDT",
                decimals: 18
            ),
            TokenBalance(
                tokenAddress: "0x64544969ed7EBf5f083679233325356EbE738930",
                rawAmount: "50000000000000000000",
                uiAmount: "50.00",
                symbol: "USDC",
                decimals: 18
            ),
            TokenBalance(
                tokenAddress: "0x8056000000000000000000000000000000008056",
                rawAmount: "2500000000000000000",
                uiAmount: "2.50",
                symbol: "sBNB (ERC-8056)",
                decimals: 18
            )
        ]
    }

    public static func defaultTransactions() -> [WalletTransactionRecord] {
        [
            WalletTransactionRecord(
                type: .fundAgent,
                title: "Fund Agent Session Key",
                amount: "0.05",
                symbol: "tBNB",
                fromAddress: "0x71C8401301F43F316568234664AC712927C5DD51",
                toAddress: "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7",
                txHash: "0x3d7b4c91a0293b2184f74d08f4305bc91238401b2a95c1284d0b1359c1234567",
                status: .confirmed
            ),
            WalletTransactionRecord(
                type: .transfer,
                title: "x402 AI Query Payment",
                amount: "0.001",
                symbol: "tBNB",
                fromAddress: "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7",
                toAddress: "0x9876543210987654321098765432109876543210",
                txHash: "0x8e2a1b9c7d4f3e2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a",
                status: .confirmed
            )
        ]
    }
}

/// SwiftUI View displaying the rich multi-token wallet, activity history, and action buttons.
public struct WalletView: View {
    @ObservedObject public var viewModel: WalletViewModel

    public init(viewModel: WalletViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            // MARK: - Account Switcher Bar
            accountSwitcherBar

            // MARK: - Balance Highlight Card
            balanceCard

            // MARK: - Quick Actions Bar
            quickActionsBar

            // MARK: - Token Balances & History Segment
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    tokenBalancesSection
                    transactionHistorySection
                }
            }
        }
        .padding(14)
        .background(Color.clear)
        .sheet(isPresented: $viewModel.isShowingQRSheet) {
            QRReceiveView(
                viewModel: QRReceiveViewModel(
                    userAddress: viewModel.userAddress,
                    agentAddress: viewModel.agentAddress,
                    selectedAccount: viewModel.selectedAccount == .agent ? .agent : .user,
                    networkName: viewModel.networkName
                )
            )
        }
        .sheet(isPresented: $viewModel.isShowingConfirmModal) {
            if let details = viewModel.pendingConfirmation {
                let deps = viewModel.transactionDependencies
                TransactionConfirmationModal(
                    viewModel: TransactionConfirmationViewModel(
                        details: details,
                        authenticator: deps?.authenticator ?? TouchIDAuthenticator(),
                        signer: deps?.signer,
                        broadcaster: deps?.broadcaster,
                        contextProvider: deps?.contextProvider,
                        passwordStore: deps?.passwordStore
                    )
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingSwapSheet) {
            SwapView(viewModel: viewModel.swapViewModel)
                .frame(width: 440, height: 420)
                .background(
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                        Color.black.opacity(0.75)
                    }
                )
        }
        .sheet(isPresented: $viewModel.isShowingMakerSheet) {
            MakerModeDashboardView(viewModel: viewModel.makerModeViewModel)
                .frame(width: 440, height: 420)
                .background(
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                        Color.black.opacity(0.75)
                    }
                )
        }
    }

    // MARK: - Account Switcher
    private var accountSwitcherBar: some View {
        HStack(spacing: 8) {
            ForEach(WalletAccountType.allCases) { account in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectedAccount = account
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: account.iconName)
                            .font(.system(size: 11))
                        Text(account.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(viewModel.selectedAccount == account ? .white : .white.opacity(0.6))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(viewModel.selectedAccount == account ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Network Indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 6, height: 6)
                Text(viewModel.networkName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.yellow)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.yellow.opacity(0.12)))
        }
    }

    // MARK: - Balance Card
    private var balanceCard: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedAccount.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text(viewModel.selectedAccount.badgeTitle)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(viewModel.selectedAccount.badgeColor)
                }

                Spacer()

                // Address & Copy Button
                Button(action: {
                    viewModel.copyAddress()
                }) {
                    HStack(spacing: 4) {
                        Text(viewModel.formattedCurrentAddress)
                            .font(.system(size: 10, design: .monospaced))
                        Image(systemName: viewModel.copiedAddressToast ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(viewModel.copiedAddressToast ? .green : .white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            // Balance Number
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(viewModel.nativeBalance)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text("tBNB")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(Color.yellow)

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Quick Actions Bar
    private var quickActionsBar: some View {
        HStack(spacing: 8) {
            // Fund Agent Action
            quickButton(
                title: "Fund Agent",
                icon: "bolt.shield.fill",
                color: .green
            ) {
                viewModel.requestFundAgent(amount: "0.05")
            }

            // Receive Action
            quickButton(
                title: "Receive",
                icon: "qrcode",
                color: .cyan
            ) {
                viewModel.isShowingQRSheet = true
            }

            // Send Action
            quickButton(
                title: "Send",
                icon: "arrow.up.right",
                color: .blue
            ) {
                viewModel.requestTransfer(to: "0x9876543210987654321098765432109876543210", amount: "0.01")
            }

            // Swap Action
            quickButton(
                title: "Swap",
                icon: "arrow.triangle.2.circlepath",
                color: .orange
            ) {
                viewModel.requestSwap(fromToken: "tBNB", toToken: "USDT", amount: "0.05")
            }
        }
    }

    private func quickButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Token Balances Section
    private var tokenBalancesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Assets & Tokens")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text("\(viewModel.tokenBalances.count) Tokens")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }

            VStack(spacing: 6) {
                ForEach(viewModel.tokenBalances, id: \.tokenAddress) { token in
                    HStack {
                        // Token Symbol & ERC-8056 Badge
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(token.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)

                                if token.symbol.contains("ERC-8056") {
                                    Text("Dynamic UI")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.purple)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.purple.opacity(0.2)))
                                }
                            }

                            Text(shortenTokenAddress(token.tokenAddress))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                        }

                        Spacer()

                        // Token Balance
                        Text(token.uiAmount)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.03))
                    )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.3))
        )
    }

    // MARK: - Transaction History Section
    private var transactionHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Activity")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(viewModel.transactions) { tx in
                    HStack(spacing: 8) {
                        Image(systemName: tx.type.iconName)
                            .font(.system(size: 14))
                            .foregroundColor(tx.type.accentColor)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(tx.type.accentColor.opacity(0.15))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)

                            HStack(spacing: 4) {
                                Text(tx.formattedTxHash)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                                Text("• \(tx.relativeTime)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(tx.amount) \(tx.symbol)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)

                            Text(tx.status.rawValue)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(tx.status.color)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.03))
                    )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.3))
        )
    }

    private func shortenTokenAddress(_ addr: String) -> String {
        guard addr.count >= 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}
