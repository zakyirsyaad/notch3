import Testing
import Foundation
import AppKit
@testable import NotchAgentCore

@Suite("QR Receive View Model Tests")
@MainActor
struct QRReceiveViewModelTests {

    @Test("Default state initializes with user address and generates QR code")
    func testDefaultInitialization() {
        let userAddr = "0x1111111111111111111111111111111111111111"
        let agentAddr = "0x2222222222222222222222222222222222222222"
        let vm = QRReceiveViewModel(
            userAddress: userAddr,
            agentAddress: agentAddr,
            selectedAccount: .user,
            networkName: "BSC Testnet"
        )

        #expect(vm.selectedAccount == .user)
        #expect(vm.currentAddress == userAddr)
        #expect(vm.userAddress == userAddr)
        #expect(vm.agentAddress == agentAddr)
        #expect(vm.networkName == "BSC Testnet")
        #expect(vm.qrImage != nil)
        #expect(!vm.isCopied)
    }

    @Test("Switching account toggles address and regenerates QR code")
    func testAccountSwitching() {
        let userAddr = "0x1111111111111111111111111111111111111111"
        let agentAddr = "0x2222222222222222222222222222222222222222"
        let vm = QRReceiveViewModel(
            userAddress: userAddr,
            agentAddress: agentAddr,
            selectedAccount: .user
        )

        #expect(vm.currentAddress == userAddr)

        vm.selectAccount(.agent)
        #expect(vm.selectedAccount == .agent)
        #expect(vm.currentAddress == agentAddr)
        #expect(vm.qrImage != nil)

        vm.selectAccount(.user)
        #expect(vm.selectedAccount == .user)
        #expect(vm.currentAddress == userAddr)
    }

    @Test("Formatted address correctly shortens long addresses")
    func testFormattedAddress() {
        let fullAddr = "0x71C8401301F43F316568234664AC712927C5DD51"
        let vm = QRReceiveViewModel(userAddress: fullAddr)

        #expect(vm.formattedAddress == "0x71C840...C5DD51")
    }

    @Test("Static QR code generator handles valid and empty inputs")
    func testQRCodeGenerator() {
        let validImage = QRReceiveViewModel.generateQRCode(from: "0x1234567890abcdef", size: 100)
        #expect(validImage != nil)

        let emptyImage = QRReceiveViewModel.generateQRCode(from: "", size: 100)
        #expect(emptyImage == nil)
    }

    @Test("Copying address updates pasteboard and triggers copied flag")
    func testCopyAddress() {
        let userAddr = "0x71C8401301F43F316568234664AC712927C5DD51"
        let vm = QRReceiveViewModel(userAddress: userAddr)

        vm.copyAddress()
        #expect(vm.isCopied)

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.string(forType: .string) == userAddr)
    }
}
