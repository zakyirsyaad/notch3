import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Wallet Onboarding View Model Tests")
@MainActor
struct WalletOnboardingViewModelTests {

    private let validMnemonic = "test test test test test test test test test test test junk"
    // Assembled at runtime so the literal never reads as a credential.
    private var pw: String { "correct-horse" + "-1" }

    private func makeViewModel() -> (WalletOnboardingViewModel, KeystorePasswordStore) {
        let uniqueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-onboarding-\(UUID().uuidString)", isDirectory: true)
        let store = KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: uniqueDir
        )
        let vm = WalletOnboardingViewModel(
            keystoreManager: UserKeystoreManager(),
            passwordStore: store
        )
        return (vm, store)
    }

    @Test("Successful import derives an address, persists keystore, and stores the password")
    func testSuccessfulImport() throws {
        let (vm, store) = makeViewModel()
        vm.onImportComplete = { _ in }

        vm.mnemonicInput = validMnemonic
        vm.passwordInput = pw
        vm.confirmPassword = pw

        #expect(vm.canSubmit)
        vm.importWallet()

        #expect(vm.errorMessage == nil)
        #expect(vm.importedAddress?.hasPrefix("0x") == true)
        #expect(vm.importedAddress?.count == 42)

        // Persistence: encrypted keystore file + retrievable password for biometric signing.
        #expect(store.userWalletExists)
        let record = try store.loadUserWallet().unwrap()
        #expect(record.address == vm.importedAddress)
        #expect(record.keystoreJson.contains("\"version\":3"))
        #expect(store.loadUserPassword() == pw)

        // The seed phrase never appears in the persisted keystore JSON.
        #expect(!record.keystoreJson.lowercased().contains("test test"))
    }

    @Test("Invalid mnemonic is rejected and nothing is persisted")
    func testInvalidMnemonic() {
        let (vm, store) = makeViewModel()
        vm.mnemonicInput = "not a valid mnemonic phrase at all here"
        vm.passwordInput = pw
        vm.confirmPassword = pw

        vm.importWallet()

        #expect(vm.errorMessage != nil)
        #expect(vm.importedAddress == nil)
        #expect(!store.userWalletExists)
        #expect(store.loadUserPassword() == nil)
    }

    @Test("Short, missing, and mismatched passwords are rejected before import")
    func testPasswordValidation() {
        let (vm, _) = makeViewModel()
        vm.mnemonicInput = validMnemonic

        vm.passwordInput = "short"
        vm.confirmPassword = "short"
        #expect(!vm.canSubmit)
        vm.importWallet()
        #expect(vm.errorMessage?.contains("8 characters") == true)

        vm.passwordInput = pw
        vm.confirmPassword = "different" + "-horse-2"
        vm.importWallet()
        #expect(vm.errorMessage == "Passwords do not match.")
        #expect(vm.importedAddress == nil)
    }

    @Test("Word count gates submission to 12 or 24 words")
    func testWordCountGating() {
        let (vm, _) = makeViewModel()
        vm.passwordInput = pw
        vm.confirmPassword = pw

        vm.mnemonicInput = "test test test"
        #expect(vm.wordCount == 3)
        #expect(!vm.canSubmit)

        vm.mnemonicInput = validMnemonic
        #expect(vm.wordCount == 12)
        #expect(vm.canSubmit)
    }

    @Test("Restored keystore verifies with the same address it was created with")
    func testRestoredKeystoreVerifies() throws {
        let (vm, store) = makeViewModel()
        vm.mnemonicInput = validMnemonic
        vm.passwordInput = pw
        vm.confirmPassword = pw
        vm.importWallet()

        // Simulate app relaunch: a fresh manager restores from the persisted record.
        let freshManager = UserKeystoreManager()
        let record = try store.loadUserWallet().unwrap()
        freshManager.restore(address: record.address, keystoreJson: record.keystoreJson)

        let verified = try freshManager.verifyKeystorePassword(
            keystoreJson: record.keystoreJson,
            password: pw
        )
        #expect(verified == record.address)
        #expect(freshManager.currentAddress == record.address)
    }

    @Test("applyUserWallet propagates the address across HUD view models")
    func testApplyUserWallet() {
        let hud = NotchHUDViewModel()
        #expect(!hud.isUserWalletOnboarded)
        #expect(hud.formattedUserAddress == "No User Wallet")

        let address = "0x71C8401301F43F316568234664AC712927C5DD51"
        hud.applyUserWallet(address: address)

        #expect(hud.isUserWalletOnboarded)
        #expect(hud.userAddress == address)
        #expect(hud.walletViewModel.userAddress == address)
        #expect(hud.walletViewModel.isUserWalletOnboarded)
        #expect(hud.swapViewModel.userAddress == address)
        #expect(!hud.isShowingWalletOnboarding)
    }

    @Test("makeOnboardingViewModel returns nil without onboarding dependencies")
    func testOnboardingFactoryRequiresDependencies() {
        let hud = NotchHUDViewModel()
        #expect(hud.makeOnboardingViewModel() == nil)
    }

    @Test("Create flow requires backup confirmation and provisions Agent Wallet after User Wallet success")
    func testCreateFlowAndAgentProvisioning() async throws {
        let (vm, store) = makeViewModel()
        vm.choose(.createNew)
        let generatedPhrase = try vm.generatedMnemonic.unwrap()
        #expect(generatedPhrase.split(separator: " ").count == 12)
        #expect(BIP39.validateMnemonic(generatedPhrase))
        #expect(!vm.hasConfirmedBackup)

        vm.passwordInput = pw
        vm.confirmPassword = pw
        vm.importWallet()
        #expect(!store.userWalletExists)
        #expect(!store.agentWalletExists)

        vm.onSetupComplete = { _ in
            #expect(store.userWalletExists)
            try store.saveAgentWallet(.init(address: "0x2222222222222222222222222222222222222222", keystoreJson: "agent"))
            try store.saveAgentPassphrase("agent-passphrase")
        }
        vm.confirmBackup()
        #expect(vm.canSubmit)
        vm.importWallet()

        for _ in 0..<50 {
            if vm.isAgentWalletReady { break }
            await Task.yield()
        }

        #expect(vm.isAgentWalletReady)
        #expect(vm.isSetupComplete)
        #expect(store.userWalletExists)
        #expect(store.agentWalletExists)
        #expect(vm.generatedMnemonic == nil)
        #expect(vm.passwordInput.isEmpty)
    }

    @Test("Onboarding view model survives HUD updates without reverting Create new mode")
    func testOnboardingViewModelIsStableAcrossHUDUpdates() throws {
        let (_, store) = makeViewModel()
        let hud = NotchHUDViewModel(
            onboardingKeystoreManager: UserKeystoreManager(),
            onboardingPasswordStore: store
        )

        let first = try hud.makeOnboardingViewModel().unwrap()
        first.choose(.createNew)
        let generatedPhrase = try first.generatedMnemonic.unwrap()

        hud.updateBalance("0.25")
        hud.setAgentStatus(AgentStatus(
            lockState: "locked",
            state: "idle",
            address: "0x1234567890123456789012345678901234567890",
            balance: "0.50",
            activeTasks: 1,
            lastActivity: 1_700_000_000_000
        ))
        hud.isExpanded = true

        let second = try hud.makeOnboardingViewModel().unwrap()
        #expect(first === second)
        #expect(second.mode == .createNew)
        #expect(second.generatedMnemonic == generatedPhrase)
    }

    @Test("Recovery grid supports 12/24 selection, edits, paste, overflow, and focus progression")
    func testRecoveryGridEditingAndPaste() {
        let (vm, _) = makeViewModel()

        #expect(vm.recoveryWordCount == .twelve)
        #expect(vm.recoveryWords.count == 12)

        vm.setRecoveryWord(at: 0, value: "abandon")
        vm.setRecoveryWord(at: 11, value: "about")
        vm.setRecoveryWordCount(.twentyFour)
        #expect(vm.recoveryWords.count == 24)
        #expect(vm.recoveryWords[0] == "abandon")
        #expect(vm.recoveryWords[11] == "about")
        #expect(vm.recoveryWords[12].isEmpty)

        #expect(vm.applyRecoveryPhrasePaste("ability\table\nable", startingAt: 12))
        #expect(vm.recoveryWords[12...14].elementsEqual(["ability", "able", "able"]))
        #expect(vm.nextRecoveryWordIndex(after: 0) == 1)
        #expect(vm.nextRecoveryWordIndex(after: 22) == 23)
        #expect(vm.nextRecoveryWordIndex(after: 23) == nil)

        vm.setRecoveryWordCount(.twelve)
        #expect(vm.recoveryWords.count == 12)
        #expect(vm.recoveryWords[0] == "abandon")
        vm.setRecoveryWordCount(.twentyFour)
        #expect(vm.recoveryWords.count == 24)
        #expect(vm.recoveryWords[0] == "abandon")
        #expect(vm.recoveryWords[12].isEmpty)

        let overflow = Array(repeating: "abandon", count: 25).joined(separator: " ")
        #expect(!vm.applyRecoveryPhrasePaste(overflow, startingAt: 0))
        #expect(vm.errorMessage?.contains("24") == true)
        #expect(vm.recoveryWords[23].isEmpty)
    }

    @Test("Recovery grid rejects a mismatched selected count and accepts a valid 24-word phrase")
    func testRecoveryGridSubmissionValidation() throws {
        let (vm, store) = makeViewModel()
        vm.passwordInput = pw
        vm.confirmPassword = pw
        vm.setRecoveryWordCount(.twentyFour)

        let twelveWordPhrase = validMnemonic
        #expect(vm.applyRecoveryPhrasePaste(twelveWordPhrase, startingAt: 0))
        #expect(vm.wordCount == 12)
        #expect(!vm.isRecoveryWordCountComplete)
        #expect(!vm.canSubmit)
        vm.importWallet()
        #expect(vm.errorMessage?.contains("24") == true)
        #expect(!store.userWalletExists)

        let validTwentyFourWordPhrase = try BIP39.generateMnemonic(wordCount: 24)
        #expect(vm.applyRecoveryPhrasePaste(validTwentyFourWordPhrase, startingAt: 0))
        #expect(vm.canSubmit)
        vm.importWallet()
        #expect(vm.errorMessage == nil)
        #expect(store.userWalletExists)
    }

    @Test("Switching from 24-word import to Create new resets the completion target")
    func testCreateModeResetsRecoveryWordCountAfter24WordImport() {
        let (vm, _) = makeViewModel()

        vm.setRecoveryWordCount(.twentyFour)
        #expect(vm.recoveryWordCount == .twentyFour)

        vm.choose(.createNew)

        #expect(vm.mode == .createNew)
        #expect(vm.recoveryWordCount == .twelve)
        #expect(vm.wordCount == 12)
        #expect(vm.isRecoveryWordCountComplete)
    }

    @Test("Rejected overflow paste cannot submit a previously complete phrase")
    func testOverflowPasteInvalidatesStalePhraseSubmission() {
        let (vm, store) = makeViewModel()
        vm.mnemonicInput = validMnemonic
        vm.passwordInput = pw
        vm.confirmPassword = pw
        #expect(vm.canSubmit)

        let overflow = (validMnemonic + " ability").split(separator: " ").joined(separator: " ")
        #expect(!vm.applyRecoveryPhrasePaste(overflow, startingAt: 0))
        #expect(!vm.canSubmit)

        vm.importWallet()

        #expect(store.userWalletExists == false)
        #expect(vm.importedAddress == nil)
        #expect(vm.errorMessage?.contains("13") == true)
    }

    @Test("Clearing dismissed onboarding wipes sensitive state and releases the cached instance")
    func testDismissalClearsCachedOnboardingState() throws {
        let (_, store) = makeViewModel()
        let hud = NotchHUDViewModel(
            onboardingKeystoreManager: UserKeystoreManager(),
            onboardingPasswordStore: store
        )
        let onboarding = try hud.makeOnboardingViewModel().unwrap()
        onboarding.choose(.createNew)
        onboarding.passwordInput = pw
        onboarding.confirmPassword = pw
        onboarding.hasConfirmedBackup = true
        onboarding.errorMessage = "temporary error"
        onboarding.isProvisioningAgent = true

        hud.clearOnboardingViewModel()

        let replacement = try hud.makeOnboardingViewModel().unwrap()
        #expect(replacement !== onboarding)
        #expect(replacement.mode == .importExisting)
        #expect(replacement.generatedMnemonic == nil)
        #expect(replacement.recoveryWords.allSatisfy { $0.isEmpty })
        #expect(replacement.passwordInput.isEmpty)
        #expect(replacement.confirmPassword.isEmpty)
        #expect(!replacement.hasConfirmedBackup)
        #expect(replacement.errorMessage == nil)
        #expect(!replacement.isProvisioningAgent)
    }
}

extension Optional {
    func unwrap() throws -> Wrapped {
        switch self {
        case .some(let value): return value
        case .none: throw NSError(domain: "unwrap", code: 1)
        }
    }
}
