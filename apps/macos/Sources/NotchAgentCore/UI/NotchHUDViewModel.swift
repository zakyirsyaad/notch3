import Foundation
import SwiftUI
import Combine

/// Navigation tabs available within the expanded Notch HUD drawer.
public enum HUDTab: String, CaseIterable, Identifiable, Sendable {
    case chat = "Chat"
    case wallet = "Wallet"
    case swap = "Swap"
    case maker = "Maker"
    case storage = "Storage"
    case settings = "Settings"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .wallet: return "creditcard.fill"
        case .swap: return "arrow.triangle.2.circlepath"
        case .maker: return "server.rack"
        case .storage: return "cylinder.split.1x2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Main view model managing state, balance, lock transitions, and drawer navigation for the Notch HUD.
@MainActor
public final class NotchHUDViewModel: ObservableObject {
    
    // MARK: - Published State

    /// The agent starts locked. Unlocking requires an authenticated handler
    /// (Touch ID / master passcode → `agent.unlock` RPC) wired by the AppDelegate.
    @Published public var agentState: AgentLockState = .locked
    @Published public var balanceTBNB: String = "0.00"
    @Published public var agentAddress: String = "0x0000000000000000000000000000000000000000"
    @Published public var userAddress: String? = nil
    @Published public var networkName: String = "BSC Testnet"
    @Published public var chainId: Int = 97
    @Published public var isExpanded: Bool = false
    @Published public var selectedTab: HUDTab = .chat
    @Published public var autoPayLimit: String = "0.05"
    @Published public var isBiometricsEnabled: Bool = true
    @Published public var isERC8004Registered: Bool = false
    @Published public var activeTools: [String] = []
    @Published public var isExecutingTool: Bool = false
    @Published public var activeToolName: String? = nil
    @Published public var lastNotificationMessage: String? = nil
    @Published public var isShowingNetworkSwitcher: Bool = false
    /// Last unlock/lock failure reason, surfaced honestly instead of faking success.
    @Published public var lastError: String? = nil
    /// True once a user wallet keystore has been imported (or restored from disk).
    @Published public var isUserWalletOnboarded: Bool = false
    @Published public var isShowingWalletOnboarding: Bool = false
    @Published public var chatViewModel: ChatViewModel
    @Published public var walletViewModel: WalletViewModel
    @Published public var swapViewModel: SwapViewModel
    @Published public var makerModeViewModel: MakerModeViewModel
    @Published public var networkSwitcherViewModel: NetworkSwitcherViewModel
    @Published public var greenfieldStorageViewModel: GreenfieldStorageViewModel
    
    // MARK: - Callbacks & Handlers
    
    public var onKillSwitch: (() -> Void)?
    public var onStateChanged: ((AgentLockState) -> Void)?
    public var onUnlockRequested: ((String?) async throws -> Bool)?
    public var onSetAutoPayLimit: ((String) async throws -> Void)?

    /// Onboarding dependencies (nil in previews/tests — the sheet is then unavailable).
    public let onboardingKeystoreManager: UserKeystoreManager?
    public let onboardingPasswordStore: KeystorePasswordStore?
    
    // MARK: - Computed Properties
    
    public var isActive: Bool {
        agentState == .unlocked
    }
    
    public var isPaused: Bool {
        agentState == .paused
    }
    
    public var isLocked: Bool {
        agentState == .locked
    }
    
    public var statusTitle: String {
        switch agentState {
        case .unlocked: return "Active"
        case .paused: return "Paused"
        case .locked: return "Locked"
        }
    }
    
    public var statusEmoji: String {
        switch agentState {
        case .unlocked: return "🟢"
        case .paused: return "⏸️"
        case .locked: return "🔒"
        }
    }
    
    public var formattedBalance: String {
        "\(balanceTBNB) tBNB"
    }
    
    public var formattedAgentAddress: String {
        guard agentAddress.count >= 10 else { return agentAddress }
        let start = agentAddress.prefix(6)
        let end = agentAddress.suffix(4)
        return "\(start)...\(end)"
    }
    
