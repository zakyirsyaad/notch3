import Testing
import Foundation
@testable import NotchAgentCore

// MARK: - Pipeline Mocks

private struct MockSigner: TransactionSigning {
    var shouldThrow = false
    func signTransaction(_ tx: LegacyTransaction, password: String) throws -> String {
        if shouldThrow { throw KeystoreError.invalidPassword }
        return "0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997ff761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
    }
}

private struct MockBroadcaster: TransactionBroadcasting {
    var txHash = "0xfeed00000000000000000000000000000000000000000000000000000000beef"
    var shouldThrow = false
    func broadcast(signedTx: String) async throws -> String {
        if shouldThrow { throw AgentUnlockError("broadcast rejected") }
        return txHash
    }
}

private struct MockContextProvider: TransactionContextProviding {
    func context(for address: String) async throws -> TransactionContext {
        TransactionContext(nonce: 3, gasPriceWei: "5000000000", chainId: 97)
    }
}

@Suite("Transaction Confirmation View Model Tests")
@MainActor
struct TransactionConfirmationViewModelTests {

    private func makeSampleDetails(
        opType: TransactionOperationType = .transfer,
        amount: String = "0.5",
        symbol: String = "tBNB",
        includeProposal: Bool = true
    ) -> TransactionConfirmationDetails {
        TransactionConfirmationDetails(
            operationType: opType,
            fromAddress: "0x1111111111111111111111111111111111111111",
            toAddress: "0x2222222222222222222222222222222222222222",
            assetSymbol: symbol,
            amount: amount,
            estimatedGasTBNB: "0.00035",
            networkName: "BSC Testnet",
            chainId: 97,
            slippageTolerance: opType == .swap ? "0.5%" : nil,
            dataPayloadHex: "0xa9059cbb0000000000000000000000002222222222222222222222222222222222222222",
            txProposal: includeProposal ? TransactionProposal(
                toAddress: "0x2222222222222222222222222222222222222222",
                valueWei: "500000000000000000",
                dataHex: nil,
                chainId: 97,
                gasLimit: 21_000
            ) : nil
        )
    }

