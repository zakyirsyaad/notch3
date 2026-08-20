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
    
    /// Updates the status bar item with Notch3 branding. Session authentication
    /// is intentionally not represented as a lock/pause status here.
    public func updateStatusItemVisuals() {
        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Notch3")?.withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }

        button.toolTip = "Notch3 (\(viewModel.formattedBalance))"
    }
    
    // MARK: - Menu Construction
    
    /// Builds the standard context menu for the status item.
    public func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        
        // 1. Toggle Notch Panel
        let toggleTitle = windowController.isPanelVisible ? "Close Notch3" : "Open Notch3"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleNotchHUDAction), keyEquivalent: "n")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Status & Network Info
        let statusMenuItem = NSMenuItem(title: "Notch3", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        let balanceMenuItem = NSMenuItem(title: "Balance: \(viewModel.formattedBalance)", action: nil, keyEquivalent: "")
        balanceMenuItem.isEnabled = false
        menu.addItem(balanceMenuItem)
        
        // Multi-Chain Network Submenu
        let networkMenuItem = NSMenuItem(title: "Network: \(viewModel.networkName) (\(viewModel.chainId))", action: nil, keyEquivalent: "")
        let networkSubmenu = NSMenu(title: "Switch Network")
        networkSubmenu.autoenablesItems = false
        
        for network in viewModel.networkSwitcherViewModel.supportedNetworks {
            let itemTitle = "\(network.name) (\(network.chainId))\(network.isTestnet ? " [Testnet]" : "")"
            let netItem = NSMenuItem(title: itemTitle, action: #selector(switchNetworkAction(_:)), keyEquivalent: "")
            netItem.target = self
            netItem.tag = network.chainId
            netItem.state = (viewModel.chainId == network.chainId) ? .on : .off
            networkSubmenu.addItem(netItem)
        }
        
        networkMenuItem.submenu = networkSubmenu
        menu.addItem(networkMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem.separator())

        // 3. Open Drawer Tabs
        let chatItem = NSMenuItem(title: "Open Chat", action: #selector(openChatAction), keyEquivalent: "1")
        chatItem.target = self
        menu.addItem(chatItem)
        
        let walletItem = NSMenuItem(title: "Open Wallet", action: #selector(openWalletAction), keyEquivalent: "2")
        walletItem.target = self
        menu.addItem(walletItem)
        
        let storageItem = NSMenuItem(title: "Open Greenfield Storage", action: #selector(openStorageAction), keyEquivalent: "3")
        storageItem.target = self
        menu.addItem(storageItem)
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. Emergency termination
        let killSwitchItem = NSMenuItem(title: "Emergency kill switch", action: #selector(killSwitchAction), keyEquivalent: "k")
        killSwitchItem.target = self
        menu.addItem(killSwitchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 5. Quit
        let quitItem = NSMenuItem(title: "Quit Notch3", action: #selector(quitAction), keyEquivalent: "q")
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
    
    @objc private func openChatAction() {
        openTabAfterAuthentication(.chat)
    }
    
    @objc private func openWalletAction() {
        openTabAfterAuthentication(.wallet)
    }
    
    @objc private func openStorageAction() {
        openTabAfterAuthentication(.storage)
    }
    
    @objc private func switchNetworkAction(_ sender: NSMenuItem) {
        let chainId = sender.tag
        Task { [weak self] in
            _ = await self?.viewModel.networkSwitcherViewModel.switchNetwork(to: chainId)
        }
    }
    
    @objc private func openSettingsAction() {
        openTabAfterAuthentication(.settings)
    }

    private func openTabAfterAuthentication(_ tab: HUDTab) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if viewModel.isExpanded {
                if !viewModel.isShowingWalletOnboarding {
                    viewModel.selectedTab = tab
                }
            } else {
                await viewModel.openFromNotch()
                if viewModel.isExpanded && viewModel.isSetupComplete {
                    viewModel.selectedTab = tab
                }
            }
            windowController.showNotchPanel()
        }
    }
    
    @objc private func killSwitchAction() {
        viewModel.triggerKillSwitch()
        windowController.hideNotchPanel()
    }
    
    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
