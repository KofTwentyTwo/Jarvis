import Foundation
import AppKit
import Carbon.HIToolbox  // for kVK_* constants only — NOT RegisterEventHotKey

/// Flags a handful of popular-app collisions for the first-launch hotkey
/// binder. Warnings are informational — a collision still binds successfully;
/// the warning tells the user "this shortcut will shadow app X while Jarvis
/// is running." UI-SPEC Surface 2 copywriting table lines 185-186.
///
/// kVK_ANSI_J = 38, kVK_Space = 49.
public enum CollisionDetector {
    public struct CollisionWarning: Sendable, Equatable {
        public let apps: [String]
        public let message: String
    }

    public static func check(_ shortcut: KeyboardShortcut) -> CollisionWarning? {
        let flags = shortcut.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Shift+J → Chrome / Slack / VS Code
        if shortcut.keyCode == UInt16(kVK_ANSI_J) && flags == [.command, .shift] {
            return CollisionWarning(
                apps: ["Chrome", "Slack", "VS Code"],
                message: "`Cmd+Shift+J` is used by Chrome, Slack, and VS Code. It will work, but those apps won't see the shortcut while Jarvis is bound to it."
            )
        }

        // Option+Space → Alfred / Raycast
        if shortcut.keyCode == UInt16(kVK_Space) && flags == [.option] {
            return CollisionWarning(
                apps: ["Alfred", "Raycast"],
                message: "`Option+Space` is used by Alfred and Raycast. It will work, but those apps won't see the shortcut while Jarvis is bound to it."
            )
        }

        return nil
    }
}