    public var formattedUserAddress: String {
        guard let userAddress = userAddress, userAddress.count >= 10 else {
            return "No User Wallet"
        }
        let start = userAddress.prefix(6)
        let end = userAddress.suffix(4)
        return "\(start)...\(end)"
    }
    
    // MARK: - Initializer
    
    public init(
        agentState: AgentLockState = .locked,
        balanceTBNB: String = "0.00",
        agentAddress: String = "0x0000000000000000000000000000000000000000",
        userAddress: String? = nil,
        networkName: String = "BSC Testnet",
        chainId: Int = 97,
        isExpanded: Bool = false,
        selectedTab: HUDTab = .chat,
        chatViewModel: ChatViewModel? = nil,
        walletViewModel: WalletViewModel? = nil,
        swapViewModel: SwapViewModel? = nil,
        makerModeViewModel: MakerModeViewModel? = nil,
        networkSwitcherViewModel: NetworkSwitcherViewModel? = nil,
        greenfieldStorageViewModel: GreenfieldStorageViewModel? = nil,
        transactionDependencies: TransactionDependencies? = nil,
        onboardingKeystoreManager: UserKeystoreManager? = nil,
        onboardingPasswordStore: KeystorePasswordStore? = nil,
        userWalletAddress: String? = nil
    ) {
        self.onboardingKeystoreManager = onboardingKeystoreManager
        self.onboardingPasswordStore = onboardingPasswordStore
        self.agentState = agentState
        self.balanceTBNB = balanceTBNB
        self.agentAddress = agentAddress
        self.userAddress = userAddress
        self.networkName = networkName
        self.chainId = chainId
        self.isExpanded = isExpanded
        self.selectedTab = selectedTab
        let chatVM = chatViewModel ?? ChatViewModel(rpcClient: transactionDependencies?.rpcClient)
        self.chatViewModel = chatVM
        self.walletViewModel = walletViewModel ?? WalletViewModel(
            userAddress: userAddress ?? "0x71C8401301F43F316568234664AC712927C5DD51",
            agentAddress: agentAddress,
            nativeBalance: balanceTBNB,
            networkName: networkName,
            chainId: chainId,
            transactionDependencies: transactionDependencies
        )
        self.swapViewModel = swapViewModel ?? SwapViewModel(
            userAddress: userAddress ?? "0x71C8401301F43F316568234664AC712927C5DD51",
            chainId: chainId,
            networkName: networkName,
            transactionDependencies: transactionDependencies
        )
        self.makerModeViewModel = makerModeViewModel ?? MakerModeViewModel(
            recipientAddress: agentAddress,
            rpcClient: transactionDependencies?.rpcClient
        )

        let initialNetwork = NetworkConfig.allNetworks.first(where: { $0.chainId == chainId }) ?? .bscTestnet
        let netVM = networkSwitcherViewModel ?? NetworkSwitcherViewModel(
            activeNetwork: initialNetwork,
            rpcClient: transactionDependencies?.rpcClient
        )
        self.networkSwitcherViewModel = netVM

        self.greenfieldStorageViewModel = greenfieldStorageViewModel ?? GreenfieldStorageViewModel(
            rpcClient: transactionDependencies?.rpcClient,
            chatViewModel: chatVM,
            passwordStore: transactionDependencies?.passwordStore
        )
        
        if let userWalletAddress {
            self.userAddress = userWalletAddress
            self.isUserWalletOnboarded = true
            self.walletViewModel.userAddress = userWalletAddress
            self.swapViewModel.userAddress = userWalletAddress
        }

        // Propagate network switches
        netVM.onNetworkSwitched = { [weak self] network in
            guard let self = self else { return }
            self.networkName = network.name
            self.chainId = network.chainId
            self.walletViewModel.networkName = network.name
            self.walletViewModel.chainId = network.chainId
            self.swapViewModel.networkName = network.name
            self.swapViewModel.chainId = network.chainId
        }
    }
    
    // MARK: - State Management Actions
    
    /// Pauses the agent. Resuming requires re-authentication through
    /// `unlockAgent()` — a local toggle must never silently re-unlock funds.
    public func togglePauseResume() {
        guard agentState == .unlocked else { return }
        agentState = .paused
        onStateChanged?(agentState)
    }
    
