import SwiftUI
import AppKit

enum NotchHUDTabPresentation: Equatable {
    case iconAboveLabel
}

enum NotchHUDContainerStyle: Equatable {
    case collapsedPill
    case expandedDrawer
}

enum NotchHUDTabScrollPolicy: Equatable {
    case preserveInternal
    case outerVertical
}

enum NotchHUDLayout {
    static let expandedSize = CGSize(width: 520, height: 520)
    static let collapsedRegionCount = 3
    static let collapsedBrandMarkSize = NotchDisplayLayout.brandMarkSize
    static let collapsedHeight = NotchDisplayLayout.collapsedHeight
    static let drawerHorizontalPadding: CGFloat = 16
    static let tabSpacing: CGFloat = 4
    static let tabContentSpacing: CGFloat = 4
    static let tabFontSize: CGFloat = 12
    static let tabLabelHorizontalInset: CGFloat = 6
    static let tabTitleLineLimit = 1
    static let tabMinimumHitHeight: CGFloat = 44
    static let tabPressAnimationDuration = 0.08
    static let tabSelectionAnimationDuration = 0.08
    static let drawerInsertionDuration: TimeInterval = 0.20
    static let drawerRemovalDuration: TimeInterval = 0.12
    static let drawerTransitionDuration: TimeInterval = drawerInsertionDuration
    static let drawerMotionOffset: CGFloat = 6
    static let tabPresentation: NotchHUDTabPresentation = .iconAboveLabel

    static func collapsedRegionFrames(
        in frame: CGRect,
        hasActiveTaskBadge: Bool
    ) -> [CGRect] {
        // The badge occupies the existing trailing region only. It never
        // changes the three equal tracks, keeping the product name centered.
        _ = hasActiveTaskBadge
        let regionWidth = frame.width / CGFloat(collapsedRegionCount)
        return (0..<collapsedRegionCount).map { index in
            CGRect(
                x: frame.minX + (CGFloat(index) * regionWidth),
                y: frame.minY,
                width: regionWidth,
                height: frame.height
            )
        }
    }

    static func drawerAnimationDuration(
        isInsertion: Bool,
        reduceMotion: Bool
    ) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return isInsertion ? drawerInsertionDuration : drawerRemovalDuration
    }

    static func drawerMotionOffset(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : drawerMotionOffset
    }

    static func containerStyle(isExpanded: Bool) -> NotchHUDContainerStyle {
        isExpanded ? .expandedDrawer : .collapsedPill
    }

    static func scrollPolicy(for tab: HUDTab) -> NotchHUDTabScrollPolicy {
        switch tab {
        case .swap, .maker, .settings:
            return .outerVertical
        case .chat, .wallet, .storage:
            return .preserveInternal
        }
    }
}

/// Main Notch HUD SwiftUI view displaying the top status bar, balance chip, quick toggles, and expandable drawer.
public struct NotchHUDView: View {
    @ObservedObject public var viewModel: NotchHUDViewModel
    public let displayLayout: NotchDisplayLayout
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    
    public init(
        viewModel: NotchHUDViewModel,
        displayLayout: NotchDisplayLayout = .fallback
    ) {
        self.viewModel = viewModel
        self.displayLayout = displayLayout
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Notch Header Bar (Always Visible)
            headerBar
            
            // MARK: - Expandable Drawer Body
            Group {
                if viewModel.isExpanded {
                    drawerContent
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(drawerTransition)
                }
            }
            .animation(drawerAnimation, value: viewModel.isExpanded)
        }
        // The NSHostingView fills the AppKit panel. The panel owns size and
        // position animation; SwiftUI only renders the current content state.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(V6Palette.ink)
        .clipShape(containerShape)
        .shadow(color: Color.black.opacity(0.22), radius: 14, x: 0, y: 6)
        .sheet(isPresented: $viewModel.isShowingNetworkSwitcher) {
            NetworkSwitcherView(viewModel: viewModel.networkSwitcherViewModel)
        }
        .sheet(isPresented: $viewModel.isShowingWalletOnboarding, onDismiss: {
            viewModel.clearOnboardingViewModel()
        }) {
            if let onboardingVM = viewModel.makeOnboardingViewModel() {
                WalletOnboardingView(viewModel: onboardingVM)
            }
        }
        .animation(sessionAnimation, value: viewModel.isSessionAuthenticated)
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        Group {
            if viewModel.isExpanded {
                // Expanded Header Layout (Standard controller list)
                HStack(spacing: 12) {
                    statusPill
                    
                    Spacer()
                    
                    if viewModel.isExecutingTool, let tool = viewModel.activeToolName {
                        toolExecutingBadge(tool: tool)
                    }
                    
                    networkChip
                    balanceChip
                    expandButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                collapsedHeaderBar
            }
        }
        .frame(maxWidth: .infinity)
        .background(headerBackground)
    }

