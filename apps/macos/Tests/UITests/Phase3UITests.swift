import Testing
import Foundation
import SwiftUI
@testable import NotchAgentCore

@Suite("Phase 3 Native UI & View Model Tests")
@MainActor
struct Phase3UITests {

    // MARK: - NetworkSwitcherViewModel Tests

    @Test("NetworkSwitcherViewModel initializes with 4 supported networks and BSC Testnet active")
    func testNetworkSwitcherDefaultState() {
        let vm = NetworkSwitcherViewModel()

        #expect(vm.supportedNetworks.count == 4)
        #expect(vm.activeNetwork.chainId == 97)
        #expect(vm.activeNetwork.name == "BSC Testnet")
        #expect(vm.activeNetwork.nativeSymbol == "tBNB")
        #expect(vm.activeNetwork.isTestnet == true)
        #expect(!vm.isSwitching)
        #expect(vm.errorMessage == nil)

        let chainIds = vm.supportedNetworks.map(\.chainId)
        #expect(chainIds.contains(97))
        #expect(chainIds.contains(56))
        #expect(chainIds.contains(5611))
        #expect(chainIds.contains(204))
    }

    @Test("NetworkSwitcherViewModel switches between BSC Testnet, BSC Mainnet, opBNB Testnet, and opBNB Mainnet")
    func testNetworkSwitcherNetworkSwitching() async {
        let vm = NetworkSwitcherViewModel()

        // 1. Switch to BSC Mainnet (56)
        var success = await vm.switchNetwork(to: 56)
        #expect(success)
        #expect(vm.activeNetwork.chainId == 56)
        #expect(vm.activeNetwork.name == "BSC Mainnet")
        #expect(vm.activeNetwork.nativeSymbol == "BNB")
        #expect(!vm.activeNetwork.isTestnet)

        // 2. Switch to opBNB Testnet (5611)
        success = await vm.switchNetwork(to: 5611)
        #expect(success)
        #expect(vm.activeNetwork.chainId == 5611)
        #expect(vm.activeNetwork.name == "opBNB Testnet")
        #expect(vm.activeNetwork.isTestnet)

        // 3. Switch to opBNB Mainnet (204)
        success = await vm.switchNetwork(to: 204)
        #expect(success)
        #expect(vm.activeNetwork.chainId == 204)
        #expect(vm.activeNetwork.name == "opBNB Mainnet")
        #expect(!vm.activeNetwork.isTestnet)

        // 4. Switch back to BSC Testnet (97)
        success = await vm.switchNetwork(to: 97)
        #expect(success)
        #expect(vm.activeNetwork.chainId == 97)
        #expect(vm.activeNetwork.name == "BSC Testnet")
    }

    @Test("NetworkSwitcherViewModel handles unsupported chain IDs gracefully")
    func testNetworkSwitcherInvalidChainId() async {
        let vm = NetworkSwitcherViewModel()
        let initialChainId = vm.activeNetwork.chainId

        let success = await vm.switchNetwork(to: 999999)
        #expect(!success)
        #expect(vm.activeNetwork.chainId == initialChainId)
        #expect(vm.errorMessage != nil)
    }

    @Test("NetworkSwitcherViewModel triggers onNetworkSwitched callback")
    func testNetworkSwitcherCallback() async {
        let vm = NetworkSwitcherViewModel()
        var switchedChainId: Int? = nil

        vm.onNetworkSwitched = { network in
            switchedChainId = network.chainId
        }

        _ = await vm.switchNetwork(to: 56)
        #expect(switchedChainId == 56)
    }

    // MARK: - GreenfieldStorageViewModel Tests

    @Test("GreenfieldStorageViewModel initializes with default bucket and default objects")
    func testGreenfieldStorageDefaultState() {
        let vm = GreenfieldStorageViewModel()

        #expect(vm.currentBucket == "notch-agent-backups")
        #expect(vm.availableBuckets.contains("notch-agent-backups"))
        #expect(vm.availableBuckets.contains("agent-data"))
        #expect(vm.availableBuckets.contains("session-store"))
        #expect(!vm.objects.isEmpty)
        #expect(!vm.isLoading)
        #expect(!vm.isUploading)
        #expect(!vm.isBackingUp)
        #expect(vm.isClientSideEncryptionEnabled)
    }

    @Test("GreenfieldStorageViewModel uploadObject adds new metadata record")
    func testGreenfieldStorageUploadObject() async {
        let vm = GreenfieldStorageViewModel()
        let initialCount = vm.objects.count

        let uploadResult = await vm.uploadObject(
            name: "configs/agent-rules.json",
            content: "{\"version\": 1.0, \"mode\": \"autonomous\"}",
            contentType: "application/json",
            isPrivate: true
        )

        #expect(uploadResult != nil)
        #expect(uploadResult?.objectName == "configs/agent-rules.json")
        #expect(uploadResult?.bucket == vm.currentBucket)
        #expect(uploadResult?.isPrivate == true)
        #expect(vm.objects.count == initialCount + 1)
        #expect(vm.objects.contains(where: { $0.objectName == "configs/agent-rules.json" }))
    }

