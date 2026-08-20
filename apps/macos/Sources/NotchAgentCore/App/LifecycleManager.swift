import Foundation
import AppKit
import Combine

/// Manages the small set of lifecycle events that clear the internal agent
/// session. Display sleep and fast-user-switching are intentionally not public
/// lock controls; only screen lock, app quit, and emergency termination clear
/// the session.
public final class LifecycleManager: @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()
    public weak var processRunner: AgentProcessRunning?
    public weak var viewModel: NotchHUDViewModel?
    public weak var keystoreManager: UserKeystoreManager?

    private let distributedNotificationCenter: NotificationCenter

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
        // Retain the parameter for source compatibility with callers that
        // inject a workspace notification center; sleep notifications are no
        // longer part of the session-clearing policy.
        _ = notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
    }

    deinit {
        stopMonitoring()
        zeroVolatileSessionKeys()
    }

    // MARK: - Lifecycle Monitoring

    /// Starts observing screen lock notifications.
    public func startMonitoring() {
        lock.lock()
        guard !isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = true
        lock.unlock()

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

        let distObs = distributedObservers
        distributedObservers.removeAll()
        lock.unlock()

        for obs in distObs {
            distributedNotificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Event Handlers

    /// Handles screen lock events (`com.apple.screenIsLocked`).
    public func handleScreenLockEvent() {
        performLock(reason: "screen_lock")
    }

    /// Display sleep is intentionally not a session boundary. The agreed
    /// lifecycle policy clears credentials only for screen lock, app quit, or
    /// the emergency kill switch.
    public func handleScreenSleepEvent() {
        // Intentionally empty. The next user action continues through the
        // existing authentication/session policy.
    }

    /// Handles screen unlock events (`com.apple.screenIsUnlocked`).
    public func handleScreenUnlockEvent() {
        onScreenUnlocked?()
    }

    /// Handles screen wake events (`screensDidWakeNotification`).
    public func handleScreenWakeEvent() {
        // Intentionally empty. The next notch click performs authentication.
    }

    /// Actuates the emergency kill switch: halts execution, issues agent.lock,
    /// wipes sensitive keys, and collapses the HUD.
    public func triggerKillSwitch() {
        performLock(reason: "kill_switch")

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.viewModel?.clearAuthenticatedSession()
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

        for key in Array(volatileSessionKeys.keys) {
            volatileSessionKeys[key]?.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                memset_s(base, ptr.count, 0, ptr.count)
            }
            volatileSessionKeys.removeValue(forKey: key)
        }
        volatileSessionKeys.removeAll()
    }

    // MARK: - Private Lock Enforcement

    private func performLock(reason: String) {
        // 1. Issue agent.lock to runner if available via standard AgentProcessRunning client
        if let runner = processRunner {
            try? runner.client.sendNotification(method: "agent.lock", params: ["reason": reason])
        }

        // 2. Transition HUD View Model to locked state and collapse
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.viewModel?.clearAuthenticatedSession()
        }

        // 3. Zero volatile keys
        zeroVolatileSessionKeys()

        // 4. Notify screen locked callback
        onScreenLocked?()
    }

    // MARK: - Observers Registration

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

        lock.lock()
        distributedObservers.append(contentsOf: [lockObs, unlockObs])
        lock.unlock()
    }
}
