import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Notch HUD View Model Tests")
@MainActor
struct NotchHUDViewModelTests {
    
    @Test("Default state initializes with active unlocked status, 0.05 tBNB, and collapsed HUD")
    func testDefaultState() {
        let vm = NotchHUDViewModel()
        
        #expect(vm.agentState == .unlocked)
        #expect(vm.statusTitle == "Active")
        #expect(vm.statusEmoji == "🟢")
        #expect(vm.balanceTBNB == "0.05")
        #expect(vm.formattedBalance == "0.05 tBNB")
        #expect(vm.chainId == 97)
        #expect(vm.networkName == "BSC Testnet")
        #expect(!vm.isExpanded)
        #expect(vm.selectedTab == .chat)
        #expect(!vm.isExecutingTool)
        #expect(vm.activeToolName == nil)
    }
    
    @Test("Toggle pause and resume updates state between unlocked and paused")
    func testTogglePauseResume() {
        let vm = NotchHUDViewModel()
        
        #expect(vm.agentState == .unlocked)
        #expect(vm.isActive)
        
        vm.togglePauseResume()
        #expect(vm.agentState == .paused)
        #expect(vm.statusTitle == "Paused")
        #expect(vm.statusEmoji == "⏸️")
        #expect(!vm.isActive)
        #expect(vm.isPaused)
        
        vm.togglePauseResume()
        #expect(vm.agentState == .unlocked)
        #expect(vm.statusTitle == "Active")
        #expect(vm.isActive)
    }
    
    @Test("Locking and unlocking transitions agent state")
    func testLockAndUnlock() async {
        let vm = NotchHUDViewModel()
        
        vm.lockAgent()
        #expect(vm.agentState == .locked)
        #expect(vm.statusTitle == "Locked")
        #expect(vm.statusEmoji == "🔒")
        #expect(vm.isLocked)
        #expect(!vm.isActive)
        
        // When locked, togglePauseResume should remain locked without unlock
        vm.togglePauseResume()
        #expect(vm.agentState == .locked)
        
        let unlocked = await vm.unlockAgent(passphrase: "test-pass")
        #expect(unlocked)
        #expect(vm.agentState == .unlocked)
        #expect(vm.isActive)
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
    
    @Test("Applying AgentStatus updates address, balance, and tool registry")
    func testSetAgentStatus() {
        let vm = NotchHUDViewModel()
        
        let status = AgentStatus(
            isUnlocked: true,
            address: "0x1234567890123456789012345678901234567890",
            balanceTBNB: "0.25",
            activeTools: ["pay_x402_service", "query_bnb_docs"],
            erc8004Registered: true
        )
        
        vm.setAgentStatus(status)
        #expect(vm.agentAddress == "0x1234567890123456789012345678901234567890")
        #expect(vm.balanceTBNB == "0.25")
        #expect(vm.isERC8004Registered)
        #expect(vm.activeTools.count == 2)
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
