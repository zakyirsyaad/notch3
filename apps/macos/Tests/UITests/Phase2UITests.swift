import Testing
import Foundation
import SwiftUI
@testable import NotchAgentCore

@Suite("Phase 2 Native UI & View Model Tests")
@MainActor
struct Phase2UITests {

    // MARK: - SwapViewModel Tests

    @Test("SwapViewModel initializes with default tokens, slippage, and BSC testnet settings")
    func testSwapViewModelDefaultState() {
        let vm = SwapViewModel()

        #expect(vm.tokenIn.symbol == "tBNB")
        #expect(vm.tokenOut.symbol == "USDT")
        #expect(vm.selectedSlippage == 0.5)
        #expect(!vm.isCustomSlippage)
        #expect(vm.amountIn == "")
        #expect(vm.currentQuote == nil)
        #expect(!vm.isShowingConfirmation)
        #expect(vm.chainId == 97)
        #expect(vm.networkName == "BSC Testnet")
        #expect(vm.availableTokens.count >= 4)
    }

    @Test("SwapViewModel switches Token In and Token Out correctly")
    func testSwapViewModelSwitchTokens() async {
        let vm = SwapViewModel()
        let initialIn = vm.tokenIn
        let initialOut = vm.tokenOut

        vm.amountIn = "1.0"
        vm.switchTokens()

        #expect(vm.tokenIn.symbol == initialOut.symbol)
        #expect(vm.tokenOut.symbol == initialIn.symbol)
    }

    @Test("SwapViewModel slippage tolerance selection and custom input validation")
    func testSwapViewModelSlippageSelection() {
        let vm = SwapViewModel()

        vm.setSlippage(0.1)
        #expect(vm.selectedSlippage == 0.1)
        #expect(!vm.isCustomSlippage)

        vm.setSlippage(1.0)
        #expect(vm.selectedSlippage == 1.0)

        // Custom slippage
        vm.setCustomSlippage("2.5")
        #expect(vm.selectedSlippage == 2.5)
        #expect(vm.isCustomSlippage)

        // Invalid custom slippage should not apply negative or out of range
        vm.setCustomSlippage("-5.0")
        #expect(vm.selectedSlippage == 2.5)

        vm.setCustomSlippage("60.0") // > 50% unrealistic
        #expect(vm.selectedSlippage == 2.5)
    }

    @Test("SwapViewModel calculates dynamic quote with minimum received deducting slippage")
    func testSwapViewModelQuoteCalculation() async {
        let vm = SwapViewModel()
        vm.amountIn = "1.0" // 1 tBNB -> ~600 USDT
        vm.selectedSlippage = 0.5

        await vm.calculateQuote()

        #expect(vm.currentQuote != nil)
        guard let quote = vm.currentQuote else { return }

        #expect(quote.tokenIn.symbol == "tBNB")
        #expect(quote.tokenOut.symbol == "USDT")
        #expect(quote.amountIn == "1.0")
        
        let outVal = Double(quote.amountOut) ?? 0.0
        let minVal = Double(quote.amountOutMin) ?? 0.0
        #expect(outVal > 0)
        #expect(minVal > 0)
        #expect(minVal < outVal) // amountOutMin should be strictly less than amountOut due to slippage
        #expect(quote.route.count >= 2)
        #expect(quote.priceImpactPercent >= 0)
    }

    @Test("SwapViewModel handles ERC-8056 scaling in quote and token display")
    func testSwapViewModelERC8056TokenHandling() async {
        let vm = SwapViewModel()
        
        if let sBnb = vm.availableTokens.first(where: { $0.isERC8056 }) {
            vm.tokenIn = sBnb
            #expect(vm.tokenIn.isERC8056)
            #expect(vm.tokenIn.multiplier != nil)

            vm.amountIn = "2.0"
            await vm.calculateQuote()
            #expect(vm.currentQuote != nil)
        } else {
            Issue.record("ERC-8056 token not found in availableTokens")
        }
    }

