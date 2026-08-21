import AppKit
import SwiftUI
import Combine

/// Custom borderless floating NSPanel subclass optimized for Notch HUD presentation.
public final class NotchPanel: NSPanel {
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return true
    }
}

/// Borderless non-activating panel representing the touch target over the hardware notch.
public final class NotchTriggerPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Content view for the trigger panel to handle left clicks and right clicks (hover tracking removed).
public final class NotchTriggerView: NSView {
    public var onClick: (() -> Void)?
    public var onRightClick: ((NSEvent) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open Notch3")
        setAccessibilityHelp("Expand the Notch3 drawer")
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    
    public override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    
    public override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    public override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

/// Hosting view that lets HUD controls respond without first activating the app.
public final class NotchHostingView<Content: View>: NSHostingView<Content> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Controller managing the floating borderless Notch HUD panel, hardware notch detection,
/// dynamic window resizing, and right-click context menus. Sits permanently on screen.
@MainActor
public final class NotchWindowController: NSObject, ObservableObject {

    /// AppKit owns the panel frame animation. Opening is deliberately a little
    /// slower than closing so the drawer feels considered without becoming
    /// bouncy or spring-driven.
    public static let openAnimationDuration: TimeInterval = 0.26
    public static let closeAnimationDuration: TimeInterval = 0.18

    /// Compatibility alias for callers that only need the opening duration.
    public static let panelAnimationDuration: TimeInterval = openAnimationDuration

    public static func animationDuration(
        isOpening: Bool,
        reduceMotion: Bool
    ) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return isOpening ? openAnimationDuration : closeAnimationDuration
    }
    
    // MARK: - Properties
    
    public let viewModel: NotchHUDViewModel
    public private(set) var panel: NotchPanel?
    public private(set) var triggerPanel: NotchTriggerPanel?
    
    private var hostingView: NotchHostingView<NotchHUDView>?
    private var cancellables = Set<AnyCancellable>()
    private var panelFrameAnimation: NSViewAnimation?
    private var screenParametersObserver: NSObjectProtocol?
    private var isOpeningFromNotch = false

    private(set) var displayLayout: NotchDisplayLayout
    
    @Published public private(set) var isPanelVisible: Bool = false
    
    public var onRightClick: (@MainActor (NSEvent) -> Void)?
    
    public var defaultContentSize: CGSize {
        viewModel.isExpanded ? NotchHUDLayout.expandedSize : displayLayout.collapsedSize
    }
    
    // MARK: - Initializers
    
    public init(viewModel: NotchHUDViewModel) {
        self.viewModel = viewModel
        self.displayLayout = Self.initialDisplayLayout()
        super.init()
        setupPanel()
        setupTriggerPanel()
        bindViewModel()
        observeScreenChanges()
        
        // Show immediately at launch in the default collapsed state.
        showNotchPanel()
    }
    
    public override convenience init() {
        self.init(viewModel: NotchHUDViewModel())
    }
    
    // MARK: - Panel Setup
    
    private func setupPanel() {
        let size = defaultContentSize
        let initialFrame = calculateTargetFrame(for: size)
        
        let newPanel = NotchPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        
        let hudView = NotchHUDView(
            viewModel: viewModel,
            displayLayout: displayLayout
        )
        let hostView = NotchHostingView(rootView: hudView)
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.autoresizingMask = [.width, .height]
        hostView.frame = NSRect(origin: .zero, size: initialFrame.size)
        
        newPanel.contentView = hostView
        self.hostingView = hostView
        self.panel = newPanel
    }
    
    /// Spawns the invisible trigger panel right at the screen's top center over the notch.
    private func setupTriggerPanel() {
        // Match the complete display-aware collapsed chrome so its icon,
        // title, and active-work indicator all respond to the first click.
        let triggerFrame = displayLayout.triggerFrame
        
        let trigger = NotchTriggerPanel(
            contentRect: triggerFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        trigger.level = .statusBar + 1
        trigger.isOpaque = false
        trigger.backgroundColor = .clear
        trigger.hasShadow = false
        trigger.ignoresMouseEvents = viewModel.isExpanded
        trigger.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        
        let triggerView = NotchTriggerView(frame: NSRect(origin: .zero, size: triggerFrame.size))
        
        triggerView.onClick = { [weak self] in
            self?.toggleNotchPanel()
        }
        
        triggerView.onRightClick = { [weak self] event in
            self?.onRightClick?(event)
        }
        
        trigger.contentView = triggerView
        trigger.orderFrontRegardless()
        self.triggerPanel = trigger
    }
    
    // MARK: - Combine Bindings
    
    private func bindViewModel() {
        // Automatically resize the HUD panel window when collapsed vs expanded (drawer toggle)
        viewModel.$isExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isExpanded in
                self?.adjustPanelSize(isExpanded: isExpanded)
                self?.triggerPanel?.ignoresMouseEvents = isExpanded
                self?.triggerPanel?.contentView?.setAccessibilityElement(!isExpanded)
            }
            .store(in: &cancellables)
    }
    
    private func adjustPanelSize(isExpanded: Bool) {
        guard isPanelVisible, panel != nil else { return }
        let size = isExpanded ? NotchHUDLayout.expandedSize : displayLayout.collapsedSize
        let targetFrame = calculateTargetFrame(for: size)

        animatePanel(to: targetFrame, isOpening: isExpanded)
    }

    /// Animates the window frame itself so the transparent hosting view and the
    /// visible SwiftUI surface always share one geometry transition. Keeping
    /// the animation object lets rapid toggles stop the old frame animation,
    /// read its current window frame, and retarget from that exact position.
    private func animatePanel(to targetFrame: NSRect, isOpening: Bool) {
        guard let panel else { return }

        stopPanelFrameAnimation()

        let currentFrame = panel.frame

        let duration = Self.animationDuration(
            isOpening: isOpening,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        guard duration > 0 else {
            panel.setFrame(targetFrame, display: true, animate: false)
            return
        }

        guard currentFrame != targetFrame else { return }

        let animation = NSViewAnimation(viewAnimations: [[
            NSViewAnimation.Key.target: panel,
            NSViewAnimation.Key.startFrame: NSValue(rect: currentFrame),
            NSViewAnimation.Key.endFrame: NSValue(rect: targetFrame)
        ]])
        animation.duration = duration
        animation.animationCurve = .easeInOut
        animation.animationBlockingMode = .nonblocking
        panelFrameAnimation = animation
        animation.start()
    }
    
    // MARK: - Geometry & Frame Calculations
    
    /// Calculates the panel NSRect centered horizontally and attached to the top screen notch or menu bar.
    public func calculateFrame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        notchHeight: CGFloat,
        contentSize: CGSize
    ) -> NSRect {
        _ = visibleFrame
        _ = notchHeight
        let width = contentSize.width
        let height = contentSize.height
        
        // Centered horizontally on the target screen
        let originX = screenFrame.origin.x + (screenFrame.width - width) / 2.0
        
        // Hugs the top of the physical screen
        let originY = screenFrame.maxY - height
        
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
    
    /// Queries the active screen (or main screen) to compute the ideal panel frame.
    public func calculateTargetFrame(for contentSize: CGSize) -> NSRect {
        guard let screen = screenForPanel() else {
            return displayLayout.frame(for: contentSize)
        }

        if screen.frame == displayLayout.screenFrame {
            return displayLayout.frame(for: contentSize)
        }
        
        let screenFrame = screen.frame
        return calculateFrame(
            screenFrame: screenFrame,
            visibleFrame: screen.visibleFrame,
            notchHeight: 0,
            contentSize: contentSize
        )
    }

    /// Uses the panel's current display first. A panel can briefly have no
    /// associated screen during construction or display changes, so the main
    /// display remains a safe fallback for that short interval.
    private func screenForPanel() -> NSScreen? {
        NSScreen.main ?? panel?.screen ?? NSScreen.screens.first
    }

    private static func initialDisplayLayout() -> NotchDisplayLayout {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return .fallback
        }
        return NotchDisplayLayout(screen: screen)
    }

    private func observeScreenChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDisplayLayout()
            }
        }
    }

    /// Re-reads the active display and applies the same display-aware frame to
    /// both the rendered collapsed panel and its invisible trigger.
    public func refreshDisplayLayout() {
        stopPanelFrameAnimation()
        let nextLayout = screenForPanel().map(NotchDisplayLayout.init(screen:)) ?? .fallback
        displayLayout = nextLayout
        hostingView?.rootView = NotchHUDView(
            viewModel: viewModel,
            displayLayout: nextLayout
        )
        triggerPanel?.setFrame(nextLayout.triggerFrame, display: true, animate: false)

        guard isPanelVisible, let panel else { return }
        let targetFrame = viewModel.isExpanded
            ? nextLayout.frame(for: NotchHUDLayout.expandedSize)
            : nextLayout.triggerFrame
        panel.setFrame(targetFrame, display: true, animate: false)
    }
    
    // MARK: - Presentation Actions
    
    /// Opening from the collapsed notch is always authenticated. Closing an
    /// already expanded HUD remains immediate.
    public func toggleNotchPanel() {
        if viewModel.isExpanded {
            viewModel.toggleExpanded()
            isOpeningFromNotch = false
            return
        }

        guard !isOpeningFromNotch else { return }
        isOpeningFromNotch = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.openFromNotch()
            self.isOpeningFromNotch = false
        }
    }
    
    /// Shows the Notch HUD panel. Always visible at the top screen.
    public func showNotchPanel() {
        guard let panel = panel else { return }

        refreshDisplayLayout()
        let size = defaultContentSize
        let targetFrame = viewModel.isExpanded ? calculateTargetFrame(for: size) : displayLayout.triggerFrame
        panel.setFrame(targetFrame, display: true)
        
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        
        self.isPanelVisible = true
    }
    
    /// Hiding the Notch HUD is a no-op to guarantee it remains permanently on screen.
    public func hideNotchPanel() {
        // No-op. The HUD is a persistent Dynamic Island.
        self.isPanelVisible = true
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        panelFrameAnimation?.stop()
    }

    private func stopPanelFrameAnimation() {
        panelFrameAnimation?.stop()
        panelFrameAnimation = nil
    }
}
