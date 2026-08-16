import Testing
import Foundation
@testable import NotchAgentCore

@Suite("Send Transfer View Model Tests")
@MainActor
struct SendTransferViewModelTests {

    private let validRecipient = "0x3333333333333333333333333333333333333333"

    @Test("Recipient validation accepts only 0x + 40 hex characters")
    func testRecipientValidation() {
        let vm = SendTransferViewModel()

        vm.recipientAddress = validRecipient
        #expect(vm.isRecipientValid)

        vm.recipientAddress = "  \(validRecipient)  "
        #expect(vm.isRecipientValid)  // trimming is applied

        vm.recipientAddress = "0x123"
        #expect(!vm.isRecipientValid)

        vm.recipientAddress = "3333333333333333333333333333333333333333"  // no 0x
        #expect(!vm.isRecipientValid)

        vm.recipientAddress = "0xZZ33333333333333333333333333333333333333"  // non-hex
        #expect(!vm.isRecipientValid)
    }

    @Test("Amount validation uses exact wei conversion and rejects zero")
    func testAmountValidation() {
        let vm = SendTransferViewModel()

        vm.amountInput = "0.01"
        #expect(vm.isAmountValid)
        #expect(vm.weiAmount == "10000000000000000")

        vm.amountInput = "1"
        #expect(vm.weiAmount == "1000000000000000000")

        vm.amountInput = "0"
        #expect(!vm.isAmountValid)  // zero-value transfer is meaningless

        vm.amountInput = "1.23.45"
        #expect(!vm.isAmountValid)

        vm.amountInput = "abc"
        #expect(!vm.isAmountValid)

        vm.amountInput = ""
        #expect(!vm.isAmountValid)
    }

    @Test("canSend requires both fields to be valid")
    func testCanSendGating() {
        let vm = SendTransferViewModel()
        #expect(!vm.canSend)

        vm.recipientAddress = validRecipient
        #expect(!vm.canSend)  // amount still missing

        vm.amountInput = "0.5"
        #expect(vm.canSend)
    }

    @Test("Confirm emits validated recipient and amount")
    func testConfirmCallback() {
        let vm = SendTransferViewModel()
        var captured: [(String, String)] = []
        vm.onConfirm = { to, amount in captured.append((to, amount)) }

        vm.recipientAddress = "  \(validRecipient) "
        vm.amountInput = " 0.25 "
        vm.confirm()

        #expect(vm.errorMessage == nil)
        #expect(captured.count == 1)
        #expect(captured[0].0 == validRecipient)
        #expect(captured[0].1 == "0.25")
    }

    @Test("Confirm surfaces an explicit error for an invalid recipient")
    func testConfirmInvalidRecipient() {
        let vm = SendTransferViewModel()
        var calls = 0
        vm.onConfirm = { _, _ in calls += 1 }

        vm.recipientAddress = "0xbad"
        vm.amountInput = "1.0"
        vm.confirm()

        #expect(vm.errorMessage?.contains("0x-prefixed") == true)
        #expect(calls == 0)
    }

    @Test("Confirm surfaces an explicit error for an invalid amount")
    func testConfirmInvalidAmount() {
        let vm = SendTransferViewModel()
        var calls = 0
        vm.onConfirm = { _, _ in calls += 1 }

        vm.recipientAddress = validRecipient
        vm.amountInput = "0"
        vm.confirm()

        #expect(vm.errorMessage?.contains("amount") == true)
        #expect(calls == 0)
    }

    @Test("Cancel clears the error and invokes onDismiss")
    func testCancel() {
        let vm = SendTransferViewModel()
        let dismissed = DismissFlag()
        vm.onDismiss = { dismissed.value = true }

        vm.errorMessage = "boom"
        vm.cancel()

        #expect(vm.errorMessage == nil)
        #expect(dismissed.value)
    }
}

private final class DismissFlag: @unchecked Sendable {
    var value = false
}
