import Testing
import Foundation
@testable import Harness

/// OBS-04 pillar (b) — parameterized SSE fixture replay.
///
/// One `@Test` invocation per fixture so failures pinpoint the broken
/// fixture by id (per swift-testing per-arg diagnostics, RESEARCH §Pattern 3).
/// The tag projection is intentionally narrow — covering the structural
/// case sequence, not payload bytes — so this suite locks the byte-level
/// CLAUDE.md Opus 4.7 footgun coverage without re-asserting payloads the
/// AnthropicProvider unit tests already cover.
@Suite("SSEFixtureCorpusTests")
struct SSEFixtureCorpusTests {

    @Test(arguments: SSEFixtureCorpus.all)
    func eachFixtureMatchesManifest(_ fixture: SSEFixture) async throws {
        let runner = SSEFixtureRunner()
        let result = try await runner.runOne(fixture)
        #expect(
            result.passed,
            """
            [\(fixture.id)] tag sequence mismatch.
              expected (\(result.expectedEventCount)): \(result.expectedEventTags)
              actual   (\(result.actualEventCount)): \(result.actualEventTags)
              firstMismatchIndex: \(String(describing: result.firstMismatchIndex))
            """
        )
    }

    @Test("SSE corpus has at least 9 fixtures (CLAUDE.md Opus 4.7 footgun coverage)")
    func corpusSizeMinimum() throws {
        let corpus = try SSEFixtureCorpus.loadManifest()
        #expect(corpus.count >= 9)
    }

    @Test("Required Opus 4.7 footgun fixture ids are present")
    func footgunCoveragePresent() throws {
        let corpus = try SSEFixtureCorpus.loadManifest()
        let required: Set<String> = [
            // (i) plain text + message_stop
            "happy-text",
            // (ii) content_block_start + input_json_delta for tool args
            "text-then-tool-use",
            // (iii) thinking_delta blocks
            "thinking-then-text",
            // (iv) stop_reason: refusal
            "refusal",
            // (v) mid-delta disconnect → partial_tool_use_at_disconnect
            "mid-delta-disconnect",
            // ping swallow
            "ping-spam",
            // cache-read telemetry
            "cache-hit",
        ]
        let present = Set(corpus.map { $0.id })
        #expect(
            required.isSubset(of: present),
            "Missing required footgun fixtures: \(required.subtracting(present))"
        )
    }

    @Test("At least one fixture exercises thinking_delta (D-22 spirit / Opus 4.7 footgun)")
    func thinkingDeltaCovered() throws {
        let corpus = try SSEFixtureCorpus.loadManifest()
        let exercises = corpus.filter { $0.expectedEventTags.contains("thinkingDelta") }
        #expect(!exercises.isEmpty, "no SSE fixture emits thinkingDelta")
    }

    @Test("partialToolUseAtDisconnect path is exercised by at least one fixture")
    func partialToolUseDisconnectCovered() throws {
        let corpus = try SSEFixtureCorpus.loadManifest()
        let exercises = corpus.filter {
            $0.expectedEventTags.contains("partialToolUseAtDisconnect")
        }
        #expect(!exercises.isEmpty, "no SSE fixture emits partialToolUseAtDisconnect")
    }
}
