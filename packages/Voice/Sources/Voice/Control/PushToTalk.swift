import AppKit
import Foundation

// MARK: - PushToTalk
//
// Wraps Phase 1's NSEvent.addGlobalMonitorForEvents to provide a PTT hotkey.
//
// VOICE-13 requirements:
//   - Holding the bound hotkey activates STT directly (bypasses wake-word DAG).
//   - Releasing finalizes the transcript and submits as a voice turn.
//   - Reuses Phase 1's NSEvent.addGlobalMonitorForEvents (not Carbon RegisterEventHotKey).
//
// VOICE-12 contract:
//   - PTT works even when wake-word is muted.
//   - Tested by PTTTests P3: muteWakeWord() then pttDown() still transitions to .listening(.ptt).
//
// Input Monitoring probe (CLAUDE.md hotkey hygiene):
//   NSEvent.addGlobalMonitorForEvents silently returns nil if Input Monitoring is
//   denied. AppDelegate's Phase 1 `hidProbe` already surfaces this via banner.
//   PushToTalk falls back to local-only mode (monitor while Jarvis is frontmost).
//
// Thread safety:
//   @unchecked Sendable — `globalToken` and `localToken` are only mutated from
//   MainActor (bind/unbind callers). The NSEvent callbacks fire on an arbitrary
//   thread but immediately hop to a detached Task.

@MainActor
public final class PushToTalk: @unchecked Sendable {

    // MARK: - State

    private let controller: VoiceController
    private var globalKeyDownToken: Any?
    private var globalKeyUpToken: Any?
    private var localKeyDownToken: Any?
    private var localKeyUpToken: Any?
    private var boundKeyCode: UInt16?
    private var boundModifiers: NSEvent.ModifierFlags = []
    private var isPTTDown: Bool = false

    // MARK: - Init

    public init(controller: VoiceController) {
        self.controller = controller
    }

    // MARK: - Bind

    /// Bind the PTT hotkey. Reads the keyCode+modifiers from the spec.
    ///
    /// Pass `inputMonitoringGranted: true` if the user granted Input Monitoring
    /// (from Phase 1's InputMonitoringProbe result stored in WizardState).
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code to monitor.
    ///   - modifiers: The required modifier flags.
    ///   - inputMonitoringGranted: Whether to install a global (cross-app) monitor.
    public func bind(keyCode: UInt16,
                     modifiers: NSEvent.ModifierFlags,
                     inputMonitoringGranted: Bool) {
        unbind()
        boundKeyCode = keyCode
        boundModifiers = modifiers

        let controller = controller

        // KEY DOWN
        let onDown: () -> Void = {
            Task { await controller.pttDown() }
        }

        // KEY UP
        let onUp: () -> Void = {
            Task { await controller.pttUp() }
        }

        if inputMonitoringGranted {
            globalKeyDownToken = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.matches(event: event) else { return }
                if !self.isPTTDown {
                    self.isPTTDown = true
                    onDown()
                }
            }
            globalKeyUpToken = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, self.matches(event: event) else { return }
                if self.isPTTDown {
                    self.isPTTDown = false
                    onUp()
                }
            }
        }

        // Local monitors work while Jarvis is frontmost regardless of Input Monitoring grant.
        localKeyDownToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event: event) else { return event }
            if !self.isPTTDown {
                self.isPTTDown = true
                onDown()
            }
            return nil  // Consume the event
        }
        localKeyUpToken = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.matches(event: event) else { return event }
            if self.isPTTDown {
                self.isPTTDown = false
                onUp()
            }
            return nil
        }
    }

    /// Remove all installed monitors.
    public func unbind() {
        if let t = globalKeyDownToken { NSEvent.removeMonitor(t); globalKeyDownToken = nil }
        if let t = globalKeyUpToken  { NSEvent.removeMonitor(t); globalKeyUpToken = nil  }
        if let t = localKeyDownToken { NSEvent.removeMonitor(t); localKeyDownToken = nil }
        if let t = localKeyUpToken   { NSEvent.removeMonitor(t); localKeyUpToken = nil   }
        boundKeyCode = nil
        boundModifiers = []
        isPTTDown = false
    }

    /// Whether a PTT hotkey is currently bound.
    public var isBound: Bool { boundKeyCode != nil }

    // MARK: - Private

    private func matches(event: NSEvent) -> Bool {
        guard let code = boundKeyCode else { return false }
        guard event.keyCode == code else { return false }
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wantedMods = boundModifiers.intersection(.deviceIndependentFlagsMask)
        return eventMods == wantedMods
    }
}
