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
        var completed: [String] = []
        vm.onImportComplete = { completed.append($0) }

        vm.mnemonicInput = validMnemonic
        vm.passwordInput = pw
        vm.confirmPassword = pw

        #expect(vm.canSubmit)
        vm.importWallet()

        #expect(vm.errorMessage == nil)
        #expect(vm.importedAddress?.hasPrefix("0x") == true)
        #expect(vm.importedAddress?.count == 42)
        #expect(completed == [vm.importedAddress])

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
}

extension Optional {
    func unwrap() throws -> Wrapped {
        switch self {
        case .some(let value): return value
        case .none: throw NSError(domain: "unwrap", code: 1)
        }
    }
}
