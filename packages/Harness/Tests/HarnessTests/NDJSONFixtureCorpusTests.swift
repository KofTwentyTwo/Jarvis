import Testing
import Foundation
@testable import Harness

/// OBS-04 pillar (c-fixture) — parameterized Ollama NDJSON / OpenAI-compat
/// fixture replay. The native-NDJSON fixtures lock the CLAUDE.md transport
/// gotcha (`tool_calls` arriving on the chunk PRECEDING `done: true`); the
/// OpenAI-compat fixtures lock the atomic-tool_calls + `[DONE]` sentinel
/// shape. Both decoders run with no modification.
@Suite("NDJSONFixtureCorpusTests")
struct NDJSONFixtureCorpusTests {

    @Test(arguments: NDJSONFixtureCorpus.all)
    func eachFixtureMatchesManifest(_ fixture: NDJSONFixture) async throws {
        let runner = NDJSONFixtureRunner()
        let result = try await runner.runOne(fixture)
        #expect(
            result.passed,
            """
            [\(fixture.id)] tag sequence mismatch.
              transport: \(fixture.transport)
              expected (\(result.expectedEventCount)): \(result.expectedEventTags)
              actual   (\(result.actualEventCount)): \(result.actualEventTags)
              firstMismatchIndex: \(String(describing: result.firstMismatchIndex))
            """
        )
    }

    @Test("NDJSON corpus has at least 6 fixtures")
    func corpusSizeMinimum() throws {
        let corpus = try NDJSONFixtureCorpus.loadManifest()
        #expect(corpus.count >= 6)
    }

    @Test("Required Ollama transport-gotcha fixture ids are present")
    func ollamaCoveragePresent() throws {
        let corpus = try NDJSONFixtureCorpus.loadManifest()
        let required: Set<String> = [
            // (i) plain text turn
            "happy-text",
            // (ii) tool_calls on chunk PRECEDING done:true (the locked quirk)
            "text-then-tool-call",
            // (iii) parallel tool_calls
            "parallel-tool-calls",
            // (iv) mid-stream EOF → flushOnEOF
            "mid-stream-eof",
        ]
        let present = Set(corpus.map { $0.id })
        #expect(
            required.isSubset(of: present),
            "Missing required Ollama fixtures: \(required.subtracting(present))"
        )
    }

    /// CLAUDE.md transport gotcha lock — at least one native-NDJSON fixture
    /// emits toolUseRequested while `done` is still false on its line.
    /// Equivalent to "decoder didn't gate on `done: true`".
    @Test("At least one native NDJSON fixture exercises tool_calls before done:true")
    func toolCallsBeforeDoneCovered() throws {
        let corpus = try NDJSONFixtureCorpus.loadManifest()
        let exercises = corpus.filter {
            $0.transport == .native && $0.expectedEventTags.contains("toolUseRequested")
        }
        #expect(
            !exercises.isEmpty,
            "no native-NDJSON fixture exercises the tool_calls-before-done:true Ollama gotcha"
        )
    }

    @Test("Native and OpenAI-compat transports both represented")
    func bothTransportsPresent() throws {
        let corpus = try NDJSONFixtureCorpus.loadManifest()
        let native = corpus.filter { $0.transport == .native }
        let compat = corpus.filter { $0.transport == .openAICompat }
        #expect(native.count >= 4, "at least 4 native-NDJSON fixtures expected")
        #expect(compat.count >= 1, "at least 1 OpenAI-compat fixture expected")
    }
}
