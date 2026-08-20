import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Notch3 HUD View Model Tests")
@MainActor
struct NotchHUDViewModelTests {

    private func makeCompleteStore() throws -> KeystorePasswordStore {
        let store = KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-hud-\(UUID().uuidString)", isDirectory: true),
            userDefaults: UserDefaults(suiteName: "notch-hud-\(UUID().uuidString)")!
        )
        try store.saveUserWallet(.init(address: "0x1111111111111111111111111111111111111111", keystoreJson: "user"))
        try store.saveAgentWallet(.init(address: "0x2222222222222222222222222222222222222222", keystoreJson: "agent"))
        try store.saveAgentPassphrase("agent-passphrase")
        return store
    }

    private func makeEmptyStore() -> KeystorePasswordStore {
        KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-hud-empty-\(UUID().uuidString)", isDirectory: true),
            userDefaults: UserDefaults(suiteName: "notch-hud-empty-\(UUID().uuidString)")!
        )
    }

    @Test("Default HUD is collapsed, branded Notch3, and has no synthetic task badge")
    func defaultState() {
        let vm = NotchHUDViewModel()

        #expect(vm.statusTitle == "Notch3")
        #expect(vm.balanceTBNB == "0.00")
        #expect(vm.formattedBalance == "0.00 tBNB")
        #expect(vm.chainId == 97)
        #expect(vm.networkName == "BSC Testnet")
        #expect(!vm.isExpanded)
        #expect(!vm.isSessionAuthenticated)
        #expect(!vm.isSetupComplete)
        #expect(!vm.isExecutingTool)
    }

    @Test("Clicking before setup opens guided onboarding without authenticating")
    func opensOnboardingBeforeSetup() async {
        let vm = NotchHUDViewModel()
        await vm.openFromNotch()

        #expect(vm.isExpanded)
        #expect(vm.isShowingWalletOnboarding)
        #expect(!vm.isSessionAuthenticated)
    }

    @Test("Every completed-setup opening requires successful authentication")
    func authenticationGatesExpansion() async throws {
        let store = try makeCompleteStore()
        let vm = NotchHUDViewModel(
            onboardingPasswordStore: store,
            userWalletAddress: "0x1111111111111111111111111111111111111111"
        )
        var calls = 0
        vm.onAuthenticateForHUD = {
            calls += 1
            return true
        }

        await vm.openFromNotch()

        #expect(calls == 1)
        #expect(vm.isExpanded)
        #expect(vm.isSessionAuthenticated)

        vm.clearAuthenticatedSession()
        #expect(!vm.isExpanded)
        #expect(!vm.isSessionAuthenticated)
    }

    @Test("Authentication failure fails closed and leaves the HUD collapsed")
    func authenticationFailureFailsClosed() async throws {
        let store = try makeCompleteStore()
        let vm = NotchHUDViewModel(onboardingPasswordStore: store, userWalletAddress: "0x1111111111111111111111111111111111111111")
        vm.onAuthenticateForHUD = { false }

        await vm.openFromNotch()

        #expect(!vm.isExpanded)
        #expect(!vm.isSessionAuthenticated)
        #expect(vm.lastError == "Authentication failed.")
    }

    @Test("Selecting a tab from a collapsed completed HUD still requires authentication")
    func tabSelectionUsesAuthenticationGate() async throws {
        let store = try makeCompleteStore()
        let vm = NotchHUDViewModel(onboardingPasswordStore: store, userWalletAddress: "0x1111111111111111111111111111111111111111")
        var authenticationCalls = 0
        vm.onAuthenticateForHUD = {
            authenticationCalls += 1
            return true
        }

        vm.selectTab(.settings)
        await Task.yield()

        #expect(authenticationCalls == 1)
        #expect(vm.selectedTab == .settings)
        #expect(vm.isExpanded)
    }

    @Test("Successful first-run setup collapses before the completed HUD is enabled")
    func setupCompletionCollapsesBeforeAuthentication() async {
        let store = makeEmptyStore()
        let hud = NotchHUDViewModel(
            onboardingKeystoreManager: UserKeystoreManager(),
            onboardingPasswordStore: store
        )
        hud.isExpanded = true
        hud.isShowingWalletOnboarding = true
        hud.onProvisionAgentWallet = { _ in
            try store.saveAgentWallet(.init(address: "0x2222222222222222222222222222222222222222", keystoreJson: "agent"))
            try store.saveAgentPassphrase("agent-passphrase")
        }
        let onboarding = hud.makeOnboardingViewModel()!
        onboarding.mnemonicInput = "test test test test test test test test test test test junk"
        onboarding.passwordInput = "correct-horse-1"
        onboarding.confirmPassword = "correct-horse-1"
        onboarding.importWallet()

        for _ in 0..<100 {
            if store.agentWalletExists { break }
            await Task.yield()
        }

        #expect(store.userWalletExists)
        #expect(store.agentWalletExists)
        #expect(!hud.isExpanded)
        #expect(!hud.isSessionAuthenticated)
    }

    @Test("Passive runtime status updates wallet/task information only")
    func passiveStatusDoesNotAuthenticate() {
        let vm = NotchHUDViewModel()
        vm.setAgentStatus(AgentStatus(
            lockState: "unlocked",
            state: "active",
            address: "0x1234567890123456789012345678901234567890",
            balance: "0.25",
            activeTasks: 1,
            lastActivity: 1_700_000_000_000
        ))

        #expect(vm.agentAddress == "0x1234567890123456789012345678901234567890")
        #expect(vm.balanceTBNB == "0.25")
        #expect(vm.isExecutingTool)
        #expect(!vm.isSessionAuthenticated)
    }

    @Test("Balance updates validate input and keep UI formatting stable")
    func balanceUpdates() {
        let vm = NotchHUDViewModel()
        vm.updateBalance("0.125")
        #expect(vm.formattedBalance == "0.125 tBNB")
        vm.updateBalance("")
        #expect(vm.formattedBalance == "0.00 tBNB")
    }

    @Test("Tab selection and tool execution remain functional")
    func tabAndToolState() {
        let vm = NotchHUDViewModel()
        vm.selectTab(.wallet)
        #expect(vm.selectedTab == .wallet)
        #expect(vm.isExpanded)

        vm.beginToolExecution(name: "pay_x402_service")
        #expect(vm.isExecutingTool)
        #expect(vm.activeToolName == "pay_x402_service")
        vm.endToolExecution()
        #expect(!vm.isExecutingTool)
        #expect(vm.activeToolName == nil)
    }

    @Test("Emergency kill switch clears the internal session and collapses HUD")
    func killSwitchClearsSession() async throws {
        let store = try makeCompleteStore()
        let vm = NotchHUDViewModel(onboardingPasswordStore: store, userWalletAddress: "0x1111111111111111111111111111111111111111")
        vm.onAuthenticateForHUD = { true }
        await vm.openFromNotch()
        vm.triggerKillSwitch()

        #expect(!vm.isExpanded)
        #expect(!vm.isSessionAuthenticated)
    }
}
