import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

public enum WalletRecoveryWordCount: Int, CaseIterable, Identifiable, Sendable {
    case twelve = 12
    case twentyFour = 24

    public var id: Int { rawValue }
    public var title: String { "\(rawValue) words" }
}

/// View model for the two-wallet setup flow.
///
/// The User Wallet is encrypted and persisted first. The app then provisions
/// the Agent Wallet through the runtime and persists its encrypted keystore and
/// passphrase. Setup is considered complete only after both records exist.
@MainActor
public final class WalletOnboardingViewModel: ObservableObject {
    @Published public var mode: WalletOnboardingMode = .importExisting
    @Published public var recoveryWordCount: WalletRecoveryWordCount = .twelve
    @Published public private(set) var recoveryWords: [String] = Array(repeating: "", count: WalletRecoveryWordCount.twelve.rawValue)
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

    /// A rejected phrase paste must invalidate the current submit attempt even
    /// when the grid still contains a previously complete phrase. The visible
    /// error is kept separate from other setup errors so correcting a password
    /// does not accidentally clear a stale recovery-input rejection.
    private var recoveryInputErrorMessage: String?

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

    /// Compatibility surface for callers that still provide one complete
    /// phrase. The recovery grid remains the source of truth for imports.
    public var mnemonicInput: String {
        get {
            mode == .createNew
                ? normalizedWords(from: generatedMnemonic ?? "").joined(separator: " ")
                : normalizedRecoveryPhrase
        }
        set {
            guard mode == .importExisting else { return }
            setRecoveryPhrase(newValue)
        }
    }

    public var wordCount: Int {
        mode == .createNew
            ? normalizedWords(from: generatedMnemonic ?? "").count
            : recoveryWords.filter { !$0.isEmpty }.count
    }

    public var wordCountLabel: String {
        "\(wordCount) words"
    }

    public var isRecoveryWordCountComplete: Bool {
        wordCount == recoveryWordCount.rawValue
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
            && recoveryInputErrorMessage == nil
            && isPhraseComplete
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
        recoveryInputErrorMessage = nil
        importedAddress = nil
        hasConfirmedBackup = false

        switch newMode {
        case .importExisting:
            generatedMnemonic = nil
            recoveryWordCount = .twelve
            recoveryWords = Array(repeating: "", count: recoveryWordCount.rawValue)
            isMnemonicVisible = false
        case .createNew:
            generateNewWallet()
        }
    }

