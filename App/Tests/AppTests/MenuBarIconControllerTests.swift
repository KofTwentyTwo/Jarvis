import XCTest
import AppKit
@testable import Jarvis

@MainActor
final class MenuBarIconControllerTests: XCTestCase {
    func test_stateTransitionUpdatesAccessibilityLabel() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        defer { statusBar.removeStatusItem(item) }

        let menu = MenuBarContextMenu.build(
            setupAction: {},
            devOverlayToggleAction: {},
            stateDumpAction: {}
        )
        let controller = MenuBarIconController(statusItem: item, contextMenu: menu)

        controller.transition(to: .listening)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(item.button?.accessibilityLabel(), "Jarvis, listening")

        controller.transition(to: .thinking)
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(item.button?.accessibilityLabel(), "Jarvis, thinking")
    }

    func test_sameStateTransitionIsNoOp() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        defer { statusBar.removeStatusItem(item) }

        let menu = MenuBarContextMenu.build(
            setupAction: {},
            devOverlayToggleAction: {},
            stateDumpAction: {}
        )
        let controller = MenuBarIconController(statusItem: item, contextMenu: menu)

        controller.transition(to: .idle)
        let firstAnimations = item.button?.layer?.animationKeys()?.sorted() ?? []
        controller.transition(to: .idle) // second call — should no-op
        let secondAnimations = item.button?.layer?.animationKeys()?.sorted() ?? []
        XCTAssertEqual(firstAnimations, secondAnimations)
    }

    func test_contextMenuItems() {
        let menu = MenuBarContextMenu.build(
            setupAction: {},
            devOverlayToggleAction: {},
            stateDumpAction: {}
        )
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Setup…"))
        XCTAssertTrue(titles.contains("Settings…"))
        XCTAssertTrue(titles.contains("Show Dev Overlay"))
        XCTAssertTrue(titles.contains("Copy State Dump"))
        XCTAssertTrue(titles.contains("Quit Jarvis"))
        // Settings… is disabled per UI-SPEC Surface 4 (P1-scope stub).
        let settings = menu.items.first { $0.title == "Settings…" }
        XCTAssertNotNil(settings)
        XCTAssertFalse(settings!.isEnabled)
    }

    func test_hudStateVoiceOverLabels() {
        XCTAssertEqual(HudState.idle.voiceOverLabel, "Jarvis, idle")
        XCTAssertEqual(HudState.listening.voiceOverLabel, "Jarvis, listening")
        XCTAssertEqual(HudState.thinking.voiceOverLabel, "Jarvis, thinking")
        XCTAssertEqual(HudState.speaking.voiceOverLabel, "Jarvis, speaking")
        XCTAssertEqual(
            HudState.awaitingConfirmation.voiceOverLabel,
            "Jarvis, waiting for your confirmation"
        )
    }
}
