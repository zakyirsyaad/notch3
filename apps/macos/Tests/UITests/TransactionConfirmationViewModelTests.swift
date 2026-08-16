import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Transaction Confirmation View Model Tests")
@MainActor
struct TransactionConfirmationViewModelTests {

    private func makeSampleDetails(
        opType: TransactionOperationType = .transfer,
        amount: String = "0.5",
        symbol: String = "tBNB"
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
            dataPayloadHex: "0xa9059cbb0000000000000000000000002222222222222222222222222222222222222222"
        )
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

    @Test("Biometric authentication success signs transaction and transitions to success state")
    func testBiometricAuthSuccess() async {
        let details = makeSampleDetails()
        let mockAuth = MockTouchIDAuthenticator(shouldSucceed: true, canUseBiometrics: true)
        let vm = TransactionConfirmationViewModel(details: details, authenticator: mockAuth)

        let signedBox = TestBox<Data?>(nil)
        vm.onSigned = { data in
            signedBox.value = data
        }

        await vm.authenticateAndSign()

        #expect(signedBox.value != nil)
        if case .success(let txHash) = vm.authState {
            #expect(txHash.hasPrefix("0x"))
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
