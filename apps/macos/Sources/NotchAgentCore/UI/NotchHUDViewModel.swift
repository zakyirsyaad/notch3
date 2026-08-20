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

/// Main view model for the truthful Notch3 HUD.
///
/// Authentication is an internal session concern. There is deliberately no
/// public locked/paused state or manual lock control in this model. A collapsed
/// HUD click authenticates before expansion; lifecycle events clear the session
/// and collapse the HUD without presenting a "locked" status to the user.
@MainActor
public final class NotchHUDViewModel: ObservableObject {
    @Published public var balanceTBNB: String = "0.00"
    @Published public var agentAddress: String = "0x0000000000000000000000000000000000000000"
    @Published public var userAddress: String?
    @Published public var networkName: String = "BSC Testnet"
    @Published public var chainId: Int = 97
    @Published public var isExpanded: Bool = false
    @Published public var selectedTab: HUDTab = .chat
    @Published public var isBiometricsEnabled: Bool = true
    @Published public var isERC8004Registered: Bool = false
    @Published public var activeTools: [String] = []
    @Published public var isExecutingTool: Bool = false
    @Published public var activeToolName: String?
    @Published public var lastNotificationMessage: String?
    @Published public var isShowingNetworkSwitcher: Bool = false
    @Published public var lastError: String?
    @Published public var isUserWalletOnboarded: Bool = false
    @Published public var isShowingWalletOnboarding: Bool = false
    @Published public private(set) var isSetupComplete: Bool = false
    @Published public private(set) var isSessionAuthenticated: Bool = false
    @Published public var chatViewModel: ChatViewModel
    @Published public var walletViewModel: WalletViewModel
    @Published public var swapViewModel: SwapViewModel
    @Published public var makerModeViewModel: MakerModeViewModel
    @Published public var networkSwitcherViewModel: NetworkSwitcherViewModel
    @Published public var greenfieldStorageViewModel: GreenfieldStorageViewModel
    @Published public var providerSettingsViewModel: ProviderSettingsViewModel?

    public var onKillSwitch: (() -> Void)?
    public var onAuthenticateForHUD: (() async throws -> Bool)?
    public var onProvisionAgentWallet: ((String) async throws -> Void)?
    public var onProviderConfigurationRollbackFailed: (() -> Void)?

    public let onboardingKeystoreManager: UserKeystoreManager?
    public let onboardingPasswordStore: KeystorePasswordStore?

    public var isActive: Bool { isSessionAuthenticated }
    public var statusTitle: String { "Notch3" }
    public var statusEmoji: String { "" }

    public var formattedBalance: String {
        "\(balanceTBNB) tBNB"
    }

    public var formattedAgentAddress: String {
        guard agentAddress.count >= 10 else { return agentAddress }
        return "\(agentAddress.prefix(6))...\(agentAddress.suffix(4))"
    }

    public var formattedUserAddress: String {
        guard let userAddress, userAddress.count >= 10 else { return "No User Wallet" }
        return "\(userAddress.prefix(6))...\(userAddress.suffix(4))"
    }

    public var isProviderConfigured: Bool {
        guard let store = onboardingPasswordStore,
              let baseURL = store.loadOpenAIBaseURL(),
              let model = store.loadOpenAIModel() else {
            return false
        }
        return (try? OpenAIProviderConfiguration(baseURL: baseURL, model: model)) != nil
    }

    public init(
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
        userWalletAddress: String? = nil,
        setupComplete: Bool? = nil
    ) {
        self.onboardingKeystoreManager = onboardingKeystoreManager
        self.onboardingPasswordStore = onboardingPasswordStore
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
            userAddress: userAddress ?? "0x0000000000000000000000000000000000000000",
            agentAddress: agentAddress,
            nativeBalance: balanceTBNB,
            networkName: networkName,
            chainId: chainId,
            transactionDependencies: transactionDependencies
        )
        self.swapViewModel = swapViewModel ?? SwapViewModel(
            userAddress: userAddress ?? "0x0000000000000000000000000000000000000000",
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
            self.walletViewModel.isUserWalletOnboarded = true
            self.swapViewModel.userAddress = userWalletAddress
        }

        let persistedSetup = onboardingPasswordStore.map {
            $0.userWalletExists && $0.agentWalletSetupComplete
        } ?? false
        self.isSetupComplete = setupComplete ?? persistedSetup
        self.providerSettingsViewModel = onboardingPasswordStore.map(ProviderSettingsViewModel.init(passwordStore:))
        self.chatViewModel.isProviderConfigured = onboardingPasswordStore.flatMap {
            guard let baseURL = $0.loadOpenAIBaseURL(), let model = $0.loadOpenAIModel() else { return false }
            return (try? OpenAIProviderConfiguration(baseURL: baseURL, model: model)) != nil
        } ?? false
        self.chatViewModel.onConfigurationRequired = { [weak self] in
            self?.selectTab(.settings)
        }

