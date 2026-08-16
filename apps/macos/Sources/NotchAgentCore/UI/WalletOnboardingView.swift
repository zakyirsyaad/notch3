import SwiftUI
import AppKit

/// View model driving user-wallet onboarding: BIP-39 seed phrase import,
/// Web3 v3 keystore encryption, persistent storage, and Keychain-held password.
///
/// The seed phrase itself is never persisted, never logged, and never sent to the
/// agent runtime — only the encrypted keystore JSON is stored on disk.
@MainActor
public final class WalletOnboardingViewModel: ObservableObject {
    @Published public var mnemonicInput: String = ""
    @Published public var passwordInput: String = ""
    @Published public var confirmPassword: String = ""
    @Published public var isMnemonicVisible: Bool = false
    @Published public var isImporting: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var importedAddress: String? = nil

    public let keystoreManager: UserKeystoreManager
    public let passwordStore: KeystorePasswordStore

    /// Called with the freshly imported checksummed address on success.
    public var onImportComplete: (@Sendable (String) -> Void)?

    public init(
        keystoreManager: UserKeystoreManager,
        passwordStore: KeystorePasswordStore
    ) {
        self.keystoreManager = keystoreManager
        self.passwordStore = passwordStore
    }

    public var wordCount: Int {
        mnemonicInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .filter { !$0.isEmpty }
            .count
    }

    public var wordCountLabel: String {
        "\(wordCount) words"
    }

    public var canSubmit: Bool {
        !isImporting
            && (wordCount == 12 || wordCount == 24)
            && passwordInput.count >= 8
            && passwordInput == confirmPassword
    }

    /// Imports the seed phrase, encrypts it into a Web3 v3 keystore, persists the
    /// keystore + password, and reports the derived address.
    public func importWallet() {
        guard !isImporting else { return }
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

        isImporting = true
        defer { isImporting = false }

        do {
            // 1. Validate the mnemonic and derive the encrypted keystore.
            let address = try keystoreManager.importSeedPhrase(mnemonic: mnemonic, password: password)

            // 2. Persist the encrypted keystore (seed phrase itself is never stored).
            guard let keystoreJson = keystoreManager.currentKeystoreJson else {
                errorMessage = "Keystore generation failed — nothing to persist."
                return
            }
            try passwordStore.saveUserWallet(
                KeystorePasswordStore.UserWalletRecord(
                    address: address,
                    keystoreJson: keystoreJson
                )
            )

            // 3. Store the password so the biometric signing path can retrieve it
            //    after a successful Touch ID prompt.
            try passwordStore.saveUserPassword(password)

            importedAddress = address
            onImportComplete?(address)
        } catch let error as KeystoreError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resetForm() {
        mnemonicInput = ""
        passwordInput = ""
        confirmPassword = ""
        isMnemonicVisible = false
        errorMessage = nil
        importedAddress = nil
    }
}

/// Sheet for importing the user wallet's BIP-39 seed phrase and creating the
/// encrypted local keystore. Manual signing (Touch ID / master passcode) is only
/// possible after this onboarding step.
public struct WalletOnboardingView: View {
    @ObservedObject public var viewModel: WalletOnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: WalletOnboardingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 14) {
            header

            if viewModel.importedAddress != nil {
                successCard
            } else {
                mnemonicSection
                passwordSection
                if let error = viewModel.errorMessage {
                    errorCard(error)
                }
                actionButtons
            }
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
                .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Import User Wallet")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Encrypted locally · never leaves this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            if !viewModel.isImporting {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Mnemonic

    private var mnemonicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Seed Phrase (12 or 24 words)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(viewModel.wordCountLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(
                        (viewModel.wordCount == 12 || viewModel.wordCount == 24)
                            ? .green : .white.opacity(0.5)
                    )
            }

            Group {
                if viewModel.isMnemonicVisible {
                    TextField("abandon ability able about ...", text: $viewModel.mnemonicInput, axis: .vertical)
                        .lineLimit(3...5)
                } else {
                    SecureField("••• ••• ••• ••• ••• ••• ...", text: $viewModel.mnemonicInput)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.white)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )

            Button(action: { viewModel.isMnemonicVisible.toggle() }) {
                Label(
                    viewModel.isMnemonicVisible ? "Hide" : "Reveal",
                    systemImage: viewModel.isMnemonicVisible ? "eye.slash.fill" : "eye.fill"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Password

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keystore Password (min. 8 characters)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            SecureField("Password", text: $viewModel.passwordInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )

            SecureField("Confirm password", text: $viewModel.confirmPassword)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )

            Text("Stored in the macOS Keychain so Touch ID signing can unlock it after your fingerprint.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Errors & Actions

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
                .font(.system(size: 14))
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.15)))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.resetForm() }) {
                Text("Clear")
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

            Button(action: { viewModel.importWallet() }) {
                HStack(spacing: 6) {
                    if viewModel.isImporting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(viewModel.isImporting ? "Importing…" : "Import & Encrypt")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue)
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1.0 : 0.5)
        }
    }

    // MARK: - Success

    private var successCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundColor(.green)

            Text("User wallet imported")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text(viewModel.importedAddress ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .contextMenu {
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.importedAddress ?? "", forType: .string)
                    }
                }

            Text("Your seed phrase was encrypted into a local keystore. Sign transfers and swaps with Touch ID or your master password.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Button(action: { dismiss() }) {
                Text("Done")
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
        }
        .padding(10)
    }
}
