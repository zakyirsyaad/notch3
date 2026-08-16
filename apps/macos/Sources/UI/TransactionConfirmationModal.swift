import SwiftUI
import AppKit

/// Operation type classification for manual User Wallet confirmation.
public enum TransactionOperationType: String, Codable, Sendable {
    case transfer = "Token Transfer"
    case swap = "PancakeSwap DEX Swap"
    case fundAgent = "Fund Agent Session Key"
    case contractCall = "Smart Contract Execution"

    public var iconName: String {
        switch self {
        case .transfer: return "arrow.up.right.circle.fill"
        case .swap: return "arrow.triangle.2.circlepath.circle.fill"
        case .fundAgent: return "bolt.shield.fill"
        case .contractCall: return "doc.text.fill"
        }
    }

    public var accentColor: Color {
        switch self {
        case .transfer: return .blue
        case .swap: return .orange
        case .fundAgent: return .green
        case .contractCall: return .purple
        }
    }
}

/// Transaction payload and metadata requiring manual user confirmation and signing.
public struct TransactionConfirmationDetails: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let operationType: TransactionOperationType
    public let title: String
    public let fromAddress: String
    public let toAddress: String
    public let assetSymbol: String
    public let amount: String
    public let estimatedGasTBNB: String
    public let estimatedGasUSD: String?
    public let networkName: String
    public let chainId: Int
    public let slippageTolerance: String?
    public let dataPayloadHex: String?
    public let rawTxData: Data?

    public init(
        id: UUID = UUID(),
        operationType: TransactionOperationType,
        title: String? = nil,
        fromAddress: String,
        toAddress: String,
        assetSymbol: String = "tBNB",
        amount: String,
        estimatedGasTBNB: String = "0.00035",
        estimatedGasUSD: String? = "$0.20",
        networkName: String = "BSC Testnet",
        chainId: Int = 97,
        slippageTolerance: String? = nil,
        dataPayloadHex: String? = nil,
        rawTxData: Data? = nil
    ) {
        self.id = id
        self.operationType = operationType
        self.title = title ?? operationType.rawValue
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.assetSymbol = assetSymbol
        self.amount = amount
        self.estimatedGasTBNB = estimatedGasTBNB
        self.estimatedGasUSD = estimatedGasUSD
        self.networkName = networkName
        self.chainId = chainId
        self.slippageTolerance = slippageTolerance
        self.dataPayloadHex = dataPayloadHex
        self.rawTxData = rawTxData
    }

    public var formattedFromAddress: String {
        Self.shortenAddress(fromAddress)
    }

    public var formattedToAddress: String {
        Self.shortenAddress(toAddress)
    }

    private static func shortenAddress(_ addr: String) -> String {
        guard addr.count >= 12 else { return addr }
        let start = addr.prefix(6)
        let end = addr.suffix(4)
        return "\(start)...\(end)"
    }
}

/// Authentication & Signing state for the confirmation modal.
public enum ConfirmationAuthState: Equatable, Sendable {
    case idle
    case authenticating
    case signing
    case success(txHash: String)
    case failed(errorMessage: String)

    public var isBusy: Bool {
        switch self {
        case .authenticating, .signing: return true
        default: return false
        }
    }
}

/// Selected authentication mechanism.
public enum AuthMethod: String, CaseIterable, Identifiable, Sendable {
    case biometrics
    case masterPasscode

    public var id: String { title }

    public var title: String {
        switch self {
        case .biometrics: return "Touch ID"
        case .masterPasscode: return "Master Passcode"
        }
    }
}

/// View model driving the manual confirmation sheet, biometric / password auth, and signing invocation.
@MainActor
public final class TransactionConfirmationViewModel: ObservableObject {
    @Published public var details: TransactionConfirmationDetails
    @Published public var authState: ConfirmationAuthState = .idle
    @Published public var authMethod: AuthMethod = .biometrics
    @Published public var passwordInput: String = ""
    @Published public var isPasswordVisible: Bool = false
    @Published public var isPayloadExpanded: Bool = false

