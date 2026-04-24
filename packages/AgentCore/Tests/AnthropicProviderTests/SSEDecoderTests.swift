import XCTest
import Foundation
@testable import AnthropicProvider
@testable import AgentCore

/// Direct dispatch of synthetic SSEFrame values through `SSEDecoder.dispatch`.
/// No URLSession, no fixture files — pure state-machine coverage.
final class SSEDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Build an SSEFrame from a JSON string `data` payload.
    private func frame(_ event: String, _ json: String) -> SSEFrame {
        SSEFrame(event: event, data: Data(json.utf8))
    }

    /// Run a sequence of frames through SSEDecoder, collecting events.
    private func run(_ frames: [SSEFrame], flushOnEOF: Bool = false) -> [LLMEvent] {
        var state = SSEDecoder.State()
        var emitted: [LLMEvent] = []
        for f in frames {
            SSEDecoder.dispatch(frame: f, state: &state) { emitted.append($0) }
        }
        if flushOnEOF, !state.messageStopEmitted {
            SSEDecoder.flushOnEOF(state: &state) { emitted.append($0) }
        }
        return emitted
    }

    // MARK: - Test S1: message_start parses usage prefix

    func testMessageStartEmitsLLMMessageStart() {
        let events = run([
            frame("message_start", #"""
            {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-7","usage":{"input_tokens":12,"cache_creation_input_tokens":100,"cache_read_input_tokens":4251,"output_tokens":1}}}
            """#),
        ])
        XCTAssertEqual(events.count, 1)
        guard case .messageStart(let start) = events[0] else {
            XCTFail("expected .messageStart"); return
        }
        XCTAssertEqual(start.messageId, "msg_1")
        XCTAssertEqual(start.model, "claude-opus-4-7")
        XCTAssertEqual(start.usagePrefix?.inputTokens, 12)
        XCTAssertEqual(start.usagePrefix?.cacheCreationInputTokens, 100)
        XCTAssertEqual(start.usagePrefix?.cacheReadInputTokens, 4251)
    }

    // MARK: - Test S2: three text deltas + close trio

    func testThreeTextDeltasAndCloseTrio() {
        let events = run([
            frame("message_start", #"{"type":"message_start","message":{"id":"m","model":"x","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#),
            frame("content_block_start", #"{"index":0,"content_block":{"type":"text"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":"a"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":"b"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":"c"}}"#),
            frame("content_block_stop", #"{"index":0}"#),
            frame("message_delta", #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#),
            frame("message_stop", #"{"type":"message_stop"}"#),
        ])

        // Expected: messageStart, textDelta×3, stopReason(.endTurn), usage, messageStop
        XCTAssertEqual(events.count, 7)
        if case .textDelta("a") = events[1] {} else { XCTFail("idx 1 expected textDelta(a)") }
        if case .textDelta("b") = events[2] {} else { XCTFail("idx 2 expected textDelta(b)") }
        if case .textDelta("c") = events[3] {} else { XCTFail("idx 3 expected textDelta(c)") }
        if case .stopReason(.endTurn) = events[4] {} else { XCTFail("idx 4 expected stopReason(endTurn)") }
        if case .usage(let u) = events[5] {
            XCTAssertEqual(u.outputTokens, 3)
        } else { XCTFail("idx 5 expected usage") }
        if case .messageStop = events[6] {} else { XCTFail("idx 6 expected messageStop") }
    }

    // MARK: - Test S3: ping events emit ZERO LLMEvents

    func testPingEventsAreSwallowed() {
        let events = run([
            frame("ping", "{}"),
            frame("ping", "{}"),
            frame("ping", "{}"),
        ])
        XCTAssertEqual(events.count, 0,
                       "ping events must produce zero LLMEvents")
    }

    // MARK: - Test S4: tool_use sequence emits ONE assembled toolUseRequested

    func testToolUseSequenceEmitsOneAssembledRequest() {
        let events = run([
            frame("content_block_start", #"{"index":0,"content_block":{"type":"tool_use","id":"toolu_X","name":"get_time","input":{}}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"\":1"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":",\"b\":"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"2}"}}"#),
            frame("content_block_stop", #"{"index":0}"#),
        ])
        // Expected: toolUseBuffering, toolUseRequested. No intermediate emits.
        XCTAssertEqual(events.count, 2)
        if case .toolUseBuffering(let id) = events[0] {
            XCTAssertEqual(id, "toolu_X")
        } else { XCTFail("idx 0 expected toolUseBuffering") }
        guard case .toolUseRequested(let req) = events[1] else {
            XCTFail("idx 1 expected toolUseRequested"); return
        }
        XCTAssertEqual(req.id, "toolu_X")
        XCTAssertEqual(req.name, "get_time")
        let assembled = String(data: req.argsJSON, encoding: .utf8)
        XCTAssertEqual(assembled, "{\"a\":1,\"b\":2}")
        // Verify it parses as JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: req.argsJSON))
    }

    // MARK: - Test S5: empty input_json_delta is skipped

    func testEmptyInputJSONDeltaIsSkipped() {
        let events = run([
            frame("content_block_start", #"{"index":0,"content_block":{"type":"tool_use","id":"t","name":"n"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"{\"k"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":""}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"\":1"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":""}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"}"}}"#),
            frame("content_block_stop", #"{"index":0}"#),
        ])
        guard case .toolUseRequested(let req) = events.last else {
            XCTFail("expected trailing toolUseRequested"); return
        }
        XCTAssertEqual(String(data: req.argsJSON, encoding: .utf8), "{\"k\":1}")
    }

    // MARK: - Test S6: thinking_delta routes to its own case

    func testThinkingDeltaRoutesToThinkingDeltaEvent() {
        let events = run([
            frame("content_block_start", #"{"index":0,"content_block":{"type":"thinking"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"thinking_delta","thinking":"step 1"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"thinking_delta","thinking":"step 2"}}"#),
            frame("content_block_stop", #"{"index":0}"#),
        ])
        XCTAssertEqual(events.count, 2)
        if case .thinkingDelta("step 1") = events[0] {} else { XCTFail("idx 0 expected thinkingDelta(step 1)") }
        if case .thinkingDelta("step 2") = events[1] {} else { XCTFail("idx 1 expected thinkingDelta(step 2)") }
    }

    // MARK: - Test S7: stop_reason: refusal maps to .refusal

    func testRefusalIsFirstClassStopReason() {
        let events = run([
            frame("message_delta", #"{"delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#),
            frame("message_stop", #"{}"#),
        ])
        // Expect: stopReason(.refusal), usage, messageStop
        XCTAssertEqual(events.count, 3)
        if case .stopReason(.refusal) = events[0] {} else { XCTFail("idx 0 expected .refusal") }
        if case .messageStop = events[2] {} else { XCTFail("idx 2 expected messageStop") }
    }

    // MARK: - Test S8: mid-stream EOF mid-tool-args

    func testMidStreamEOFEmitsPartialToolUseAtDisconnect() {
        let events = run([
            frame("content_block_start", #"{"index":0,"content_block":{"type":"tool_use","id":"toolu_Y","name":"search"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"{\"q"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"input_json_delta","partial_json":"uery"}}"#),
        ], flushOnEOF: true)
        // Expect: toolUseBuffering, partialToolUseAtDisconnect, stopReason(.streamTruncated), usage, messageStop
        XCTAssertEqual(events.count, 5)
        if case .toolUseBuffering = events[0] {} else { XCTFail("idx 0 expected toolUseBuffering") }
        guard case .partialToolUseAtDisconnect(let req) = events[1] else {
            XCTFail("idx 1 expected partialToolUseAtDisconnect"); return
        }
        XCTAssertEqual(req.id, "toolu_Y")
        XCTAssertEqual(req.name, "search")
        XCTAssertEqual(String(data: req.argsJSON, encoding: .utf8), "{\"query")
        if case .stopReason(.streamTruncated) = events[2] {} else { XCTFail("idx 2 expected streamTruncated") }
        if case .messageStop = events[4] {} else { XCTFail("idx 4 expected messageStop") }
    }

    // MARK: - Test S9: unknown event name does not throw

    func testUnknownEventNameContinuesGracefully() {
        let events = run([
            frame("future_event", #"{"data":"whatever"}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":"ok"}}"#),
        ])
        XCTAssertEqual(events.count, 1)
        if case .textDelta("ok") = events[0] {} else { XCTFail("expected textDelta(ok)") }
    }

    // MARK: - Test S10: message_delta does NOT close — only message_stop does

    func testMessageDeltaDoesNotClose() {
        let events = run([
            frame("message_delta", #"{"delta":{"stop_reason":"end_turn"}}"#),
            frame("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":"trailing"}}"#),
            frame("message_stop", "{}"),
        ])
        // Expect: textDelta("trailing"), stopReason(.endTurn), usage, messageStop.
        let textIndex = events.firstIndex { if case .textDelta("trailing") = $0 { return true } else { return false } }
        XCTAssertNotNil(textIndex,
                        "trailing text_delta after message_delta must still be emitted")
        let stopIndex = events.lastIndex { if case .messageStop = $0 { return true } else { return false } }
        XCTAssertNotNil(stopIndex)
        XCTAssertGreaterThan(stopIndex!, textIndex!,
                             "messageStop must come AFTER the trailing text")
    }

    // MARK: - Test S11: stop_reason mapping

    func testStopReasonMapping() {
        XCTAssertEqual(SSEDecoder.mapStopReason("end_turn"), .endTurn)
        XCTAssertEqual(SSEDecoder.mapStopReason("tool_use"), .toolUse)
        XCTAssertEqual(SSEDecoder.mapStopReason("max_tokens"), .maxTokens)
        XCTAssertEqual(SSEDecoder.mapStopReason("refusal"), .refusal)
        XCTAssertEqual(SSEDecoder.mapStopReason("garbage"), .endTurn,
                       "unknown stop_reason maps to .endTurn (logs warning)")
    }
}
