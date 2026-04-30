import XCTest
@testable import Harness

final class ToolCapRecoveryRunnerTests: XCTestCase {

    // MARK: - CapturingURLProtocol unit checks

    func test_capturingURLProtocol_reset_clearsState() {
        CapturingURLProtocol.lock.lock()
        CapturingURLProtocol.capturedBodies = [Data("x".utf8)]
        CapturingURLProtocol.capturedRequests = [URLRequest(url: URL(string: "x://y")!)]
        CapturingURLProtocol.cannedResponse = Data("x".utf8)
        CapturingURLProtocol.cannedHeaders = ["X-Test": "1"]
        CapturingURLProtocol.cannedStatusCode = 500
        CapturingURLProtocol.lock.unlock()

        CapturingURLProtocol.reset()
        XCTAssertEqual(CapturingURLProtocol.capturedBodies.count, 0)
        XCTAssertEqual(CapturingURLProtocol.capturedRequests.count, 0)
        XCTAssertEqual(CapturingURLProtocol.cannedResponse.count, 0)
        XCTAssertEqual(CapturingURLProtocol.cannedHeaders["Content-Type"], "text/event-stream")
        XCTAssertEqual(CapturingURLProtocol.cannedStatusCode, 200)
    }

    // MARK: - Report shape — D-21 dual assertion

    func test_capRecoveryReport_passed_anthropic_requiresToolChoiceNone() {
        // Both clauses pass.
        let ok = ToolCapRecoveryRunner.CapRecoveryReport(
            provider: .anthropic,
            toolUseEventCount: 0,
            recoveryRequestBody: Data(),
            toolChoiceSerializedAsNone: true,
            toolsArrayPresent: true   // Anthropic keeps tools array on .none
        )
        XCTAssertTrue(ok.passed)

        // Clause 1 fails (got a tool_use event).
        let badEvents = ToolCapRecoveryRunner.CapRecoveryReport(
            provider: .anthropic,
            toolUseEventCount: 1,
            recoveryRequestBody: Data(),
            toolChoiceSerializedAsNone: true,
            toolsArrayPresent: true
        )
        XCTAssertFalse(badEvents.passed)

        // Clause 2 fails (tool_choice not none on the wire).
        let badBody = ToolCapRecoveryRunner.CapRecoveryReport(
            provider: .anthropic,
            toolUseEventCount: 0,
            recoveryRequestBody: Data(),
            toolChoiceSerializedAsNone: false,
            toolsArrayPresent: true
        )
        XCTAssertFalse(badBody.passed)
    }

    func test_capRecoveryReport_passed_ollama_requiresToolsArrayDropped() {
        // AGENT-07: Ollama drops tools array entirely on .none.
        let ok = ToolCapRecoveryRunner.CapRecoveryReport(
            provider: .ollama,
            toolUseEventCount: 0,
            recoveryRequestBody: Data(),
            toolChoiceSerializedAsNone: true,
            toolsArrayPresent: false
        )
        XCTAssertTrue(ok.passed)

        // tools array still present → AGENT-07 regression.
        let regression = ToolCapRecoveryRunner.CapRecoveryReport(
            provider: .ollama,
            toolUseEventCount: 0,
            recoveryRequestBody: Data(),
            toolChoiceSerializedAsNone: false,
            toolsArrayPresent: true
        )
        XCTAssertFalse(regression.passed)
    }

    // MARK: - Canned response fixtures

    func test_cannedNoToolUseResponse_anthropic_isMinimalSSE() throws {
        let bytes = try ToolCapRecoveryRunner.cannedNoToolUseResponse(for: .anthropic)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("message_start"))
        XCTAssertTrue(text.contains("message_stop"))
        XCTAssertTrue(text.contains("end_turn"))
        // No tool_use anywhere in the canned bytes.
        XCTAssertFalse(text.contains("tool_use"))
    }

    func test_cannedNoToolUseResponse_ollama_isDoneTrueLine() throws {
        let bytes = try ToolCapRecoveryRunner.cannedNoToolUseResponse(for: .ollama)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\"done\":true"))
        XCTAssertFalse(text.contains("tool_calls"))
    }

    // MARK: - End-to-end: D-21 dual assertion through real provider stack

    /// Anthropic recovery turn must serialize `tool_choice: {"type":"none"}`
    /// in outbound bytes AND yield zero tool_use events on the canned
    /// response. R4-L1 regression guard: if a future refactor removes
    /// `toolChoice` from `LLMProvider.stream(...)`, this test fails.
    func test_run_anthropic_serializesToolChoiceNone_andNoToolUseEvents() async throws {
        let runner = ToolCapRecoveryRunner()
        let report = try await runner.run(provider: .anthropic)
        XCTAssertEqual(report.toolUseEventCount, 0,
            "clause 1 (event count): recovery turn must yield zero tool_use events")
        XCTAssertTrue(report.toolChoiceSerializedAsNone,
            "clause 2 (outbound bytes): Anthropic recovery turn must encode tool_choice {type:none}")
        XCTAssertTrue(report.passed)
    }

    /// Ollama recovery turn must DROP the `tools` array entirely from the
    /// outbound JSON body (AGENT-07).
    func test_run_ollama_dropsToolsArray_andNoToolUseEvents() async throws {
        let runner = ToolCapRecoveryRunner()
        let report = try await runner.run(provider: .ollama)
        XCTAssertEqual(report.toolUseEventCount, 0)
        XCTAssertFalse(report.toolsArrayPresent,
            "AGENT-07: Ollama recovery turn must drop tools array entirely on .none")
        XCTAssertTrue(report.toolChoiceSerializedAsNone)
        XCTAssertTrue(report.passed)
    }
}
