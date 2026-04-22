import XCTest
import AppKit
@testable import Jarvis

@MainActor
final class JarvisHUDPanelTests: XCTestCase {
    func test_panelHasExpectedStyleAndLevel() {
        let panel = JarvisHUDPanel()
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func test_summonAndDismiss() {
        let panel = JarvisHUDPanel()
        XCTAssertFalse(panel.isSummoned)
        panel.summon()
        XCTAssertTrue(panel.isSummoned)
        panel.dismiss()
        XCTAssertFalse(panel.isSummoned)
    }

    func test_escapeDismissesViaCancelOperation() {
        let panel = JarvisHUDPanel()
        panel.summon()
        XCTAssertTrue(panel.isSummoned)
        panel.cancelOperation(nil) // simulates Escape
        XCTAssertFalse(panel.isSummoned)
    }
}
