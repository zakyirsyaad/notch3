import SwiftUI
import AppKit

// MARK: - Swap Token Model

/// Token entity supported within PancakeSwap swap routing on BNB Chain.
public struct SwapToken: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let symbol: String
    public let name: String
    public let address: String
    public let decimals: Int
    public let isERC8056: Bool
    public let multiplier: String?
    public let iconSystemName: String

    public init(
        id: String? = nil,
        symbol: String,
        name: String,
        address: String,
        decimals: Int = 18,
        isERC8056: Bool = false,
        multiplier: String? = nil,
        iconSystemName: String = "circle.circle.fill"
    ) {
        self.id = id ?? address
        self.symbol = symbol
        self.name = name
        self.address = address
        self.decimals = decimals
        self.isERC8056 = isERC8056
        self.multiplier = multiplier
        self.iconSystemName = iconSystemName
    }

    public var formattedAddress: String {
        guard address.count >= 12 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    public static let defaultTokens: [SwapToken] = [
        SwapToken(
            symbol: "tBNB",
            name: "BNB Native (Testnet)",
            address: "0x0000000000000000000000000000000000000000",
            decimals: 18,
            isERC8056: false,
            multiplier: nil,
            iconSystemName: "circle.grid.cross.fill"
        ),
        SwapToken(
            symbol: "USDT",
            name: "Tether USD",
            address: "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd",
            decimals: 18,
            isERC8056: false,
            multiplier: nil,
            iconSystemName: "dollarsign.circle.fill"
        ),
        SwapToken(
            symbol: "BUSD",
            name: "Binance USD",
            address: "0xaB1a4d4f1D656d2450692D237fdD6C7f9146e814",
            decimals: 18,
            isERC8056: false,
            multiplier: nil,
            iconSystemName: "b.circle.fill"
        ),
        SwapToken(
            symbol: "CAKE",
            name: "PancakeSwap Token",
            address: "0xFa60D973F7642B748046464e165A65B7323b0C03",
            decimals: 18,
            isERC8056: false,
            multiplier: nil,
            iconSystemName: "birthday.cake.fill"
        ),
        SwapToken(
            symbol: "sBNB",
            name: "Scaled BNB (ERC-8056)",
            address: "0x8056000000000000000000000000000000008056",
            decimals: 18,
            isERC8056: true,
            multiplier: "10.0",
            iconSystemName: "sparkles.rectangle.stack.fill"
        )
    ]
}

// MARK: - Swap Quote Model

/// Calculated quote and routing details for an on-chain swap.
public struct SwapQuote: Equatable, Sendable {
    public let tokenIn: SwapToken
    public let tokenOut: SwapToken
    public let amountIn: String
    public let amountOut: String
    public let amountOutMin: String
    public let slippagePercent: Double
    public let route: [String]
    public let priceImpactPercent: Double
    public let executionPrice: String
    public let estimatedGasTBNB: String

    public init(
        tokenIn: SwapToken,
        tokenOut: SwapToken,
        amountIn: String,
        amountOut: String,
        amountOutMin: String,
        slippagePercent: Double,
        route: [String],
        priceImpactPercent: Double = 0.05,
        executionPrice: String = "",
        estimatedGasTBNB: String = "0.00085"
    ) {
        self.tokenIn = tokenIn
        self.tokenOut = tokenOut
        self.amountIn = amountIn
        self.amountOut = amountOut
        self.amountOutMin = amountOutMin
        self.slippagePercent = slippagePercent
        self.route = route
        self.priceImpactPercent = priceImpactPercent
        self.executionPrice = executionPrice.isEmpty ? "1 \(tokenIn.symbol) ≈ \(amountOut) \(tokenOut.symbol)" : executionPrice
        self.estimatedGasTBNB = estimatedGasTBNB
    }
}

// MARK: - Swap View Model

