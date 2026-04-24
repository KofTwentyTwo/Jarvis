import XCTest
import Foundation
@testable import OllamaProvider
@testable import AgentCore

/// Unit tests for `NDJSONDecoder`. The critical AGENT-04 regression guard
/// (Test N2) verifies that `tool_calls` on a non-terminator chunk is emitted
/// before `stopReason` — i.e., the decoder does NOT gate tool_calls on the
/// terminator flag.
final class NDJSONDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Run a sequence of NDJSON lines (as JSON-string literals) through the
    /// decoder, collecting all yielded events.
    private func run(_ lines: [String], eof: Bool = true) -> [LLMEvent] {
        var decoder = NDJSONDecoder()
        var collected: [LLMEvent] = []
        for line in lines {
            decoder.dispatch(line: Data(line.utf8)) { collected.append($0) }
            if decoder.messageStopEmitted { break }
        }
        if eof, !decoder.messageStopEmitted {
            decoder.flushOnEOF { collected.append($0) }
        }
        return collected
    }

    /// Find the first index whose event matches the predicate.
    private func firstIndex(
        _ events: [LLMEvent],
        matching predicate: (LLMEvent) -> Bool
    ) -> Int? {
        events.firstIndex(where: predicate)
    }

    // MARK: - N1: happy text

    func testHappyText() {
        let events = run([
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"x"},"done":false}"#,
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"y"},"done":false}"#,
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"z"},"done":false}"#,
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":47}"#,
        ])
        // messageStart, textDelta×3, stopReason, usage, messageStop.
        XCTAssertEqual(events.count, 7)
        guard case .messageStart = events[0] else { XCTFail("expected messageStart"); return }
        guard case .textDelta(let t1) = events[1], t1 == "x" else { XCTFail("textDelta x"); return }
        guard case .textDelta(let t2) = events[2], t2 == "y" else { XCTFail("textDelta y"); return }
        guard case .textDelta(let t3) = events[3], t3 == "z" else { XCTFail("textDelta z"); return }
        guard case .stopReason(let r) = events[4], r == .endTurn else { XCTFail("stopReason endTurn"); return }
        guard case .usage(let u) = events[5] else { XCTFail("usage"); return }
        XCTAssertEqual(u.inputTokens, 12)
        XCTAssertEqual(u.outputTokens, 47)
        XCTAssertEqual(u.cacheCreationInputTokens, 0)
        XCTAssertEqual(u.cacheReadInputTokens, 0)
        guard case .messageStop = events[6] else { XCTFail("messageStop"); return }
    }

    // MARK: - N2: AGENT-04 regression guard — tool_calls on non-terminator chunk

    /// Tool calls arrive on chunk 2 with `done:false`; the terminator is
    /// chunk 3. The decoder MUST emit `.toolUseRequested` from chunk 2 —
    /// before the terminator — not gate it on `done:true`.
    func testToolCallsOnNonTerminatorChunk_AGENT04() {
        let events = run([
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"let me check"},"done":false}"#,
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":{"timezone":"UTC"}}}]},"done":false}"#,
            #"{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
        ])

        let toolReqIdx = firstIndex(events) {
            if case .toolUseRequested = $0 { return true } else { return false }
        }
        let stopReasonIdx = firstIndex(events) {
            if case .stopReason = $0 { return true } else { return false }
        }
        XCTAssertNotNil(toolReqIdx, "decoder must emit toolUseRequested on tool_calls chunk")
        XCTAssertNotNil(stopReasonIdx, "decoder must emit stopReason at terminator")
        XCTAssertLessThan(toolReqIdx!, stopReasonIdx!,
            "AGENT-04 regression: toolUseRequested must precede stopReason")

        guard case .toolUseRequested(let req) = events[toolReqIdx!] else {
            XCTFail("event type"); return
        }
        XCTAssertEqual(req.name, "get_time")
        XCTAssertEqual(String(data: req.argsJSON, encoding: .utf8), #"{"timezone":"UTC"}"#)
        XCTAssertNotNil(UUID(uuidString: req.id), "id should be a UUID")
    }

    // MARK: - N3: done_reason mapping

    func testDoneReasonMapping_stop() {
        let events = run([
            #"{"message":{"content":"hi"},"done":true,"done_reason":"stop"}"#,
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.endTurn) = $0 { return true } else { return false } })
    }

    func testDoneReasonMapping_length() {
        let events = run([
            #"{"message":{"content":"hi"},"done":true,"done_reason":"length"}"#,
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.maxTokens) = $0 { return true } else { return false } })
    }

    func testDoneReasonMapping_toolCalls() {
        let events = run([
            #"{"message":{"content":"","tool_calls":[{"function":{"name":"a","arguments":{}}}]},"done":true,"done_reason":"tool_calls"}"#,
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.toolUse) = $0 { return true } else { return false } })
    }

    func testDoneReasonMapping_missingButToolCallsSeen() {
        // done:true with NO done_reason field BUT we previously saw tool_calls
        // → maps to .toolUse.
        let events = run([
            #"{"message":{"content":"","tool_calls":[{"function":{"name":"a","arguments":{}}}]},"done":false}"#,
            #"{"message":{"content":""},"done":true}"#,
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.toolUse) = $0 { return true } else { return false } })
    }

    // MARK: - N4: mid-stream EOF

    func testMidStreamEOF() {
        let events = run([
            #"{"message":{"content":"partial"},"done":false}"#,
            #"{"message":{"content":" response"},"done":false}"#,
        ], eof: true)

        // Must end with stopReason(.streamTruncated), usage, messageStop.
        XCTAssertTrue(events.contains { if case .stopReason(.streamTruncated) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .messageStop = $0 { return true } else { return false } })
        // No partialToolUseAtDisconnect — NDJSON is atomic per line.
        XCTAssertFalse(events.contains { if case .partialToolUseAtDisconnect = $0 { return true } else { return false } })
    }

    // MARK: - N5: parallel tool calls

    func testParallelToolCalls() {
        let events = run([
            #"{"message":{"content":"","tool_calls":[{"function":{"name":"a","arguments":{}}},{"function":{"name":"b","arguments":{}}}]},"done":false}"#,
            #"{"message":{"content":""},"done":true,"done_reason":"tool_calls"}"#,
        ])
        let names: [String] = events.compactMap {
            if case .toolUseRequested(let r) = $0 { return r.name } else { return nil }
        }
        XCTAssertEqual(names, ["a", "b"])
    }

    // MARK: - N6: each tool_use id is a distinct UUID

    func testToolUseIDsAreFreshUUIDs() {
        let events = run([
            #"{"message":{"content":"","tool_calls":[{"function":{"name":"a","arguments":{}}},{"function":{"name":"b","arguments":{}}}]},"done":false}"#,
            #"{"message":{"content":""},"done":true,"done_reason":"tool_calls"}"#,
        ])
        let ids: [String] = events.compactMap {
            if case .toolUseRequested(let r) = $0 { return r.id } else { return nil }
        }
        XCTAssertEqual(ids.count, 2)
        for id in ids {
            XCTAssertNotNil(UUID(uuidString: id), "id '\(id)' is not a valid UUID")
            XCTAssertFalse(id.isEmpty)
        }
        XCTAssertNotEqual(ids[0], ids[1], "parallel tool_use ids must differ")
    }

    // MARK: - N7: malformed JSON

    func testMalformedJSON() {
        let events = run([
            #"{"incomplete":"# ,
        ])
        XCTAssertTrue(events.contains {
            if case .providerError(let err) = $0,
               case .decode = err { return true }
            return false
        })
        XCTAssertTrue(events.contains { if case .messageStop = $0 { return true } else { return false } })
    }
}
