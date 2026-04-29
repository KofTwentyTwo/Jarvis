import XCTest
import Foundation
@testable import JarvisVision

/// Plan 07-05 / Task 6 — D-15 replay placeholder content invariant.
///
/// When an image-bearing turn is recorded, the payload MUST be the literal
/// `{"type":"image","discarded":true,"text":"<original-user-text>"}` and
/// MUST NOT contain any base64 / JPEG / PNG signatures.
final class FrameAttachReplayPlaceholderTests: XCTestCase {

    func testRecordedPayloadIsPlaceholderOnly() async throws {
        let recorder = RecordingReplayLog()
        let sink = FrameAttachReplaySink(replayLog: recorder)
        await sink.recordImageTurn(text: "what is on my screen")
        let entries = await recorder.entries
        XCTAssertEqual(entries.count, 1)
        let payload = entries[0]
        let payloadStr = String(data: payload, encoding: .utf8) ?? ""
        XCTAssertEqual(payloadStr,
            "{\"type\":\"image\",\"discarded\":true,\"text\":\"what is on my screen\"}",
            "exact placeholder payload required")
    }

    func testRecordedPayloadContainsNoBase64Signatures() async throws {
        // Construct a JPEG-like fixture; verify the recorded payload has no
        // base64 padding (`==`), no JPEG SOI ("\xFF\xD8\xFF"), no PNG magic
        // ("\x89PNG"), and no `data:image/` data-URL prefix.
        let recorder = RecordingReplayLog()
        let sink = FrameAttachReplaySink(replayLog: recorder)
        await sink.recordImageTurn(text: "describe this")
        let entries = await recorder.entries
        XCTAssertEqual(entries.count, 1)
        let payload = entries[0]
        // Base64 padding pattern
        let payloadStr = String(data: payload, encoding: .utf8) ?? ""
        XCTAssertFalse(payloadStr.contains("=="), "no base64 padding")
        // JPEG / PNG raw byte signatures
        let jpegSOI = Data([0xFF, 0xD8, 0xFF])
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertNil(payload.range(of: jpegSOI), "no JPEG signature")
        XCTAssertNil(payload.range(of: pngMagic), "no PNG signature")
        XCTAssertFalse(payloadStr.contains("data:image/"), "no data-URL prefix")
    }
}

// MARK: - Test fakes

private actor RecordingReplayLog: FrameAttachReplaySink.ReplayLogProtocol {
    var entries: [Data] = []
    func recordPlaceholder(_ payload: Data) async {
        entries.append(payload)
    }
}
