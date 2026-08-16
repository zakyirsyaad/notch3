import Foundation
import SwiftUI
import Combine

/// Navigation tabs available within the expanded Notch HUD drawer.
public enum HUDTab: String, CaseIterable, Identifiable, Sendable {
    case chat = "Chat"
    case wallet = "Wallet"
    case settings = "Settings"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .wallet: return "creditcard.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Main view model managing state, balance, lock transitions, and drawer navigation for the Notch HUD.
@MainActor
public final class NotchHUDViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published public var agentState: AgentLockState = .unlocked
    @Published public var balanceTBNB: String = "0.05"
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
    @Published public var chatViewModel: ChatViewModel
    @Published public var walletViewModel: WalletViewModel
    
    // MARK: - Callbacks & Handlers
    
    public var onKillSwitch: (() -> Void)?
    public var onStateChanged: ((AgentLockState) -> Void)?
    public var onUnlockRequested: ((String?) async -> Bool)?
    
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
        agentState: AgentLockState = .unlocked,
        balanceTBNB: String = "0.05",
        agentAddress: String = "0x0000000000000000000000000000000000000000",
        userAddress: String? = nil,
        networkName: String = "BSC Testnet",
        chainId: Int = 97,
        isExpanded: Bool = false,
        selectedTab: HUDTab = .chat,
        chatViewModel: ChatViewModel? = nil,
        walletViewModel: WalletViewModel? = nil
    ) {
        self.agentState = agentState
        self.balanceTBNB = balanceTBNB
        self.agentAddress = agentAddress
        self.userAddress = userAddress
        self.networkName = networkName
        self.chainId = chainId
        self.isExpanded = isExpanded
        self.selectedTab = selectedTab
        self.chatViewModel = chatViewModel ?? ChatViewModel()
        self.walletViewModel = walletViewModel ?? WalletViewModel(
            userAddress: userAddress ?? "0x71C8401301F43F316568234664AC712927C5DD51",
            agentAddress: agentAddress,
            nativeBalance: balanceTBNB,
            networkName: networkName,
            chainId: chainId
        )
    }
    
    // MARK: - State Management Actions
    
    /// Toggles between Active (`.unlocked`) and Paused (`.paused`).
    /// If currently locked, state remains locked until unlocked.
    public func togglePauseResume() {
        guard agentState != .locked else { return }
        
        if agentState == .unlocked {
            agentState = .paused
        } else {
            agentState = .unlocked
        }
        onStateChanged?(agentState)
    }
    
    /// Immediately locks the agent.
    public func lockAgent() {
        agentState = .locked
        onStateChanged?(agentState)
    }
    
    /// Unlocks the agent with optional passphrase / biometric auth.
    public func unlockAgent(passphrase: String? = nil) async -> Bool {
        if let customHandler = onUnlockRequested {
            let success = await customHandler(passphrase)
            if success {
                agentState = .unlocked
                onStateChanged?(agentState)
            }
            return success
        } else {
            // Default unlock
            agentState = .unlocked
            onStateChanged?(agentState)
            return true
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
    public func setAgentStatus(_ status: AgentStatus) {
        if let addr = status.address, !addr.isEmpty {
            self.agentAddress = addr
            self.walletViewModel.agentAddress = addr
        }
        if let bal = status.balanceTBNB {
            updateBalance(bal)
        }
        if let tools = status.activeTools {
            self.activeTools = tools
        }
        if let erc8004 = status.erc8004Registered {
            self.isERC8004Registered = erc8004
        }
        
        if !status.isUnlocked {
            self.agentState = .locked
        } else if self.agentState == .locked {
            self.agentState = .unlocked
        }
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
    }
    
    /// Triggers the emergency kill switch.
    public func triggerKillSwitch() {
        self.agentState = .locked
        self.isExpanded = false
        self.onKillSwitch?()
    }
}