/// View model driving the PancakeSwap DEX swap interface, live quotes, and confirmation triggers.
@MainActor
public final class SwapViewModel: ObservableObject {
    @Published public var tokenIn: SwapToken
    @Published public var tokenOut: SwapToken
    @Published public var amountIn: String = ""
    @Published public var selectedSlippage: Double = 0.5
    @Published public var customSlippageInput: String = ""
    @Published public var isCustomSlippage: Bool = false
    @Published public var currentQuote: SwapQuote? = nil
    @Published public var isCalculatingQuote: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var isShowingConfirmation: Bool = false
    @Published public var pendingConfirmation: TransactionConfirmationDetails? = nil
    @Published public var userAddress: String
    @Published public var routerAddress: String = "0xD99D1c33F9fC3444f8101754aBC46c52416550D1"
    @Published public var chainId: Int = 97
    @Published public var networkName: String = "BSC Testnet"
    @Published public var availableTokens: [SwapToken]

    public let slippagePresets: [Double] = [0.1, 0.5, 1.0]

    /// Live pipeline for real quotes and transaction building. When nil (previews,
    /// tests) quotes fail honestly instead of being fabricated from hardcoded prices.
    public var transactionDependencies: TransactionDependencies? = nil

    public init(
        userAddress: String = "0x71C8401301F43F316568234664AC712927C5DD51",
        routerAddress: String = "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
        tokens: [SwapToken] = SwapToken.defaultTokens,
        chainId: Int = 97,
        networkName: String = "BSC Testnet",
        transactionDependencies: TransactionDependencies? = nil
    ) {
        let resolvedTokens = tokens.isEmpty ? SwapToken.defaultTokens : tokens
        self.availableTokens = resolvedTokens
        self.tokenIn = resolvedTokens.first ?? SwapToken.defaultTokens[0]
        self.tokenOut = resolvedTokens.count > 1 ? resolvedTokens[1] : SwapToken.defaultTokens[1]
        self.userAddress = userAddress
        self.routerAddress = routerAddress
        self.chainId = chainId
        self.networkName = networkName
        self.transactionDependencies = transactionDependencies
    }

    // MARK: - User Actions

    /// Inverts the Token In and Token Out selections.
    public func switchTokens() {
        let oldIn = tokenIn
        tokenIn = tokenOut
        tokenOut = oldIn
        Task {
            await calculateQuote()
        }
    }

    /// Selects a new Token In.
    public func selectTokenIn(_ token: SwapToken) {
        guard token.address != tokenIn.address else { return }
        if token.address == tokenOut.address {
            switchTokens()
            return
        }
        tokenIn = token
        Task {
            await calculateQuote()
        }
    }

    /// Selects a new Token Out.
    public func selectTokenOut(_ token: SwapToken) {
        guard token.address != tokenOut.address else { return }
        if token.address == tokenIn.address {
            switchTokens()
            return
        }
        tokenOut = token
        Task {
            await calculateQuote()
        }
    }

    /// Updates slippage from predefined presets.
    public func setSlippage(_ percent: Double) {
        self.selectedSlippage = percent
        self.isCustomSlippage = false
        self.customSlippageInput = ""
        Task {
            await calculateQuote()
        }
    }

    /// Sets custom slippage percentage with validation.
    public func setCustomSlippage(_ input: String) {
        self.customSlippageInput = input
        guard let value = Double(input), value >= 0.01, value <= 50.0 else {
            return
        }
        self.selectedSlippage = value
        self.isCustomSlippage = true
        Task {
            await calculateQuote()
        }
    }

