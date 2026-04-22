import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Shell

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    /// `@unchecked Sendable`: mutable `var` storage is required to capture
    /// the delegate callbacks for assertion, and every test interaction
    /// happens on the main thread.
    private final class RecordingDelegate: ShortcutRecorderHostView.Delegate, @unchecked Sendable {
        var recorded: KeyboardShortcut?
        var rejectedReason: String?
        var aborted = false

        func shortcutRecorder(
            _ view: ShortcutRecorderHostView,
            recorded shortcut: KeyboardShortcut
        ) {
            recorded = shortcut
        }

        func shortcutRecorder(
            _ view: ShortcutRecorderHostView,
            rejected reason: String
        ) {
            rejectedReason = reason
        }

        func shortcutRecorderDidAbort(_ view: ShortcutRecorderHostView) {
            aborted = true
        }
    }

    private func makeEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func test_modifierOnlyRejected() {
        let view = ShortcutRecorderHostView()
        let delegate = RecordingDelegate()
        view.delegate = delegate

        // Shift-key keyCode (kVK_Shift = 56) with no modifier flags.
        let event = makeEvent(keyCode: UInt16(kVK_Shift), modifiers: [])
        _ = view.process(event: event)

        XCTAssertNotNil(delegate.rejectedReason)
        XCTAssertTrue(delegate.rejectedReason!.contains("at least one regular key"))
        XCTAssertNil(delegate.recorded)
    }

    func test_shiftOnlyRejected() {
        let view = ShortcutRecorderHostView()
        let delegate = RecordingDelegate()
        view.delegate = delegate

        let event = makeEvent(keyCode: UInt16(kVK_ANSI_J), modifiers: [.shift])
        _ = view.process(event: event)

        XCTAssertNotNil(delegate.rejectedReason)
        XCTAssertTrue(delegate.rejectedReason!.contains("Shift alone"))
        XCTAssertNil(delegate.recorded)
    }

    func test_escapeAborts() {
        let view = ShortcutRecorderHostView()
        let delegate = RecordingDelegate()
        view.delegate = delegate

        let event = makeEvent(keyCode: UInt16(kVK_Escape), modifiers: [])
        _ = view.process(event: event)

        XCTAssertTrue(delegate.aborted)
        XCTAssertNil(delegate.recorded)
        XCTAssertNil(delegate.rejectedReason)
    }

    func test_validCaptureCallsCoordinator() {
        let view = ShortcutRecorderHostView()
        let delegate = RecordingDelegate()
        view.delegate = delegate

        let event = makeEvent(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .shift])
        _ = view.process(event: event)

        XCTAssertNotNil(delegate.recorded)
        XCTAssertEqual(delegate.recorded?.keyCode, UInt16(kVK_ANSI_J))
        XCTAssertEqual(
            delegate.recorded?.modifierFlags.intersection(.deviceIndependentFlagsMask),
            [.command, .shift]
        )
    }

    func test_cmdShiftJCollision() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt16(kVK_ANSI_J),
            modifiers: [.command, .shift]
        )
        let warning = CollisionDetector.check(shortcut)
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.apps, ["Chrome", "Slack", "VS Code"])
    }

    func test_optionSpaceCollision() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt16(kVK_Space),
            modifiers: [.option]
        )
        let warning = CollisionDetector.check(shortcut)
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.apps, ["Alfred", "Raycast"])
    }

    func test_uncommonComboNoCollision() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt16(kVK_F5),
            modifiers: [.control]
        )
        XCTAssertNil(CollisionDetector.check(shortcut))
    }
}
