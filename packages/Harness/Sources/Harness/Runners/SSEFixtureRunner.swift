import Foundation
import AgentCore

/// OBS-04 pillar (b) — Anthropic SSE fixture runner.
///
/// Each fixture is a `.sse` byte file under `Corpora/sse-anthropic/`.
/// `MockLLMProvider(fixtureURL:, kind: .anthropicSSE)` plumbs those bytes
/// through the **real** production `AnthropicProvider`'s URLSession
/// transport, `SSELineReader`, and `SSEDecoder` — i.e. the same code path
/// production runs on every Opus 4.7 turn. The runner does NOT touch the
/// decoder; if a fixture passes here it locks the byte-level contract.
///
/// Compared to `AnthropicProviderTests/FixtureReplayTests` (the
/// `@testable import`-style test that lives next to the decoder), this
/// runner reaches the decoder via the public `LLMProvider` protocol — so
/// the harness can ship as a regular library consumer with no
/// `@testable import` and the decoder stays internal.
public actor SSEFixtureRunner {

    public init() {}

    public struct FixtureResult: Sendable, Codable, Equatable {
        public let fixtureId: String
        public let actualEventCount: Int
        public let actualEventTags: [String]
        public let expectedEventCount: Int
        public let expectedEventTags: [String]
        public let passed: Bool
        /// First mismatch index (or nil if counts/tags fully match).
        public let firstMismatchIndex: Int?
    }

    public struct Report: Sendable, Codable, Equatable {
        public let results: [FixtureResult]
        public var passed: Bool { results.allSatisfy { $0.passed } }
    }

    public func run(corpus: [SSEFixture]) async throws -> Report {
        var results: [FixtureResult] = []
        results.reserveCapacity(corpus.count)
        for fixture in corpus {
            let result = try await runOne(fixture)
            results.append(result)
        }
        return Report(results: results)
    }

    public func runOne(_ fixture: SSEFixture) async throws -> FixtureResult {
        let url = try SSEFixtureCorpus.url(for: fixture)
        let mock = MockLLMProvider(fixtureURL: url, kind: .anthropicSSE)
        var tags: [String] = []
        let stream = mock.stream(
            messages: [],
            tools: [],
            toolChoice: .auto,
            model: ModelID.opus47,
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

/// Stable string projection of an `LLMEvent` case for fixture-manifest
/// comparison. The case-name view is intentionally narrow — payload deltas
/// (e.g. exact tool ID, exact thinking text) are not part of the contract
/// the manifest enforces; that's the SSE/NDJSON decoder unit test's job.
public enum LLMEventTag {
    public static func tag(for event: LLMEvent) -> String {
        switch event {
        case .messageStart:                return "messageStart"
        case .textDelta:                   return "textDelta"
        case .thinkingDelta:               return "thinkingDelta"
        case .toolUseRequested:            return "toolUseRequested"
        case .toolUseBuffering:            return "toolUseBuffering"
        case .partialToolUseAtDisconnect:  return "partialToolUseAtDisconnect"
        case .stopReason:                  return "stopReason"
        case .usage:                       return "usage"
        case .providerError:               return "providerError"
        case .messageStop:                 return "messageStop"
        }
    }
}