    /// True for zero-address / sentinel native-asset representations.
    static func isNativeTokenAddress(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        return a.isEmpty
            || a == "0x0000000000000000000000000000000000000000"
            || a == "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }

    /// Fetches a live quote from the runtime (`wallet.estimateSwapQuote`).
    /// Without a runtime connection this reports an error — never a fabricated rate.
    public func calculateQuote() async {
        let trimmed = amountIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Double(trimmed) != nil, Double(trimmed)! > 0 else {
            self.currentQuote = nil
            self.errorMessage = nil
            return
        }

        guard let client = transactionDependencies?.rpcClient else {
            self.currentQuote = nil
            self.errorMessage = "Agent runtime unavailable — live quotes required."
            return
        }

        self.isCalculatingQuote = true
        self.errorMessage = nil
        defer { self.isCalculatingQuote = false }

        do {
            let params = SwapQuoteParams(
                tokenIn: tokenIn.address,
                tokenOut: tokenOut.address,
                amountIn: trimmed,
                slippageTolerancePercent: selectedSlippage,
                route: nil
            )
            let result: SwapQuoteResult = try await client.sendRequest(
                method: "wallet.estimateSwapQuote",
                params: params
            )

            self.currentQuote = SwapQuote(
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: result.amountIn,
                amountOut: result.amountOut,
                amountOutMin: result.amountOutMin,
                slippagePercent: result.slippageTolerancePercent,
                route: routeSymbols(fromAddresses: result.route),
                priceImpactPercent: result.priceImpactPercent ?? 0,
                executionPrice: result.executionPrice.map { price in
                    "1 \(tokenIn.symbol) ≈ \(price) \(tokenOut.symbol)"
                } ?? "",
                estimatedGasTBNB: result.estimatedGas ?? "—"
            )
        } catch {
            self.currentQuote = nil
            self.errorMessage = "Quote failed: \(error.localizedDescription)"
        }
    }

    private func routeSymbols(fromAddresses route: [String]) -> [String] {
        let byAddress = Dictionary(uniqueKeysWithValues: availableTokens.map { ($0.address.lowercased(), $0.symbol) })
        return route.map { byAddress[$0.lowercased()] ?? String($0.suffix(6)) }
    }

    /// Builds the real unsigned swap transaction (`wallet.buildSwapTx`) and opens the
    /// confirmation modal with an exact proposal. Fails honestly when the runtime is
    /// unreachable — the confirmation never displays fabricated economics.
    @discardableResult
    public func reviewSwap() async -> TransactionConfirmationDetails? {
        let trimmed = amountIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Double(trimmed) != nil, Double(trimmed)! > 0 else {
            self.errorMessage = "Please enter a valid swap amount greater than zero."
            self.isShowingConfirmation = false
            return nil
        }

        guard let quote = currentQuote else {
            self.errorMessage = "No active quote available. Please calculate quote first."
            self.isShowingConfirmation = false
            return nil
        }

        guard let client = transactionDependencies?.rpcClient else {
            self.errorMessage = "Agent runtime unavailable — cannot build swap transaction."
            self.isShowingConfirmation = false
            return nil
        }

        do {
            // ERC-20 input requires a router allowance — approve first when missing.
            if !Self.isNativeTokenAddress(tokenIn.address) {
                struct AllowanceQuery: Codable, Sendable {
                    let token: String
                    let owner: String
                }
                let allowance: AllowanceResult = try await client.sendRequest(
                    method: "wallet.getAllowance",
                    params: AllowanceQuery(token: tokenIn.address, owner: userAddress)
                )
                let requiredWei = WeiConverter.wei(fromUIAmount: quote.amountIn, decimals: tokenIn.decimals) ?? "0"
                let sufficient = WeiConverter.compare(allowance.allowanceWei, requiredWei).map { $0 >= 0 } ?? false

                if !sufficient {
                    struct ApproveParams: Codable, Sendable {
                        let token: String
                        let chainId: Int
                    }
                    let payload: UnsignedTransactionPayload = try await client.sendRequest(
                        method: "wallet.buildApproveTx",
                        params: ApproveParams(token: tokenIn.address, chainId: chainId)
                    )
                    let approveDetails = TransactionConfirmationDetails(
                        operationType: .contractCall,
                        title: "Approve \(tokenIn.symbol) for PancakeSwap",
                        fromAddress: userAddress,
                        toAddress: payload.to,
                        assetSymbol: tokenIn.symbol,
                        amount: "Unlimited",
                        estimatedGasTBNB: "0.00010",
                        networkName: networkName,
                        chainId: payload.chainId ?? chainId,
                        dataPayloadHex: payload.data,
                        txProposal: TransactionProposal(
                            toAddress: payload.to,
                            valueWei: payload.value,
                            dataHex: payload.data,
                            chainId: payload.chainId ?? chainId,
                            gasLimit: UInt64(payload.gasLimit ?? "") ?? 60_000
                        )
                    )
                    self.pendingConfirmation = approveDetails
                    self.isShowingConfirmation = true
                    self.errorMessage = "Router allowance missing. Approve once, then press Review & Sign again to execute the swap."
                    return approveDetails
                }
            }

            let params = BuildSwapParams(
                tokenIn: tokenIn.address,
                tokenOut: tokenOut.address,
                amountIn: quote.amountIn,
                amountOutMin: quote.amountOutMin,
                recipient: userAddress,
                deadline: nil,
                slippageTolerancePercent: selectedSlippage,
                route: nil,
                chainId: chainId
            )
            let payload: UnsignedTransactionPayload = try await client.sendRequest(
                method: "wallet.buildSwapTx",
                params: params
            )

            let slippageString = String(format: "%.1f%%", selectedSlippage)
            let details = TransactionConfirmationDetails(
                operationType: .swap,
                title: "Swap on PancakeSwap",
                fromAddress: userAddress,
                toAddress: payload.to,
                assetSymbol: tokenIn.symbol,
                amount: quote.amountIn,
                estimatedGasTBNB: quote.estimatedGasTBNB,
                networkName: networkName,
                chainId: payload.chainId ?? chainId,
                slippageTolerance: slippageString,
                dataPayloadHex: payload.data,
                txProposal: TransactionProposal(
                    toAddress: payload.to,
                    valueWei: payload.value,
                    dataHex: payload.data,
                    chainId: payload.chainId ?? chainId,
                    gasLimit: UInt64(payload.gasLimit ?? "") ?? 250_000
                )
            )

            self.pendingConfirmation = details
            self.isShowingConfirmation = true
            self.errorMessage = nil
            return details
        } catch {
            self.errorMessage = "Building swap failed: \(error.localizedDescription)"
            self.isShowingConfirmation = false
            return nil
        }
    }
}

// MARK: - Swap View

/// SwiftUI View for the PancakeSwap DEX swap interface with ERC-8056 scaling and Touch ID integration.
public struct SwapView: View {
    @ObservedObject public var viewModel: SwapViewModel