    public func generateNewWallet() {
        do {
            let phrase = try BIP39.generateMnemonic(wordCount: 12)
            generatedMnemonic = phrase
            isMnemonicVisible = true
            hasConfirmedBackup = false
            errorMessage = nil
        } catch {
            generatedMnemonic = nil
            recoveryWords = Array(repeating: "", count: recoveryWordCount.rawValue)
            errorMessage = error.localizedDescription
            recoveryInputErrorMessage = nil
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

        if let recoveryInputErrorMessage {
            errorMessage = recoveryInputErrorMessage
            return
        }

        errorMessage = nil

        let mnemonic = normalizedMnemonicForSubmission
        let password = passwordInput

        guard !mnemonic.isEmpty else {
            errorMessage = "Enter your 12 or 24-word seed phrase."
            return
        }
        guard isPhraseComplete else {
            errorMessage = "Enter all \(recoveryWordCount.rawValue) recovery words."
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
            recoveryWords = Array(repeating: "", count: recoveryWordCount.rawValue)
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
        recoveryWordCount = .twelve
        recoveryWords = Array(repeating: "", count: recoveryWordCount.rawValue)
        generatedMnemonic = nil
        passwordInput = ""
        confirmPassword = ""
        isMnemonicVisible = false
        hasConfirmedBackup = false
        errorMessage = nil
        importedAddress = nil
        isImporting = false
        isProvisioningAgent = false
        isAgentWalletReady = false
        recoveryInputErrorMessage = nil
    }

    /// Wipes all in-memory onboarding material before a cached sheet model is
    /// released. Persisted encrypted wallet records are intentionally untouched.
    public func clearSensitiveState() {
        resetForm()
        onSetupComplete = nil
        onImportComplete = nil
    }

    public func setRecoveryWordCount(_ newCount: WalletRecoveryWordCount) {
        guard mode == .importExisting, !isImporting, !isProvisioningAgent else { return }
        let preserved = Array(recoveryWords.prefix(newCount.rawValue))
        recoveryWordCount = newCount
        recoveryWords = preserved + Array(
            repeating: "",
            count: max(0, newCount.rawValue - preserved.count)
        )
        errorMessage = nil
        recoveryInputErrorMessage = nil
    }

    public func setRecoveryWord(at index: Int, value: String) {
        guard mode == .importExisting, recoveryWords.indices.contains(index) else { return }

        let words = normalizedWords(from: value)
        if words.count > 1 {
            _ = applyRecoveryPhrasePaste(value, startingAt: index)
            return
        }

        recoveryWords[index] = words.first ?? ""
        errorMessage = nil
        recoveryInputErrorMessage = nil
    }

    /// Applies a paste payload to the selected field and subsequent fields.
    /// Nothing is changed when the phrase cannot fit in the selected grid.
    @discardableResult
    public func applyRecoveryPhrasePaste(_ phrase: String, startingAt index: Int) -> Bool {
        guard mode == .importExisting,
              recoveryWords.indices.contains(index) else { return false }

        let words = normalizedWords(from: phrase)
        guard !words.isEmpty else { return false }

        guard words.count <= recoveryWordCount.rawValue else {
            let message = "This phrase has \(words.count) words. Select the matching 12- or 24-word mode before pasting."
            recoveryInputErrorMessage = message
            errorMessage = message
            return false
        }

        guard index + words.count <= recoveryWordCount.rawValue else {
            let message = "This phrase does not fit from word \(index + 1). Paste it into an earlier field."
            recoveryInputErrorMessage = message
            errorMessage = message
            return false
        }

        var nextWords = recoveryWords
        for (offset, word) in words.enumerated() {
            nextWords[index + offset] = word
        }
        recoveryWords = nextWords
        errorMessage = nil
        recoveryInputErrorMessage = nil
        return true
    }

    public func nextRecoveryWordIndex(after index: Int) -> Int? {
        let nextIndex = index + 1
        return nextIndex < recoveryWordCount.rawValue ? nextIndex : nil
    }

    private var normalizedRecoveryPhrase: String {
        recoveryWords.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var normalizedMnemonicForSubmission: String {
        mode == .createNew
            ? normalizedWords(from: generatedMnemonic ?? "").joined(separator: " ")
            : normalizedRecoveryPhrase
    }

    private var isPhraseComplete: Bool {
        if mode == .createNew {
            return normalizedWords(from: generatedMnemonic ?? "").count == 12
        }
        return recoveryWords.count == recoveryWordCount.rawValue
            && recoveryWords.allSatisfy { !$0.isEmpty }
    }

    private func setRecoveryPhrase(_ phrase: String) {
        let words = normalizedWords(from: phrase)
        guard words.count <= recoveryWordCount.rawValue else {
            let message = "This phrase has \(words.count) words. Select the matching 12- or 24-word mode before entering it."
            recoveryInputErrorMessage = message
            errorMessage = message
            return
        }

        recoveryWords = words + Array(
            repeating: "",
            count: max(0, recoveryWordCount.rawValue - words.count)
        )
        errorMessage = nil
        recoveryInputErrorMessage = nil
    }

    private func normalizedWords(from input: String) -> [String] {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
}

/// Guided onboarding for the User Wallet and Agent Wallet pair.
public struct WalletOnboardingView: View {
    @ObservedObject public var viewModel: WalletOnboardingViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FocusTarget?

    private enum FocusTarget: Hashable {
        case recoveryWord(Int)
        case password
        case confirmPassword
    }

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
        Picker("Wallet setup method", selection: Binding(
            get: { viewModel.mode },
            set: { viewModel.choose($0) }
        )) {
            ForEach(WalletOnboardingMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
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
                    .foregroundColor(viewModel.isRecoveryWordCountComplete ? .green : .white.opacity(0.5))
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
                recoveryGrid
            }

            Text(viewModel.mode == .createNew
                ? "Notch3 never stores or sends this phrase. It is used only to create your encrypted User Wallet."
                : "The phrase is used locally to create an encrypted User Wallet and is never sent to the agent runtime.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Recovery phrase length", selection: Binding(
                get: { viewModel.recoveryWordCount },
                set: { viewModel.setRecoveryWordCount($0) }
            )) {
                ForEach(WalletRecoveryWordCount.allCases) { count in
                    Text(count.title).tag(count)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isImporting || viewModel.isProvisioningAgent)
            .accessibilityLabel("Recovery phrase length")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 90), spacing: 8), count: 4),
                spacing: 8
            ) {
                ForEach(0..<viewModel.recoveryWordCount.rawValue, id: \.self) { index in
                    recoveryWordField(index: index)
                }
            }
            .accessibilityElement(children: .contain)

            HStack(spacing: 8) {
                Button {
                    viewModel.isMnemonicVisible.toggle()
                } label: {
                    Label(
                        viewModel.isMnemonicVisible ? "Hide words" : "Show words",
                        systemImage: viewModel.isMnemonicVisible ? "eye.slash" : "eye"
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.65))
                .accessibilityLabel(viewModel.isMnemonicVisible ? "Hide recovery words" : "Show recovery words")

                Text("Paste a full phrase into any field to fill forward.")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func recoveryWordField(index: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 18, alignment: .trailing)

            Group {
                if viewModel.isMnemonicVisible {
                    TextField("word", text: recoveryWordBinding(index: index))
                } else {
                    SecureField("word", text: recoveryWordBinding(index: index))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white)
            .focused($focusedField, equals: .recoveryWord(index))
            .onSubmit { focusAfterRecoveryWord(index) }
            .onKeyPress(.tab) {
                focusAfterRecoveryWord(index)
                return .handled
            }
            .onPasteCommand(of: [UTType.plainText]) { providers in
                pasteRecoveryPhrase(from: providers, startingAt: index)
            }
            .accessibilityLabel("Recovery word \(index + 1) of \(viewModel.recoveryWordCount.rawValue)")
            .accessibilityHint("Enter one word, or paste the full recovery phrase here")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func recoveryWordBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                guard viewModel.recoveryWords.indices.contains(index) else { return "" }
                return viewModel.recoveryWords[index]
            },
            set: { viewModel.setRecoveryWord(at: index, value: $0) }
        )
    }

    private func pasteRecoveryPhrase(from providers: [NSItemProvider], startingAt index: Int) {
        guard let provider = providers.first else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data, let phrase = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                if viewModel.applyRecoveryPhrasePaste(phrase, startingAt: index) {
                    focusAfterRecoveryWord(index, pastedWordCount: phraseWordCount(phrase))
                }
            }
        }
    }

    private func phraseWordCount(_ phrase: String) -> Int {
        phrase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    private func focusAfterRecoveryWord(_ index: Int, pastedWordCount: Int = 1) {
        let lastPastedIndex = index + max(1, pastedWordCount) - 1
        if let nextIndex = viewModel.nextRecoveryWordIndex(after: lastPastedIndex) {
            focusedField = .recoveryWord(nextIndex)
        } else {
            focusedField = .password
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Local keystore password")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            SecureField("At least 8 characters", text: $viewModel.passwordInput)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .onSubmit { focusedField = .confirmPassword }
                .onKeyPress(.tab) {
                    focusedField = .confirmPassword
                    return .handled
                }
                .accessibilityLabel("User Wallet keystore password")
            SecureField("Confirm password", text: $viewModel.confirmPassword)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .confirmPassword)
                .onSubmit { focusedField = nil }
                .onKeyPress(.tab) {
                    focusedField = nil
                    return .handled
                }
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
                .keyboardShortcut(.defaultAction)
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
            .accessibilityLabel("Wallet setup error: \(message)")
            .accessibilityAddTraits(.isStaticText)
    }
}
