import XCTest
import Foundation
@testable import AnthropicProvider
@testable import AgentCore

/// Replay each pre-recorded SSE fixture through SSELineReader → SSEDecoder
/// and assert the emitted event sequence matches an expected pattern.
///
/// LLMEvent isn't `Equatable` (associated `LLMProviderError` makes deep
/// equality fragile across versions), so we compare via a structural
/// `ExpectedEvent` enum and a per-case match helper.
final class FixtureReplayTests: XCTestCase {

    // MARK: - Reduced enum used for assertions

    enum ExpectedEvent: Equatable {
        case messageStart
        case textDelta(String)
        case thinkingDelta(String)
        case toolUseRequested(id: String, name: String, argsJSON: String)
        case toolUseBuffering(String)
        case partialToolUseAtDisconnect(id: String, argsJSON: String)
        case stopReason(StopReason)
        case usage
        case messageStop
    }

    // MARK: - Helpers

    /// Convert a fixture file's bytes into an AsyncStream<UInt8>, push
    /// through SSELineReader, dispatch each frame to SSEDecoder, and
    /// collect emitted LLMEvents.
    private func replay(fixture name: String) async throws -> [LLMEvent] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt"),
            "fixture '\(name).txt' missing from test bundle"
        )
        let data = try Data(contentsOf: url)

        let stream = AsyncStream<UInt8> { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
        let reader = SSELineReader(bytes: stream)
        var state = SSEDecoder.State()
        var collected: [LLMEvent] = []
        for try await frame in reader.frames() {
            SSEDecoder.dispatch(frame: frame, state: &state) { event in
                collected.append(event)
            }
            if state.messageStopEmitted { break }
        }
        if !state.messageStopEmitted {
            SSEDecoder.flushOnEOF(state: &state) { collected.append($0) }
        }
        return collected
    }

    /// Match one actual LLMEvent against an ExpectedEvent shape.
    private func matches(_ actual: LLMEvent, _ expected: ExpectedEvent) -> Bool {
        switch (actual, expected) {
        case (.messageStart, .messageStart):
            return true
        case (.textDelta(let a), .textDelta(let b)):
            return a == b
        case (.thinkingDelta(let a), .thinkingDelta(let b)):
            return a == b
        case (.toolUseBuffering(let a), .toolUseBuffering(let b)):
            return a == b
        case (.toolUseRequested(let req), .toolUseRequested(let id, let name, let args)):
            return req.id == id && req.name == name &&
                   String(data: req.argsJSON, encoding: .utf8) == args
        case (.partialToolUseAtDisconnect(let req), .partialToolUseAtDisconnect(let id, let args)):
            return req.id == id &&
                   String(data: req.argsJSON, encoding: .utf8) == args
        case (.stopReason(let a), .stopReason(let b)):
            return a == b
        case (.usage, .usage):
            return true
        case (.messageStop, .messageStop):
            return true
        default:
            return false
        }
    }

    /// Assert the actual event sequence structurally matches the expected
    /// shape list. Reports per-index mismatches with helpful context.
    private func assertSequence(
        _ actual: [LLMEvent],
        matches expected: [ExpectedEvent],
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count,
                       "[\(fixture)] event count mismatch — actual: \(actual)",
                       file: (file), line: line)
        let pairs = zip(actual, expected).enumerated()
        for (idx, (a, e)) in pairs {
            XCTAssertTrue(
                self.matches(a, e),
                "[\(fixture)] event[\(idx)] mismatch — actual: \(a), expected: \(e)",
                file: (file), line: line
            )
        }
    }

    // MARK: - F1: happy-text

    func testFixture_happyText() async throws {
        let events = try await replay(fixture: "happy-text")
        assertSequence(events, matches: [
            .messageStart,
            .textDelta("Hello"),
            .textDelta(" "),
            .textDelta("world"),
            .stopReason(.endTurn),
            .usage,
            .messageStop,
        ], fixture: "happy-text")
    }

    // MARK: - F2: text-then-tool-use

    func testFixture_textThenToolUse() async throws {
        let events = try await replay(fixture: "text-then-tool-use")
        assertSequence(events, matches: [
            .messageStart,
            .textDelta("Let me check"),
            .toolUseBuffering("toolu_ABC"),
            .toolUseRequested(id: "toolu_ABC", name: "get_time", argsJSON: "{\"timezone\":\"UTC\"}"),
            .stopReason(.toolUse),
            .usage,
            .messageStop,
        ], fixture: "text-then-tool-use")

        // Critical: argsJSON must JSON-decode successfully.
        guard case .toolUseRequested(let req) = events[3] else {
            XCTFail("expected toolUseRequested at idx 3"); return
        }
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: req.argsJSON))
    }

    // MARK: - F3: thinking-then-text

    func testFixture_thinkingThenText() async throws {
        let events = try await replay(fixture: "thinking-then-text")
        let thinkingCount = events.filter {
            if case .thinkingDelta = $0 { return true } else { return false }
        }.count
        XCTAssertGreaterThanOrEqual(thinkingCount, 2,
                                    "expected at least 2 thinkingDelta events")

        // Find first thinkingDelta and first textDelta — thinking must come first.
        let firstThinking = events.firstIndex { if case .thinkingDelta = $0 { return true } else { return false } }
        let firstText = events.firstIndex { if case .textDelta = $0 { return true } else { return false } }
        XCTAssertNotNil(firstThinking)
        XCTAssertNotNil(firstText)
        XCTAssertLessThan(firstThinking!, firstText!,
                          "thinkingDelta must precede any textDelta")
    }

    // MARK: - F4: refusal

    func testFixture_refusal() async throws {
        let events = try await replay(fixture: "refusal")
        // Final stopReason MUST be .refusal — not .endTurn.
        let stop = events.first { if case .stopReason = $0 { return true } else { return false } }
        guard let stop, case .stopReason(let reason) = stop else {
            XCTFail("expected stopReason event"); return
        }
        XCTAssertEqual(reason, .refusal)
    }

    // MARK: - F5: mid-delta-disconnect

    func testFixture_midDeltaDisconnect() async throws {
        let events = try await replay(fixture: "mid-delta-disconnect")

        // Must end with: ..., partialToolUseAtDisconnect, stopReason(.streamTruncated), usage, messageStop
        let partialIdx = events.firstIndex { if case .partialToolUseAtDisconnect = $0 { return true } else { return false } }
        XCTAssertNotNil(partialIdx, "expected partialToolUseAtDisconnect event")

        guard case .partialToolUseAtDisconnect(let req) = events[partialIdx!] else {
            XCTFail("type mismatch"); return
        }
        XCTAssertEqual(req.id, "toolu_DISC")
        // The accumulated buffer is the partial (invalid) JSON
        // "{\"que" + "ry\":" = "{\"query\":"
        XCTAssertEqual(String(data: req.argsJSON, encoding: .utf8), "{\"query\":")

        // Followed by stopReason(.streamTruncated) and messageStop.
        let trailing = Array(events.suffix(from: partialIdx! + 1))
        XCTAssertEqual(trailing.count, 3)
        if case .stopReason(.streamTruncated) = trailing[0] {} else { XCTFail("expected streamTruncated") }
        if case .usage = trailing[1] {} else { XCTFail("expected usage") }
        if case .messageStop = trailing[2] {} else { XCTFail("expected messageStop") }
    }

    // MARK: - F6: ping-spam

    func testFixture_pingSpam() async throws {
        let events = try await replay(fixture: "ping-spam")
        let textCount = events.filter {
            if case .textDelta = $0 { return true } else { return false }
        }.count
        XCTAssertEqual(textCount, 3,
                       "expected exactly 3 textDelta events through 20 pings")

        // Verify ping events emitted ZERO LLMEvents (not appearing in stream).
        // Total events: messageStart + 3×textDelta + stopReason + usage + messageStop = 7
        XCTAssertEqual(events.count, 7,
                       "20 ping events must not produce any LLMEvent emissions; got: \(events)")
    }

    // MARK: - F7: unknown-event

    func testFixture_unknownEvent() async throws {
        // Must not throw. Must still emit text events.
        let events = try await replay(fixture: "unknown-event")
        let textTexts: [String] = events.compactMap {
            if case .textDelta(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(textTexts, ["start", "middle", "end"])
    }

    // MARK: - F8: cache-hit

    func testFixture_cacheHit() async throws {
        let events = try await replay(fixture: "cache-hit")
        guard case .messageStart(let start) = events[0] else {
            XCTFail("expected messageStart at idx 0"); return
        }
        XCTAssertEqual(start.usagePrefix?.cacheReadInputTokens, 4251,
                       "cache_read_input_tokens must surface from message_start")
        XCTAssertEqual(start.usagePrefix?.inputTokens, 12)
        XCTAssertEqual(start.usagePrefix?.cacheCreationInputTokens, 0)
    }

    // MARK: - F9: empty-input-json-delta

    func testFixture_emptyInputJSONDelta() async throws {
        let events = try await replay(fixture: "empty-input-json-delta")
        let req: ToolUseRequest? = {
            for e in events {
                if case .toolUseRequested(let r) = e { return r }
            }
            return nil
        }()
        guard let req else {
            XCTFail("expected toolUseRequested"); return
        }
        // The non-empty chunks were: {"a":"1", ,"b":2, } → assembled: {"a":"1","b":2}
        XCTAssertEqual(String(data: req.argsJSON, encoding: .utf8),
                       "{\"a\":\"1\",\"b\":2}")
        // Must JSON-decode successfully.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: req.argsJSON))
    }
}
