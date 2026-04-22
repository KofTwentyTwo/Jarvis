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
}
