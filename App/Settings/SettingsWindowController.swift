import AppKit
import SwiftUI
import Keychain
import Shell

/// Hosts the `SettingsView` in an `NSWindow`. Distinct from the first-run
/// wizard:
///
///   Setup…    → `OnboardingWizardController` (sequential first-run flow)
///   Settings… → `SettingsWindowController` (this — freeform settings panel)
///
/// Both share the same `WizardState` because the canonical truth lives there
/// (Keychain for the API key, IOHIDCheckAccess for input monitoring,
/// UserDefaults `Jarvis.hotkey` for the global shortcut). Edits in either
/// surface write through to those stores so the other surface sees current
/// values on next open.
///
/// Window discipline mirrors `OnboardingWizardController`: a single reusable
/// window, brought forward and refreshed on each `open(...)`. No stacking.
@MainActor
public final class SettingsWindowController {
    public let state: WizardState
    private var window: NSWindow?

    public init(state: WizardState) {
        self.state = state
    }

    public func open(
        keychain: any KeychainStore,
        validator: AnthropicKeyValidator,
        onGrantInputMonitoring: @escaping () -> Bool,
        onHotkeyChanged: @escaping (Shell.KeyboardShortcut?) -> Void,
        onPTTHotkeyChanged: @escaping (Shell.KeyboardShortcut?) -> Void = { _ in }
    ) {
        // Refresh truth before view creation: TCC grants and Keychain entries
        // can change between sessions, same reasoning as the wizard's
        // refresh-on-open in `OnboardingWizardController`.
        state.refresh()

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsView(
            state: state,
            keychain: keychain,
            validator: validator,
            onGrantInputMonitoring: onGrantInputMonitoring,
            onHotkeyChanged: onHotkeyChanged,
            onPTTHotkeyChanged: onPTTHotkeyChanged,
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Settings — Jarvis"
        window.isReleasedWhenClosed = false
        self.window = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
        window = nil
    }
}
