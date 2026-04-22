import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Renders a single key-cap chip ("⌘", "J", "Space", etc.) styled per
/// UI-SPEC Surface 2 "Key cap" component. Used by `KeyCapRowView` to render
/// a full shortcut preview like `[⌘]+[⇧]+[J]`.
public struct KeyCapView: View {
    public let text: String
    public init(text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular).monospacedDigit())
            .foregroundColor(Color(NSColor.labelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.controlColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
    }
}

/// Renders a full shortcut preview as a row of caps joined by "+".
public struct KeyCapRowView: View {
    public let shortcut: KeyboardShortcut
    public init(shortcut: KeyboardShortcut) { self.shortcut = shortcut }

    public var body: some View {
        HStack(spacing: 4) {
            let symbols = modifierSymbols(shortcut.modifierFlags)
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                KeyCapView(text: sym)
                Text("+").foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            KeyCapView(text: keyGlyph(for: shortcut.keyCode))
        }
    }

    private func modifierSymbols(_ mods: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if mods.contains(.control) { out.append("⌃") }
        if mods.contains(.option)  { out.append("⌥") }
        if mods.contains(.shift)   { out.append("⇧") }
        if mods.contains(.command) { out.append("⌘") }
        return out
    }

    private func keyGlyph(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_J:  return "J"
        case kVK_Space:   return "Space"
        case kVK_Return:  return "Return"
        case kVK_Tab:     return "Tab"
        // Extended as needed.
        default: return "Key\(keyCode)"
        }
    }
}
