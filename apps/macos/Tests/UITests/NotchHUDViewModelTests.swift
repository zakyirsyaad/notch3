import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Notch HUD View Model Tests")
@MainActor
struct NotchHUDViewModelTests {

    @Test("Default state is honest: locked, zero balance, collapsed HUD")
    func testDefaultState() {
        let vm = NotchHUDViewModel()

        #expect(vm.agentState == .locked)
        #expect(vm.statusTitle == "Locked")
        #expect(vm.statusEmoji == "🔒")
        #expect(vm.balanceTBNB == "0.00")
        #expect(vm.formattedBalance == "0.00 tBNB")
        #expect(vm.chainId == 97)
        #expect(vm.networkName == "BSC Testnet")
        #expect(!vm.isExpanded)
        #expect(vm.selectedTab == .chat)
        #expect(!vm.isExecutingTool)
        #expect(vm.activeToolName == nil)
    }

    @Test("Pausing works while active; resuming requires authenticated unlock")
    func testTogglePauseResume() {
        let vm = NotchHUDViewModel(agentState: .unlocked)

        #expect(vm.agentState == .unlocked)
        #expect(vm.isActive)

        vm.togglePauseResume()
        #expect(vm.agentState == .paused)
        #expect(vm.statusTitle == "Paused")
        #expect(!vm.isActive)
        #expect(vm.isPaused)

        // A local toggle must never silently re-unlock funds.
        vm.togglePauseResume()
        #expect(vm.agentState == .paused)
    }

    @Test("Unlock fails closed without an authenticated handler")
    func testUnlockFailsClosed() async {
        let vm = NotchHUDViewModel()

        vm.lockAgent()
        #expect(vm.agentState == .locked)
        #expect(vm.statusTitle == "Locked")
        #expect(vm.isLocked)
        #expect(!vm.isActive)

        // When locked, togglePauseResume should remain locked without unlock
        vm.togglePauseResume()
        #expect(vm.agentState == .locked)

        // No handler installed → unlock must fail and surface an error.
        let unlocked = await vm.unlockAgent(passphrase: "test-pass")
        #expect(!unlocked)
        #expect(vm.agentState == .locked)
        #expect(vm.lastError != nil)
    }

    @Test("Authenticated unlock handler unlocks the agent")
    func testAuthenticatedUnlock() async {
        let vm = NotchHUDViewModel()
        vm.lockAgent()
        vm.onUnlockRequested = { _ in true }

        let unlocked = await vm.unlockAgent(passphrase: "test-pass")
        #expect(unlocked)
        #expect(vm.agentState == .unlocked)
        #expect(vm.isActive)
        #expect(vm.lastError == nil)
    }

    @Test("Unlock handler errors surface as lastError and keep the agent locked")
    func testUnlockErrorSurfaces() async {
        let vm = NotchHUDViewModel()
        vm.onUnlockRequested = { _ in throw AgentUnlockError("runtime is not running") }

        let unlocked = await vm.unlockAgent()
        #expect(!unlocked)
        #expect(vm.agentState == .locked)
        #expect(vm.lastError?.contains("runtime is not running") == true)
    }

    @Test("Balance updates correctly format and fallback on invalid amounts")
    func testUpdateBalance() {
        let vm = NotchHUDViewModel()

        vm.updateBalance("0.125")
        #expect(vm.balanceTBNB == "0.125")
        #expect(vm.formattedBalance == "0.125 tBNB")

        // Empty or invalid handling
        vm.updateBalance("")
        #expect(vm.balanceTBNB == "0.00")
        #expect(vm.formattedBalance == "0.00 tBNB")
    }

    @Test("Applying AgentStatus updates address and balance using the runtime contract")
    func testSetAgentStatus() {
        let vm = NotchHUDViewModel(agentState: .unlocked)

        let status = AgentStatus(
            lockState: "unlocked",
            state: "active",
            address: "0x1234567890123456789012345678901234567890",
            balance: "0.25",
            activeTasks: 1,
            lastActivity: 1_700_000_000_000
        )

        vm.setAgentStatus(status)
        #expect(vm.agentAddress == "0x1234567890123456789012345678901234567890")
        #expect(vm.balanceTBNB == "0.25")
        #expect(vm.isExecutingTool)
    }

    @Test("A passive status poll may lock but never unlock")
    func testPassiveStatusCannotUnlock() {
        let vm = NotchHUDViewModel()
        #expect(vm.agentState == .locked)

        vm.setAgentStatus(AgentStatus(lockState: "unlocked", state: "active", balance: "1.0"))
        #expect(vm.agentState == .locked)
    }

    @Test("Locked status from runtime locks an active agent")
    func testRuntimeLockPropagates() {
        let vm = NotchHUDViewModel(agentState: .unlocked)

        vm.setAgentStatus(AgentStatus(lockState: "locked", state: "locked"))
        #expect(vm.agentState == .locked)
    }

    @Test("Tab selection and drawer expansion toggle")
    func testTabSelectionAndExpansion() {
        let vm = NotchHUDViewModel()

        #expect(!vm.isExpanded)
        #expect(vm.selectedTab == .chat)

        vm.selectTab(.wallet)
        #expect(vm.selectedTab == .wallet)
        #expect(vm.isExpanded) // selecting a tab auto-expands

        vm.selectTab(.settings)
        #expect(vm.selectedTab == .settings)

        vm.toggleExpanded()
        #expect(!vm.isExpanded)

        vm.toggleExpanded()
        #expect(vm.isExpanded)
    }

    @Test("Tool execution state tracking")
    func testToolExecutionState() {
        let vm = NotchHUDViewModel()

        #expect(!vm.isExecutingTool)
        #expect(vm.activeToolName == nil)

        vm.beginToolExecution(name: "pay_x402_service")
        #expect(vm.isExecutingTool)
        #expect(vm.activeToolName == "pay_x402_service")

        vm.endToolExecution()
        #expect(!vm.isExecutingTool)
        #expect(vm.activeToolName == nil)
    }

    @Test("Auto-pay limit configuration and validation")
    func testAutoPayLimitConfig() {
        let vm = NotchHUDViewModel()

        #expect(vm.autoPayLimit == "0.05")

        vm.setAutoPayLimit("0.10")
        #expect(vm.autoPayLimit == "0.10")

        // Invalid limit input
        vm.setAutoPayLimit("-1.0")
        #expect(vm.autoPayLimit == "0.10") // retains previous valid
    }
}