        netVM.onNetworkSwitched = { [weak self] network in
            guard let self else { return }
            self.networkName = network.name
            self.chainId = network.chainId
            self.walletViewModel.networkName = network.name
            self.walletViewModel.chainId = network.chainId
            self.swapViewModel.networkName = network.name
            self.swapViewModel.chainId = network.chainId
        }
    }

    /// Gates collapsed-notch expansion behind Touch ID/device authentication.
    /// Before setup, the same click opens the guided wallet onboarding sheet.
    public func openFromNotch() async {
        if isExpanded {
            isExpanded = false
            return
        }

        refreshSetupStatus()
        guard isSetupComplete else {
            selectedTab = .settings
            isShowingWalletOnboarding = true
            isExpanded = true
            return
        }

        guard let authenticate = onAuthenticateForHUD else {
            lastError = "Authentication is unavailable."
            isExpanded = false
            return
        }

        do {
            guard try await authenticate() else {
                lastError = "Authentication failed."
                isExpanded = false
                return
            }
            lastError = nil
            isSessionAuthenticated = true
            isExpanded = true
        } catch {
            lastError = error.localizedDescription
            isExpanded = false
        }
    }

    /// Internal session clearing used by screen-lock, app-quit, and emergency
    /// termination paths. No visible "locked" state is exposed.
    public func clearAuthenticatedSession() {
        isSessionAuthenticated = false
        isExpanded = false
        isShowingWalletOnboarding = false
    }

    public func refreshSetupStatus() {
        guard let store = onboardingPasswordStore else {
            isSetupComplete = false
            return
        }
        isSetupComplete = store.userWalletExists && store.agentWalletSetupComplete
        if isSetupComplete {
            isUserWalletOnboarded = true
        }
    }

    public func updateBalance(_ newBalance: String) {
        let trimmed = newBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        balanceTBNB = trimmed.isEmpty || Double(trimmed) == nil ? "0.00" : trimmed
        walletViewModel.nativeBalance = balanceTBNB
    }

    /// Updates only observable task and wallet data from the runtime. Internal
    /// session state is never inferred from a passive status poll.
    public func setAgentStatus(_ status: AgentStatus) {
        if let address = status.address, !address.isEmpty {
            agentAddress = address
            walletViewModel.agentAddress = address
            makerModeViewModel.recipientAddress = address
        }
        if let balance = status.balance, !balance.isEmpty {
            updateBalance(balance)
        }
        if let tasks = status.activeTasks {
            isExecutingTool = tasks > 0
        }
    }

    public func applyUserWallet(address: String, closeOnboarding: Bool = true) {
        userAddress = address
        isUserWalletOnboarded = true
        if closeOnboarding {
            isShowingWalletOnboarding = false
        }
        walletViewModel.userAddress = address
        walletViewModel.isUserWalletOnboarded = true
        swapViewModel.userAddress = address
        refreshSetupStatus()
    }

    public func makeOnboardingViewModel() -> WalletOnboardingViewModel? {
        guard let keystoreManager = onboardingKeystoreManager,
              let passwordStore = onboardingPasswordStore else { return nil }
        let vm = WalletOnboardingViewModel(keystoreManager: keystoreManager, passwordStore: passwordStore)
        vm.onImportComplete = { [weak self] address in
            Task { @MainActor in self?.applyUserWallet(address: address, closeOnboarding: false) }
        }
        vm.onSetupComplete = { [weak self] address in
            guard let self, let provision = self.onProvisionAgentWallet else {
                throw AgentUnlockError("Agent Wallet provisioning is unavailable.")
            }
            try await provision(address)
            self.refreshSetupStatus()
            if self.isSetupComplete {
                // The onboarding sheet may have been shown from an
                // unauthenticated first-run click. Collapse before the newly
                // completed setup can expose the full HUD; the next click must
                // perform Touch ID authentication.
                self.clearAuthenticatedSession()
            }
        }
        return vm
    }

    public func makeProviderSettingsViewModel() -> ProviderSettingsViewModel? {
        guard let passwordStore = onboardingPasswordStore else { return nil }
        if let providerSettingsViewModel { return providerSettingsViewModel }
        let vm = ProviderSettingsViewModel(passwordStore: passwordStore)
        vm.onConfigurationSaved = { [weak self] configuration in
            try await self?.onProviderConfigurationSaved?(configuration)
        }
        vm.onConfigurationRollbackFailed = { [weak self] in
            self?.onProviderConfigurationRollbackFailed?()
        }
        providerSettingsViewModel = vm
        return vm
    }

    public var onProviderConfigurationSaved: ((OpenAIProviderConfiguration?) async throws -> Void)? {
        didSet {
            providerSettingsViewModel?.onConfigurationSaved = { [weak self] configuration in
                try await self?.onProviderConfigurationSaved?(configuration)
            }
            providerSettingsViewModel?.onConfigurationRollbackFailed = { [weak self] in
                self?.onProviderConfigurationRollbackFailed?()
            }
            chatViewModel.isProviderConfigured = isProviderConfigured
        }
    }

    public func selectTab(_ tab: HUDTab) {
        selectedTab = tab
        guard !isExpanded else { return }

        refreshSetupStatus()
        guard isSetupComplete else {
            selectedTab = .settings
            isShowingWalletOnboarding = true
            isExpanded = true
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.openFromNotch()
            if self.isExpanded {
                self.selectedTab = tab
            }
        }
    }

    public func toggleExpanded() {
        if isExpanded {
            isExpanded = false
        } else {
            Task { await openFromNotch() }
        }
    }

    public func beginToolExecution(name: String) {
        isExecutingTool = true
        activeToolName = name
    }

    public func endToolExecution() {
        isExecutingTool = false
        activeToolName = nil
    }

    public func triggerKillSwitch() {
        clearAuthenticatedSession()
        onKillSwitch?()
    }
}
