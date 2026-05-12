import XCTest
import AppKit
@testable import Jarvis

@MainActor
final class HUDBannerCoordinatorTests: XCTestCase {
    func test_enqueueShowsImmediatelyWhenIdle() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.inputMonitoringDenied)
        XCTAssertEqual(coordinator.currentBanner?.id, "input-monitoring-denied")
        XCTAssertEqual(coordinator.queuedCount, 0)
    }

    func test_priorityPreemption() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.inputMonitoringDenied) // priority 2
        coordinator.enqueue(.keychainEmpty)         // priority 1 — higher → pre-empt
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "keychain-empty",
            "Higher priority (keychain-empty) should pre-empt inputMonitoringDenied"
        )
    }

    func test_dismissDrainsQueue() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.keychainEmpty)
        coordinator.enqueue(.hotkeyBindFailed)
        XCTAssertEqual(coordinator.currentBanner?.id, "keychain-empty")
        coordinator.dismissCurrent()
        // Queue drain is async (0.3s delay in showBanner); wait via runloop.
        let exp = expectation(description: "next banner shows")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(coordinator.currentBanner?.id, "hotkey-bind-failed")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func test_dismissedThisLaunchDoesNotRe_enqueue() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.ollamaURLRejected)
        coordinator.dismissCurrent()
        coordinator.enqueue(.ollamaURLRejected)
        XCTAssertNil(
            coordinator.currentBanner,
            "Same banner dismissed-this-launch should not re-enqueue"
        )
    }

    /// WR-05: `clear()` called during the 300ms drain window must cancel
    /// the pending drain — otherwise a banner pops up during app quit.
    func test_clearCancelsPendingDrain() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.keychainEmpty)
        coordinator.enqueue(.hotkeyBindFailed)
        coordinator.dismissCurrent()          // schedules 300ms drain of hotkey-bind-failed
        coordinator.clear()                   // must cancel the drain

        let exp = expectation(description: "drain must not fire after clear()")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertNil(
                coordinator.currentBanner,
                "WR-05: clear() during drain window must cancel the pending drain"
            )
            XCTAssertEqual(coordinator.queuedCount, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - Round 4 — non-dismissible critical banners

    /// Round 4: non-dismissible banners must ignore `dismissCurrent()`.
    /// The whole point is that the user cannot silently restore the
    /// lying-Jarvis failure mode the round was created to fix.
    func test_nonDismissibleBannerIgnoresDismiss() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.bootHealthCritical(subsystem: "memory", reason: "vec0 missing"))
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "boot-health-critical-memory",
            "critical banner should render immediately"
        )
        coordinator.dismissCurrent()
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "boot-health-critical-memory",
            "dismissCurrent must no-op for non-dismissible banners"
        )
    }

    /// Round 4: a critical (priority-1, non-dismissible) banner must
    /// pre-empt a lower-priority current banner just like keychainEmpty
    /// would — the non-dismissible flag does not break the priority
    /// pre-emption invariant.
    func test_criticalBannerPreemptsLowerPriorityCurrent() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.hotkeyBindFailed) // priority 3
        coordinator.enqueue(.bootHealthCritical(subsystem: "memory", reason: "vec0 missing"))
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "boot-health-critical-memory",
            "priority-1 critical banner should pre-empt priority-3 current"
        )
    }

    /// WR-05: a higher-priority banner enqueued during the 300ms drain
    /// window must not be clobbered by the queued lower-priority banner
    /// after the drain timer fires.
    func test_enqueueDuringDrainCancelsDrain() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.hotkeyBindFailed)          // priority 3 current
        coordinator.enqueue(.ollamaURLRejected)         // priority 4 queued
        coordinator.dismissCurrent()                    // schedules drain of ollamaURLRejected
        coordinator.enqueue(.keychainEmpty)             // priority 1 — should render NOW

        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "keychain-empty",
            "WR-05: enqueue during drain must render immediately, not wait 300ms"
        )

        let exp = expectation(description: "drained banner must not clobber keychain-empty")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // After the drain window lapses, the keychain-empty banner
            // must still be current (not replaced by the drained
            // ollamaURLRejected).
            XCTAssertEqual(
                coordinator.currentBanner?.id,
                "keychain-empty",
                "WR-05: drained banner must not clobber higher-priority banner enqueued during drain"
            )
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - #88 / SHELL-06 — programmatic dismiss(id:)

    /// #88: `dismiss(id:)` clears a non-dismissible banner (used by
    /// AppDelegate's foreground re-probe when TCC was re-granted).
    func test_dismissByIdClearsNonDismissibleBanner() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.inputMonitoringDenied)
        XCTAssertEqual(coordinator.currentBanner?.id, "input-monitoring-denied")
        // User-triggered dismiss must NOT clear a non-dismissible banner.
        coordinator.dismissCurrent()
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "input-monitoring-denied",
            "non-dismissible banner must ignore user dismissCurrent"
        )
        // Programmatic dismiss-by-id MUST clear it.
        coordinator.dismiss(id: "input-monitoring-denied")
        XCTAssertNil(
            coordinator.currentBanner,
            "#88: dismiss(id:) must clear a non-dismissible banner when condition resolved"
        )
    }

    /// #88: `dismiss(id:)` must NOT mark the id as dismissed-this-launch
    /// — the condition can recur (user revokes again) and we need to be
    /// able to re-enqueue.
    func test_dismissByIdAllowsReEnqueueIfConditionRecurs() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.inputMonitoringDenied)
        coordinator.dismiss(id: "input-monitoring-denied")
        XCTAssertNil(coordinator.currentBanner)
        // Condition recurs (re-probe finds denial again).
        coordinator.enqueue(.inputMonitoringDenied)
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "input-monitoring-denied",
            "#88: programmatic dismiss must NOT poison the id — re-enqueue must work"
        )
    }

    /// #88: `dismiss(id:)` on an unknown id is a no-op.
    func test_dismissByIdUnknownIsNoop() {
        let panel = HUDBannerPanel()
        let coordinator = HUDBannerCoordinator(panel: panel)
        coordinator.enqueue(.keychainEmpty)
        coordinator.dismiss(id: "nonexistent")
        XCTAssertEqual(
            coordinator.currentBanner?.id,
            "keychain-empty",
            "#88: dismiss(id:) on unknown id must not affect current banner"
        )
    }
}
