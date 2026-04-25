// PasteboardReaderTests.swift
//
// MCP-03 unit coverage: the PasteboardReader returns `.refusedFileURL`
// whenever the pasteboard's types contain `.fileURL`, regardless of whether a
// `.string` variant is also present. This is the core mitigation for
// T-05-02-01 (model-coercion via fileURL+string pasteboard).
//
// Plan 05-02 / Task 2 (TDD).

import XCTest
import AppKit
@testable import mcp_clipboard

/// Stand-in for `NSPasteboard.general` in tests; lets us seed pasteboard state
/// without touching the host's real pasteboard or requiring a GUI session.
struct MockPasteboard: PasteboardLike {
    let types: [NSPasteboard.PasteboardType]?
    let storedString: String?

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        type == .string ? storedString : nil
    }
}

final class PasteboardReaderTests: XCTestCase {

    // MCP-03: refusal MUST trigger when fileURL is present, even if a friendly
    // string also appears. This is the most likely model-coercion vector.
    func test_returnsRefusedFileURL_whenTypesContainsFileURL() {
        let reader = PasteboardReader(
            pasteboard: MockPasteboard(types: [.fileURL, .string], storedString: "innocent string")
        )
        XCTAssertEqual(reader.read(), .refusedFileURL)
    }

    func test_returnsRefusedFileURL_whenOnlyFileURL() {
        let reader = PasteboardReader(
            pasteboard: MockPasteboard(types: [.fileURL], storedString: nil)
        )
        XCTAssertEqual(reader.read(), .refusedFileURL)
    }

    func test_returnsText_whenStringPresent_andNoFileURL() {
        let reader = PasteboardReader(
            pasteboard: MockPasteboard(types: [.string], storedString: "hello")
        )
        XCTAssertEqual(reader.read(), .text("hello"))
    }

    func test_returnsEmpty_whenStringIsEmpty() {
        let reader = PasteboardReader(
            pasteboard: MockPasteboard(types: [.string], storedString: "")
        )
        XCTAssertEqual(reader.read(), .empty)
    }

    func test_returnsEmpty_whenStringIsNil_andNoFileURL() {
        let reader = PasteboardReader(
            pasteboard: MockPasteboard(types: [.html], storedString: nil)
        )
        XCTAssertEqual(reader.read(), .empty)
    }

    func test_returnsEmpty_whenTypesIsNil() {
        let reader = PasteboardReader(
            pasteboard: MockPasteboard(types: nil, storedString: nil)
        )
        XCTAssertEqual(reader.read(), .empty)
    }
}
