import Testing
import Foundation
import SwiftUI
@testable import NotchAgentCore

/// In-process fake agent runtime: echoes canned JSON-RPC results for registered methods.
final class FakeRuntimeTransport: @unchecked Sendable {
    let client = JSONRPCClient()
    private var handlers: [String: ([String: Any]) -> Any] = [:]

    init() {
        client.setTransportWriter { [unowned self] data in
            Task {
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"],
                      let method = obj["method"] as? String else { return }
                let params = obj["params"] as? [String: Any] ?? [:]
                let result = self.handlers[method]?(params) ?? ["ok": true]
                let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                let responseData = try JSONSerialization.data(withJSONObject: response)
                self.client.handleIncomingData(responseData + Data([0x0A]))
            }
        }
    }

    func on(_ method: String, _ handler: @escaping ([String: Any]) -> Any) {
        handlers[method] = handler
    }

    func dependencies() -> TransactionDependencies {
        TransactionDependencies(
            signer: nil,
            broadcaster: nil,
            contextProvider: nil,
            passwordStore: nil,
            authenticator: MockTouchIDAuthenticator(shouldSucceed: true),
            rpcClient: client
        )
    }
}

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

    @Test("SwapViewModel fails honestly without the runtime — never fabricates a rate")
    func testSwapQuoteRequiresRuntime() async {
        let vm = SwapViewModel()
        vm.amountIn = "1.0"

        await vm.calculateQuote()

        #expect(vm.currentQuote == nil)
        #expect(vm.errorMessage?.contains("runtime unavailable") == true)
    }

    @Test("SwapViewModel fetches a live quote from wallet.estimateSwapQuote")
    func testSwapViewModelQuoteCalculation() async {
        let runtime = FakeRuntimeTransport()
        runtime.on("wallet.estimateSwapQuote") { _ in
            [
                "tokenIn": "0x0000000000000000000000000000000000000000",
                "tokenOut": "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd",
                "amountIn": "1.0",
                "amountOut": "600.0",
                "amountOutMin": "597.0",
                "slippageTolerancePercent": 0.5,
                "route": [
                    "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd",
                    "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd"
                ],
                "priceImpactPercent": 0.1,
                "executionPrice": "600.0",
                "estimatedGas": "250000"
            ]
        }

        let vm = SwapViewModel(transactionDependencies: runtime.dependencies())
        vm.amountIn = "1.0"
        vm.selectedSlippage = 0.5

        await vm.calculateQuote()

        #expect(vm.currentQuote != nil)
        guard let quote = vm.currentQuote else { return }

        #expect(quote.amountIn == "1.0")
        #expect(quote.amountOut == "600.0")
        #expect(quote.amountOutMin == "597.0")
        #expect(quote.route.count == 2)
        #expect(vm.errorMessage == nil)
    }

    @Test("SwapViewModel reviewSwap builds a real proposal from wallet.buildSwapTx")
    func testSwapViewModelReviewSwap() async {
        let runtime = FakeRuntimeTransport()
        runtime.on("wallet.estimateSwapQuote") { _ in
            [
                "tokenIn": "0x0000000000000000000000000000000000000000",
                "tokenOut": "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd",
                "amountIn": "0.5",
                "amountOut": "300.0",
                "amountOutMin": "298.5",
                "slippageTolerancePercent": 0.5,
                "route": ["0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd", "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd"],
                "priceImpactPercent": 0.0,
                "executionPrice": "600.0",
                "estimatedGas": "250000"
            ]
        }
        runtime.on("wallet.buildSwapTx") { _ in
            [
                "to": "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
                "value": "500000000000000000",
                "data": "0x38ed17390000000000000000000000000000000000000000000000000000000000000000",
                "chainId": 97,
                "gasLimit": "250000"
            ]
        }

        let vm = SwapViewModel(
            userAddress: "0x71C8401301F43F316568234664AC712927C5DD51",
            transactionDependencies: runtime.dependencies()
        )
        vm.amountIn = "0.5"
        await vm.calculateQuote()

        let details = await vm.reviewSwap()
        #expect(details != nil)
        #expect(vm.isShowingConfirmation)
        #expect(details?.operationType == .swap)
        #expect(details?.fromAddress == "0x71C8401301F43F316568234664AC712927C5DD51")
        #expect(details?.slippageTolerance == "0.5%")

        // The signed proposal must be the exact runtime-built payload, not fabricated.
        let proposal = details?.txProposal
        #expect(proposal?.toAddress == "0xD99D1c33F9fC3444f8101754aBC46c52416550D1")
        #expect(proposal?.valueWei == "500000000000000000")
        #expect(proposal?.dataHex?.hasPrefix("0x38ed1739") == true)
        #expect(proposal?.chainId == 97)
        #expect(proposal?.gasLimit == 250_000)
    }

    @Test("SwapViewModel reviewSwap fails gracefully when amount is empty or zero")
    func testSwapViewModelReviewSwapValidation() async {
        let vm = SwapViewModel()
        vm.amountIn = ""
        let details = await vm.reviewSwap()
        #expect(details == nil)
        #expect(!vm.isShowingConfirmation)
        #expect(vm.errorMessage != nil)

        vm.amountIn = "0.00"
        let zeroDetails = await vm.reviewSwap()
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

    @Test("MakerModeViewModel startServer fails honestly without the runtime")
    func testMakerModeNoRuntime() async {
        let vm = MakerModeViewModel()

        await vm.startServer(port: 4025)
        #expect(!vm.isRunning)
        #expect(vm.errorMessage?.contains("runtime unavailable") == true)
    }

    @Test("MakerModeViewModel drives its lifecycle through mpp.startServer / mpp.stopServer")
    func testMakerModeLifecycle() async {
        let runtime = FakeRuntimeTransport()
        runtime.on("mpp.startServer") { params in
            [
                "port": params["port"] as? Int ?? 3402,
                "host": "127.0.0.1",
                "status": "running",
                "running": true
            ] as [String: Any]
        }
        runtime.on("mpp.stopServer") { _ in ["stopped": true] }

        let vm = MakerModeViewModel(rpcClient: runtime.client)

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

    @Test("MakerModeViewModel refreshStatus loads receipts from mpp.getSalesHistory")
    func testMakerModeRefreshStatus() async {
        let runtime = FakeRuntimeTransport()
        runtime.on("mpp.getStatus") { _ in
            [
                "running": true,
                "port": 3402,
                "host": "127.0.0.1",
                "recipient": "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7",
                "chainId": 97,
                "totalSales": 1,
                "totalRevenue": "0.001",
                "uptime": 42,
                "activeEndpoints": ["/api/v1/tools/weather"]
            ]
        }
        runtime.on("mpp.getSalesHistory") { _ in
            [[
                "txHash": "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                "payer": "0x1111111111111111111111111111111111111111",
                "recipient": "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7",
                "amount": "0.001",
                "token": "tBNB",
                "chainId": 97,
                "endpoint": "/api/v1/tools/weather",
                "timestamp": 1_700_000_000_000,
                "blockNumber": 100,
                "status": "settled"
            ]]
        }

        let vm = MakerModeViewModel(rpcClient: runtime.client)
        await vm.refreshStatus()

        #expect(vm.isRunning)
        #expect(vm.totalSalesCount == 1)
        #expect(vm.totalRevenueTBNB == "0.001")
        #expect(vm.salesHistory.count == 1)
        #expect(vm.salesHistory[0].endpoint == "/api/v1/tools/weather")
        #expect(vm.activeEndpoints == ["/api/v1/tools/weather"])
    }

    @Test("MakerModeViewModel recordSale only accepts real on-chain hashes")
    func testMakerModeRecordSale() {
        let vm = MakerModeViewModel(recipientAddress: "0x89205A3A3b2A69De6Dbf7f01ED13B2108B2c43e7")

        // Without a txHash the sale is rejected — no fabricated receipts.
        vm.recordSale(payer: "0x1111111111111111111111111111111111111111", amount: "0.01", endpoint: "/v1/ask")
        #expect(vm.salesHistory.isEmpty)
        #expect(vm.totalSalesCount == 0)

        vm.recordSale(
            payer: "0x1111111111111111111111111111111111111111",
            amount: "0.01",
            endpoint: "/v1/ask",
            txHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        #expect(vm.totalSalesCount == 1)
        #expect(vm.salesHistory.count == 1)
        #expect(vm.salesHistory[0].formattedPayer == "0x1111...1111")
    }

    @Test("MakerModeViewModel clearHistory resets history and stats")
    func testMakerModeClearHistory() {
        let vm = MakerModeViewModel()
        vm.recordSale(
            payer: "0x1111111111111111111111111111111111111111",
            amount: "0.05",
            endpoint: "/v1/search",
            txHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )

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
