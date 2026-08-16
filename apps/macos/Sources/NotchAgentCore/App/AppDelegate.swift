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

    public init(
        viewModel: NotchHUDViewModel? = nil,
        agentRunner: AgentProcessRunning = AgentProcessRunner(),
        keystoreManager: UserKeystoreManager = UserKeystoreManager(),
        passwordStore: KeystorePasswordStore = KeystorePasswordStore(),
        touchIDAuthenticator: TouchIDAuthenticatorProtocol = TouchIDAuthenticator()
    ) {
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
        // Lock / pause must propagate to the runtime — UI state may never diverge.
        viewModel.onStateChanged = { [weak self] state in
            guard let self = self, state == .locked else { return }
            try? self.agentRunner.client.sendNotification(
                method: "agent.lock",
                params: ["reason": "user_lock"]
            )
        }

        // Unlock is authenticated: Touch ID (or device passcode) must succeed before
        // the agent keystore is released to the runtime.
        viewModel.onUnlockRequested = { [weak self] _ in
            guard let self = self else { return false }
            return try await self.authenticateAndUnlockRuntime()
        }

        viewModel.onKillSwitch = { [weak self] in
            self?.lifecycleManager.triggerKillSwitch()
        }
    }

    // MARK: - Authenticated Unlock

    private struct UnlockResult: Codable, Sendable {
        let address: String
        let unlocked: Bool
    }

    private struct CreateWalletResult: Codable, Sendable {
        let address: String
        let keystoreJson: String
    }

    /// Authenticates the device owner and unlocks the agent wallet inside the runtime.
    /// On first use this onboards a fresh agent wallet (random Keychain-held passphrase).
    private func authenticateAndUnlockRuntime() async throws -> Bool {
        guard agentRunner.isRunning else {
            throw AgentUnlockError("Agent runtime is not running. Restart the app.")
        }

        _ = try await touchIDAuthenticator.authenticateUser(
            reason: "Unlock the Notch Agent wallet for autonomous payments"
        )

        // Onboard a fresh agent wallet on first unlock.
        if !passwordStore.agentWalletExists {
            var randomBytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, 32, &randomBytes)
            guard status == errSecSuccess else {
                throw AgentUnlockError("Failed to generate an agent wallet passphrase.")
            }
            let passphrase = randomBytes.map { String(format: "%02x", $0) }.joined()

            let created: CreateWalletResult = try await agentRunner.client.sendRequest(
                method: "agent.createWallet",
                params: ["passphrase": passphrase]
            )
            try passwordStore.saveAgentWallet(
                KeystorePasswordStore.AgentWalletRecord(
                    address: created.address,
                    keystoreJson: created.keystoreJson
                )
            )
            try passwordStore.saveAgentPassphrase(passphrase)
        }

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

    // MARK: - Runtime Process Management

    /// Locates a usable Node.js binary (env override → common install paths).
    private func nodeBinaryPath() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment["NOTCH_NODE_BIN"],
           FileManager.default.fileExists(atPath: fromEnv) {
            return fromEnv
        }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
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
                .appendingPathComponent("agent-runtime/packages/agent-runtime/dist/daemon.js")
                .path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        // Dev layout: <repo>/apps/macos/Sources/NotchAgentCore/App/AppDelegate.swift
        let devRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // NotchAgentCore
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
        let devScript = devRoot
            .appendingPathComponent("packages/agent-runtime/dist/daemon.js")
            .path
        return FileManager.default.fileExists(atPath: devScript) ? devScript : nil
    }

    private func startAgentRuntime() {
        guard let node = nodeBinaryPath() else {
            viewModel.lastError = "Node.js not found. Install Node 20+ or set NOTCH_NODE_BIN."
            return
        }
        guard let script = daemonScriptPath() else {
            viewModel.lastError = "Agent runtime daemon not built. Run `pnpm run build` first."
            return
        }
        do {
            try agentRunner.start(nodeBinaryPath: node, scriptPath: script)
            viewModel.lastError = nil
        } catch {
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
        menuBarController.setupStatusItem()

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
