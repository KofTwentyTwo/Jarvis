import Foundation
import AppKit
import Carbon.HIToolbox
import Carbon.HIToolbox

/// A persisted keyboard shortcut — keyCode plus modifier mask. Codable for
/// JSON round-trip (future Settings reload), Sendable for Swift 6 strict
/// concurrency, Equatable for tests.
///
/// Modifier mask is serialized as a raw `UInt` so the wire format stays stable
/// across NSEvent API revisions.
public struct KeyboardShortcut: Codable, Sendable, Equatable {
    public let keyCode: UInt16
    public let modifiers: UInt  // NSEvent.ModifierFlags.RawValue (UInt)

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    public init(keyCode: UInt16, modifiersRaw: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiersRaw
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Human-readable rendering for menu/UI surfaces, e.g. "⌘⇧J" or "⌃⌥Space".
    /// Modifier glyphs are ordered ⌃ ⌥ ⇧ ⌘ to match Apple's menu-rendering
    /// convention. Unmapped key codes fall back to "Key{n}" so the value stays
    /// debuggable rather than dropping silently.
    public var displayString: String {
        let mods = modifierFlags
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option)  { out += "⌥" }
        if mods.contains(.shift)   { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        out += KeyboardShortcut.keyName(for: keyCode)
        return out
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:   return "Space"
        case kVK_Return:  return "Return"
        case kVK_Tab:     return "Tab"
        case kVK_Escape:  return "Esc"
        case kVK_Delete:  return "Delete"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default: return "Key\(keyCode)"
        }
    }
}
