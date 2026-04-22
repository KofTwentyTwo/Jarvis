import SwiftUI
import Shell

/// Stage 3 of the first-launch wizard (UI-SPEC Surface 1). Binds the global
/// hotkey via the hand-rolled `ShortcutRecorderView`. Collision warnings
/// surface via `CollisionDetector`. Ships unset by default (SHELL-02); Skip
/// leaves it unbound (the menu-bar icon is always a viable fallback).
struct WizardStageHotkeyView: View {
    @ObservedObject var state: WizardState
    @State private var shortcut: Shell.KeyboardShortcut? = nil
    @State private var errorMessage: String? = nil
    let onAdvance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bind Your Hotkey").font(.system(size: 17, weight: .semibold))
            Text("Pick a keyboard shortcut to summon Jarvis from anywhere. You can change this any time from the menu bar.")
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            HStack {
                Text("Global shortcut").frame(width: 140, alignment: .leading)
                ShortcutRecorderView(shortcut: $shortcut, errorMessage: $errorMessage)
                    .frame(height: 40)
            }
            if let warning = shortcut.flatMap(CollisionDetector.check) {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(Color(NSColor.systemOrange))
            }
            if let err = errorMessage {
                Label(err, systemImage: "xmark.octagon.fill")
                    .foregroundColor(Color(NSColor.systemRed))
            }
            Text("You can also click the menu-bar icon to open Jarvis.")
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            Spacer()
            HStack {
                Spacer()
                if shortcut == nil {
                    Button("Skip for now") { onAdvance() }
                } else {
                    Button("Save Hotkey") {
                        state.hotkey = shortcut
                        onAdvance()
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
    }
}
