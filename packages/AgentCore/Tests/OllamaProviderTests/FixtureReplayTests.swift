import XCTest
import Foundation
@testable import OllamaProvider
@testable import AgentCore

/// Replay each pre-recorded byte-stream fixture through the appropriate
/// decoder and assert the emitted event sequence matches the expected shape.
///
/// **AGENT-04 regression guard at fixture level (testFixture_textThenToolCall):**
/// the production code is hit with bytes loaded from disk, not inline string
/// literals, so a developer who "fixed" a unit test by editing the literal
/// would still trip this fixture-driven assertion.
final class FixtureReplayTests: XCTestCase {

    // MARK: - Reduced enum

    enum ExpectedEvent: Equatable {
        case messageStart
        case textDelta(String)
        case toolUseRequested(name: String, argsJSON: String)
        case toolUseBuffering
        case stopReason(StopReason)
        case usage
        case messageStop
    }

    // MARK: - Replay helpers

    /// Replay an NDJSON fixture (one JSON object per line) through
    /// NDJSONDecoder.
    private func replayNDJSON(fixture name: String) throws -> [LLMEvent] {
        let data = try fixtureData(name: name)
        var collected: [LLMEvent] = []
        var decoder = NDJSONDecoder()
        // Split on \n. Per Ollama wire format each line is a complete JSON
        // object; trailing newline produces a final empty segment we skip.
        let lines = String(data: data, encoding: .utf8)!.split(
            separator: "\n", omittingEmptySubsequences: true
        )
        for line in lines {
            decoder.dispatch(line: Data(String(line).utf8)) { collected.append($0) }
            if decoder.messageStopEmitted { break }
        }
        if !decoder.messageStopEmitted {
            decoder.flushOnEOF { collected.append($0) }
        }
        return collected
    }

    /// Replay an SSE fixture (data: lines separated by blank lines) through
    /// OpenAICompatDecoder. We strip blank lines and feed each `data:` line
    /// directly — the line-based dispatch matches what URLSession.AsyncBytes
    /// .lines yields in production.
    private func replaySSE(fixture name: String) throws -> [LLMEvent] {
        let data = try fixtureData(name: name)
        var collected: [LLMEvent] = []
        var decoder = OpenAICompatDecoder()
        let raw = String(data: data, encoding: .utf8)!
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            decoder.dispatch(line: line) { collected.append($0) }
            if decoder.messageStopEmitted { break }
        }
        if !decoder.messageStopEmitted {
            decoder.flushOnEOF { collected.append($0) }
        }
        return collected
    }

    private func fixtureData(name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt"),
            "fixture '\(name).txt' missing from test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func firstIndex(_ events: [LLMEvent], where p: (LLMEvent) -> Bool) -> Int? {
        events.firstIndex(where: p)
    }

    // MARK: - F1: happy text (NDJSON)

    func testFixture_happyText() throws {
        let events = try replayNDJSON(fixture: "happy-text")
        // messageStart, textDelta×3, stopReason(.endTurn), usage, messageStop.
        XCTAssertEqual(events.count, 7)
        guard case .messageStart = events[0] else { XCTFail("messageStart"); return }
        let texts: [String] = events.compactMap {
            if case .textDelta(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["Hello", " world", "!"])
        guard case .stopReason(.endTurn) = events[4] else { XCTFail("stopReason endTurn"); return }
        guard case .usage(let u) = events[5] else { XCTFail("usage"); return }
        XCTAssertEqual(u.inputTokens, 12)
        XCTAssertEqual(u.outputTokens, 3)
        guard case .messageStop = events[6] else { XCTFail("messageStop"); return }
    }

    // MARK: - F2: AGENT-04 fixture-level regression guard

    func testFixture_textThenToolCall_AGENT04() throws {
        let events = try replayNDJSON(fixture: "text-then-tool-call")
        let toolReqIdx = firstIndex(events) {
            if case .toolUseRequested = $0 { return true } else { return false }
        }
        let stopReasonIdx = firstIndex(events) {
            if case .stopReason = $0 { return true } else { return false }
        }
        XCTAssertNotNil(toolReqIdx, "fixture must produce a toolUseRequested event")
        XCTAssertNotNil(stopReasonIdx, "fixture must produce a stopReason event")
        XCTAssertLessThan(toolReqIdx!, stopReasonIdx!,
            "AGENT-04 regression at fixture level: toolUseRequested must precede stopReason")

        guard case .toolUseRequested(let req) = events[toolReqIdx!] else {
            XCTFail("event type"); return
        }
        XCTAssertEqual(req.name, "get_time")
        XCTAssertEqual(String(data: req.argsJSON, encoding: .utf8),
                       #"{"timezone":"UTC"}"#)
        // Terminator carries done_reason:tool_calls → maps to .toolUse.
        if case .stopReason(let r) = events[stopReasonIdx!] {
            XCTAssertEqual(r, .toolUse)
        }
    }

    // MARK: - F3: parallel tool calls (NDJSON)

    func testFixture_parallelToolCalls() throws {
        let events = try replayNDJSON(fixture: "parallel-tool-calls")
        let names: [String] = events.compactMap {
            if case .toolUseRequested(let r) = $0 { return r.name } else { return nil }
        }
        XCTAssertEqual(names, ["get_time", "get_clipboard"])
    }

    // MARK: - F4: mid-stream EOF (NDJSON)

    func testFixture_midStreamEOF() throws {
        let events = try replayNDJSON(fixture: "mid-stream-eof")
        XCTAssertTrue(events.contains { if case .stopReason(.streamTruncated) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .messageStop = $0 { return true } else { return false } })
        // Defence-in-depth: NDJSON has no partial-tool-use semantic.
        XCTAssertFalse(events.contains { if case .partialToolUseAtDisconnect = $0 { return true } else { return false } })
    }

    // MARK: - F5: OpenAI-compat happy (SSE)

    func testFixture_openAICompatHappy() throws {
        let events = try replaySSE(fixture: "openai-compat-happy")
        let texts: [String] = events.compactMap {
            if case .textDelta(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["Hello", " world"])
        XCTAssertTrue(events.contains { if case .stopReason(.endTurn) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .messageStop = $0 { return true } else { return false } })
    }

    // MARK: - F6: OpenAI-compat tool call (SSE)

    func testFixture_openAICompatToolCall() throws {
        let events = try replaySSE(fixture: "openai-compat-tool-call")
        let reqs: [ToolUseRequest] = events.compactMap {
            if case .toolUseRequested(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].id, "call_X")
        XCTAssertEqual(reqs[0].name, "get_time")
        XCTAssertEqual(String(data: reqs[0].argsJSON, encoding: .utf8),
                       #"{"timezone":"UTC"}"#)
        XCTAssertTrue(events.contains { if case .stopReason(.toolUse) = $0 { return true } else { return false } })
    }
}
