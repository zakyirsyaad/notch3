import Testing
import AppKit
import SwiftUI
@testable import NotchAgentCore

@Suite("Notch Window Controller & Panel Geometry Tests")
@MainActor
struct NotchWindowControllerTests {
    
    @Test("Window controller initializes floating borderless panel with correct properties")
    func testWindowControllerInitialization() {
        let viewModel = NotchHUDViewModel()
        let controller = NotchWindowController(viewModel: viewModel)
        
        #expect(controller.panel != nil)
        #expect(controller.isPanelVisible) // Starts showing collapsed on launch by default
        #expect(controller.viewModel.agentState == .locked)
        
        guard let panel = controller.panel else {
            Issue.record("Panel should not be nil")
            return
        }
        
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.hasShadow)
        #expect(panel.styleMask.contains(NSWindow.StyleMask.nonactivatingPanel))
        #expect(panel.styleMask.contains(NSWindow.StyleMask.borderless))
        #expect(panel.collectionBehavior.contains(NSWindow.CollectionBehavior.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(NSWindow.CollectionBehavior.fullScreenAuxiliary))
    }
    
    @Test("Calculate panel frame correctly centers horizontally and respects notch height")
    func testCalculatePanelFrameForScreen() {
        let controller = NotchWindowController()
        
        // Mock screen dimensions: 1512 x 982 (14" MBP screen)
        let mockScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let mockVisibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 950) // Menu bar height = 32
        let contentSize = CGSize(width: 340, height: 40)
        
        let frameWithNotch = controller.calculateFrame(
            screenFrame: mockScreenFrame,
            visibleFrame: mockVisibleFrame,
            notchHeight: 32.0,
            contentSize: contentSize
        )
        
        // Centered horizontally: 1512 / 2 - 340 / 2 = 586
        #expect(frameWithNotch.origin.x == 586)
        #expect(frameWithNotch.size.width == 340)
        #expect(frameWithNotch.size.height == 40)
        // Hugging the top notch: maxY should equal mockScreenFrame.maxY
        #expect(frameWithNotch.maxY == mockScreenFrame.maxY)
        
        // Screen without notch fallback (notchHeight = 0) — HUD always hugs top physical screen
        let frameWithoutNotch = controller.calculateFrame(
            screenFrame: mockScreenFrame,
            visibleFrame: mockVisibleFrame,
            notchHeight: 0.0,
            contentSize: contentSize
        )
        
        #expect(frameWithoutNotch.origin.x == 586)
        #expect(frameWithoutNotch.maxY == mockScreenFrame.maxY)
    }
    
    @Test("Show and toggle panel update visibility and expand states")
    func testShowHideTogglePanel() {
        let controller = NotchWindowController()
        
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
        #expect(controller.viewModel.isExpanded)
        
        controller.toggleNotchPanel()
        #expect(!controller.viewModel.isExpanded)
    }
}
