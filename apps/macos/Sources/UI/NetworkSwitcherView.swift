import SwiftUI
import AppKit

/// View model managing network configuration state, multi-chain selection, and RPC network switching.
@MainActor
public final class NetworkSwitcherViewModel: ObservableObject {
    @Published public var supportedNetworks: [NetworkConfig] = NetworkConfig.allNetworks
    @Published public var activeNetwork: NetworkConfig
    @Published public var isSwitching: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var pendingChainId: Int? = nil

    public var rpcClient: JSONRPCClient?
    public var onNetworkSwitched: ((NetworkConfig) -> Void)?

    public init(
        activeNetwork: NetworkConfig = .bscTestnet,
        supportedNetworks: [NetworkConfig] = NetworkConfig.allNetworks,
        rpcClient: JSONRPCClient? = nil
    ) {
        self.activeNetwork = activeNetwork
        self.supportedNetworks = supportedNetworks
        self.rpcClient = rpcClient
    }

    /// Switches active blockchain network by chain ID.
    @discardableResult
    public func switchNetwork(to chainId: Int) async -> Bool {
        guard let targetNetwork = supportedNetworks.first(where: { $0.chainId == chainId }) else {
            self.errorMessage = "Unsupported chain ID: \(chainId)"
            return false
        }

        if activeNetwork.chainId == chainId {
            return true
        }

        self.isSwitching = true
        self.pendingChainId = chainId
        self.errorMessage = nil

        defer {
            self.isSwitching = false
            self.pendingChainId = nil
        }

        if let client = rpcClient {
            do {
                let result: NetworkSwitchResult = try await client.sendRequest(
                    method: "network.switchNetwork",
                    params: NetworkSwitchParams(chainId: chainId),
                    timeoutSeconds: 15.0
                )
                if result.success {
                    self.activeNetwork = result.activeNetwork
                    self.onNetworkSwitched?(result.activeNetwork)
                    return true
                } else {
                    self.errorMessage = "Failed to switch network to chain ID \(chainId)"
                    return false
                }
            } catch {
                self.errorMessage = "Network switch error: \(error.localizedDescription)"
                return false
            }
        } else {
            // Local state switch (e.g. in test or standalone mode)
            self.activeNetwork = targetNetwork
            self.onNetworkSwitched?(targetNetwork)
            return true
        }
    }

    /// Convenience to select a network config object.
    @discardableResult
    public func selectNetwork(_ network: NetworkConfig) async -> Bool {
        await switchNetwork(to: network.chainId)
    }

    /// Refreshes network list from RPC daemon if available.
    public func fetchNetworks() async {
        guard let client = rpcClient else { return }
        do {
            let networks: [NetworkConfig] = try await client.sendRequest(method: "network.getNetworks")
            if !networks.isEmpty {
                self.supportedNetworks = networks
            }
        } catch {
            // Keep local supported networks fallback
        }
    }

    /// Fetches the currently active network from RPC daemon.
    public func fetchCurrentNetwork() async {
        guard let client = rpcClient else { return }
        do {
            let current: NetworkConfig = try await client.sendRequest(method: "network.getCurrentNetwork")
            self.activeNetwork = current
            self.onNetworkSwitched?(current)
        } catch {
            // Keep local active network fallback
        }
    }
}

/// SwiftUI View displaying the Multi-Chain Network Switcher picker, status cards, and one-click switching buttons.
public struct NetworkSwitcherView: View {
    @ObservedObject public var viewModel: NetworkSwitcherViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: NetworkSwitcherViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            // MARK: - Header
            headerSection

            // MARK: - Active Network Highlight Card
            activeNetworkCard

            // MARK: - Network Selection List
            networkListSection

            // MARK: - Error Banner (if any)
            if let error = viewModel.errorMessage {
                errorBanner(message: error)
            }

            // MARK: - Footer Actions
            footerActions
        }
        .padding(20)
        .frame(width: 440)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.72)
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
                    Image(systemName: "network")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color.yellow)
                    Text("Multi-Chain Network")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Text("Select active blockchain network for x402 payments and swaps")
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

    // MARK: - Active Network Card
    private var activeNetworkCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(viewModel.activeNetwork.isTestnet ? Color.yellow.opacity(0.2) : Color.green.opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 20))
                    .foregroundColor(viewModel.activeNetwork.isTestnet ? .yellow : .green)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(viewModel.activeNetwork.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)

                    networkBadge(isTestnet: viewModel.activeNetwork.isTestnet)
                }

                HStack(spacing: 6) {
                    Text("Chain ID: \(viewModel.activeNetwork.chainId)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))

                    Text("Native: \(viewModel.activeNetwork.nativeSymbol)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Connected")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    // MARK: - Network List Section
    private var networkListSection: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.supportedNetworks) { network in
                networkRow(network: network)
            }
        }
    }

    private func networkRow(network: NetworkConfig) -> some View {
        let isSelected = viewModel.activeNetwork.chainId == network.chainId
        let isPending = viewModel.pendingChainId == network.chainId

        return Button(action: {
            Task {
                await viewModel.selectNetwork(network)
            }
        }) {
            HStack(spacing: 12) {
                // Radio / Active dot indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.yellow : Color.white.opacity(0.25), lineWidth: 2)
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 9, height: 9)
                    }
                }

                // Network Details
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(network.name)
                            .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
                            .foregroundColor(isSelected ? .white : .white.opacity(0.85))

                        networkBadge(isTestnet: network.isTestnet)
                    }

                    Text("Chain ID \(network.chainId) • RPC: \(shortenUrl(network.rpcUrl))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                // State Indicator
                if isPending {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 20, height: 20)
                } else if isSelected {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.15)))
                } else {
                    Text("Switch")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                        )
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.yellow.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSwitching)
    }

    private func networkBadge(isTestnet: Bool) -> some View {
        Text(isTestnet ? "TESTNET" : "MAINNET")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundColor(isTestnet ? .orange : .green)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isTestnet ? Color.orange.opacity(0.18) : Color.green.opacity(0.18))
            )
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.red)
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.12))
        )
    }

    // MARK: - Footer Actions
    private var footerActions: some View {
        HStack {
            Link(destination: URL(string: viewModel.activeNetwork.explorerUrl) ?? URL(string: "https://bscscan.com")!) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                    Text("Explorer")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
            }

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.yellow)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func shortenUrl(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host
    }
}
