import SwiftUI
import AppKit

/// View model for composing a native tBNB transfer: recipient address and
/// UI amount with exact validation, feeding the manual confirmation modal.
@MainActor
public final class SendTransferViewModel: ObservableObject {
    @Published public var recipientAddress: String = ""
    @Published public var amountInput: String = ""
    @Published public var errorMessage: String? = nil

    /// Invoked with (recipient, uiAmount) after validation — the caller opens
    /// the Touch ID confirmation modal from here.
    public var onConfirm: (@MainActor (String, String) -> Void)?
    public var onDismiss: (() -> Void)?

    public init(onConfirm: (@MainActor (String, String) -> Void)? = nil) {
        self.onConfirm = onConfirm
    }

    // MARK: - Validation

    public var trimmedRecipient: String {
        recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedAmount: String {
        amountInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isRecipientValid: Bool {
        let addr = trimmedRecipient
        guard addr.count == 42, addr.hasPrefix("0x") else { return false }
        let hex = addr.dropFirst(2)
        return hex.allSatisfy { $0.isHexDigit }
    }

    /// Exact wei conversion (no floating point) — also rejects zero amounts.
    public var weiAmount: String? {
        guard let wei = WeiConverter.wei(fromUIAmount: trimmedAmount) else { return nil }
        return wei == "0" ? nil : wei
    }

    public var isAmountValid: Bool {
        weiAmount != nil
    }

    public var canSend: Bool {
        isRecipientValid && isAmountValid
    }

    // MARK: - Actions

    public func confirm() {
        guard isRecipientValid else {
            errorMessage = "Recipient must be a 0x-prefixed 20-byte address."
            return
        }
        guard isAmountValid else {
            errorMessage = "Enter a valid amount greater than zero."
            return
        }
        errorMessage = nil
        onConfirm?(trimmedRecipient, trimmedAmount)
    }

    public func cancel() {
        errorMessage = nil
        onDismiss?()
    }
}

/// Sheet for composing a transfer: address + amount, then manual confirmation.
public struct SendTransferView: View {
    @ObservedObject public var viewModel: SendTransferViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: SendTransferViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 14) {
            header

            recipientField
            amountField

            if let error = viewModel.errorMessage {
                errorCard(error)
            }

            actionButtons
        }
        .padding(22)
        .frame(width: 460)
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
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Send tBNB")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Manual confirmation & Touch ID signing required")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

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

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recipient Address")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                if !viewModel.trimmedRecipient.isEmpty {
                    Image(systemName: viewModel.isRecipientValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.isRecipientValid ? .green : .red)
                }
            }

            TextField("0x…", text: $viewModel.recipientAddress)
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
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Amount (tBNB)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                if let wei = viewModel.weiAmount {
                    Text("\(wei) wei")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            TextField("0.01", text: $viewModel.amountInput)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
                .font(.system(size: 14))
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.15)))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: {
                viewModel.cancel()
                dismiss()
            }) {
                Text("Cancel")
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

            Button(action: {
                viewModel.confirm()
                if viewModel.errorMessage == nil {
                    dismiss()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "touchid")
                        .font(.system(size: 13, weight: .bold))
                    Text("Continue to Confirm")
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
            .disabled(!viewModel.canSend)
            .opacity(viewModel.canSend ? 1.0 : 0.5)
        }
    }
}