    /// Immediately locks the agent.
    public func lockAgent() {
        agentState = .locked
        onStateChanged?(agentState)
    }
    
    /// Unlocks the agent. Fails closed: without an authenticated handler installed by
    /// the AppDelegate (Touch ID / master passcode → agent.unlock RPC) this returns false.
    public func unlockAgent(passphrase: String? = nil) async -> Bool {
        guard let customHandler = onUnlockRequested else {
            lastError = "No authenticated unlock handler is installed."
            return false
        }

        do {
            let success = try await customHandler(passphrase)
            if success {
                lastError = nil
                agentState = .unlocked
                onStateChanged?(agentState)
            } else {
                lastError = lastError ?? "Authentication failed."
            }
            return success
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
    
    /// Updates the displayed balance with numeric verification and fallback.
    public func updateBalance(_ newBalance: String) {
        let trimmed = newBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || Double(trimmed) == nil {
            balanceTBNB = "0.00"
        } else {
            balanceTBNB = trimmed
        }
        walletViewModel.nativeBalance = balanceTBNB
    }
    
    /// Sets state according to received AgentStatus from IPC.
    /// A passive status poll may only ever *lock* — the locked → unlocked
    /// transition must go through the authenticated `unlockAgent()` path.
    public func setAgentStatus(_ status: AgentStatus) {
        if let addr = status.address, !addr.isEmpty {
            self.agentAddress = addr
            self.walletViewModel.agentAddress = addr
            self.makerModeViewModel.recipientAddress = addr
        }
        if let bal = status.balance, !bal.isEmpty {
            updateBalance(bal)
        }
        if let tasks = status.activeTasks, tasks > 0 {
            self.isExecutingTool = true
        } else {
            self.isExecutingTool = false
        }
        if let limit = status.autoPayMaxTBNB, !limit.isEmpty {
            self.autoPayLimit = limit
        }

        if !status.isUnlocked {
            self.agentState = .locked
        }
    }
    
    /// Applies a freshly imported (or restored) user wallet across all view models.
    public func applyUserWallet(address: String) {
        userAddress = address
        isUserWalletOnboarded = true
        isShowingWalletOnboarding = false
        walletViewModel.userAddress = address
        walletViewModel.isUserWalletOnboarded = true
        swapViewModel.userAddress = address
    }

    /// Builds the onboarding sheet's view model when onboarding deps are available.
    public func makeOnboardingViewModel() -> WalletOnboardingViewModel? {
        guard let km = onboardingKeystoreManager, let ps = onboardingPasswordStore else {
            return nil
        }
        let vm = WalletOnboardingViewModel(keystoreManager: km, passwordStore: ps)
        vm.onImportComplete = { [weak self] address in
            Task { @MainActor in
                self?.applyUserWallet(address: address)
            }
        }
        return vm
    }

    /// Selects a specific navigation tab and ensures the drawer is expanded.
    public func selectTab(_ tab: HUDTab) {
        self.selectedTab = tab
        self.isExpanded = true
    }
    
    /// Toggles drawer open/close.
    public func toggleExpanded() {
        self.isExpanded.toggle()
    }
    
    /// Tracks start of tool execution (e.g. x402 payment, BNB docs query).
    public func beginToolExecution(name: String) {
        self.isExecutingTool = true
        self.activeToolName = name
    }
    
    /// Concludes active tool execution.
    public func endToolExecution() {
        self.isExecutingTool = false
        self.activeToolName = nil
    }
    
    /// Sets max auto-pay limit for single transaction auto-settlement.
    public func setAutoPayLimit(_ limit: String) {
        guard let val = Double(limit), val >= 0 else { return }
        self.autoPayLimit = limit
        
        Task {
            do {
                if let handler = onSetAutoPayLimit {
                    try await handler(limit)
                }
            } catch {
                Task { @MainActor in
                    self.lastError = "Failed to update Auto-Pay limit on agent: \(error.localizedDescription)"
                }
            }
        }
    }
    
    /// Triggers the emergency kill switch.
    public func triggerKillSwitch() {
        self.agentState = .locked
        self.isExpanded = false
        self.onKillSwitch?()
    }
}
