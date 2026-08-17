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

/// Content view for the trigger panel to handle hover tracking, left clicks, and right clicks.
public final class NotchTriggerView: NSView {
    private var trackingArea: NSTrackingArea?
    
    public var onHover: ((Bool) -> Void)?
    public var onClick: (() -> Void)?
    public var onRightClick: ((NSEvent) -> Void)?
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }
    
    public override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }
    
    public override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
    
    public override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    
    public override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

/// Generic hosting view subclass that handles mouse hover tracking for the main HUD view.
public final class NotchHUDHostingView<Content: View>: NSHostingView<Content> {
    private var trackingArea: NSTrackingArea?
    public var onHover: ((Bool) -> Void)?
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }
    
    public override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }
    
    public override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

/// Controller managing the floating borderless Notch HUD panel, hardware notch detection,
/// hover state machine triggers, dynamic window resizing, and right-click context menus.
@MainActor
public final class NotchWindowController: NSObject, ObservableObject {
    
    // MARK: - Properties
    
    public let viewModel: NotchHUDViewModel
    public private(set) var panel: NotchPanel?
    public private(set) var triggerPanel: NotchTriggerPanel?
    
    private var hostingView: NotchHUDHostingView<NotchHUDView>?
    private var cancellables = Set<AnyCancellable>()
    
    // Hover state machine fields
    private var isMouseInTrigger = false
    private var isMouseInHUD = false
    private var hideTimer: Timer?
    
    @Published public private(set) var isPanelVisible: Bool = false
    
    public var onRightClick: (@MainActor (NSEvent) -> Void)?
    
    public var defaultContentSize: CGSize {
        viewModel.isExpanded ? CGSize(width: 520, height: 400) : CGSize(width: 240, height: 40)
    }
    
    // MARK: - Initializers
    
    public init(viewModel: NotchHUDViewModel) {
        self.viewModel = viewModel
        super.init()
        setupPanel()
        setupTriggerPanel()
        bindViewModel()
    }
    
    public override convenience init() {
        self.init(viewModel: NotchHUDViewModel())
    }
    
    deinit {
        hideTimer?.invalidate()
    }
    
    // MARK: - Panel Setup
    
    private func setupPanel() {
        let size = viewModel.isExpanded ? CGSize(width: 520, height: 400) : CGSize(width: 240, height: 40)
        let initialFrame = calculateTargetFrame(for: size)
        
        let newPanel = NotchPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        
        let hudView = NotchHUDView(viewModel: viewModel)
        let hostView = NotchHUDHostingView(rootView: hudView)
        hostView.autoresizingMask = [.width, .height]
        hostView.frame = NSRect(origin: .zero, size: initialFrame.size)
        
        hostView.onHover = { [weak self] isHovered in
            self?.isMouseInHUD = isHovered
            if isHovered {
                self?.cancelHideTimer()
            } else {
                self?.startHideTimer()
            }
        }
        
        newPanel.contentView = hostView
        self.hostingView = hostView
        self.panel = newPanel
    }
    
    /// Spawns the invisible trigger panel right at the screen's top center over the notch.
    private func setupTriggerPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // Detect hardware notch height if present (typical safe inset top)
        var notchHeight: CGFloat = 0.0
        if #available(macOS 12.0, *) {
            if let safeInsets = screen.safeAreaInsets as NSEdgeInsets?, safeInsets.top > 0 {
                notchHeight = safeInsets.top
            } else if screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil {
                notchHeight = max(screenFrame.maxY - visibleFrame.maxY, 32.0)
            }
        }
        
        // Use 24pt fallback height (standard menu bar) on notchless displays
        let triggerHeight = notchHeight > 0 ? notchHeight : 24.0
        let triggerWidth: CGFloat = 180.0
        
        let triggerFrame = NSRect(
            x: screenFrame.origin.x + (screenFrame.width - triggerWidth) / 2.0,
            y: screenFrame.maxY - triggerHeight,
            width: triggerWidth,
            height: triggerHeight
        )
        
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
        trigger.ignoresMouseEvents = false
        trigger.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        
        let triggerView = NotchTriggerView(frame: NSRect(origin: .zero, size: triggerFrame.size))
        
        triggerView.onHover = { [weak self] isHovered in
            self?.isMouseInTrigger = isHovered
            if isHovered {
                self?.cancelHideTimer()
                self?.showNotchPanel()
            } else {
                self?.startHideTimer()
            }
        }
        
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
            }
            .store(in: &cancellables)
    }
    
    private func adjustPanelSize(isExpanded: Bool) {
        guard isPanelVisible else { return }
        let size = isExpanded ? CGSize(width: 520, height: 400) : CGSize(width: 440, height: 48)
        let targetFrame = calculateTargetFrame(for: size)
        
        // Smoothly animate window size changes (matching Dynamic Island style)
        panel?.setFrame(targetFrame, display: true, animate: true)
    }
    
    // MARK: - Hover Timer State Machine
    
    private func startHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.isMouseInTrigger && !self.isMouseInHUD {
                    self.hideNotchPanel()
                    self.viewModel.isExpanded = false
                }
            }
        }
    }
    
    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
    
    // MARK: - Geometry & Frame Calculations
    
    /// Calculates the panel NSRect centered horizontally and attached to the top screen notch or menu bar.
    public func calculateFrame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        notchHeight: CGFloat,
        contentSize: CGSize
    ) -> NSRect {
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 100, y: 100, width: contentSize.width, height: contentSize.height)
        }
        
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // Detect hardware notch height if present via auxiliary areas or safe area insets
        var notchHeight: CGFloat = 0.0
        if #available(macOS 12.0, *) {
            if let safeInsets = screen.safeAreaInsets as NSEdgeInsets?, safeInsets.top > 0 {
                notchHeight = safeInsets.top
            } else if screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil {
                notchHeight = max(screenFrame.maxY - visibleFrame.maxY, 32.0)
            }
        }
        
        return calculateFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            notchHeight: notchHeight,
            contentSize: contentSize
        )
    }
    
    // MARK: - Presentation Actions
    
    /// Toggles the visibility of the Notch HUD panel.
    public func toggleNotchPanel() {
        if isPanelVisible {
            hideNotchPanel()
            viewModel.isExpanded = false
        } else {
            showNotchPanel()
        }
    }
    
    /// Smoothly animates and shows the Notch HUD panel.
    public func showNotchPanel() {
        guard let panel = panel else { return }
        
        let size = viewModel.isExpanded ? CGSize(width: 520, height: 400) : CGSize(width: 440, height: 48)
        let targetFrame = calculateTargetFrame(for: size)
        panel.setFrame(targetFrame, display: true)
        
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isPanelVisible = true
            }
        }
        
        self.isPanelVisible = true
    }
    
    /// Smoothly animates and hides the Notch HUD panel.
    public func hideNotchPanel() {
        guard let panel = panel else { return }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.isPanelVisible = false
            }
        }
        
        self.isPanelVisible = false
    }
}
