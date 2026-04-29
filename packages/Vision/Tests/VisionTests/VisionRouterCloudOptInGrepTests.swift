import XCTest
import Foundation

/// Plan 07-05 / Task 5 — D-18 no-auto-cloud invariant grep gate.
///
/// Asserts that every reference to `AnthropicProvider` or `claude-opus`
/// inside `packages/Vision/Sources/Vision` lives in a file that ALSO
/// references `EscalationPhraseDetector.matchesCloudOptIn` — OR is the
/// `VisionTier.swift` model-constants file (where the literal model name
/// is defined as a static property and is NOT a code path to cloud egress).
///
/// This is the structural equivalent of Phase 6's TTSInterrupt single-
/// emission-site grep gate — a regression that adds a second cloud-egress
/// site outside the matchesCloudOptIn dataflow fails this test loudly.
final class VisionRouterCloudOptInGrepTests: XCTestCase {

    func testNoOrphanCloudReferencesInVisionPackage() throws {
        let repoRoot = try findRepoRoot()
        let scope = repoRoot.appendingPathComponent("packages/Vision/Sources/Vision")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: scope, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(scope.path)")
            return
        }
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let mentionsCloudByName = source.contains("AnthropicProvider")
                || source.contains("claude-opus")
            guard mentionsCloudByName else { continue }
            // Allowlist file: VisionTier.swift owns the model-name constant.
            if url.lastPathComponent == "VisionTier.swift" { continue }
            // Otherwise the file MUST also reach the cloud-opt-in detector.
            let reachesOptInCheck = source.contains("matchesCloudOptIn")
            if !reachesOptInCheck {
                violations.append("\(url.lastPathComponent) mentions cloud but not matchesCloudOptIn")
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "D-18 no-auto-cloud invariant violation: \(violations)")
    }

    private func findRepoRoot() throws -> URL {
        // Walk up from the test bundle until we find `.planning/`.
        var url = URL(fileURLWithPath: #filePath)
        let fm = FileManager.default
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent(".planning")
            if fm.fileExists(atPath: candidate.path) {
                return url
            }
        }
        throw NSError(domain: "VisionRouterCloudOptInGrepTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not locate repo root from \(#filePath)"])
    }
}
