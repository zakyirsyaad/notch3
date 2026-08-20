import SwiftUI
import AppKit

public enum WalletOnboardingMode: String, CaseIterable, Sendable {
    case importExisting
    case createNew

    public var title: String {
        switch self {
        case .importExisting: return "Import existing"
        case .createNew: return "Create new"
        }
    }
}

/// View model for the two-wallet setup flow.
///
/// The User Wallet is encrypted and persisted first. The app then provisions
/// the Agent Wallet through the runtime and persists its encrypted keystore and
/// passphrase. Setup is considered complete only after both records exist.
@MainActor
public final class WalletOnboardingViewModel: ObservableObject {
    @Published public var mode: WalletOnboardingMode = .importExisting
    @Published public var mnemonicInput: String = ""
    @Published public var generatedMnemonic: String? = nil
    @Published public var passwordInput: String = ""
    @Published public var confirmPassword: String = ""
    @Published public var isMnemonicVisible: Bool = false
    @Published public var hasConfirmedBackup: Bool = false
    @Published public var isImporting: Bool = false
    @Published public var isProvisioningAgent: Bool = false
    @Published public var isAgentWalletReady: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var importedAddress: String? = nil

    public let keystoreManager: UserKeystoreManager
    public let passwordStore: KeystorePasswordStore

    /// Called with the User Wallet address after its encrypted record is saved.
    /// The app delegate uses this hook to create and persist the Agent Wallet.
    public var onSetupComplete: ((String) async throws -> Void)?

    /// Compatibility callback used by the HUD to refresh wallet-dependent views.
    public var onImportComplete: (@Sendable (String) -> Void)?

    public init(
        keystoreManager: UserKeystoreManager,
        passwordStore: KeystorePasswordStore
    ) {
        self.keystoreManager = keystoreManager
        self.passwordStore = passwordStore
        self.isAgentWalletReady = passwordStore.agentWalletSetupComplete
    }

    public var wordCount: Int {
        normalizedWords.count
    }

    public var wordCountLabel: String {
        "\(wordCount) words"
    }

    public var isSetupComplete: Bool {
        importedAddress != nil
            && passwordStore.userWalletExists
            && passwordStore.agentWalletSetupComplete
            && isAgentWalletReady
    }

    public var canSubmit: Bool {
        !isImporting
            && !isProvisioningAgent
            && (wordCount == 12 || wordCount == 24)
            && passwordInput.count >= 8
            && passwordInput == confirmPassword
            && (mode == .importExisting || hasConfirmedBackup)
    }

    public var canConfirmCreate: Bool {
        mode == .createNew && generatedMnemonic != nil && !isImporting && !isProvisioningAgent
    }

    public func choose(_ newMode: WalletOnboardingMode) {
        guard !isImporting, !isProvisioningAgent else { return }
        mode = newMode
        errorMessage = nil
        importedAddress = nil
        hasConfirmedBackup = false

        switch newMode {
        case .importExisting:
            generatedMnemonic = nil
            mnemonicInput = ""
            isMnemonicVisible = false
        case .createNew:
            generateNewWallet()
        }
    }

    public func generateNewWallet() {
        do {
            let phrase = try BIP39.generateMnemonic(wordCount: 12)
            generatedMnemonic = phrase
            mnemonicInput = phrase
            isMnemonicVisible = true
            hasConfirmedBackup = false
            errorMessage = nil
        } catch {
            generatedMnemonic = nil
            mnemonicInput = ""
            errorMessage = error.localizedDescription
        }
    }

    public func confirmBackup() {
        guard canConfirmCreate else { return }
        hasConfirmedBackup = true
    }

