import AppKit
import SwiftUI

/// Custom borderless floating NSPanel subclass optimized for Notch HUD presentation.
public final class NotchPanel: NSPanel {
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return true
    }
}

/// Controller managing the floating borderless Notch HUD panel, notch geometry detection, and slide animations.
@MainActor
public final class NotchWindowController: NSObject, ObservableObject {
    
    // MARK: - Properties
    
    public let viewModel: NotchHUDViewModel
    public private(set) var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchHUDView>?
    
    @Published public private(set) var isPanelVisible: Bool = false
    
    public var defaultContentSize = CGSize(width: 480, height: 260)
    
    // MARK: - Initializers
    
    public init(viewModel: NotchHUDViewModel) {
        self.viewModel = viewModel
        super.init()
        setupPanel()
    }
    
    public override convenience init() {
        self.init(viewModel: NotchHUDViewModel())
    }
    
    // MARK: - Panel Setup
    
    private func setupPanel() {
        let initialFrame = calculateTargetFrame(for: defaultContentSize)
        
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
        let hostView = NSHostingView(rootView: hudView)
        hostView.autoresizingMask = [.width, .height]
        hostView.frame = NSRect(origin: .zero, size: initialFrame.size)
        
        newPanel.contentView = hostView
        self.hostingView = hostView
        self.panel = newPanel
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
        
        // If there's a hardware notch, panel hugs the top of the physical screen
        // If notchHeight == 0 (notchless screen), panel aligns below the menu bar (visibleFrame.maxY)
        let originY: CGFloat
        if notchHeight > 0 {
            originY = screenFrame.maxY - height
        } else {
            originY = visibleFrame.maxY - height
        }
        
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
        } else {
            showNotchPanel()
        }
    }
    
    /// Smoothly animates and shows the Notch HUD panel.
    public func showNotchPanel() {
        guard let panel = panel else { return }
        
        let targetFrame = calculateTargetFrame(for: defaultContentSize)
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
