// PasteboardReader.swift
//
// Testable extraction of the clipboard read logic for the mcp-clipboard
// helper. The production helper wraps `NSPasteboard.general` via a tiny
// `SystemPasteboard` adapter (in main.swift); tests inject a `MockPasteboard`.
//
// MCP-03 trust-boundary mitigation (T-05-02-01):
//   The pasteboard's CONTENT is untrusted — any app on the user's machine
//   can post anything. If `NSPasteboardTypeFileURL` is present we refuse the
//   read regardless of accompanying string content, because a model could
//   coerce a path-read by attaching a friendly-looking string to a fileURL
//   pasteboard. Refusal precedes string extraction to avoid information
//   disclosure (the refusal message contains no leaked content).
//
// Plan 05-02.

import AppKit
import Foundation

public protocol PasteboardLike: Sendable {
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

public enum ClipboardReadResult: Sendable, Equatable {
    case text(String)
    case empty
    case refusedFileURL
}

public struct PasteboardReader: Sendable {
    public let pasteboard: any PasteboardLike

    public init(pasteboard: any PasteboardLike) {
        self.pasteboard = pasteboard
    }

    public func read() -> ClipboardReadResult {
        // MCP-03: Refuse pasteboards carrying NSPasteboardTypeFileURL regardless
        // of string content. Refusal precedes string extraction to avoid
        // information disclosure.
        if let types = pasteboard.types, types.contains(.fileURL) {
            return .refusedFileURL
        }
        guard let s = pasteboard.string(forType: .string), !s.isEmpty else {
            return .empty
        }
        return .text(s)
    }
}
