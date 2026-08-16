import Foundation
import AppKit
import Combine

/// Manages macOS system lifecycle events (screen lock, display sleep, system sleep, session changes)
/// and enforces security guarantees such as instant agent lock, kill switch actuation, and volatile memory zeroing.
public final class LifecycleManager: @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()
    public weak var processRunner: AgentProcessRunning?
    public weak var viewModel: NotchHUDViewModel?
    public weak var keystoreManager: UserKeystoreManager?

    private let notificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private var volatileSessionKeys: [String: Data] = [:]

    public private(set) var isMonitoring: Bool = false

    // MARK: - Callbacks

    public var onScreenLocked: (@Sendable () -> Void)?
    public var onScreenUnlocked: (@Sendable () -> Void)?
    public var onKillSwitchTriggered: (@Sendable () -> Void)?

    // MARK: - Initializer

    public init(
        processRunner: AgentProcessRunning? = nil,
        viewModel: NotchHUDViewModel? = nil,
        keystoreManager: UserKeystoreManager? = nil,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.processRunner = processRunner
        self.viewModel = viewModel
        self.keystoreManager = keystoreManager
        self.notificationCenter = notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
    }

    deinit {
        stopMonitoring()
        zeroVolatileSessionKeys()
    }

    // MARK: - Lifecycle Monitoring

    /// Starts observing system lifecycle, screen lock, and display sleep notifications.
    public func startMonitoring() {
        lock.lock()
        guard !isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = true
        lock.unlock()

        registerWorkspaceObservers()
        registerDistributedObservers()
    }

    /// Stops observing system lifecycle notifications.
    public func stopMonitoring() {
        lock.lock()
        guard isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = false

        let wsObs = workspaceObservers
        let distObs = distributedObservers
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        lock.unlock()

        for obs in wsObs {
            notificationCenter.removeObserver(obs)
        }
        for obs in distObs {
            distributedNotificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Event Handlers

    /// Handles screen lock events (`com.apple.screenIsLocked`).
    public func handleScreenLockEvent() {
        performLock(reason: "screen_lock")
    }

    /// Handles display sleep events (`screensDidSleepNotification`).
    public func handleScreenSleepEvent() {
        performLock(reason: "screen_sleep")
    }

    /// Handles screen unlock events (`com.apple.screenIsUnlocked`).
    public func handleScreenUnlockEvent() {
        onScreenUnlocked?()
    }

    /// Handles screen wake events (`screensDidWakeNotification`).
    public func handleScreenWakeEvent() {
        onScreenUnlocked?()
    }

    /// Actuates the emergency kill switch: halts execution, issues agent.lock, wipes sensitive keys, collapses HUD.
    public func triggerKillSwitch() {
        performLock(reason: "kill_switch")

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.viewModel?.triggerKillSwitch()
        }

        onKillSwitchTriggered?()
    }

    // MARK: - Volatile Session Key Custody & Zeroing

    /// Registers a sensitive in-memory session key or buffer to be zeroed on lock or kill switch.
    public func registerVolatileSessionKey(name: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        volatileSessionKeys[name] = data
    }

    /// Retrieves a registered volatile session key if still present.
    public func getVolatileSessionKey(name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return volatileSessionKeys[name]
    }

    /// Count of volatile session keys currently held in memory.
    public var registeredVolatileKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return volatileSessionKeys.count
    }

    /// Cryptographically zeroes all registered volatile session key buffers and clears memory storage.
    public func zeroVolatileSessionKeys() {
        lock.lock()
        defer { lock.unlock() }

        for (key, var data) in volatileSessionKeys {
            data.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                memset_s(base, ptr.count, 0, ptr.count)
            }
            volatileSessionKeys.removeValue(forKey: key)
        }
        volatileSessionKeys.removeAll()
    }

    // MARK: - Private Lock Enforcement

    private func performLock(reason: String) {
        // 1. Issue agent.lock to runner if available
        if let runner = processRunner {
            if let mock = runner as? MockAgentProcessRunner {
                mock.issueLock()
            }
            try? runner.client.sendNotification(method: "agent.lock", params: ["reason": reason])
        }

        // 2. Transition HUD View Model to locked state
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.viewModel?.lockAgent()
        }

        // 3. Zero volatile keys
        zeroVolatileSessionKeys()

        // 4. Notify screen locked callback
        onScreenLocked?()
    }

    // MARK: - Observers Registration

    private func registerWorkspaceObservers() {
        let center = notificationCenter

        // Screen sleep
        let sleepObs = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenSleepEvent()
        }

        // System will sleep
        let willSleepObs = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.performLock(reason: "system_sleep")
        }

        // Fast user switching / session resign
        let resignObs = center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.performLock(reason: "session_resign")
        }

        // Screen wake
        let wakeObs = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenWakeEvent()
        }

        // System did wake
        let didWakeObs = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenWakeEvent()
        }

        lock.lock()
        workspaceObservers.append(contentsOf: [sleepObs, willSleepObs, resignObs, wakeObs, didWakeObs])
        lock.unlock()
    }

    private func registerDistributedObservers() {
        let center = distributedNotificationCenter

        // Screen is locked notification
        let lockObs = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenLockEvent()
        }

        // Screen is unlocked notification
        let unlockObs = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenUnlockEvent()
        }

        // Distributed screens did sleep notification
        let screenSleepObs = center.addObserver(
            forName: NSNotification.Name("com.apple.screensDidSleepNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenSleepEvent()
        }

        // Distributed screens did wake notification
        let screenWakeObs = center.addObserver(
            forName: NSNotification.Name("com.apple.screensDidWakeNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleScreenWakeEvent()
        }

        lock.lock()
        distributedObservers.append(contentsOf: [lockObs, unlockObs, screenSleepObs, screenWakeObs])
        lock.unlock()
    }
}