    /// Imports an existing phrase or persists the generated phrase after the
    /// backup confirmation. This method remains synchronous for simple view
    /// model callers; Agent Wallet provisioning continues asynchronously.
    public func importWallet() {
        guard !isImporting, !isProvisioningAgent else { return }
        errorMessage = nil

        let mnemonic = mnemonicInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordInput

        guard !mnemonic.isEmpty else {
            errorMessage = "Enter your 12 or 24-word seed phrase."
            return
        }
        guard password.count >= 8 else {
            errorMessage = "Keystore password must be at least 8 characters."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        guard mode == .importExisting || hasConfirmedBackup else {
            errorMessage = "Confirm that you backed up the recovery phrase before continuing."
            return
        }

        isImporting = true
        defer { isImporting = false }

        do {
            let address = try keystoreManager.importSeedPhrase(mnemonic: mnemonic, password: password)
            guard let keystoreJson = keystoreManager.currentKeystoreJson else {
                errorMessage = "Keystore generation failed — nothing was persisted."
                return
            }

            try passwordStore.saveUserWallet(
                KeystorePasswordStore.UserWalletRecord(address: address, keystoreJson: keystoreJson)
            )
            try passwordStore.saveUserPassword(password)

            importedAddress = address
            onImportComplete?(address)

            // Do not retain the recovery phrase or password after encryption.
            mnemonicInput = ""
            generatedMnemonic = nil
            passwordInput = ""
            confirmPassword = ""
            hasConfirmedBackup = false

            if let onSetupComplete {
                isProvisioningAgent = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await onSetupComplete(address)
                        self.isAgentWalletReady = self.passwordStore.agentWalletSetupComplete
                        guard self.isAgentWalletReady else {
                            throw AgentUnlockError("Agent Wallet was not persisted; setup is incomplete.")
                        }
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                    self.isProvisioningAgent = false
                }
            } else {
                isAgentWalletReady = passwordStore.agentWalletSetupComplete
            }
        } catch let error as KeystoreError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func retryAgentWalletProvisioning() {
        guard let address = importedAddress,
              let onSetupComplete,
              !isProvisioningAgent else { return }
        errorMessage = nil
        isProvisioningAgent = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onSetupComplete(address)
                self.isAgentWalletReady = self.passwordStore.agentWalletSetupComplete
                guard self.isAgentWalletReady else {
                    throw AgentUnlockError("Agent Wallet was not persisted; setup is incomplete.")
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isProvisioningAgent = false
        }
    }

    public func resetForm() {
        mode = .importExisting
        mnemonicInput = ""
        generatedMnemonic = nil
        passwordInput = ""
        confirmPassword = ""
        isMnemonicVisible = false
        hasConfirmedBackup = false
        errorMessage = nil
        importedAddress = nil
        isProvisioningAgent = false
    }

    private var normalizedWords: [String] {
        mnemonicInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
}

/// Guided onboarding for the User Wallet and Agent Wallet pair.
public struct WalletOnboardingView: View {
    @ObservedObject public var viewModel: WalletOnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: WalletOnboardingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modePicker

            if viewModel.isSetupComplete {
                completionCard
            } else if viewModel.importedAddress != nil {
                provisioningCard
            } else {
                phraseSection
                passwordSection
                if let errorMessage = viewModel.errorMessage {
                    errorCard(errorMessage)
                }
                actionButtons
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.75)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Notch3")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("User Wallet first, then a separate Agent Wallet")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            if !viewModel.isImporting && !viewModel.isProvisioningAgent {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close wallet setup")
            }
        }
    }

    private var modePicker: some View {
        Picker("Wallet setup method", selection: $viewModel.mode) {
            ForEach(WalletOnboardingMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: viewModel.mode) { _, mode in
            viewModel.choose(mode)
        }
        .accessibilityLabel("Wallet setup method")
    }

    @ViewBuilder
    private var phraseSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(viewModel.mode == .createNew ? "Recovery phrase" : "Recovery phrase to import")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text(viewModel.wordCountLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor((viewModel.wordCount == 12 || viewModel.wordCount == 24) ? .green : .white.opacity(0.5))
            }

            if viewModel.mode == .createNew, let phrase = viewModel.generatedMnemonic {
                Text(phrase)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.3), lineWidth: 1))

                Toggle("I wrote down this phrase and stored it safely", isOn: $viewModel.hasConfirmedBackup)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .accessibilityLabel("Confirm recovery phrase backup")
            } else {
                HStack(spacing: 6) {
                    Group {
                        if viewModel.isMnemonicVisible {
                            TextField("word1 word2 word3 …", text: $viewModel.mnemonicInput, axis: .vertical)
                        } else {
                            SecureField("12 or 24 words", text: $viewModel.mnemonicInput)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)

                    Button {
                        viewModel.isMnemonicVisible.toggle()
                    } label: {
                        Image(systemName: viewModel.isMnemonicVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.65))
                    .accessibilityLabel(viewModel.isMnemonicVisible ? "Hide recovery phrase" : "Show recovery phrase")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            }

            Text(viewModel.mode == .createNew
                ? "Notch3 never stores or sends this phrase. It is used only to create your encrypted User Wallet."
                : "The phrase is used locally to create an encrypted User Wallet and is never sent to the agent runtime.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Local keystore password")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            SecureField("At least 8 characters", text: $viewModel.passwordInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("User Wallet keystore password")
            SecureField("Confirm password", text: $viewModel.confirmPassword)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Confirm User Wallet keystore password")
        }
    }

    private var actionButtons: some View {
        HStack {
            if viewModel.mode == .createNew && !viewModel.hasConfirmedBackup {
                Button("I backed it up") {
                    viewModel.confirmBackup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canConfirmCreate)
            } else {
                Button(viewModel.isProvisioningAgent ? "Creating Agent Wallet…" : "Save encrypted wallets") {
                    viewModel.importWallet()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
            }

            Spacer()

            if viewModel.isImporting || viewModel.isProvisioningAgent {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Wallet setup in progress")
            }
        }
    }

    private var provisioningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("User Wallet encrypted", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Creating and securely saving the separate Agent Wallet. This window will complete when both wallet records are ready.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage = viewModel.errorMessage {
                errorCard(errorMessage)
                Button("Retry Agent Wallet setup") {
                    viewModel.retryAgentWalletProvisioning()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var completionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notch3 setup complete", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.green)
            if let address = viewModel.importedAddress {
                Text("User Wallet: \(address)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .textSelection(.enabled)
            }
            Text("The Agent Wallet is separate and can be used for explicit chat tasks. User-wallet transfers and swaps still require Touch ID confirmation.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .accessibilityAddTraits(.isStaticText)
    }
}