    @Test("GreenfieldStorageViewModel listObjects filters by prefix")
    func testGreenfieldStorageListObjectsFiltering() async {
        let vm = GreenfieldStorageViewModel()

        _ = await vm.uploadObject(name: "backups/session-1.json", content: "data1")
        _ = await vm.uploadObject(name: "backups/session-2.json", content: "data2")
        _ = await vm.uploadObject(name: "docs/readme.md", content: "hello")

        let backups = vm.filteredObjects(prefix: "backups/")
        #expect(backups.count >= 2)
        #expect(backups.allSatisfy { $0.objectName.hasPrefix("backups/") })
    }

    @Test("GreenfieldStorageViewModel backupChatHistory creates encrypted backup record")
    func testGreenfieldStorageBackupChatHistory() async {
        let chatVM = ChatViewModel(messages: [
            ChatMessage(role: .user, content: "What is my BNB balance?"),
            ChatMessage(role: .assistant, content: "Your balance is 0.05 tBNB.")
        ])

        let vm = GreenfieldStorageViewModel(chatViewModel: chatVM)

        let result = await vm.backupChatHistory(sessionId: "test-session-123")
        #expect(result != nil)
        #expect(result?.sessionId == "test-session-123")
        #expect(result?.url.contains("test-session-123") == true)
        #expect(vm.lastBackupResult?.sessionId == "test-session-123")
        #expect(vm.backupStatusMessage?.contains("Backed up successfully") == true)
    }

    @Test("GreenfieldStorageViewModel inspectObject returns object details")
    func testGreenfieldStorageInspectObject() async {
        let vm = GreenfieldStorageViewModel()
        let uploadResult = await vm.uploadObject(
            name: "test-inspect.txt",
            content: "Inspectable Greenfield Storage Data"
        )
        #expect(uploadResult != nil)

        guard let meta = vm.objects.first(where: { $0.objectName == "test-inspect.txt" }) else {
            Issue.record("Uploaded object metadata not found")
            return
        }

        let inspected = await vm.inspectObject(meta)
        #expect(inspected != nil)
        #expect(inspected?.content == "Inspectable Greenfield Storage Data")
        #expect(inspected?.objectName == "test-inspect.txt")
    }

    // MARK: - HUD & MenuBar Integration Tests

    @Test("NotchHUDViewModel integrates Greenfield Storage tab and Network Switcher")
    func testNotchHUDPhase3Integration() async {
        let hudVM = NotchHUDViewModel()

        // 1. Greenfield Storage Tab
        hudVM.selectTab(.storage)
        #expect(hudVM.selectedTab == .storage)
        #expect(hudVM.isExpanded)

        // 2. Network Switcher integration
        #expect(hudVM.networkSwitcherViewModel.activeNetwork.chainId == 97)

        let switched = await hudVM.networkSwitcherViewModel.switchNetwork(to: 56)
        #expect(switched)
        #expect(hudVM.networkName == "BSC Mainnet")
        #expect(hudVM.chainId == 56)
        #expect(hudVM.walletViewModel.networkName == "BSC Mainnet")
        #expect(hudVM.walletViewModel.chainId == 56)
    }

    @Test("MenuBarController builds network submenu with all 4 networks")
    func testMenuBarControllerNetworkSubmenu() {
        let hudVM = NotchHUDViewModel()
        let windowController = NotchWindowController(viewModel: hudVM)
        let menuBarController = MenuBarController(viewModel: hudVM, windowController: windowController)

        let menu = menuBarController.buildMenu()

        // Find Network item with submenu
        let networkItem = menu.items.first(where: { $0.title.contains("Network") && $0.hasSubmenu })
        #expect(networkItem != nil)

        guard let submenu = networkItem?.submenu else {
            Issue.record("Network submenu not found in MenuBarController menu")
            return
        }

        #expect(submenu.items.count >= 4)
        let bscTestnetItem = submenu.items.first(where: { $0.title.contains("BSC Testnet") })
        let bscMainnetItem = submenu.items.first(where: { $0.title.contains("BSC Mainnet") })
        let opBnbTestnetItem = submenu.items.first(where: { $0.title.contains("opBNB Testnet") })
        let opBnbMainnetItem = submenu.items.first(where: { $0.title.contains("opBNB Mainnet") })

        #expect(bscTestnetItem != nil)
        #expect(bscMainnetItem != nil)
        #expect(opBnbTestnetItem != nil)
        #expect(opBnbMainnetItem != nil)

        // Active network item should be checked
        #expect(bscTestnetItem?.state == .on)
        #expect(bscMainnetItem?.state == .off)
    }
}
