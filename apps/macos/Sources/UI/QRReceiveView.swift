import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Target wallet account type for receiving funds.
public enum ReceiveAccountType: String, CaseIterable, Identifiable, Sendable {
    case user = "User Wallet"
    case agent = "Agent Wallet"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .user: return "person.crop.circle.fill"
        case .agent: return "bolt.shield.fill"
        }
    }

    public var badgeDescription: String {
        switch self {
        case .user: return "Manual Touch ID Custody"
        case .agent: return "Autonomous x402 Auto-signing"
        }
    }
}

/// View model for managing QR code generation, address selection, clipboard copy, and sharing.
@MainActor
public final class QRReceiveViewModel: ObservableObject {
    @Published public var userAddress: String
    @Published public var agentAddress: String
    @Published public var selectedAccount: ReceiveAccountType
    @Published public var isCopied: Bool = false
    @Published public var networkName: String
    @Published public var qrImage: NSImage?

    public var currentAddress: String {
        switch selectedAccount {
        case .user: return userAddress
        case .agent: return agentAddress
        }
    }

    public var formattedAddress: String {
        let addr = currentAddress
        guard addr.count >= 12 else { return addr }
        let start = addr.prefix(8)
        let end = addr.suffix(6)
        return "\(start)...\(end)"
    }

    public init(
        userAddress: String = "0x0000000000000000000000000000000000000000",
        agentAddress: String = "0x0000000000000000000000000000000000000000",
        selectedAccount: ReceiveAccountType = .user,
        networkName: String = "BSC Testnet"
    ) {
        self.userAddress = userAddress
        self.agentAddress = agentAddress
        self.selectedAccount = selectedAccount
        self.networkName = networkName
        self.updateQRImage()
    }

    /// Switches the active receiving account and regenerates QR code.
    public func selectAccount(_ account: ReceiveAccountType) {
        self.selectedAccount = account
        self.isCopied = false
        self.updateQRImage()
    }

    /// Copies current address to macOS system pasteboard with brief feedback state.
    public func copyAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentAddress, forType: .string)
        self.isCopied = true

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.isCopied = false
        }
    }

    /// Regenerates the cached QR image for the currently selected address.
    public func updateQRImage() {
        self.qrImage = Self.generateQRCode(from: currentAddress, size: 220)
    }

    /// Generates a sharp, high-DPI QR code `NSImage` from a string using CoreImage.
    public static func generateQRCode(from string: String, size: CGFloat = 220) -> NSImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel") // High error correction

        guard let outputImage = filter?.outputImage else { return nil }

        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let rep = NSCIImageRep(ciImage: transformed)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

/// SwiftUI View displaying the QR Code receive modal sheet.
public struct QRReceiveView: View {
    @ObservedObject public var viewModel: QRReceiveViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: QRReceiveViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 18) {
            // MARK: - Header
            headerSection

            // MARK: - Account Selector
            accountPicker

            // MARK: - QR Code Display Card
            qrCardSection

            // MARK: - Address Bar & Copy Button
            addressBarSection

            // MARK: - Network Disclaimer
            networkDisclaimerSection

            // MARK: - Footer Actions
            footerActions
        }
        .padding(24)
        .frame(width: 420)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.7)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color.yellow)
                    Text("Receive Assets")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Text("Scan QR code or copy address to deposit BNB / BEP-20 tokens")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Account Picker
    private var accountPicker: some View {
        HStack(spacing: 8) {
            ForEach(ReceiveAccountType.allCases) { account in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectAccount(account)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: account.iconName)
                            .font(.system(size: 12))
                        Text(account.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(viewModel.selectedAccount == account ? .white : .white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(viewModel.selectedAccount == account ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                viewModel.selectedAccount == account ? Color.yellow.opacity(0.4) : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - QR Card
    private var qrCardSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 236, height: 236)
                    .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)

                if let image = viewModel.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 216, height: 216)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                        .scaleEffect(1.2)
                }
            }

            Text(viewModel.selectedAccount.badgeDescription)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                )
        }
    }

    // MARK: - Address Bar
    private var addressBarSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text(viewModel.currentAddress)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: {
                    viewModel.copyAddress()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isCopied ? "checkmark" : "doc.on.doc.fill")
                            .font(.system(size: 10))
                        Text(viewModel.isCopied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(viewModel.isCopied ? .green : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(viewModel.isCopied ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Network Disclaimer
    private var networkDisclaimerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow)

            Text("Only send \(viewModel.networkName) (BEP-20) compatible assets to this address.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Footer Actions
    private var footerActions: some View {
        HStack(spacing: 12) {
            Button(action: {
                shareAddress()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                    Text("Share Address")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Button(action: {
                dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.yellow)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func shareAddress() {
        let picker = NSSharingServicePicker(items: [viewModel.currentAddress])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }
}
