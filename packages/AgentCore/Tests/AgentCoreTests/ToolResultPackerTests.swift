import XCTest
@testable import AgentCore

final class ToolResultPackerTests: XCTestCase {
    /// TP1: 4 KB input → no truncation; full string returned; full bytes preserved.
    func test_TP1_smallInputNotCapped() {
        let raw = Data(repeating: UInt8(ascii: "a"), count: 4 * 1024)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertFalse(packed.wasCapped)
        XCTAssertEqual(packed.omittedByteCount, 0)
        XCTAssertEqual(packed.modelFacing.count, 4 * 1024)
        XCTAssertEqual(packed.fullBytes.count, 4 * 1024)
        XCTAssertFalse(packed.modelFacing.contains("[TRUNCATED"))
    }

    /// TP2: 16 KB input → first 8192 bytes + truncation marker; full bytes preserved.
    func test_TP2_largeInputCappedWithMarker() {
        let raw = Data(repeating: UInt8(ascii: "x"), count: 16 * 1024)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertTrue(packed.wasCapped)
        XCTAssertEqual(packed.omittedByteCount, 16 * 1024 - 8192)
        XCTAssertEqual(packed.fullBytes.count, 16 * 1024)
        XCTAssertTrue(packed.modelFacing.hasPrefix(String(repeating: "x", count: 8192)),
                      "modelFacing must begin with the first 8192 bytes")
        XCTAssertTrue(packed.modelFacing.contains("[TRUNCATED:"),
                      "must contain truncation marker")
        XCTAssertTrue(packed.modelFacing.contains("full blob in replay log"),
                      "must reference replay log")
    }

    /// TP3: exactly 8192 bytes — equal-to-cap is NOT over.
    func test_TP3_exactlyAtCapNotTruncated() {
        let raw = Data(repeating: UInt8(ascii: "y"), count: 8192)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertFalse(packed.wasCapped)
        XCTAssertEqual(packed.omittedByteCount, 0)
        XCTAssertFalse(packed.modelFacing.contains("[TRUNCATED"))
    }

    /// TP4: multi-byte UTF-8 boundary at byte 8192 — String(decoding:as:) replaces
    /// invalid bytes with U+FFFD and does not crash.
    func test_TP4_utf8BoundaryDoesNotCrash() {
        // Build a buffer of size 16K where bytes 8190..8192 sit on a 4-byte
        // emoji boundary. emoji "😀" is F0 9F 98 80; place at offset 8190 so
        // bytes 8190,8191 are F0 9F (start of emoji) and the cut at 8192 cuts
        // mid-codepoint.
        var raw = [UInt8](repeating: UInt8(ascii: "z"), count: 16 * 1024)
        let emoji: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        for (i, b) in emoji.enumerated() {
            raw[8190 + i] = b
        }
        let data = Data(raw)
        // Should not crash even though bytes 8190..8191 form an incomplete prefix.
        let packed = ToolResultPacker.pack(data)
        XCTAssertTrue(packed.wasCapped)
        XCTAssertNotNil(packed.modelFacing)
    }

    /// TP5: truncation marker is grep-able and deterministic.
    func test_TP5_truncationMarkerIsGreppable() {
        let raw = Data(repeating: UInt8(ascii: "a"), count: 9000)
        let packed = ToolResultPacker.pack(raw)
        XCTAssertTrue(packed.modelFacing.contains("TRUNCATED"))
        XCTAssertTrue(packed.modelFacing.contains("full blob in replay log"))
    }
}
