import AppKit
import Carbon.HIToolbox

/// Testable NSView subclass that processes a single `NSEvent.keyDown` and
/// dispatches to its delegate. Separated from `ShortcutRecorderView` so tests
/// can drive `process(event:)` directly without spinning up a real AppKit
/// event loop.
///
/// Rejection rules per UI-SPEC Surface 2 copywriting contract (lines 184-188):
/// - Escape aborts without setting a shortcut.
/// - Modifier-only keystrokes (mods.isEmpty after masking) are rejected with
///   "A shortcut needs at least one regular key. Try adding a letter or number."
/// - Shift-only keystrokes (mods == .shift) are rejected with
///   "Shift alone isn't a valid modifier. Try Command, Option, or Control."
/// - Anything else records as-is.
@MainActor
public final class ShortcutRecorderHostView: NSView {
    /// `@MainActor` so conformances inherit main-actor isolation — matches the
    /// host view's isolation and keeps Swift 6 strict concurrency happy. The
    /// delegate is only ever invoked inside AppKit event handling, so this is
    /// correct semantically as well.
    @MainActor
    public protocol Delegate: AnyObject {
        func shortcutRecorder(
            _ view: ShortcutRecorderHostView,
            recorded shortcut: KeyboardShortcut
        )
        func shortcutRecorder(
            _ view: ShortcutRecorderHostView,
            rejected reason: String
        )
        func shortcutRecorderDidAbort(_ view: ShortcutRecorderHostView)
    }

    public weak var delegate: Delegate?
    private var monitor: Any?

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            return self.process(event: event) ? nil : event
        }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        return super.resignFirstResponder()
    }

    /// Returns true if the event was consumed. Tests call this directly.
    @discardableResult
    public func process(event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let keyCode = event.keyCode

        if keyCode == UInt16(kVK_Escape) {
            delegate?.shortcutRecorderDidAbort(self)
            _ = resignFirstResponder()
            return true
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty {
            delegate?.shortcutRecorder(
                self,
                rejected: "A shortcut needs at least one regular key. Try adding a letter or number."
            )
            return true
        }
        if mods == .shift {
            delegate?.shortcutRecorder(
                self,
                rejected: "Shift alone isn't a valid modifier. Try Command, Option, or Control."
            )
            return true
        }

        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: mods)
        delegate?.shortcutRecorder(self, recorded: shortcut)
        _ = resignFirstResponder()
        return true
    }
}
