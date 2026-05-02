import AppKit
import Combine
import SwiftUI
import Keychain
import Shell

/// Hosts the `WizardView` in an NSWindow and manages first-launch vs re-entry
/// modality per D-06 / D-09:
///
/// - First launch + apiKey stage → close button disabled until Stage 1
///   completes, so the user can't dismiss without a valid API key. Once
///   the user advances to TCC stage, the close button auto-enables.
/// - Re-entry via Setup… menu item → standard titled window, closable,
///   non-modal; the user can close at any time.
///
/// Window reuse: clicking Setup… repeatedly does NOT spawn additional
/// windows. If a wizard window is already open, it's brought forward and
/// state.refresh() is called so the visible stage matches truth.
///
/// D-09 "stateless re-entry": `open(...)` calls `state.refresh()` each time
/// so the wizard lands at the first unresolved stage regardless of where it
/// was when last closed.
@MainActor
public final class OnboardingWizardController {
    public let state: WizardState
    private var window: NSWindow?
    private var stageObserver: AnyCancellable?

    public init(state: WizardState) { self.state = state }

    public func open(
        keychain: any KeychainStore,
        validator: AnthropicKeyValidator,
        onGrantInputMonitoring: @escaping () -> Bool,
        onComplete: @escaping () -> Void,
        firstLaunch: Bool
    ) {
        // WR-09: `state.refresh()` calls `keychain.get(.anthropic)`, which
        // can block the main thread for hundreds of ms under keychain-lock
        // contention or first-run ACL prompts. Refresh BEFORE we touch any
        // window so the published `currentStage` is correct at view-creation
        // time and no flash-of-wrong-stage occurs on re-entry.
        state.refresh()
        assert(Thread.isMainThread, "WR-09: state.refresh must complete on main before view creation")

        // Reuse an existing window instead of stacking new ones. Each call
        // to open() (e.g. menu-bar Setup… clicked repeatedly) just brings
        // the same window forward.
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            applyCloseButtonState(window: existing, firstLaunch: firstLaunch)
            return
        }

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
        // Always include .closable + .miniaturizable in the style mask so
        // the user has standard window controls. The close *button* is
        // separately enabled/disabled based on stage (see helper below).
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Setup — Jarvis"
        window.isReleasedWhenClosed = false

        // Track the existing window before configuring stage-dependent state
        // so the helper can read it back.
        self.window = window

        applyCloseButtonState(window: window, firstLaunch: firstLaunch)

        // Re-enable the close button when the user advances past .apiKey on
        // first launch — without this the close button stays stuck disabled
        // for the entire session. objectWillChange fires before the
        // published value updates; defer to next runloop tick to read the
        // settled state.
        stageObserver = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, let w = self.window else { return }
                self.applyCloseButtonState(window: w, firstLaunch: firstLaunch)
            }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
        window = nil
        stageObserver = nil
    }

    /// Enable the standard close button unless we're on first-launch + the
    /// user hasn't entered an API key yet (Stage 1 of the very first run).
    /// Once the user advances past .apiKey, the button re-enables.
    private func applyCloseButtonState(window: NSWindow, firstLaunch: Bool) {
        let lockClosed = firstLaunch
            && state.currentStage == .apiKey
            && !state.apiKeyStored
        window.standardWindowButton(.closeButton)?.isEnabled = !lockClosed
        // Elevated panel level only while locked; otherwise let the wizard
        // behave like a normal window so it can be sent behind other apps.
        window.level = lockClosed ? .modalPanel : .normal
    }
}
