import XCTest
import AppKit
@testable import Jarvis

@MainActor
final class AppDelegateEntitlementTests: XCTestCase {
    private struct MockProbe: EntitlementGateProbe {
        let verified: Bool
        func isVerified() -> Bool { verified }
    }

    func test_hardBlockTriggersOnMissingVerification() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = MockProbe(verified: false)
        var failureCalled = false
        delegate.onEntitlementFailure = { failureCalled = true }

        delegate.applicationWillFinishLaunching(Notification(name: .init("test")))
        XCTAssertTrue(
            failureCalled,
            "Entitlement failure callback should fire when probe returns false"
        )
    }

    func test_noHardBlockWhenVerified() {
        let delegate = AppDelegate()
        delegate.entitlementProbe = MockProbe(verified: true)
        var failureCalled = false
        delegate.onEntitlementFailure = { failureCalled = true }

        delegate.applicationWillFinishLaunching(Notification(name: .init("test")))
        XCTAssertFalse(
            failureCalled,
            "Entitlement failure should NOT fire when probe returns true"
        )

        // Clean up side effects: remove the installed status item so the test
        // leaves the status bar unchanged.
        if let item = delegate.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
