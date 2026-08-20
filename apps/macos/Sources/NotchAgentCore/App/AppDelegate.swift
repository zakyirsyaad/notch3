import AppKit
import Foundation
import Security

/// Main macOS Application Delegate coordinating the MenuBarController, NotchWindowController,
/// LifecycleManager, Keystore Custody, and the Node.js agent runtime subprocess.
@MainActor
open class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Core Components

    public let viewModel: NotchHUDViewModel
    public let windowController: NotchWindowController
    public let menuBarController: MenuBarController
    public let agentRunner: AgentProcessRunning
    public let keystoreManager: UserKeystoreManager
    public let lifecycleManager: LifecycleManager
    public let passwordStore: KeystorePasswordStore
    public let touchIDAuthenticator: TouchIDAuthenticatorProtocol

    // MARK: - Initializer

    public let enableStatusItem: Bool

    public init(
        viewModel: NotchHUDViewModel? = nil,
        agentRunner: AgentProcessRunning = AgentProcessRunner(),
        keystoreManager: UserKeystoreManager = UserKeystoreManager(),
        passwordStore: KeystorePasswordStore = KeystorePasswordStore(),
        touchIDAuthenticator: TouchIDAuthenticatorProtocol = TouchIDAuthenticator(),
        enableStatusItem: Bool = false
    ) {
        self.enableStatusItem = enableStatusItem
        self.agentRunner = agentRunner
        self.keystoreManager = keystoreManager
        self.passwordStore = passwordStore
        self.touchIDAuthenticator = touchIDAuthenticator

        // Assemble the real transaction pipeline from the live process runner.
        let pipeline = RuntimeTransactionPipeline(client: agentRunner.client)
        let dependencies = TransactionDependencies(
            signer: keystoreManager,
            broadcaster: pipeline,
            contextProvider: pipeline,
            passwordStore: passwordStore,
            authenticator: touchIDAuthenticator,
            rpcClient: agentRunner.client
        )

        // Restore a previously imported user wallet from disk (keystore stays
        // encrypted; only ciphertext + address are loaded back into memory).
        let persistedUserWallet = passwordStore.loadUserWallet()
        if let record = persistedUserWallet {
            keystoreManager.restore(address: record.address, keystoreJson: record.keystoreJson)
        }

        let vm = viewModel ?? NotchHUDViewModel(
            transactionDependencies: dependencies,
            onboardingKeystoreManager: keystoreManager,
            onboardingPasswordStore: passwordStore,
            userWalletAddress: persistedUserWallet?.address
        )
        self.viewModel = vm

        let winController = NotchWindowController(viewModel: vm)
        self.windowController = winController
        self.menuBarController = MenuBarController(viewModel: vm, windowController: winController)

        self.lifecycleManager = LifecycleManager(
            processRunner: agentRunner,
            viewModel: vm,
            keystoreManager: keystoreManager
        )

        super.init()

        wireCallbacks()
    }

    private func wireCallbacks() {
        // Opening the collapsed notch is authenticated. The result is kept only
        // as an internal session flag; no public "locked" state is rendered.
        viewModel.onAuthenticateForHUD = { [weak self] in
            guard let self else { return false }
            return try await self.authenticateAndUnlockRuntime()
        }

        viewModel.onProvisionAgentWallet = { [weak self] _ in
            guard let self else {
                throw AgentUnlockError("Notch3 is unavailable while provisioning the Agent Wallet.")
            }
            try await self.provisionAgentWalletIfNeeded()
        }

        viewModel.onProviderConfigurationSaved = { [weak self] _ in
            guard let self else { return }
            try await self.syncProviderConfiguration()
        }

        viewModel.onKillSwitch = { [weak self] in
            self?.lifecycleManager.triggerKillSwitch()
        }

        viewModel.chatViewModel.onConfigurationRequired = { [weak self] in
            self?.viewModel.selectTab(.settings)
        }

        // Pop up the status bar context menu directly at the cursor on right click.
        windowController.onRightClick = { [weak self] event in
            guard let self = self else { return }
            let menu = self.menuBarController.buildMenu()
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: - Authenticated Unlock

    private struct UnlockResult: Codable, Sendable {
        let address: String
        let unlocked: Bool
    }

    private struct InitResult: Codable, Sendable {
        let initialized: Bool
    }

    private struct CreateWalletResult: Codable, Sendable {
        let address: String
        let keystoreJson: String
    }

    /// Authenticates the device owner and opens the internal agent session.
    private func authenticateAndUnlockRuntime() async throws -> Bool {
        guard agentRunner.isRunning else {
            throw AgentUnlockError("Agent runtime is not running. Restart the app.")
        }

        guard try await touchIDAuthenticator.authenticateUser(
            reason: "Authenticate to open Notch3"
        ) else {
            return false
        }

        try await provisionAgentWalletIfNeeded()
        try await syncProviderConfiguration()

        guard let record = passwordStore.loadAgentWallet(),
              let passphrase = passwordStore.loadAgentPassphrase() else {
            throw AgentUnlockError("Agent wallet storage is corrupted. Reset the agent wallet.")
        }

        let result: UnlockResult = try await agentRunner.client.sendRequest(
            method: "agent.unlock",
            params: ["keystoreJson": record.keystoreJson, "passphrase": passphrase]
        )

        viewModel.agentAddress = record.address
        return result.unlocked
    }

    /// Creates the Agent Wallet only after the encrypted User Wallet exists.
    /// The random passphrase is written only to the Keychain and never enters
    /// the model, logs, or user-facing UI.
    private func provisionAgentWalletIfNeeded() async throws {
        guard passwordStore.userWalletExists else {
            throw AgentUnlockError("Complete User Wallet setup before creating the Agent Wallet.")
        }
        guard !passwordStore.agentWalletExists || passwordStore.loadAgentPassphrase() == nil else {
            viewModel.refreshSetupStatus()
            return
        }
        guard agentRunner.isRunning else {
            throw AgentUnlockError("Agent runtime is not running. Run the Notch3 runtime before setup.")
        }

        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw AgentUnlockError("Failed to generate an Agent Wallet passphrase.")
        }
        let passphrase = randomBytes.map { String(format: "%02x", $0) }.joined()

        let created: CreateWalletResult = try await agentRunner.client.sendRequest(
            method: "agent.createWallet",
            params: ["passphrase": passphrase]
        )
        do {
            try passwordStore.saveAgentWallet(
                KeystorePasswordStore.AgentWalletRecord(
                    address: created.address,
                    keystoreJson: created.keystoreJson
                )
            )
            try passwordStore.saveAgentPassphrase(passphrase)
        } catch {
            passwordStore.deleteAgentWallet()
            throw error
        }
        viewModel.refreshSetupStatus()
    }

    /// Sends the exact provider fields on every settings update and every
    /// authenticated session open. The API key is read only from its dedicated
    /// Keychain record and is never returned by the runtime.
    private func syncProviderConfiguration() async throws {
        guard agentRunner.isRunning,
              let baseURL = passwordStore.loadOpenAIBaseURL(),
              let model = passwordStore.loadOpenAIModel() else {
            viewModel.chatViewModel.isProviderConfigured = false
            return
        }
        let configuration = try OpenAIProviderConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: passwordStore.loadOpenAIAPIKey()
        )
        let params = AgentConfig(
            chainId: viewModel.chainId,
            rpcUrl: viewModel.networkSwitcherViewModel.activeNetwork.rpcUrl,
            openaiApiKey: configuration.apiKey,
            openaiBaseUrl: configuration.baseURL,
            openaiModel: configuration.model
        )
        let _: InitResult = try await agentRunner.client.sendRequest(
            method: "agent.init",
            params: params
        )
        viewModel.chatViewModel.isProviderConfigured = true
    }

    // MARK: - Runtime Process Management

    /// Locates a usable Node.js binary:
    /// env override → PATH scan → version managers (fnm/volta) → common install paths.
    private func nodeBinaryPath() -> String? {
        let fm = FileManager.default

        if let fromEnv = ProcessInfo.processInfo.environment["NOTCH_NODE_BIN"],
           fm.isExecutableFile(atPath: fromEnv) {
            return fromEnv
        }

        if let resources = Bundle.main.resourceURL {
            let bundledNode = resources.appendingPathComponent("agent-runtime/node").path
            if fm.isExecutableFile(atPath: bundledNode) {
                return bundledNode
            }
        }

        // Honor the launching shell's PATH (fnm/nvm/asdf shim dirs live here).
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            let candidate = dir + "/node"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // GUI launches inherit a minimal PATH — probe version-manager defaults.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(home)/.fnm/aliases/default/bin/node",
            "\(home)/.local/share/fnm/aliases/default/bin/node",
            "\(home)/.volta/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Locates the compiled agent runtime daemon script:
    /// env override → bundled copy inside the .app → dev checkout via #filePath.
    private func daemonScriptPath() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["NOTCH_RUNTIME_SCRIPT"],
           FileManager.default.fileExists(atPath: fromEnv) {
            return fromEnv
        }

        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appendingPathComponent("agent-runtime/daemon.js")
                .path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        // Dev layout: walk up from this source file until the repo checkout's
        // packages/agent-runtime/dist/daemon.js is found (robust to restructuring).
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("packages/agent-runtime/dist/daemon.js")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private func startAgentRuntime() {
        guard let node = nodeBinaryPath() else {
            NSLog("[Notch3] node binary not found (PATH, fnm/volta, homebrew all empty)")
            viewModel.lastError = "Node.js not found. Install Node 20+ or set NOTCH_NODE_BIN."
            return
        }
        guard let script = daemonScriptPath() else {
            NSLog("[Notch3] daemon script not found (NOTCH_RUNTIME_SCRIPT, bundle, dev root)")
            viewModel.lastError = "Agent runtime daemon not built. Run `pnpm run build` first."
            return
        }
        do {
            NSLog("[Notch3] spawning runtime: \(node) \(script)")
            try agentRunner.start(nodeBinaryPath: node, scriptPath: script)
            viewModel.lastError = nil
        } catch {
            NSLog("[Notch3] runtime spawn failed: \(error)")
            viewModel.lastError = "Failed to start agent runtime: \(error.localizedDescription)"
        }
    }

    private func pollRuntimeStatus() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self, self.agentRunner.isRunning else { continue }
                if let status: AgentStatus = try? await self.agentRunner.client.sendRequest(
                    method: "agent.getStatus"
                ) {
                    self.viewModel.setAgentStatus(status)
                }
            }
        }
    }

    // MARK: - NSApplicationDelegate Lifecycle

    open func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Setup Menu Bar status item
        // Setup Menu Bar status item is disabled for a pure hardware notch trigger in prod.
        if enableStatusItem {
            menuBarController.setupStatusItem()
        }

        // 2. Start observing system lifecycle, screen lock, and sleep events
        lifecycleManager.startMonitoring()

        // 3. Spawn the Node.js agent runtime subprocess (zero-port stdin/stdout IPC)
        startAgentRuntime()

        // 4. Keep the HUD synchronized with real runtime status
        pollRuntimeStatus()
    }

    open func applicationWillTerminate(_ notification: Notification) {
        // 1. Stop lifecycle monitoring
        lifecycleManager.stopMonitoring()

        // 2. Actuate kill switch and zero sensitive session keys
        lifecycleManager.triggerKillSwitch()
        // AppDelegate is main-actor isolated, so clear the HUD synchronously
        // before stopping the subprocess rather than relying only on the
        // lifecycle manager's asynchronous notification hop.
        viewModel.clearAuthenticatedSession()

        // 3. Cleanly terminate agent subprocess and close pipes
        agentRunner.stop()
    }

    open func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.showNotchPanel()
        return true
    }
}

/// Simple domain error for unlock failures surfaced to the HUD.
public struct AgentUnlockError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
