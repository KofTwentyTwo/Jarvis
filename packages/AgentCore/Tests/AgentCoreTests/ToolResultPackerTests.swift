import XCTest
@testable import AgentCore

// Tests reflect the #21 (audit-2026-05-12 CRIT-2) closure: `ToolResultPacker`
// no longer truncates. The 8 KB cap fires at the MCP dispatcher boundary via
// `SanitizeForModel.prepareForBoundary`; the packer is a pass-through that
// decodes the dispatcher-prepared bytes for the LLM message history and
// hands the same bytes to ReplayLog. `wasCapped` is informational only
// (derived from input size); `omittedByteCount` is always zero since the
// dispatcher already stripped the omitted bytes before the packer sees them.
final class ToolResultPackerTests: XCTestCase {

    /// TP1: under-cap input flows through unchanged; no truncation marker.
    func test_TP1_smallInputNotCapped() {
        let raw = Data(repeating: UInt8(ascii: "a"), count: 4 * 1024)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertFalse(packed.wasCapped)
        XCTAssertEqual(packed.omittedByteCount, 0)
        XCTAssertEqual(packed.modelFacing.count, 4 * 1024)
        XCTAssertEqual(packed.fullBytes.count, 4 * 1024)
        XCTAssertFalse(packed.modelFacing.contains("[TRUNCATED"))
    }

    /// TP2 (post-#21): packer does NOT truncate. The dispatcher already
    /// truncated upstream — bytes flowing in are ≤ 8 KB. The packer passes
    /// them through unchanged, and `fullBytes == raw` regardless of size.
    func test_TP2_packerDoesNotTruncate() {
        // Simulate the rare/buggy case where a caller hands us larger bytes
        // (the production path won't, but the API stability matters): packer
        // still doesn't truncate.
        let raw = Data(repeating: UInt8(ascii: "x"), count: 16 * 1024)
        let packed = ToolResultPacker.pack(raw)
        // After #21 the packer never inserts a TRUNCATED marker; the
        // dispatcher's `SanitizeForModel.headTruncate` is the only marker
        // source.
        XCTAssertFalse(packed.modelFacing.contains("[TRUNCATED:"))
        XCTAssertEqual(packed.fullBytes.count, 16 * 1024,
                       "fullBytes is a pass-through of the input")
        XCTAssertEqual(packed.modelFacing.count, 16 * 1024,
                       "modelFacing is a pass-through decoding of the input")
        XCTAssertEqual(packed.omittedByteCount, 0,
                       "packer no longer knows omitted-count; always zero")
    }

    /// TP3: input exactly at cap reports `wasCapped == true` (size >= cap)
    /// but no marker is added — the packer is purely informational.
    func test_TP3_exactlyAtCapInformational() {
        let raw = Data(repeating: UInt8(ascii: "y"), count: 8192)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertTrue(packed.wasCapped,
                      "size >= cap reports true informationally")
        XCTAssertEqual(packed.omittedByteCount, 0)
        XCTAssertFalse(packed.modelFacing.contains("[TRUNCATED"))
    }

    /// TP4: UTF-8 decode of input never crashes — `String(decoding:as:)`
    /// replaces invalid sequences with U+FFFD. Production input has been
    /// scrubbed by `SanitizeForModel.sanitize` upstream so invalid sequences
    /// are vanishingly rare, but the API must not crash on adversarial input.
    func test_TP4_utf8DecodeNeverCrashes() {
        // Bytes 8190..8191 are the start of a 4-byte emoji — incomplete by
        // themselves. `String(decoding:as:)` substitutes U+FFFD; no crash.
        var bytes = [UInt8](repeating: UInt8(ascii: "z"), count: 16 * 1024)
        let emoji: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        for (i, b) in emoji.enumerated() {
            bytes[8190 + i] = b
        }
        let packed = ToolResultPacker.pack(Data(bytes))
        XCTAssertFalse(packed.modelFacing.isEmpty)
    }

    /// TP5 (post-#21): the packer never adds the `[TRUNCATED: …]` marker.
    /// The dispatcher's `…[tool-result-truncated at 8192 bytes]` marker is
    /// the only one a downstream observer should ever see.
    func test_TP5_packerNeverAddsTruncatedMarker() {
        let raw = Data(repeating: UInt8(ascii: "a"), count: 9000)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertFalse(packed.modelFacing.contains("[TRUNCATED:"))
    }
}
