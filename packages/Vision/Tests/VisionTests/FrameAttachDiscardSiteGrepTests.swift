import XCTest
import Foundation

/// Plan 07-05 / Task 6 — D-15 single-emission-site grep gates.
///
/// Two structural invariants:
///   1. `grep -c 'discardFrame' packages/Vision/Sources/Vision/FrameAttachController.swift` == 1
///      The function definition and all call sites live in this single file.
///   2. Raw-bytes egress fence — no png/jpeg/data-source serialization
///      patterns appear in `packages/Replay/Sources` or in
///      `packages/Vision/Sources/Vision/FrameAttachReplaySink.swift`.
///
/// Mirrors Phase 6's TTSInterrupt single-emission-site grep gate idiom.
final class FrameAttachDiscardSiteGrepTests: XCTestCase {

    func testDiscardFrameSingleEmissionSite() throws {
        let repoRoot = try findRepoRoot()
        let url = repoRoot.appendingPathComponent("packages/Vision/Sources/Vision/FrameAttachController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // The function definition + every call site lives in this single file.
        // Count must equal 1 — the function definition is the only occurrence.
        // Note: tests file references discardFrame too but is in a separate file.
        let occurrences = source.components(separatedBy: "discardFrame").count - 1
        XCTAssertEqual(occurrences, 1,
            "FrameAttachController.swift must contain exactly one 'discardFrame' reference (the function definition); found \(occurrences)")
    }

    func testRawBytesEgressFenceInReplay() throws {
        let repoRoot = try findRepoRoot()
        // Walk packages/Replay/Sources looking for forbidden patterns.
        let scope = repoRoot.appendingPathComponent("packages/Replay/Sources")
        try assertNoRawImageSerialization(in: scope)
    }

    func testRawBytesEgressFenceInReplaySink() throws {
        let repoRoot = try findRepoRoot()
        let url = repoRoot.appendingPathComponent("packages/Vision/Sources/Vision/FrameAttachReplaySink.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = ["pngData", "jpegData", "UIImagePNGRepresentation", "UIImageJPEGRepresentation"]
        for pattern in forbidden {
            XCTAssertFalse(source.contains(pattern),
                "FrameAttachReplaySink.swift contains forbidden raw-image pattern '\(pattern)'")
        }
        // imageBlock.data — looser pattern, but the sink shouldn't even see ImageBlock
        XCTAssertFalse(source.contains("imageBlock.data"),
            "FrameAttachReplaySink.swift must not access imageBlock.data — bytes never enter the sink")
    }

    private func assertNoRawImageSerialization(in scope: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: scope, includingPropertiesForKeys: nil) else { return }
        let forbidden = ["pngData", "jpegData", "UIImagePNGRepresentation", "UIImageJPEGRepresentation"]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbidden {
                XCTAssertFalse(source.contains(pattern),
                    "\(url.lastPathComponent) contains forbidden raw-image pattern '\(pattern)'")
            }
        }
    }

    private func findRepoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        let fm = FileManager.default
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent(".planning")
            if fm.fileExists(atPath: candidate.path) {
                return url
            }
        }
        throw NSError(domain: "FrameAttachDiscardSiteGrepTests", code: 1)
    }
}