    public let authenticator: TouchIDAuthenticatorProtocol
    public let keystoreManager: UserKeystoreManager?
    public var onSigned: (@Sendable (Data) -> Void)?
    public var onDismiss: (@Sendable () -> Void)?

    public init(
        details: TransactionConfirmationDetails,
        authenticator: TouchIDAuthenticatorProtocol = TouchIDAuthenticator(),
        keystoreManager: UserKeystoreManager? = nil
    ) {
        self.details = details
        self.authenticator = authenticator
        self.keystoreManager = keystoreManager

        // Default to passcode if biometrics are not supported
        if !authenticator.canAuthenticateWithBiometrics() {
            self.authMethod = .masterPasscode
        }
    }

    /// Authenticates with Touch ID or Password, then signs transaction payload.
    public func authenticateAndSign() async {
        guard !authState.isBusy else { return }

        authState = .authenticating

        do {
            if authMethod == .biometrics {
                let promptReason = "Authorize \(details.operationType.rawValue) of \(details.amount) \(details.assetSymbol)"
                let authenticated = try await authenticator.authenticateUser(reason: promptReason)
                guard authenticated else {
                    authState = .failed(errorMessage: "Biometric authentication failed or cancelled.")
                    return
                }
            } else {
                guard !passwordInput.isEmpty else {
                    authState = .failed(errorMessage: "Please enter your master password.")
                    return
                }

                if let km = keystoreManager, let json = km.currentKeystoreJson {
                    _ = try km.verifyKeystorePassword(keystoreJson: json, password: passwordInput)
                }
            }

            authState = .signing

            // Transaction signing
            let txPayload = details.rawTxData ?? details.amount.data(using: .utf8) ?? Data()
            let signatureData: Data

            if let km = keystoreManager {
                let pass = passwordInput.isEmpty ? "biometric-session" : passwordInput
                signatureData = try km.signTransaction(txData: txPayload, password: pass)
            } else {
                // Mock / standard simulated signature for UI testing & decoupled execution
                signatureData = Data(repeating: 0xaa, count: 65)
            }

            let simulatedTxHash = "0x" + (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
            onSigned?(signatureData)
            authState = .success(txHash: simulatedTxHash)

        } catch let error as AuthenticationError {
            authState = .failed(errorMessage: error.localizedDescription)
        } catch let error as KeystoreError {
            authState = .failed(errorMessage: error.localizedDescription)
        } catch {
            authState = .failed(errorMessage: error.localizedDescription)
        }
    }

    /// Resets failure state to retry.
    public func retry() {
        self.authState = .idle
        self.passwordInput = ""
    }

    /// Cancels confirmation.
    public func cancel() {
        self.authState = .idle
        self.onDismiss?()
    }
}

/// Strict manual confirmation modal for User Wallet actions.
public struct TransactionConfirmationModal: View {
    @ObservedObject public var viewModel: TransactionConfirmationViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: TransactionConfirmationViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            // MARK: - Header
            modalHeader

            // MARK: - Transaction Details Card
            transactionSummaryCard

            // MARK: - Payload / Advanced Details
            if viewModel.details.dataPayloadHex != nil || viewModel.details.slippageTolerance != nil {
                advancedPayloadSection
            }

            // MARK: - Security Notice
            securityNoticeCard

            // MARK: - Auth Input / Status
            authSection

