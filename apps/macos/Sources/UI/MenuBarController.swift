import AppKit
import Combine

/// Controller responsible for managing the macOS system status bar item and context menu.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    
    // MARK: - Properties
    
    public let viewModel: NotchHUDViewModel
    public let windowController: NotchWindowController
    public private(set) var statusItem: NSStatusItem?
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initializer
    
    public init(viewModel: NotchHUDViewModel, windowController: NotchWindowController) {
        self.viewModel = viewModel
        self.windowController = windowController
        super.init()
        bindViewModel()
    }
    
    // MARK: - Combine Bindings
    
    private func bindViewModel() {
        viewModel.$agentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemVisuals()
            }
            .store(in: &cancellables)
        
        viewModel.$balanceTBNB
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemVisuals()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Setup
    
    /// Initializes and configures the system status item in the macOS menu bar.
    public func setupStatusItem() {
        guard statusItem == nil else { return }
        
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        self.statusItem = item
        updateStatusItemVisuals()
    }
    
    /// Updates the icon, title, and tooltip of the status bar item based on current agent state.
    public func updateStatusItemVisuals() {
        guard let button = statusItem?.button else { return }
        
        let iconName: String
        switch viewModel.agentState {
        case .unlocked:
            iconName = "sparkles"
        case .paused:
            iconName = "pause.circle.fill"
        case .locked:
            iconName = "lock.fill"
        }
        
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Notch Agent")?.withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        
        button.toolTip = "Notch Agent: \(viewModel.statusTitle) (\(viewModel.formattedBalance))"
    }
    
    // MARK: - Menu Construction
    
    /// Builds the standard context menu for the status item.
    public func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        
        // 1. Toggle Notch Panel
        let toggleTitle = windowController.isPanelVisible ? "Close Notch HUD" : "Toggle Notch HUD"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleNotchHUDAction), keyEquivalent: "n")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Status & Network Info
        let statusMenuItem = NSMenuItem(title: "Status: \(viewModel.statusEmoji) \(viewModel.statusTitle)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        let balanceMenuItem = NSMenuItem(title: "Balance: \(viewModel.formattedBalance)", action: nil, keyEquivalent: "")
        balanceMenuItem.isEnabled = false
        menu.addItem(balanceMenuItem)
        
        let networkMenuItem = NSMenuItem(title: "Network: \(viewModel.networkName) (\(viewModel.chainId))", action: nil, keyEquivalent: "")
        networkMenuItem.isEnabled = false
        menu.addItem(networkMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Pause / Resume Toggle
        let pauseResumeTitle = viewModel.isPaused ? "Resume Agent" : "Pause Agent"
        let pauseResumeItem = NSMenuItem(title: pauseResumeTitle, action: #selector(pauseResumeAction), keyEquivalent: "p")
        pauseResumeItem.target = self
        pauseResumeItem.isEnabled = !viewModel.isLocked
        menu.addItem(pauseResumeItem)
        
        // 4. Lock / Unlock Action
        let lockTitle = viewModel.isLocked ? "Unlock Agent..." : "Lock Agent"
        let lockItem = NSMenuItem(title: lockTitle, action: #selector(lockUnlockAction), keyEquivalent: "l")
        lockItem.target = self
        menu.addItem(lockItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 5. Open Drawer Tabs
        let chatItem = NSMenuItem(title: "Open Chat", action: #selector(openChatAction), keyEquivalent: "1")
        chatItem.target = self
        menu.addItem(chatItem)
        
        let walletItem = NSMenuItem(title: "Open Wallet", action: #selector(openWalletAction), keyEquivalent: "2")
        walletItem.target = self
        menu.addItem(walletItem)
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 6. Kill Switch
        let killSwitchItem = NSMenuItem(title: "Kill Switch (Emergency Lock)", action: #selector(killSwitchAction), keyEquivalent: "k")
        killSwitchItem.target = self
        menu.addItem(killSwitchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 7. Quit
        let quitItem = NSMenuItem(title: "Quit Notch Agent", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        return menu
    }
    
    // MARK: - Actions
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            handleStatusItemClick()
            return
        }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Display context menu on right click or ctrl-click
            let menu = buildMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // Reset menu so next left click still toggles panel
            DispatchQueue.main.async { [weak self] in
                self?.statusItem?.menu = nil
            }
        } else {
            // Left click toggles the Notch panel
            handleStatusItemClick()
        }
    }
    
    /// Public helper for toggling window from status item click.
    public func handleStatusItemClick() {
        windowController.toggleNotchPanel()
    }
    
    @objc private func toggleNotchHUDAction() {
        windowController.toggleNotchPanel()
    }
    
    @objc private func pauseResumeAction() {
        viewModel.togglePauseResume()
    }
    
    @objc private func lockUnlockAction() {
        if viewModel.isLocked {
            Task { _ = await viewModel.unlockAgent() }
        } else {
            viewModel.lockAgent()
        }
    }
    
    @objc private func openChatAction() {
        viewModel.selectTab(.chat)
        windowController.showNotchPanel()
    }
    
    @objc private func openWalletAction() {
        viewModel.selectTab(.wallet)
        windowController.showNotchPanel()
    }
    
    @objc private func openSettingsAction() {
        viewModel.selectTab(.settings)
        windowController.showNotchPanel()
    }
    
    @objc private func killSwitchAction() {
        viewModel.triggerKillSwitch()
        windowController.hideNotchPanel()
    }
    
    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
