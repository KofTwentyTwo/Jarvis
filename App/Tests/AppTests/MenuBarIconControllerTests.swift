import XCTest
import AppKit
import AgentCore
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

    // MARK: - Round 4 — boot-health tint

    /// Round 4: `.loud` and `.critical` paint the menu-bar button red;
    /// `.ok` and `.soft` clear the tint.
    func test_applyHealthTintsRedForLoudAndCritical() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        defer { statusBar.removeStatusItem(item) }
        let menu = MenuBarContextMenu.build(setupAction: {}, devOverlayToggleAction: {}, stateDumpAction: {})
        let controller = MenuBarIconController(statusItem: item, contextMenu: menu)

        controller.applyHealth(.critical)
        XCTAssertEqual(controller.currentHealth, .critical)
        XCTAssertEqual(item.button?.contentTintColor, NSColor.systemRed)

        controller.applyHealth(.loud)
        XCTAssertEqual(controller.currentHealth, .loud)
        XCTAssertEqual(item.button?.contentTintColor, NSColor.systemRed)

        controller.applyHealth(.soft)
        XCTAssertEqual(controller.currentHealth, .soft)
        XCTAssertNil(item.button?.contentTintColor)

        controller.applyHealth(.ok)
        XCTAssertEqual(controller.currentHealth, .ok)
        XCTAssertNil(item.button?.contentTintColor)
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
