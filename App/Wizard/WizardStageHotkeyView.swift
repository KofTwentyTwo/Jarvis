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
                .fixedSize(horizontal: false, vertical: true)

            // How-to instructions — explicit because the recorder accepts
            // chord input and there's no obvious affordance until clicked.
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Click the field below to start recording.")
                } icon: {
                    Image(systemName: "1.circle.fill").foregroundColor(.accentColor)
                }
                Label {
                    Text("Hold one or more modifier keys (\(Text("⌘ ⌥ ⌃").bold().monospaced()) — and optionally \(Text("⇧").bold().monospaced())) and press a regular key (letter, number, Space, Return, etc.).")
                } icon: {
                    Image(systemName: "2.circle.fill").foregroundColor(.accentColor)
                }
                .fixedSize(horizontal: false, vertical: true)
                Label {
                    Text("Press \(Text("Esc").bold().monospaced()) at any time to cancel without saving.")
                } icon: {
                    Image(systemName: "3.circle.fill").foregroundColor(.accentColor)
                }
            }
            .font(.system(size: 12))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )

            HStack {
                Text("Global shortcut").frame(width: 140, alignment: .leading)
                ShortcutRecorderView(shortcut: $shortcut, errorMessage: $errorMessage)
                    .frame(height: 40)
            }

            // Visible confirmation of the selected shortcut so the user knows
            // what will be saved when they hit Save Hotkey.
            if let s = shortcut {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(NSColor.systemGreen))
                    Text("Selected:")
                    Text(s.displayString)
                        .font(.system(size: 14, weight: .semibold).monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.controlColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    Button("Clear") {
                        shortcut = nil
                        errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Color(NSColor.linkColor))
                }
                .font(.system(size: 13))
            }

            if let warning = shortcut.flatMap(CollisionDetector.check) {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(Color(NSColor.systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = errorMessage {
                Label(err, systemImage: "xmark.octagon.fill")
                    .foregroundColor(Color(NSColor.systemRed))
                    .fixedSize(horizontal: false, vertical: true)
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