    private func makePasswordStore(storedPassword: String? = "keystore-pass-1") -> KeystorePasswordStore {
        let store = KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: FileManager.default.temporaryDirectory
        )
        if let storedPassword {
            try? store.saveUserPassword(storedPassword)
        }
        return store
    }

    @Test("Initialization sets details and biometrics default when available")
    func testInitialization() {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(details: details, authenticator: mockAuth)

        #expect(vm.details.operationType == .transfer)
        #expect(vm.details.amount == "0.5")
        #expect(vm.details.assetSymbol == "tBNB")
        #expect(vm.authMethod == .biometrics)
        #expect(vm.authState == .idle)
    }

    @Test("Initialization falls back to masterPasscode when biometrics unavailable")
    func testPasswordFallbackWhenNoBiometrics() {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: false)
        let vm = TransactionConfirmationViewModel(details: details, authenticator: mockAuth)

        #expect(vm.authMethod == .masterPasscode)
    }

    @Test("Full biometric flow signs, broadcasts, and reports the real tx hash")
    func testBiometricAuthSuccess() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(
            details: details,
            authenticator: mockAuth,
            signer: MockSigner(),
            broadcaster: MockBroadcaster(),
            contextProvider: MockContextProvider(),
            passwordStore: makePasswordStore()
        )

        let signedBox = TestBox<String?>(nil)
        let broadcastBox = TestBox<String?>(nil)
        vm.onSigned = { raw in signedBox.value = raw }
        vm.onBroadcast = { hash in broadcastBox.value = hash }

        await vm.authenticateAndSign()

        #expect(signedBox.value?.hasPrefix("0x") == true)
        #expect(broadcastBox.value == "0xfeed00000000000000000000000000000000000000000000000000000000beef")

        if case .success(let txHash) = vm.authState {
            #expect(txHash == "0xfeed00000000000000000000000000000000000000000000000000000000beef")
        } else {
            Issue.record("Expected .success state, got \(vm.authState)")
        }
    }

    @Test("Biometric authentication failure transitions to failed state")
    func testBiometricAuthFailure() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: false, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(details: details, authenticator: mockAuth)

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(!error.isEmpty)
        } else {
            Issue.record("Expected .failed state, got \(vm.authState)")
        }
    }

    @Test("Biometric path without a stored password fails honestly — no placeholder password")
    func testBiometricWithoutStoredPasswordFails() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(
            details: details,
            authenticator: mockAuth,
            signer: MockSigner(),
            broadcaster: MockBroadcaster(),
            contextProvider: MockContextProvider(),
            passwordStore: makePasswordStore(storedPassword: nil)
        )

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(error.contains("Master Passcode"))
        } else {
            Issue.record("Expected honest failure, got \(vm.authState)")
        }
    }

    @Test("Without a signer the modal fails honestly instead of simulating a signature")
    func testNoSignerFailsHonestly() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(
            details: details,
            authenticator: mockAuth,
            signer: nil,
            broadcaster: MockBroadcaster(),
            contextProvider: MockContextProvider(),
            passwordStore: makePasswordStore()
        )

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(error.contains("keystore"))
        } else {
            Issue.record("Expected honest failure, got \(vm.authState)")
        }
    }

    @Test("Without a transaction proposal the modal refuses to sign")
    func testNoProposalFailsHonestly() async {
        let details = makeSampleDetails(includeProposal: false)
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(
            details: details,
            authenticator: mockAuth,
            signer: MockSigner(),
            broadcaster: MockBroadcaster(),
            contextProvider: MockContextProvider(),
            passwordStore: makePasswordStore()
        )

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(error.contains("No transaction payload"))
        } else {
            Issue.record("Expected honest failure, got \(vm.authState)")
        }
    }

    @Test("Broadcast failure surfaces as an error, not a fake success hash")
    func testBroadcastFailureSurfaces() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(
            details: details,
            authenticator: mockAuth,
            signer: MockSigner(),
            broadcaster: MockBroadcaster(shouldThrow: true),
            contextProvider: MockContextProvider(),
            passwordStore: makePasswordStore()
        )

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(error.contains("broadcast rejected"))
        } else {
            Issue.record("Expected honest failure, got \(vm.authState)")
        }
    }

    @Test("Wrong keystore password produces a keystore error")
    func testWrongPasswordFails() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(
            details: details,
            authenticator: mockAuth,
            signer: MockSigner(shouldThrow: true),
            broadcaster: MockBroadcaster(),
            contextProvider: MockContextProvider(),
            passwordStore: makePasswordStore()
        )

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(error.contains("password") || error.contains("Password"))
        } else {
            Issue.record("Expected honest failure, got \(vm.authState)")
        }
    }

    @Test("Password authentication fails when password input is empty")
    func testPasswordAuthEmptyInput() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(details: details, authenticator: mockAuth)

        vm.authMethod = .masterPasscode
        vm.passwordInput = ""

        await vm.authenticateAndSign()

        if case .failed(let error) = vm.authState {
            #expect(error.contains("password"))
        } else {
            Issue.record("Expected .failed state for empty password, got \(vm.authState)")
        }
    }

    @Test("Retry resets authState and clears password input")
    func testRetry() {
        let details = makeSampleDetails()
        let vm = TransactionConfirmationViewModel(details: details)

        vm.authState = .failed(errorMessage: "Some error")
        vm.passwordInput = "dummy-value"

        vm.retry()

        #expect(vm.authState == .idle)
        #expect(vm.passwordInput.isEmpty)
    }

    @Test("Cancel resets state and triggers dismiss callback")
    func testCancel() {
        let details = makeSampleDetails()
        let vm = TransactionConfirmationViewModel(details: details)

        let dismissBox = TestBox(false)
        vm.onDismiss = {
            dismissBox.value = true
        }

        vm.cancel()

        #expect(vm.authState == .idle)
        #expect(dismissBox.value)
    }
}

private final class TestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
