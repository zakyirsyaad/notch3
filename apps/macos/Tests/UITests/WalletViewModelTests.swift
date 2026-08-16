import Testing
import Foundation
import AppKit
@testable import NotchAgentCore

@Suite("Wallet View Model Tests")
@MainActor
struct WalletViewModelTests {

    @Test("Default state initializes with Agent wallet selected, default balances, and transactions")
    func testDefaultState() {
        let vm = WalletViewModel()

        #expect(vm.selectedAccount == .agent)
        #expect(vm.nativeBalance == "0.05")
        #expect(!vm.tokenBalances.isEmpty)
        #expect(!vm.transactions.isEmpty)
        #expect(vm.networkName == "BSC Testnet")
        #expect(vm.chainId == 97)
        #expect(!vm.isShowingQRSheet)
        #expect(!vm.isShowingConfirmModal)
    }

    @Test("Account selection toggles address and formatting")
    func testAccountSelection() {
        let userAddr = "0x71C8401301F43F316568234664AC712927C5DD51"
        let agentAddr = "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7"
        let vm = WalletViewModel(userAddress: userAddr, agentAddress: agentAddr)

        #expect(vm.selectedAccount == .agent)
        #expect(vm.currentAddress == agentAddr)

        vm.selectedAccount = .user
        #expect(vm.currentAddress == userAddr)
        #expect(vm.formattedCurrentAddress == "0x71C8...DD51")
    }

    @Test("Requesting Fund Agent sets confirmation details for modal")
    func testRequestFundAgent() {
        let vm = WalletViewModel()

        vm.requestFundAgent(amount: "0.10")

        #expect(vm.isShowingConfirmModal)
        #expect(vm.pendingConfirmation != nil)
        #expect(vm.pendingConfirmation?.operationType == .fundAgent)
        #expect(vm.pendingConfirmation?.amount == "0.10")
        #expect(vm.pendingConfirmation?.assetSymbol == "tBNB")
    }

    @Test("Requesting Transfer sets confirmation details with recipient")
    func testRequestTransfer() {
        let vm = WalletViewModel()
        let recipient = "0x3333333333333333333333333333333333333333"

        vm.requestTransfer(to: recipient, amount: "1.5", symbol: "USDT")

        #expect(vm.isShowingConfirmModal)
        #expect(vm.pendingConfirmation?.operationType == .transfer)
        #expect(vm.pendingConfirmation?.toAddress == recipient)
        #expect(vm.pendingConfirmation?.amount == "1.5")
        #expect(vm.pendingConfirmation?.assetSymbol == "USDT")
    }

    @Test("Requesting Swap sets PancakeSwap details with slippage")
    func testRequestSwap() {
        let vm = WalletViewModel()

        vm.requestSwap(fromToken: "tBNB", toToken: "USDT", amount: "0.25")

        #expect(vm.isShowingConfirmModal)
        #expect(vm.pendingConfirmation?.operationType == .swap)
        #expect(vm.pendingConfirmation?.amount == "0.25")
        #expect(vm.pendingConfirmation?.slippageTolerance == "0.5%")
    }

    @Test("ERC-8056 formatting returns token amount with symbol")
    func testERC8056Formatting() {
        let vm = WalletViewModel()
        let token = TokenBalance(
            tokenAddress: "0x8056000000000000000000000000000000008056",
            rawAmount: "1000000000000000000",
            uiAmount: "10.00",
            symbol: "sBNB",
            decimals: 18
        )

        let formatted = vm.formatERC8056Display(for: token)
        #expect(formatted == "10.00 sBNB")
    }

    @Test("Copy address updates pasteboard and toast state")
    func testCopyAddress() {
        let vm = WalletViewModel()

        vm.copyAddress()
        #expect(vm.copiedAddressToast)

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.string(forType: .string) == vm.currentAddress)
    }
}
