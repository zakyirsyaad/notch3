import Testing
import AppKit
import Foundation
@testable import NotchAgentCore

@Suite("Lifecycle Manager, Screen Lock, and AppDelegate Tests")
struct LifecycleManagerTests {

    // MARK: - Screen Lock & Sleep Tests

    @Test("Screen lock event immediately triggers agent.lock")
    func testScreenLockTriggersAgentLock() async {
        let runner = MockAgentProcessRunner()
        let manager = LifecycleManager(processRunner: runner)
        manager.handleScreenLockEvent()
        #expect(runner.lockIssued == true, "Expected agent.lock to be issued when screen lock occurs")
    }

    @Test("Screen sleep event triggers agent.lock and updates view model")
    func testScreenSleepTriggersAgentLock() async {
        let runner = MockAgentProcessRunner()
        let viewModel = await NotchHUDViewModel()
        let manager = LifecycleManager(processRunner: runner, viewModel: viewModel)
        
        manager.handleScreenSleepEvent()
        
        #expect(runner.lockIssued == true, "Expected agent.lock to be issued when screen sleeps")
        let isLocked = await viewModel.isLocked
        #expect(isLocked == true, "Expected NotchHUDViewModel to transition to locked state on screen sleep")
    }

    @Test("System sleep notification triggers agent lock")
    func testSystemSleepNotificationTriggersLock() async {
        let runner = MockAgentProcessRunner()
        let viewModel = await NotchHUDViewModel()
        let notificationCenter = NotificationCenter()
        let manager = LifecycleManager(
            processRunner: runner,
            viewModel: viewModel,
            notificationCenter: notificationCenter
        )
        
        manager.startMonitoring()
        
        // Post mock willSleepNotification
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        
        #expect(runner.lockIssued == true, "Expected willSleepNotification to trigger agent lock")
        let isLocked = await viewModel.isLocked
        #expect(isLocked == true)
    }

    @Test("Distributed screen lock notification issues agent.lock")
    func testDistributedScreenLockNotification() async {
        let runner = MockAgentProcessRunner()
        let distributedCenter = NotificationCenter()
        let manager = LifecycleManager(
            processRunner: runner,
            distributedNotificationCenter: distributedCenter
        )
        
        manager.startMonitoring()
        
        // Post distributed screen lock notification
        distributedCenter.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        
        #expect(runner.lockIssued == true, "Distributed screen lock notification must issue agent.lock")
    }

    // MARK: - Kill Switch Tests

    @Test("Kill switch triggers emergency halt, locks agent, and collapses HUD")
    func testKillSwitchEmergencyHaltAndState() async {
        let runner = MockAgentProcessRunner()
        let viewModel = await NotchHUDViewModel()
        let manager = LifecycleManager(processRunner: runner, viewModel: viewModel)
        
        let killSwitchCallbackInvoked = ValueContainer<Bool>(false)
        manager.onKillSwitchTriggered = {
            killSwitchCallbackInvoked.set(true)
        }
        
        manager.triggerKillSwitch()
        
        #expect(runner.lockIssued == true, "Kill switch must immediately issue agent lock")
        #expect(killSwitchCallbackInvoked.get() == true, "Kill switch callback must be invoked")
        let isLocked = await viewModel.isLocked
        #expect(isLocked == true, "View model must be locked")
        let isExpanded = await viewModel.isExpanded
        #expect(isExpanded == false, "HUD panel must be collapsed on kill switch")
    }

    // MARK: - Volatile Session Key Zeroing Tests

    @Test("Volatile session keys are securely registered and zeroed on lock")
    func testVolatileSessionKeyRegistrationAndZeroing() async {
        let runner = MockAgentProcessRunner()
        let manager = LifecycleManager(processRunner: runner)
        
        let sensitiveKey = "session_ephemeral_auth_key"
        let sampleSecret = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        
        manager.registerVolatileSessionKey(name: sensitiveKey, data: sampleSecret)
        #expect(manager.registeredVolatileKeyCount == 1)
        
        // Trigger lock
        manager.handleScreenLockEvent()
        
        // Ensure registered volatile keys are wiped/zeroed
        #expect(manager.registeredVolatileKeyCount == 0, "Volatile keys must be cleared upon lock")
        #expect(manager.getVolatileSessionKey(name: sensitiveKey) == nil, "Key must no longer exist after wipe")
    }

    // MARK: - Lifecycle Monitoring State Tests

    @Test("Start and stop monitoring transitions lifecycle monitoring state")
    func testStartAndStopMonitoring() async {
        let runner = MockAgentProcessRunner()
        let manager = LifecycleManager(processRunner: runner)
        
        #expect(manager.isMonitoring == false)
        
        manager.startMonitoring()
        #expect(manager.isMonitoring == true)
        
        // Calling startMonitoring repeatedly is idempotent
        manager.startMonitoring()
        #expect(manager.isMonitoring == true)
        
        manager.stopMonitoring()
        #expect(manager.isMonitoring == false)
    }

    // MARK: - AppDelegate Integration Tests

    @Test("AppDelegate initializes components, starts monitoring, and performs clean shutdown")
    @MainActor
    func testAppDelegateIntegration() {
        let runner = MockAgentProcessRunner()
        let viewModel = NotchHUDViewModel()
        let delegate = AppDelegate(viewModel: viewModel, agentRunner: runner)
        
        #expect(delegate.viewModel === viewModel)
        #expect(delegate.windowController.viewModel === viewModel)
        #expect(delegate.menuBarController.viewModel === viewModel)
        #expect(delegate.lifecycleManager.isMonitoring == false)
        
        // Simulate app launch
        let notif = Notification(name: NSApplication.didFinishLaunchingNotification)
        delegate.applicationDidFinishLaunching(notif)
        
        #expect(delegate.lifecycleManager.isMonitoring == true, "AppDelegate must start lifecycle monitoring on launch")
        #expect(delegate.menuBarController.statusItem != nil, "AppDelegate must setup status item in menu bar")
        
        // Triggering kill switch via view model should propagate to lifecycle manager
        viewModel.triggerKillSwitch()
        #expect(runner.lockIssued == true, "Kill switch triggered from view model must reach runner")
        
        // Simulate app termination
        let termNotif = Notification(name: NSApplication.willTerminateNotification)
        delegate.applicationWillTerminate(termNotif)
        
        #expect(delegate.lifecycleManager.isMonitoring == false, "AppDelegate must stop monitoring on termination")
        #expect(runner.stopCalled == true, "AppDelegate must stop agent runner on termination")
    }
}

// MARK: - Test Helpers

private final class ValueContainer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) {
        self.value = initial
    }

    func set(_ val: T) {
        lock.lock()
        defer { lock.unlock() }
        self.value = val
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return self.value
    }
}
