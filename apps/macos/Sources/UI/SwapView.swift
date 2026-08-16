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

    public init(
        userAddress: String = "0x71C8401301F43F316568234664AC712927C5DD51",
        routerAddress: String = "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
        tokens: [SwapToken] = SwapToken.defaultTokens,
        chainId: Int = 97,
        networkName: String = "BSC Testnet"
    ) {
        let resolvedTokens = tokens.isEmpty ? SwapToken.defaultTokens : tokens
        self.availableTokens = resolvedTokens
        self.tokenIn = resolvedTokens.first ?? SwapToken.defaultTokens[0]
        self.tokenOut = resolvedTokens.count > 1 ? resolvedTokens[1] : SwapToken.defaultTokens[1]
        self.userAddress = userAddress
        self.routerAddress = routerAddress
        self.chainId = chainId
        self.networkName = networkName
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

    /// Calculates dynamic swap quote and minimum received amount based on slippage and token multipliers.
    public func calculateQuote() async {
        let trimmed = amountIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inVal = Double(trimmed), inVal > 0 else {
            self.currentQuote = nil
            self.errorMessage = nil
            return
        }

        self.isCalculatingQuote = true
        self.errorMessage = nil

        // Simulate fast DEX pricing calculation with ERC-8056 scaling logic
        let rate = getExchangeRate(from: tokenIn, to: tokenOut)
        let outVal = inVal * rate

        // Slippage deduction: amountOutMin = amountOut * (1 - slippage / 100)
        let slippageFrac = selectedSlippage / 100.0
        let minVal = max(0, outVal * (1.0 - slippageFrac))

        let outFormatted = String(format: "%.4f", outVal)
        let minFormatted = String(format: "%.4f", minVal)
        let priceFormatted = "1 \(tokenIn.symbol) ≈ \(String(format: "%.4f", rate)) \(tokenOut.symbol)"

        // Build route path
        var routePath: [String] = [tokenIn.symbol]
        if tokenIn.symbol != "tBNB" && tokenOut.symbol != "tBNB" {
            routePath.append("WBNB")
        }
        routePath.append(tokenOut.symbol)

        self.currentQuote = SwapQuote(
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: trimmed,
            amountOut: outFormatted,
            amountOutMin: minFormatted,
            slippagePercent: selectedSlippage,
            route: routePath,
            priceImpactPercent: 0.05,
            executionPrice: priceFormatted,
            estimatedGasTBNB: "0.00085"
        )

        self.isCalculatingQuote = false
    }

    /// Triggers review swap modal requesting manual Touch ID signature for User Wallet.
    @discardableResult
    public func reviewSwap() -> TransactionConfirmationDetails? {
        let trimmed = amountIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inVal = Double(trimmed), inVal > 0 else {
            self.errorMessage = "Please enter a valid swap amount greater than zero."
            self.isShowingConfirmation = false
            return nil
        }

        guard let quote = currentQuote else {
            self.errorMessage = "No active quote available. Please calculate quote first."
            self.isShowingConfirmation = false
            return nil
        }

        let slippageString = String(format: "%.1f%%", selectedSlippage)
        let details = TransactionConfirmationDetails(
            operationType: .swap,
            title: "Swap on PancakeSwap",
            fromAddress: userAddress,
            toAddress: routerAddress,
            assetSymbol: tokenIn.symbol,
            amount: trimmed,
            estimatedGasTBNB: quote.estimatedGasTBNB,
            estimatedGasUSD: "$0.35",
            networkName: networkName,
            chainId: chainId,
            slippageTolerance: slippageString,
            dataPayloadHex: "0x38ed1739\(tokenIn.symbol.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? "")"
        )

        self.pendingConfirmation = details
        self.isShowingConfirmation = true
        self.errorMessage = nil
        return details
    }

    // MARK: - Private Price Modeling

    private func getExchangeRate(from: SwapToken, to: SwapToken) -> Double {
        // Base dollar estimates for testnet tokens
        let usdRate: (SwapToken) -> Double = { token in
            switch token.symbol {
            case "tBNB": return 600.0
            case "USDT", "BUSD": return 1.0
            case "CAKE": return 2.5
            case "sBNB":
                let multiplier = Double(token.multiplier ?? "1.0") ?? 1.0
                return 600.0 / multiplier
            default: return 1.0
            }
        }

        let fromUsd = usdRate(from)
        let toUsd = usdRate(to)
        guard toUsd > 0 else { return 1.0 }
        return fromUsd / toUsd
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
                TransactionConfirmationModal(
                    viewModel: TransactionConfirmationViewModel(details: details)
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
            viewModel.reviewSwap()
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
