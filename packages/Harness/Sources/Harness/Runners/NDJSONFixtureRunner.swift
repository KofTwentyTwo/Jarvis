import Foundation
import AgentCore

/// OBS-04 pillar (c-fixture) — Ollama NDJSON / OpenAI-compat fixture runner.
///
/// Drives byte-identical fixtures through the real `OllamaProvider`'s
/// `NDJSONDecoder` (native `/api/chat`) or `OpenAICompatDecoder` (`/v1/chat/
/// completions`) per the fixture's declared `transport`.
///
/// The native NDJSON corpus deliberately includes the CLAUDE.md transport
/// gotcha case: `tool_calls` arrives on the chunk PRECEDING `done: true`.
/// `text-then-tool-call` and `parallel-tool-calls` both exercise that
/// invariant — if the decoder ever regresses to "gate tool_calls on done",
/// those fixtures lose their `toolUseRequested` tags and the runner fails.
public actor NDJSONFixtureRunner {

    public init() {}

    public struct FixtureResult: Sendable, Codable, Equatable {
        public let fixtureId: String
        public let actualEventCount: Int
        public let actualEventTags: [String]
        public let expectedEventCount: Int
        public let expectedEventTags: [String]
        public let passed: Bool
        public let firstMismatchIndex: Int?
    }

    public struct Report: Sendable, Codable, Equatable {
        public let results: [FixtureResult]
        public var passed: Bool { results.allSatisfy { $0.passed } }
    }

    public func run(corpus: [NDJSONFixture]) async throws -> Report {
        var results: [FixtureResult] = []
        results.reserveCapacity(corpus.count)
        for fixture in corpus {
            let result = try await runOne(fixture)
            results.append(result)
        }
        return Report(results: results)
    }

    public func runOne(_ fixture: NDJSONFixture) async throws -> FixtureResult {
        let url = try NDJSONFixtureCorpus.url(for: fixture)
        let kind: MockLLMProvider.FixtureKind
        switch fixture.transport {
        case .native:        kind = .ollamaNDJSON
        case .openAICompat:  kind = .ollamaOpenAICompat
        }
        let mock = MockLLMProvider(fixtureURL: url, kind: kind)
        var tags: [String] = []
        let stream = mock.stream(
            messages: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID.qwen25coder32b,
            maxOutputTokens: 1024,
            cacheHints: nil
        )
        for try await event in stream {
            tags.append(LLMEventTag.tag(for: event))
        }
        let countMatch = tags.count == fixture.expectedEventCount
        let tagsMatch = tags == fixture.expectedEventTags
        let firstMismatch: Int? = {
            for (i, (a, e)) in zip(tags, fixture.expectedEventTags).enumerated()
            where a != e {
                return i
            }
            if tags.count != fixture.expectedEventTags.count {
                return min(tags.count, fixture.expectedEventTags.count)
            }
            return nil
        }()
        return FixtureResult(
            fixtureId: fixture.id,
            actualEventCount: tags.count,
            actualEventTags: tags,
            expectedEventCount: fixture.expectedEventCount,
            expectedEventTags: fixture.expectedEventTags,
            passed: countMatch && tagsMatch,
            firstMismatchIndex: firstMismatch
        )
    }
}