    public init(viewModel: SwapViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            // MARK: - Header
            swapHeader

            // MARK: - Token In Card
            tokenInCard

            // MARK: - Swap Flip Button
            swapFlipButton

            // MARK: - Token Out Card
            tokenOutCard

            // MARK: - Slippage Tolerance Selector
            slippageSelectorSection

            // MARK: - Quote Details (if available)
            if let quote = viewModel.currentQuote {
                quoteDetailsCard(quote: quote)
            }

            // MARK: - Error Message
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 4)
            }

            // MARK: - Action Button
            reviewSwapButton
        }
        .padding(14)
        .background(Color.clear)
        .sheet(isPresented: $viewModel.isShowingConfirmation) {
            if let details = viewModel.pendingConfirmation {
                let deps = viewModel.transactionDependencies
                TransactionConfirmationModal(
                    viewModel: TransactionConfirmationViewModel(
                        details: details,
                        authenticator: deps?.authenticator ?? TouchIDAuthenticator(),
                        signer: deps?.signer,
                        broadcaster: deps?.broadcaster,
                        contextProvider: deps?.contextProvider,
                        passwordStore: deps?.passwordStore
                    )
                )
            }
        }
    }

    // MARK: - Header
    private var swapHeader: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14, weight: .bold))

                Text("PancakeSwap DEX")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Spacer()

            // Network Indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 5, height: 5)
                Text(viewModel.networkName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.yellow)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.yellow.opacity(0.12)))
        }
    }

    // MARK: - Token In Card
    private var tokenInCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("You Pay")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if viewModel.tokenIn.isERC8056 {
                    Text("ERC-8056 Scaled")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.2)))
                }
            }

            HStack(spacing: 8) {
                // Token Selector Menu
                Menu {
                    ForEach(viewModel.availableTokens) { token in
                        Button(action: {
                            viewModel.selectTokenIn(token)
                        }) {
                            HStack {
                                Text(token.symbol)
                                Text("(\(token.name))")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.tokenIn.iconSystemName)
                            .foregroundColor(.yellow)
                            .font(.system(size: 12))
                        Text(viewModel.tokenIn.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    )
                }
                .menuStyle(.borderlessButton)

                // Amount Text Field
                TextField("0.0", text: $viewModel.amountIn)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: viewModel.amountIn) { _, _ in
                        Task {
                            await viewModel.calculateQuote()
                        }
                    }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Flip Button
    private var swapFlipButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.switchTokens()
            }
        }) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.orange.opacity(0.25))
                        .overlay(
                            Circle()
                                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Token Out Card
    private var tokenOutCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("You Receive (Est.)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if viewModel.isCalculatingQuote {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }

            HStack(spacing: 8) {
                // Token Selector Menu
                Menu {
                    ForEach(viewModel.availableTokens) { token in
                        Button(action: {
                            viewModel.selectTokenOut(token)
                        }) {
                            HStack {
                                Text(token.symbol)
                                Text("(\(token.name))")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.tokenOut.iconSystemName)
                            .foregroundColor(.cyan)
                            .font(.system(size: 12))
                        Text(viewModel.tokenOut.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    )
                }
                .menuStyle(.borderlessButton)

                Spacer()

                // Calculated Output Amount
                Text(viewModel.currentQuote?.amountOut ?? "0.0")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.currentQuote != nil ? Color.green : .white.opacity(0.5))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Slippage Selector
    private var slippageSelectorSection: some View {
        HStack(spacing: 6) {
            Text("Slippage:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            ForEach(viewModel.slippagePresets, id: \.self) { preset in
                Button(action: {
                    viewModel.setSlippage(preset)
                }) {
                    Text("\(String(format: "%.1f", preset))%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(viewModel.selectedSlippage == preset && !viewModel.isCustomSlippage ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(viewModel.selectedSlippage == preset && !viewModel.isCustomSlippage ? Color.orange.opacity(0.3) : Color.white.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Custom Slippage Field
            HStack(spacing: 2) {
                TextField("Custom", text: $viewModel.customSlippageInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 42)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: viewModel.customSlippageInput) { _, val in
                        viewModel.setCustomSlippage(val)
                    }
                Text("%")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(viewModel.isCustomSlippage ? Color.orange.opacity(0.3) : Color.white.opacity(0.05))
            )
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Quote Details Card
    private func quoteDetailsCard(quote: SwapQuote) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Rate")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(quote.executionPrice)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            HStack {
                Text("Min. Received")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text("\(quote.amountOutMin) \(quote.tokenOut.symbol)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            HStack {
                Text("Routing")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(quote.route.indices, id: \.self) { idx in
                        Text(quote.route[idx])
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.cyan)
                        if idx < quote.route.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
            }

            HStack {
                Text("Est. Network Gas")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text("\(quote.estimatedGasTBNB) tBNB")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.3))
        )
    }

    // MARK: - Review Swap Button
    private var reviewSwapButton: some View {
        Button(action: {
            Task { await viewModel.reviewSwap() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "touchid")
                    .font(.system(size: 12, weight: .bold))
                Text("Review & Sign Swap")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentQuote == nil || viewModel.amountIn.isEmpty)
        .opacity(viewModel.currentQuote == nil || viewModel.amountIn.isEmpty ? 0.5 : 1.0)
    }
}