    private var collapsedHeaderBar: some View {
        GeometryReader { proxy in
            let regions = NotchHUDLayout.collapsedRegionFrames(
                in: CGRect(origin: .zero, size: proxy.size),
                hasActiveTaskBadge: viewModel.activeTaskBadge != nil
            )

            HStack(spacing: 0) {
                collapsedBrandRegion
                    .frame(width: regions[0].width, height: proxy.size.height, alignment: .leading)
                collapsedTitleRegion
                    .frame(width: regions[1].width, height: proxy.size.height)
                collapsedActivityRegion
                    .frame(width: regions[2].width, height: proxy.size.height, alignment: .trailing)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: displayLayout.collapsedSize.height)
        .padding(.horizontal, 10)
    }

    private var collapsedBrandRegion: some View {
        PixelInvaderView(color: V6Palette.paper.opacity(0.78))
            .frame(width: NotchHUDLayout.collapsedBrandMarkSize.width, height: NotchHUDLayout.collapsedBrandMarkSize.height)
            .accessibilityHidden(true)
    }

    private var collapsedTitleRegion: some View {
        Group {
            if displayLayout.showsProductName {
                Text("Notch3")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(V6Palette.paper.opacity(0.86))
                    .lineLimit(1)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var collapsedActivityRegion: some View {
        HStack(spacing: 5) {
            if viewModel.hasActiveWork {
                Circle()
                    .fill(V6Palette.activeBlue)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(activeWorkAccessibilityLabel)

                if let activeTaskBadge = viewModel.activeTaskBadge {
                    Text(activeTaskBadge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(V6Palette.paper.opacity(0.76))
                        .frame(width: 14, height: 14)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .accessibilityLabel("\(activeTaskBadge) active tasks")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var activeWorkAccessibilityLabel: String {
        if let activeToolName = viewModel.activeToolName, !activeToolName.isEmpty {
            return "Active work: \(activeToolName)"
        }
        return "Active work"
    }
    
    // MARK: - Multi-Chain Network Chip
    
    private var networkChip: some View {
        Button(action: {
            viewModel.isShowingNetworkSwitcher = true
        }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(viewModel.networkSwitcherViewModel.activeNetwork.isTestnet ? Color.yellow : Color.green)
                    .frame(width: 6, height: 6)
                
                Text(viewModel.networkName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(V6Palette.paper.opacity(0.9))
            }
            .padding(.horizontal, 8)
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
        .buttonStyle(.plain)
        .help("Active Network: \(viewModel.networkName) (Click to switch)")
    }
    
    // MARK: - Status Pill
    
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text("Notch3")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(V6Palette.paper)
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
                .foregroundColor(V6Palette.paper)
            
            Text(viewModel.formattedBalance)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(V6Palette.paper)
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
                .foregroundColor(V6Palette.activeBlue)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(V6Palette.activeBlue.opacity(0.15))
        )
    }
    
    // MARK: - Expand / Collapse Button
    
    private var expandButton: some View {
        Button(action: {
            viewModel.toggleExpanded()
        }) {
            Image(systemName: viewModel.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(V6Palette.paper.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(HUDPressButtonStyle())
        .help(viewModel.isExpanded ? "Collapse HUD" : "Expand Drawer")
    }
    
    // MARK: - Drawer Content
    
    private var drawerContent: some View {
        VStack(spacing: 12) {
            Divider()
                .background(Color.white.opacity(0.12))
            
            // Tab Selector
            tabSelector
                .padding(.horizontal, NotchHUDLayout.drawerHorizontalPadding)
            
            // Tab View Body
            drawerTabViewport(for: viewModel.selectedTab) {
                selectedDrawerTab
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, NotchHUDLayout.drawerHorizontalPadding)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // MARK: - Tab Selector
    
    private var tabSelector: some View {
        HStack(spacing: NotchHUDLayout.tabSpacing) {
            ForEach(HUDTab.allCases) { tab in
                Button(action: {
                    viewModel.selectTab(tab)
                }) {
                    tabLabel(for: tab)
                        .frame(maxWidth: .infinity, minHeight: NotchHUDLayout.tabMinimumHitHeight)
                        .foregroundColor(viewModel.selectedTab == tab ? .white : .white.opacity(0.6))
                        .padding(.vertical, 6)
                        .padding(.horizontal, NotchHUDLayout.tabLabelHorizontalInset)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(viewModel.selectedTab == tab ? Color.white.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(HUDPressButtonStyle())
                .frame(maxWidth: .infinity)
            }
        }
        .animation(
            .easeOut(duration: NotchHUDLayout.tabSelectionAnimationDuration),
            value: viewModel.selectedTab
        )
    }

    @ViewBuilder
    private func tabLabel(for tab: HUDTab) -> some View {
        switch NotchHUDLayout.tabPresentation {
        case .iconAboveLabel:
            VStack(spacing: NotchHUDLayout.tabContentSpacing) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: NotchHUDLayout.tabFontSize, weight: .medium))
                    .lineLimit(NotchHUDLayout.tabTitleLineLimit)
                    .minimumScaleFactor(0.85)
            }
        }
    }
    
    // MARK: - Drawer Tabs

    @ViewBuilder
    private var selectedDrawerTab: some View {
        switch viewModel.selectedTab {
        case .chat:
            chatDrawerTab
        case .wallet:
            walletDrawerTab
        case .swap:
            swapDrawerTab
        case .maker:
            makerDrawerTab
        case .storage:
            greenfieldStorageDrawerTab
        case .settings:
            settingsDrawerTab
        }
    }

    @ViewBuilder
    private func drawerTabViewport<Content: View>(
        for tab: HUDTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch NotchHUDLayout.scrollPolicy(for: tab) {
        case .outerVertical:
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preserveInternal:
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
    
    private var chatDrawerTab: some View {
        ChatView(viewModel: viewModel.chatViewModel)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }
    
    private var walletDrawerTab: some View {
        WalletView(viewModel: viewModel.walletViewModel)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }

    private var swapDrawerTab: some View {
        SwapView(viewModel: viewModel.swapViewModel)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }

    private var makerDrawerTab: some View {
        MakerModeDashboardView(viewModel: viewModel.makerModeViewModel)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }
    
    private var greenfieldStorageDrawerTab: some View {
        GreenfieldStorageView(viewModel: viewModel.greenfieldStorageViewModel)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.25))
            )
    }
    
    private var settingsDrawerTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(V6Palette.paper)

            HStack {
                Text("Touch ID")
                    .font(.system(size: 11))
                    .foregroundColor(V6Palette.paper.opacity(0.7))
                Spacer()
                Label(viewModel.isBiometricsEnabled ? "Available" : "Unavailable", systemImage: "touchid")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(viewModel.isBiometricsEnabled ? .green : .orange)
            }

            HStack {
                Text("User Wallet")
                    .font(.system(size: 11))
                    .foregroundColor(V6Palette.paper.opacity(0.7))
                Spacer()
                if viewModel.isUserWalletOnboarded {
                    Text(viewModel.formattedUserAddress)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(V6Palette.paper.opacity(0.8))
                } else {
                    Button("Set up wallets") {
                        viewModel.isShowingWalletOnboarding = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.blue)
                    .accessibilityLabel("Open wallet onboarding")
                }
            }

            if let providerSettingsViewModel = viewModel.makeProviderSettingsViewModel() {
                ProviderSettingsView(viewModel: providerSettingsViewModel)
            }

            Divider().background(Color.white.opacity(0.1))

            HStack {
                Button("Kill switch", systemImage: "power") {
                    viewModel.triggerKillSwitch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .accessibilityLabel("Trigger emergency kill switch")

                Spacer()

                Button("Quit Notch3", systemImage: "xmark.circle") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
    }
    
    // MARK: - Subviews & Helpers
    
    private func actionChip(title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(V6Palette.paper.opacity(0.85))
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
                    .foregroundColor(V6Palette.paper)
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
                .foregroundColor(V6Palette.paper.opacity(0.5))
            
            Text(balance)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(V6Palette.paper)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
    
    private var statusColor: Color {
        viewModel.hasActiveWork ? V6Palette.activeBlue : V6Palette.paper.opacity(0.72)
    }
    
    private var headerBackground: some View {
        V6Palette.ink
    }

    private var drawerAnimation: Animation {
        .easeInOut(
            duration: NotchHUDLayout.drawerAnimationDuration(
                isInsertion: viewModel.isExpanded,
                reduceMotion: accessibilityReduceMotion
            )
        )
    }

    private var sessionAnimation: Animation {
        accessibilityReduceMotion
            ? .linear(duration: 0)
            : .easeInOut(duration: 0.2)
    }

    private var drawerTransition: AnyTransition {
        if accessibilityReduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(
                with: .offset(y: -NotchHUDLayout.drawerMotionOffset(reduceMotion: false))
            ),
            removal: .opacity.combined(
                with: .offset(y: NotchHUDLayout.drawerMotionOffset(reduceMotion: false))
            )
        )
    }

    private var containerShape: AnyShape {
        switch NotchHUDLayout.containerStyle(isExpanded: viewModel.isExpanded) {
        case .collapsedPill:
            if displayLayout.visualMode.isPhysicalNotch {
                AnyShape(CollapsedHardwareShape())
            } else {
                AnyShape(Capsule())
            }
        case .expandedDrawer:
            AnyShape(NotchShape())
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


// MARK: - V6 Vibe Island Palette & Shape Definitions



// MARK: - Pixel Invader View

public struct PixelInvaderView: View {
    private static let sprite: [[Int]] = [
        [0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0],
        [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        [1, 0, 1, 1, 1, 1, 1, 1, 1, 0, 1],
        [1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1],
        [0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0]
    ]

    public let color: Color

    public init(color: Color = V6Palette.paper) {
        self.color = color
    }
    
    public var body: some View {
        Canvas { context, size in
            let rowCount = Self.sprite.count
            let columnCount = Self.sprite[0].count
            let cellWidth = size.width / CGFloat(columnCount)
            let cellHeight = size.height / CGFloat(rowCount)

            for row in 0..<rowCount {
                for column in 0..<columnCount where Self.sprite[row][column] == 1 {
                    let cell = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    context.fill(Path(cell), with: .color(color))
                }
            }
        }
        .frame(
            width: NotchHUDLayout.collapsedBrandMarkSize.width,
            height: NotchHUDLayout.collapsedBrandMarkSize.height
        )
        .accessibilityHidden(true)
    }
}

private struct HUDPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                .easeOut(duration: NotchHUDLayout.tabPressAnimationDuration),
                value: configuration.isPressed
            )
    }
}


public enum V6Palette {
    /// Deep charcoal black background (#0d0d0f)
    public static let ink = Color(red: 13/255, green: 13/255, blue: 15/255)
    /// Warm retro paper beige text/accent (#f1ead9)
    public static let paper = Color(red: 241/255, green: 234/255, blue: 217/255)
    /// Dynamic Island Brand/Status Colors
    public static let activeBlue = Color(red: 74/255, green: 163/255, blue: 223/255) // #4aa3df
    public static let pausedAmber = Color(red: 217/255, green: 119/255, blue: 66/255) // #d97742
    public static let lockedPaper = Color(red: 241/255, green: 234/255, blue: 217/255).opacity(0.6)
}

/// Flat-top silhouette used over a physical MacBook camera housing.
public struct CollapsedHardwareShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.height / 2, 16)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

/// Backwards-compatible name retained for existing callers and tests.
public typealias VibeIslandPillShape = CollapsedHardwareShape

/// Custom path for the expanded drawer: concave curves at top corners (r=22) to wrap the physical camera housing, rounded bottom corners (r=22).
public struct NotchShape: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 22.0
        
        // Starts top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
