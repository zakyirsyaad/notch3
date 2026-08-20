import Testing
import AppKit
import Foundation
@testable import NotchAgentCore

@Suite("Lifecycle Manager and Notch3 Session Tests")
struct LifecycleManagerTests {

    @Test("Screen lock issues the internal runtime session clear")
    func screenLockClearsRuntimeSession() {
        let runner = MockAgentProcessRunner()
        let manager = LifecycleManager(processRunner: runner)
        manager.handleScreenLockEvent()
        #expect(runner.lockIssued)
    }

    @Test("Display sleep clears the internal session without a public lock transition")
    @MainActor
    func displaySleepClearsSession() async {
        let runner = MockAgentProcessRunner()
        let viewModel = NotchHUDViewModel()
        viewModel.isExpanded = true
        let manager = LifecycleManager(processRunner: runner, viewModel: viewModel)

        manager.handleScreenSleepEvent()
        await Task.yield()

        #expect(runner.lockIssued)
        #expect(!viewModel.isExpanded)
        #expect(!viewModel.isSessionAuthenticated)
    }

    @Test("System sleep notification clears the internal session")
    @MainActor
    func systemSleepNotificationClearsSession() async {
        let runner = MockAgentProcessRunner()
        let viewModel = NotchHUDViewModel()
        viewModel.isExpanded = true
        let notificationCenter = NotificationCenter()
        let manager = LifecycleManager(
            processRunner: runner,
            viewModel: viewModel,
            notificationCenter: notificationCenter
        )

        manager.startMonitoring()
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()

        #expect(runner.lockIssued)
        #expect(!viewModel.isExpanded)
    }

    @Test("Display-only sleep notification clears the internal session")
    @MainActor
    func displayOnlySleepNotificationClearsSession() async {
        let runner = MockAgentProcessRunner()
        let viewModel = NotchHUDViewModel()
        viewModel.isExpanded = true
        let notificationCenter = NotificationCenter()
        let manager = LifecycleManager(
            processRunner: runner,
            viewModel: viewModel,
            notificationCenter: notificationCenter
        )

        manager.startMonitoring()
        notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await Task.yield()

        #expect(runner.lockIssued)
        #expect(!viewModel.isExpanded)
    }

    @Test("Distributed screen lock notification issues agent.lock")
    func distributedScreenLockNotification() {
        let runner = MockAgentProcessRunner()
        let distributedCenter = NotificationCenter()
        let manager = LifecycleManager(
            processRunner: runner,
            distributedNotificationCenter: distributedCenter
        )

        manager.startMonitoring()
        distributedCenter.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)

        #expect(runner.lockIssued)
    }

    @Test("Kill switch clears the internal session and collapses the HUD")
    @MainActor
    func killSwitchClearsSession() async {
        let runner = MockAgentProcessRunner()
        let viewModel = NotchHUDViewModel()
        viewModel.isExpanded = true
        let manager = LifecycleManager(processRunner: runner, viewModel: viewModel)
        let callback = ValueContainer<Bool>(false)
        manager.onKillSwitchTriggered = { callback.set(true) }

        manager.triggerKillSwitch()
        await Task.yield()

        #expect(runner.lockIssued)
        #expect(callback.get())
        #expect(!viewModel.isExpanded)
        #expect(!viewModel.isSessionAuthenticated)
    }

    @Test("Volatile session keys are cleared on screen lock")
    func volatileSessionKeyZeroing() {
        let manager = LifecycleManager(processRunner: MockAgentProcessRunner())
        let key = "session_ephemeral_auth_key"
        manager.registerVolatileSessionKey(name: key, data: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(manager.registeredVolatileKeyCount == 1)

        manager.handleScreenLockEvent()

        #expect(manager.registeredVolatileKeyCount == 0)
        #expect(manager.getVolatileSessionKey(name: key) == nil)
    }

    @Test("Lifecycle monitoring start and stop are idempotent")
    func monitoringState() {
        let manager = LifecycleManager(processRunner: MockAgentProcessRunner())
        #expect(!manager.isMonitoring)
        manager.startMonitoring()
        #expect(manager.isMonitoring)
        manager.startMonitoring()
        #expect(manager.isMonitoring)
        manager.stopMonitoring()
        #expect(!manager.isMonitoring)
    }

    @Test("AppDelegate wires Notch3 lifecycle and clean shutdown")
    @MainActor
    func appDelegateIntegration() {
        let runner = MockAgentProcessRunner()
        let viewModel = NotchHUDViewModel()
        let delegate = AppDelegate(viewModel: viewModel, agentRunner: runner, enableStatusItem: true)

        #expect(delegate.viewModel === viewModel)
        #expect(delegate.windowController.viewModel === viewModel)
        #expect(delegate.menuBarController.viewModel === viewModel)
        #expect(!delegate.lifecycleManager.isMonitoring)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.lifecycleManager.isMonitoring)
        #expect(delegate.menuBarController.statusItem != nil)

        viewModel.triggerKillSwitch()
        #expect(runner.lockIssued)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!delegate.lifecycleManager.isMonitoring)
        #expect(runner.stopCalled)
        #expect(!viewModel.isExpanded)
        #expect(!viewModel.isSessionAuthenticated)
    }
}

private final class ValueContainer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) { value = initial }

    func set(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
