import Foundation
import Testing
import AppKit
import SwiftUI
@testable import NotchAgentCore

@Suite("Notch Window Controller & Panel Geometry Tests")
@MainActor
struct NotchWindowControllerTests {

    private func makeCompletedViewModel() throws -> NotchHUDViewModel {
        let identifier = UUID().uuidString
        let store = KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-controller-\(identifier)", isDirectory: true),
            userDefaults: UserDefaults(suiteName: "notch-controller-\(identifier)")!
        )
        try store.saveUserWallet(.init(
            address: "0x1111111111111111111111111111111111111111",
            keystoreJson: "user"
        ))
        try store.saveAgentWallet(.init(
            address: "0x2222222222222222222222222222222222222222",
            keystoreJson: "agent"
        ))
        try store.saveAgentPassphrase("agent-passphrase")

        let viewModel = NotchHUDViewModel(
            onboardingPasswordStore: store,
            userWalletAddress: "0x1111111111111111111111111111111111111111",
            setupComplete: true
        )
        viewModel.onAuthenticateForHUD = { true }
        return viewModel
    }

    private func waitUntil(
        // Wait for the actual MainActor state transition instead of assuming
        // one scheduler yield is enough while other UI suites are running.
        timeout: Duration = .seconds(60),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }

        return true
    }
    
    @Test("Window controller initializes floating borderless panel with correct properties")
    func testWindowControllerInitialization() {
        let viewModel = NotchHUDViewModel()
        let controller = NotchWindowController(viewModel: viewModel)
        
        #expect(controller.panel != nil)
        #expect(controller.isPanelVisible) // Starts showing collapsed on launch by default
        #expect(controller.viewModel.statusTitle == "Notch3")
        #expect(!controller.viewModel.isSessionAuthenticated)
        
        guard let panel = controller.panel else {
            Issue.record("Panel should not be nil")
            return
        }
        
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.contentView?.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(!panel.hasShadow, "The transparent NSPanel must not expose a rectangular window shadow")
        #expect(panel.styleMask.contains(NSWindow.StyleMask.nonactivatingPanel))
        #expect(panel.styleMask.contains(NSWindow.StyleMask.borderless))
        #expect(panel.collectionBehavior.contains(NSWindow.CollectionBehavior.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(NSWindow.CollectionBehavior.fullScreenAuxiliary))
    }

    @Test("HUD controls accept the first click while the app is inactive")
    func testHUDViewsAcceptFirstMouse() {
        let controller = NotchWindowController()

        #expect(controller.panel?.contentView?.acceptsFirstMouse(for: nil) == true)
        #expect(controller.triggerPanel?.contentView?.acceptsFirstMouse(for: nil) == true)
    }

    @Test("Collapsed trigger exposes a labeled VoiceOver button")
    func testCollapsedTriggerAccessibility() {
        let controller = NotchWindowController()
        let triggerView = controller.triggerPanel?.contentView

        #expect(triggerView?.isAccessibilityElement() == true)
        #expect(triggerView?.accessibilityRole() == .button)
        #expect(triggerView?.accessibilityLabel() == "Open Notch3")
        #expect(triggerView?.accessibilityHelp() == "Expand the Notch3 drawer")
    }

    @Test("VoiceOver press invokes the collapsed trigger action")
    func testCollapsedTriggerAccessibilityPress() {
        let triggerView = NotchTriggerView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        var didPress = false
        triggerView.onClick = { didPress = true }

        #expect(triggerView.accessibilityPerformPress())
        #expect(didPress)
    }

    @Test("Collapsed trigger covers the entire pill")
    func testCollapsedTriggerCoversEntirePill() {
        let controller = NotchWindowController()

        #expect(controller.triggerPanel?.frame.size == controller.displayLayout.collapsedSize)
        #expect(controller.triggerPanel?.ignoresMouseEvents == false)
    }

    @Test("Collapsed panel and trigger use the exact same display-aware frame")
    func testCollapsedPanelAndTriggerFramesMatch() {
        let controller = NotchWindowController()

        #expect(controller.panel?.frame == controller.displayLayout.triggerFrame)
        #expect(controller.triggerPanel?.frame == controller.displayLayout.triggerFrame)
    }

    @Test("Trigger yields mouse events to expanded controls after onboarding gate")
    func testTriggerYieldsToExpandedControls() async throws {
        let controller = NotchWindowController(viewModel: try makeCompletedViewModel())
        var authenticationCalls = 0
        controller.viewModel.onAuthenticateForHUD = {
            authenticationCalls += 1
            return true
        }

        controller.toggleNotchPanel()
        let didExpand = await waitUntil {
            controller.viewModel.isExpanded
                && controller.triggerPanel?.ignoresMouseEvents == true
                && controller.triggerPanel?.contentView?.isAccessibilityElement() == false
        }
        #expect(didExpand)
        #expect(authenticationCalls == 1)
        #expect(controller.viewModel.isSessionAuthenticated)

        controller.toggleNotchPanel()
        let didCollapse = await waitUntil {
            !controller.viewModel.isExpanded
                && controller.triggerPanel?.ignoresMouseEvents == false
                && controller.triggerPanel?.contentView?.isAccessibilityElement() == true
        }
        #expect(didCollapse)
    }

    @Test("Expanded tab bar keeps every destination on one line")
    func testExpandedTabBarHasEnoughWidthForEveryTitle() {
        #expect(NotchHUDLayout.tabPresentation == .iconAboveLabel)
        #expect(NotchHUDLayout.tabTitleLineLimit == 1)

        let usableWidth = NotchHUDLayout.expandedSize.width
            - (NotchHUDLayout.drawerHorizontalPadding * 2)
        let totalSpacing = NotchHUDLayout.tabSpacing
            * CGFloat(HUDTab.allCases.count - 1)
        let cellWidth = (usableWidth - totalSpacing) / CGFloat(HUDTab.allCases.count)
        let font = NSFont.systemFont(
            ofSize: NotchHUDLayout.tabFontSize,
            weight: .medium
        )

        for tab in HUDTab.allCases {
            let titleWidth = ceil((tab.rawValue as NSString).size(withAttributes: [.font: font]).width)
            let requiredWidth = titleWidth + (NotchHUDLayout.tabLabelHorizontalInset * 2)

            #expect(
                cellWidth >= requiredWidth,
                "\(tab.rawValue) must fit in its tab cell without wrapping"
            )
        }
    }

    @Test("HUD interaction targets and motion stay responsive")
    func testInteractionMetricsStayResponsive() {
        #expect(NotchHUDLayout.tabMinimumHitHeight >= 44)
        #expect(NotchHUDLayout.tabPressAnimationDuration <= 0.1)
        #expect(NotchHUDLayout.tabSelectionAnimationDuration <= 0.1)
        #expect(NotchWindowController.openAnimationDuration == 0.26)
        #expect(NotchWindowController.closeAnimationDuration == 0.18)
        #expect(NotchHUDLayout.drawerInsertionDuration == 0.20)
        #expect(NotchHUDLayout.drawerRemovalDuration == 0.12)
    }

    @Test("Expanded HUD provides a 520 point tall viewport")
    func testExpandedHUDViewportHeightPreventsDrawerClipping() {
        #expect(NotchDisplayLayout.externalCollapsedWidth == 220)
        #expect(NotchDisplayLayout.collapsedHeight == 32)
        #expect(NotchHUDLayout.expandedSize == CGSize(width: 520, height: 520))
    }

    @Test("Expanded panel and hosted content use the full drawer viewport")
    func testExpandedPanelMatchesDrawerViewport() async throws {
        let controller = NotchWindowController(viewModel: try makeCompletedViewModel())

        controller.toggleNotchPanel()
        let didResize = await waitUntil {
            controller.panel?.frame.size == NotchHUDLayout.expandedSize
                && controller.panel?.contentView?.frame.size == NotchHUDLayout.expandedSize
        }

        #expect(didResize)
    }

    @Test("Long drawer tabs receive an outer vertical scroller")
    func testDrawerTabScrollPolicy() {
        #expect(NotchHUDLayout.scrollPolicy(for: .swap) == .outerVertical)
        #expect(NotchHUDLayout.scrollPolicy(for: .maker) == .outerVertical)
        #expect(NotchHUDLayout.scrollPolicy(for: .settings) == .outerVertical)

        #expect(NotchHUDLayout.scrollPolicy(for: .chat) == .preserveInternal)
        #expect(NotchHUDLayout.scrollPolicy(for: .wallet) == .preserveInternal)
        #expect(NotchHUDLayout.scrollPolicy(for: .storage) == .preserveInternal)
    }

    @Test("HUD chooses a shape that matches collapsed and expanded states")
    func testHUDContainerShapeTracksExpansionState() {
        #expect(NotchHUDLayout.containerStyle(isExpanded: false) == .collapsedPill)
        #expect(NotchHUDLayout.containerStyle(isExpanded: true) == .expandedDrawer)
    }

    @Test("Collapsed hardware shape preserves its rounded right corner")
    func testCollapsedPillRightCorner() {
        let rect = CGRect(x: 0, y: 0, width: 220, height: 32)
        let path = CollapsedHardwareShape().path(in: rect)

        // The 16pt bottom radius keeps this near-corner point inside the
        // silhouette, while the lower point is correctly outside the curve.
        #expect(path.contains(CGPoint(x: 219, y: 20)))
        #expect(!path.contains(CGPoint(x: 219, y: 22)))
    }
    
    @Test("Calculate panel frame correctly centers horizontally and respects notch height")
    func testCalculatePanelFrameForScreen() {
        let controller = NotchWindowController()
        
        // Mock screen dimensions: 1512 x 982 (14" MBP screen)
        let mockScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let mockVisibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 950) // Menu bar height = 32
        let contentSize = CGSize(width: 220, height: 32)
        
        let frameWithNotch = controller.calculateFrame(
            screenFrame: mockScreenFrame,
            visibleFrame: mockVisibleFrame,
            notchHeight: 32.0,
            contentSize: contentSize
        )
        
        // Centered horizontally: 1512 / 2 - 220 / 2 = 646
        #expect(frameWithNotch.origin.x == 646)
        #expect(frameWithNotch.size.width == 220)
        #expect(frameWithNotch.size.height == 32)
        // Hugging the top notch: maxY should equal mockScreenFrame.maxY
        #expect(frameWithNotch.maxY == mockScreenFrame.maxY)
        
        // Screen without notch fallback (notchHeight = 0) — HUD always hugs top physical screen
        let frameWithoutNotch = controller.calculateFrame(
            screenFrame: mockScreenFrame,
            visibleFrame: mockVisibleFrame,
            notchHeight: 0.0,
            contentSize: contentSize
        )
        
        #expect(frameWithoutNotch.origin.x == 646)
        #expect(frameWithoutNotch.maxY == mockScreenFrame.maxY)
    }

    @Test("Rapid collapsed and expanded targets keep the same horizontal midpoint")
    func testRapidExpansionTargetsShareHorizontalMidpoint() {
        let controller = NotchWindowController()
        let screenFrame = NSRect(x: -1728, y: 0, width: 1728, height: 1117)
        let visibleFrame = NSRect(x: -1728, y: 0, width: 1728, height: 1085)
        let sizes = [
            NotchDisplayLayout.externalCollapsedSize,
            NotchHUDLayout.expandedSize,
            NotchDisplayLayout.externalCollapsedSize,
            NotchHUDLayout.expandedSize
        ]

        let midpoints = sizes.map { size in
            let frame = controller.calculateFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                notchHeight: 32,
                contentSize: size
            )
            return frame.midX
        }

        #expect(midpoints.allSatisfy { $0 == screenFrame.midX })
    }

    @Test("Panel display takes precedence over main display during refresh")
    func testPanelDisplayPrecedence() {
        let panelScreen = TestScreen(identifier: "external")
        let mainScreen = TestScreen(identifier: "main")
        let fallbackScreen = TestScreen(identifier: "fallback")

        #expect(
            NotchWindowController.preferredScreen(
                panelScreen: panelScreen,
                mainScreen: mainScreen,
                fallbackScreen: fallbackScreen
            ) === panelScreen
        )
        #expect(
            NotchWindowController.preferredScreen(
                panelScreen: nil,
                mainScreen: mainScreen,
                fallbackScreen: fallbackScreen
            ) === mainScreen
        )
        #expect(
            NotchWindowController.preferredScreen(
                panelScreen: nil,
                mainScreen: nil,
                fallbackScreen: fallbackScreen
            ) === fallbackScreen
        )
    }

    @Test("Rapid toggles settle on the latest panel target")
    func testRapidTogglesSettleOnLatestTarget() async throws {
        let controller = NotchWindowController(viewModel: try makeCompletedViewModel())

        controller.toggleNotchPanel()
        let didOpen = await waitUntil { controller.viewModel.isExpanded }
        #expect(didOpen)

        controller.toggleNotchPanel()
        controller.toggleNotchPanel()

        let didSettleExpanded = await waitUntil {
            controller.viewModel.isExpanded
                && controller.panel?.frame.size == NotchHUDLayout.expandedSize
        }

        #expect(didSettleExpanded)
        #expect(controller.panel?.frame.midX == controller.panel?.screen?.frame.midX)
    }
    
    @Test("Show and toggle panel update visibility and expand states")
    func testShowHideTogglePanel() async throws {
        let controller = NotchWindowController(viewModel: try makeCompletedViewModel())
        
        // Starts showing collapsed on launch by default
        #expect(controller.isPanelVisible)
        #expect(!controller.viewModel.isExpanded)
        
        controller.showNotchPanel()
        #expect(controller.isPanelVisible)
        
        // hideNotchPanel is a no-op in a persistent HUD
        controller.hideNotchPanel()
        #expect(controller.isPanelVisible)
        
        // Toggling toggles the view model's isExpanded state
        controller.toggleNotchPanel()
        let didExpand = await waitUntil { controller.viewModel.isExpanded }
        #expect(didExpand)
        
        controller.toggleNotchPanel()
        let didCollapse = await waitUntil { !controller.viewModel.isExpanded }
        #expect(didCollapse)
    }

    @Test("Drawer collapse keeps a timed SwiftUI transition contract")
    func testDrawerCollapseTransitionContract() {
        let viewModel = NotchHUDViewModel(isExpanded: true)

        viewModel.toggleExpanded()

        #expect(!viewModel.isExpanded)
        #expect(NotchHUDLayout.drawerInsertionDuration == 0.20)
        #expect(NotchHUDLayout.drawerRemovalDuration == 0.12)
    }
}

private final class TestScreen: NSScreen {
    let identifier: String

    init(identifier: String) {
        self.identifier = identifier
        super.init()
    }
}
