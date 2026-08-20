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
        #expect(titles.contains { $0.contains("Open Notch3") || $0.contains("Close Notch3") })
        #expect(titles.contains { $0 == "Notch3" })
        #expect(!titles.contains { $0.contains("Pause Agent") || $0.contains("Resume Agent") })
        #expect(!titles.contains { $0.contains("Lock Agent") || $0.contains("Unlock Agent") })
        #expect(titles.contains { $0.contains("Quit") })
    }
    
    @Test("Menu keeps Notch3 status without public lock or pause controls")
    func testMenuHasNoManualSessionControls() {
        let viewModel = NotchHUDViewModel()
        let windowController = NotchWindowController(viewModel: viewModel)
        let menuBarController = MenuBarController(viewModel: viewModel, windowController: windowController)
        
        menuBarController.setupStatusItem()
        
        let menu = menuBarController.buildMenu()
        #expect(menu.items.contains { $0.title == "Notch3" })
        #expect(!menu.items.contains { $0.title.contains("Pause") || $0.title.contains("Resume") })
        #expect(!menu.items.contains { $0.title.contains("Lock Agent") || $0.title.contains("Unlock Agent") })
    }
    
    @Test("Status item click before setup opens onboarding instead of bypassing auth")
    func statusItemClickBeforeSetup() async {
        let viewModel = NotchHUDViewModel()
        let windowController = NotchWindowController(viewModel: viewModel)
        let menuBarController = MenuBarController(viewModel: viewModel, windowController: windowController)
        
        menuBarController.setupStatusItem()
        #expect(windowController.isPanelVisible)
        #expect(!windowController.viewModel.isExpanded)
        
        menuBarController.handleStatusItemClick()
        await Task.yield()
        #expect(windowController.viewModel.isExpanded)
        #expect(windowController.viewModel.isShowingWalletOnboarding)
    }
}