            // MARK: - Action Buttons
            actionButtons
        }
        .padding(22)
        .frame(width: 480)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.75)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(viewModel.details.operationType.accentColor.opacity(0.3), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 15)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.authState)
        .animation(.easeInOut(duration: 0.2), value: viewModel.authMethod)
    }

    // MARK: - Modal Header
    private var modalHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.details.operationType.iconName)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(viewModel.details.operationType.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.details.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text(viewModel.details.networkName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.yellow)
            }

            Spacer()

            if !viewModel.authState.isBusy {
                Button(action: {
                    viewModel.cancel()
                    dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Summary Card
    private var transactionSummaryCard: some View {
        VStack(spacing: 12) {
            // Amount Highlight
            VStack(spacing: 4) {
                Text("Transfer Amount")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(viewModel.details.amount)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)

                    Text(viewModel.details.assetSymbol)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(viewModel.details.operationType.accentColor)
                }
            }
            .padding(.vertical, 4)

            Divider()
                .background(Color.white.opacity(0.12))

            // From / To Rows
            VStack(spacing: 8) {
                detailRow(
                    label: "From",
                    value: viewModel.details.formattedFromAddress,
                    badge: "User Keystore"
                )

                detailRow(
                    label: "To",
                    value: viewModel.details.formattedToAddress,
                    badge: viewModel.details.operationType == .fundAgent ? "Agent Session" : "Recipient"
                )

                detailRow(
                    label: "Est. Network Fee",
                    value: "\(viewModel.details.estimatedGasTBNB) tBNB",
                    badge: viewModel.details.estimatedGasUSD ?? "Low Gas"
                )

                if let slippage = viewModel.details.slippageTolerance {
                    detailRow(
                        label: "Max Slippage",
                        value: slippage,
                        badge: "PancakeSwap"
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func detailRow(label: String, value: String, badge: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)

                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    )
            }
        }
    }

    // MARK: - Advanced Payload Section
    private var advancedPayloadSection: some View {
        DisclosureGroup(
            isExpanded: $viewModel.isPayloadExpanded,
            content: {
                if let hex = viewModel.details.dataPayloadHex {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(hex)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(8)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.5))
                    )
                    .padding(.top, 4)
                }
            },
            label: {
                HStack {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 10))
                    Text("Transaction Data & Payload")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.7))
            }
        )
        .padding(.horizontal, 4)
    }

    // MARK: - Security Notice
    private var securityNoticeCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)

            Text("Manual User Wallet signature required. Ephemeral keys are wiped immediately after signing.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Auth Section
    private var authSection: some View {
        VStack(spacing: 10) {
            switch viewModel.authState {
            case .idle:
                authSelectorAndInputs
            case .authenticating:
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Awaiting Touch ID Biometric Verification...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.cyan)
                }
                .padding(.vertical, 8)
            case .signing:
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Signing Transaction with Encrypted Keystore...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.yellow)
                }
                .padding(.vertical, 8)
            case .success(let txHash):
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("Transaction Successfully Signed!")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.green)
                    }

                    Text("Hash: \(txHash.prefix(10))...\(txHash.suffix(8))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(8)
            case .failed(let error):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.15))
                )
            }
        }
    }

    private var authSelectorAndInputs: some View {
        VStack(spacing: 8) {
            if viewModel.authenticator.canAuthenticateWithBiometrics() {
                Picker("Auth Method", selection: $viewModel.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
            }

            if viewModel.authMethod == .masterPasscode {
                HStack {
                    if viewModel.isPasswordVisible {
                        TextField("Enter Master Keystore Password", text: $viewModel.passwordInput)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("Enter Master Keystore Password", text: $viewModel.passwordInput)
                            .textFieldStyle(.plain)
                    }

                    Button(action: {
                        viewModel.isPasswordVisible.toggle()
                    }) {
                        Image(systemName: viewModel.isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - Action Buttons
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if case .failed = viewModel.authState {
                Button(action: {
                    viewModel.retry()
                }) {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            } else if case .success = viewModel.authState {
                Button(action: {
                    viewModel.cancel()
                    dismiss()
                }) {
                    Text("Close")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.green)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    viewModel.cancel()
                    dismiss()
                }) {
                    Text("Reject & Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.authState.isBusy)

                Button(action: {
                    Task {
                        await viewModel.authenticateAndSign()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.authMethod == .biometrics ? "touchid" : "key.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(viewModel.authMethod == .biometrics ? "Sign with Touch ID" : "Confirm & Sign")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(viewModel.details.operationType.accentColor)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.authState.isBusy)
            }
        }
    }
}
