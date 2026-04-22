import Foundation
import AppKit

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
}
