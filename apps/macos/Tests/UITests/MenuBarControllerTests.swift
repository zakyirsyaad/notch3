import Testing
import AppKit
@testable import NotchAgentCore

@Suite("Menu Bar Controller & Status Item Tests")
@MainActor
struct MenuBarControllerTests {
    
    @Test("Status item setup creates item and menu hierarchy")
    func testMenuBarControllerSetup() {
        let viewModel = NotchHUDViewModel()
        let windowController = NotchWindowController(viewModel: viewModel)
        let menuBarController = MenuBarController(viewModel: viewModel, windowController: windowController)
        
        #expect(menuBarController.statusItem == nil)
        
        menuBarController.setupStatusItem()
        
        #expect(menuBarController.statusItem != nil)
        #expect(menuBarController.statusItem?.button != nil)
        
        // Verify menu items
        let menu = menuBarController.buildMenu()
        let titles = menu.items.map { $0.title }
        #expect(titles.contains { $0.contains("Toggle Notch HUD") || $0.contains("Open Notch HUD") })
        #expect(titles.contains { $0.contains("Status:") })
        #expect(titles.contains { $0.contains("Pause Agent") || $0.contains("Resume Agent") })
        #expect(titles.contains { $0.contains("Quit") })
    }
    
    @Test("Menu items update dynamically with agent state transitions")
    func testMenuUpdatesWithAgentState() {
        let viewModel = NotchHUDViewModel(agentState: .unlocked)
        let windowController = NotchWindowController(viewModel: viewModel)
        let menuBarController = MenuBarController(viewModel: viewModel, windowController: windowController)
        
        menuBarController.setupStatusItem()
        
        // State 1: Active
        var menu = menuBarController.buildMenu()
        let activeStatusItem = menu.items.first { $0.title.contains("Status:") }
        #expect(activeStatusItem != nil)
        #expect(activeStatusItem?.title.contains("Active") == true)
        
        let pauseItem = menu.items.first { $0.title.contains("Pause Agent") }
        #expect(pauseItem != nil)
        
        // State 2: Paused
        viewModel.togglePauseResume()
        menu = menuBarController.buildMenu()
        let pausedStatusItem = menu.items.first { $0.title.contains("Status:") }
        #expect(pausedStatusItem?.title.contains("Paused") == true)
        
        let resumeItem = menu.items.first { $0.title.contains("Resume Agent") }
        #expect(resumeItem != nil)
        
        // State 3: Locked
        viewModel.lockAgent()
        menu = menuBarController.buildMenu()
        let lockedStatusItem = menu.items.first { $0.title.contains("Status:") }
        #expect(lockedStatusItem?.title.contains("Locked") == true)
    }
    
    @Test("Status item click action toggles floating panel visibility")
    func testStatusItemActionTogglesWindow() {
        let viewModel = NotchHUDViewModel()
        let windowController = NotchWindowController(viewModel: viewModel)
        let menuBarController = MenuBarController(viewModel: viewModel, windowController: windowController)
        
        menuBarController.setupStatusItem()
        #expect(!windowController.isPanelVisible)
        
        menuBarController.handleStatusItemClick()
        #expect(windowController.isPanelVisible)
        
        menuBarController.handleStatusItemClick()
        #expect(!windowController.isPanelVisible)
    }
}
