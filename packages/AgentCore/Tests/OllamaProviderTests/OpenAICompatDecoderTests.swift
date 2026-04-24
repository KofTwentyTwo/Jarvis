import XCTest
import Foundation
@testable import OllamaProvider
@testable import AgentCore

final class OpenAICompatDecoderTests: XCTestCase {

    /// Run a sequence of SSE lines (without trailing blanks) through the
    /// decoder, collecting all yielded events.
    private func run(_ lines: [String], eof: Bool = true) -> [LLMEvent] {
        var decoder = OpenAICompatDecoder()
        var collected: [LLMEvent] = []
        for line in lines {
            decoder.dispatch(line: line) { collected.append($0) }
            if decoder.messageStopEmitted { break }
        }
        if eof, !decoder.messageStopEmitted {
            decoder.flushOnEOF { collected.append($0) }
        }
        return collected
    }

    // MARK: - O1: standard text delta

    func testTextDelta() {
        let events = run([
            #"data: {"choices":[{"delta":{"content":"hello"},"index":0}]}"#,
            "data: [DONE]",
        ])
        let texts: [String] = events.compactMap {
            if case .textDelta(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["hello"])
    }

    // MARK: - O2: [DONE] sentinel emits stop trio

    func testDoneSentinel() {
        let events = run([
            #"data: {"choices":[{"delta":{"content":"x"},"index":0}]}"#,
            "data: [DONE]",
        ])
        XCTAssertTrue(events.contains { if case .stopReason = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .usage = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .messageStop = $0 { return true } else { return false } })
    }

    // MARK: - O3: finish_reason mapping

    func testFinishReasonMapping_stop() {
        let events = run([
            #"data: {"choices":[{"delta":{"content":"x"},"index":0}]}"#,
            #"data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.endTurn) = $0 { return true } else { return false } })
    }

    func testFinishReasonMapping_length() {
        let events = run([
            #"data: {"choices":[{"delta":{"content":"x"},"index":0}]}"#,
            #"data: {"choices":[{"delta":{},"index":0,"finish_reason":"length"}]}"#,
            "data: [DONE]",
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.maxTokens) = $0 { return true } else { return false } })
    }

    func testFinishReasonMapping_toolCalls() {
        let events = run([
            #"data: {"choices":[{"delta":{"tool_calls":[{"id":"call_X","type":"function","function":{"name":"get_time","arguments":"{\"timezone\":\"UTC\"}"}}]},"index":0}]}"#,
            #"data: {"choices":[{"delta":{},"index":0,"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])
        XCTAssertTrue(events.contains { if case .stopReason(.toolUse) = $0 { return true } else { return false } })
    }

    // MARK: - O4: atomic tool call with stringified arguments

    func testAtomicToolCallStringifiedArgs() {
        let events = run([
            #"data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"id":"call_X","type":"function","function":{"name":"get_time","arguments":"{\"timezone\":\"UTC\"}"}}]},"index":0}]}"#,
            #"data: {"choices":[{"delta":{},"index":0,"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])
        let reqs: [ToolUseRequest] = events.compactMap {
            if case .toolUseRequested(let r) = $0 { return r } else { return nil }
        }
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].id, "call_X")
        XCTAssertEqual(reqs[0].name, "get_time")
        XCTAssertEqual(String(data: reqs[0].argsJSON, encoding: .utf8), #"{"timezone":"UTC"}"#)
    }

    // MARK: - O5: mid-stream EOF

    func testMidStreamEOF() {
        let events = run([
            #"data: {"choices":[{"delta":{"content":"hi"},"index":0}]}"#,
        ], eof: true)
        XCTAssertTrue(events.contains { if case .stopReason(.streamTruncated) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .messageStop = $0 { return true } else { return false } })
    }

    // MARK: - P1: OllamaProvider conformance compile check

    func testOllamaProviderConformsToLLMProvider() {
        // Compile-time conformance check — referencing the actor as
        // LLMProvider is enough.
        let provider: any LLMProvider = OllamaProvider(
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        XCTAssertNotNil(provider)
    }
}
