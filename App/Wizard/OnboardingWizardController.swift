import AppKit
import SwiftUI
import Keychain
import Shell

/// Hosts the `WizardView` in an NSWindow and manages first-launch vs re-entry
/// modality per D-06 / D-09:
///
/// - First launch + Stage 1 unresolved → modal panel level + close button
///   disabled, so the user can't dismiss the window without a valid API key.
/// - Re-entry via Setup… menu item (non-first-launch) → standard titled
///   window, closable, non-modal; the user can close at any time.
///
/// D-09 "stateless re-entry": `open(...)` calls `state.refresh()` each time
/// so the wizard lands at the first unresolved stage regardless of where it
/// was when last closed.
@MainActor
public final class OnboardingWizardController {
    public let state: WizardState
    private var window: NSWindow?

    public init(state: WizardState) { self.state = state }

    public func open(
        keychain: any KeychainStore,
        validator: AnthropicKeyValidator,
        onGrantInputMonitoring: @escaping () -> Bool,
        onComplete: @escaping () -> Void,
        firstLaunch: Bool
    ) {
        state.refresh()

        let rootView = WizardView(
            state: state,
            keychain: keychain,
            validator: validator,
            onGrantInputMonitoring: onGrantInputMonitoring,
            onComplete: { [weak self] in
                onComplete()
                self?.close()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = firstLaunch
            ? [.titled, .closable]
            : [.titled, .closable, .miniaturizable]
        window.title = "Setup — Jarvis"
        window.isReleasedWhenClosed = false

        // First-launch modal-panel lock: block close + elevate window level so
        // the user completes Stage 1 before dismissing (D-06).
        if firstLaunch && state.currentStage == .apiKey {
            window.standardWindowButton(.closeButton)?.isEnabled = false
            window.level = .modalPanel
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    public func close() {
        window?.close()
        window = nil
    }
}
