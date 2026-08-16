import AppKit
import Foundation

/// Main macOS Application Delegate coordinating the MenuBarController, NotchWindowController,
/// LifecycleManager, Keystore Custody, and AgentProcessRunner.
@MainActor
open class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Core Components

    public let viewModel: NotchHUDViewModel
    public let windowController: NotchWindowController
    public let menuBarController: MenuBarController
    public let agentRunner: AgentProcessRunning
    public let keystoreManager: UserKeystoreManager
    public let lifecycleManager: LifecycleManager

    // MARK: - Initializer

    public init(
        viewModel: NotchHUDViewModel,
        agentRunner: AgentProcessRunning = AgentProcessRunner(),
        keystoreManager: UserKeystoreManager = UserKeystoreManager()
    ) {
        self.viewModel = viewModel
        self.agentRunner = agentRunner
        self.keystoreManager = keystoreManager

        let winController = NotchWindowController(viewModel: viewModel)
        self.windowController = winController
        self.menuBarController = MenuBarController(viewModel: viewModel, windowController: winController)

        self.lifecycleManager = LifecycleManager(
            processRunner: agentRunner,
            viewModel: viewModel,
            keystoreManager: keystoreManager
        )

        super.init()
    }

    public override convenience init() {
        self.init(
            viewModel: NotchHUDViewModel(),
            agentRunner: AgentProcessRunner(),
            keystoreManager: UserKeystoreManager()
        )
    }

    // MARK: - NSApplicationDelegate Lifecycle

    open func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Setup Menu Bar status item
        menuBarController.setupStatusItem()

        // 2. Start observing system lifecycle, screen lock, and sleep events
        lifecycleManager.startMonitoring()

        // 3. Connect view model kill switch callback to lifecycle manager
        viewModel.onKillSwitch = { [weak self] in
            self?.lifecycleManager.triggerKillSwitch()
        }
    }

    open func applicationWillTerminate(_ notification: Notification) {
        // 1. Stop lifecycle monitoring
        lifecycleManager.stopMonitoring()

        // 2. Actuate kill switch and zero sensitive session keys
        lifecycleManager.triggerKillSwitch()

        // 3. Cleanly terminate agent subprocess and close pipes
        agentRunner.stop()
    }

    open func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.showNotchPanel()
        return true
    }
}
