import SwiftUI

/// Main Notch HUD SwiftUI view displaying the top status bar, balance chip, quick toggles, and expandable drawer.
public struct NotchHUDView: View {
    @ObservedObject public var viewModel: NotchHUDViewModel
    
    // Animation state
    @Namespace private var animationNamespace
    
    public init(viewModel: NotchHUDViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Notch Header Bar (Always Visible)
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(headerBackground)
            
            // MARK: - Expandable Drawer Body
            if viewModel.isExpanded {
                drawerContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        )
                    )
            }
        }
        .frame(width: viewModel.isExpanded ? 520 : 440)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: viewModel.isExpanded)
        .animation(.easeInOut(duration: 0.2), value: viewModel.agentState)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedTab)
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            // Status Indicator Pill
            statusPill
            
            Spacer()
            
            // Tool Execution Badge (if running)
            if viewModel.isExecutingTool, let tool = viewModel.activeToolName {
                toolExecutingBadge(tool: tool)
            }
            
            // Balance Chip
            balanceChip
            
            // Quick Pause / Resume / Lock Action
            quickActionButton
            
            // Expand / Collapse Drawer Button
            expandButton
        }
    }
    
    // MARK: - Status Pill
    
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 3, x: 0, y: 0)
            
            Text(viewModel.statusTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.4))
                .overlay(
                    Capsule()
                        .stroke(statusColor.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Balance Chip
    
    private var balanceChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.yellow)
            
            Text(viewModel.formattedBalance)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
    }
    
    // MARK: - Tool Executing Badge
    
    private func toolExecutingBadge(tool: String) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 10, height: 10)
            
            Text(tool)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color.cyan)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.cyan.opacity(0.15))
        )
    }
    
    // MARK: - Quick Action Button
    
    private var quickActionButton: some View {
        Button(action: {
            if viewModel.isLocked {
                Task { _ = await viewModel.unlockAgent() }
            } else {
                viewModel.togglePauseResume()
            }
        }) {
            Image(systemName: quickActionIconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(quickActionColor)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(quickActionTooltip)
    }
    
    // MARK: - Expand / Collapse Button
    
    private var expandButton: some View {
        Button(action: {
            viewModel.toggleExpanded()
        }) {
            Image(systemName: viewModel.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(viewModel.isExpanded ? "Collapse HUD" : "Expand Drawer")
    }
    
    // MARK: - Drawer Content
    
    private var drawerContent: some View {
        VStack(spacing: 12) {
            Divider()
                .background(Color.white.opacity(0.12))
            
            // Tab Selector
            tabSelector
                .padding(.horizontal, 16)
            
            // Tab View Body
            Group {
                switch viewModel.selectedTab {
                case .chat:
                    chatDrawerTab
                case .wallet:
                    walletDrawerTab
                case .settings:
                    settingsDrawerTab
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }
    
    // MARK: - Tab Selector
    
    private var tabSelector: some View {
        HStack(spacing: 8) {
            ForEach(HUDTab.allCases) { tab in
                Button(action: {
                    viewModel.selectTab(tab)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(viewModel.selectedTab == tab ? .white : .white.opacity(0.6))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(viewModel.selectedTab == tab ? Color.white.opacity(0.16) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
    
    // MARK: - Drawer Tabs
    
    private var chatDrawerTab: some View {
        ChatView(viewModel: viewModel.chatViewModel)
            .frame(maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }
    
    private var walletDrawerTab: some View {
        WalletView(viewModel: viewModel.walletViewModel)
            .frame(maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }
    
    private var settingsDrawerTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent Parameters & Security")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            
            HStack {
                Text("Auto-Pay Tx Limit:")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text("\(viewModel.autoPayLimit) tBNB")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            
            HStack {
                Text("Biometrics / Touch ID:")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(viewModel.isBiometricsEnabled ? "Enabled" : "Disabled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(viewModel.isBiometricsEnabled ? .green : .red)
            }
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            HStack {
                Button(action: {
                    viewModel.lockAgent()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                        Text("Lock Agent")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: {
                    viewModel.triggerKillSwitch()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Kill Switch")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.2))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }
    
    // MARK: - Subviews & Helpers
    
    private func actionChip(title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
        )
    }
    
    private func walletCard(title: String, address: String, balance: String, badge: String, badgeColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(badge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(badgeColor.opacity(0.15)))
            }
            
            Text(address)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            
            Text(balance)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color.yellow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
    
    private var statusColor: Color {
        switch viewModel.agentState {
        case .unlocked: return .green
        case .paused: return .orange
        case .locked: return .red
        }
    }
    
    private var quickActionIconName: String {
        switch viewModel.agentState {
        case .unlocked: return "pause.fill"
        case .paused: return "play.fill"
        case .locked: return "lock.open.fill"
        }
    }
    
    private var quickActionColor: Color {
        switch viewModel.agentState {
        case .unlocked: return .orange
        case .paused: return .green
        case .locked: return .blue
        }
    }
    
    private var quickActionTooltip: String {
        switch viewModel.agentState {
        case .unlocked: return "Pause Agent"
        case .paused: return "Resume Agent"
        case .locked: return "Unlock Agent"
        }
    }
    
    private var headerBackground: some View {
        Color.clear
    }
    
    private var panelBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.65)
        }
    }
}

// MARK: - NSVisualEffectView AppKit Bridge

public struct VisualEffectView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode
    
    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