    @Test("SwapViewModel reviewSwap builds valid TransactionConfirmationDetails")
    func testSwapViewModelReviewSwap() async {
        let vm = SwapViewModel(userAddress: "0x71C8401301F43F316568234664AC712927C5DD51")
        vm.amountIn = "0.5"
        await vm.calculateQuote()

        let details = vm.reviewSwap()
        #expect(details != nil)
        #expect(vm.isShowingConfirmation)
        #expect(vm.pendingConfirmation != nil)
        #expect(details?.operationType == .swap)
        #expect(details?.fromAddress == "0x71C8401301F43F316568234664AC712927C5DD51")
        #expect(details?.amount == "0.5")
        #expect(details?.assetSymbol == "tBNB")
        #expect(details?.slippageTolerance == "0.5%")
    }

    @Test("SwapViewModel reviewSwap fails gracefully when amount is empty or zero")
    func testSwapViewModelReviewSwapValidation() {
        let vm = SwapViewModel()
        vm.amountIn = ""
        let details = vm.reviewSwap()
        #expect(details == nil)
        #expect(!vm.isShowingConfirmation)
        #expect(vm.errorMessage != nil)

        vm.amountIn = "0.00"
        let zeroDetails = vm.reviewSwap()
        #expect(zeroDetails == nil)
    }

    // MARK: - MakerModeViewModel Tests

    @Test("MakerModeViewModel initializes in stopped state with default port 4020 and 0 sales")
    func testMakerModeViewModelDefaultState() {
        let vm = MakerModeViewModel()

        #expect(!vm.isRunning)
        #expect(vm.port == 4020)
        #expect(vm.host == "127.0.0.1")
        #expect(vm.totalSalesCount == 0)
        #expect(vm.totalRevenueTBNB == "0.00")
        #expect(!vm.activeEndpoints.isEmpty)
        #expect(vm.salesHistory.isEmpty)
    }

    @Test("MakerModeViewModel startServer and stopServer toggle lifecycle")
    func testMakerModeLifecycle() async {
        let vm = MakerModeViewModel()

        #expect(!vm.isRunning)

        await vm.startServer(port: 4025)
        #expect(vm.isRunning)
        #expect(vm.port == 4025)

        await vm.stopServer()
        #expect(!vm.isRunning)

        // Toggle test
        await vm.toggleServer()
        #expect(vm.isRunning)

        await vm.toggleServer()
        #expect(!vm.isRunning)
    }

    @Test("MakerModeViewModel recordSale accumulates sales count, revenue, and history list")
    func testMakerModeRecordSale() {
        let vm = MakerModeViewModel(recipientAddress: "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7")

        vm.recordSale(
            payer: "0x1111111111111111111111111111111111111111",
            amount: "0.01",
            endpoint: "/v1/ask",
            txHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )

        #expect(vm.totalSalesCount == 1)
        #expect(vm.totalRevenueTBNB == "0.01")
        #expect(vm.salesHistory.count == 1)
        #expect(vm.salesHistory[0].endpoint == "/v1/ask")
        #expect(vm.salesHistory[0].amount == "0.01")
        #expect(vm.salesHistory[0].status == "settled")
        #expect(vm.salesHistory[0].formattedPayer == "0x1111...1111")

        // Second sale
        vm.recordSale(
            payer: "0x2222222222222222222222222222222222222222",
            amount: "0.015",
            endpoint: "/v1/audit",
            txHash: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        )

        #expect(vm.totalSalesCount == 2)
        #expect(vm.totalRevenueTBNB == "0.025")
        #expect(vm.salesHistory.count == 2)
    }

    @Test("MakerModeViewModel clearHistory resets history and stats")
    func testMakerModeClearHistory() {
        let vm = MakerModeViewModel()
        vm.recordSale(payer: "0x1111111111111111111111111111111111111111", amount: "0.05", endpoint: "/v1/search")

        #expect(vm.totalSalesCount == 1)
        vm.clearHistory()
        #expect(vm.totalSalesCount == 0)
        #expect(vm.totalRevenueTBNB == "0.00")
        #expect(vm.salesHistory.isEmpty)
    }

    // MARK: - HUD & Wallet Integration Tests

    @Test("NotchHUDViewModel supports Swap and Maker tabs navigation")
    func testNotchHUDNavigationTabs() {
        let hudVM = NotchHUDViewModel()

        hudVM.selectTab(.swap)
        #expect(hudVM.selectedTab == .swap)
        #expect(hudVM.isExpanded)

        hudVM.selectTab(.maker)
        #expect(hudVM.selectedTab == .maker)
        #expect(hudVM.isExpanded)
    }
}
