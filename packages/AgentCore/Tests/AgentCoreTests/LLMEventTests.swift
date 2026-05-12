import XCTest
@testable import AgentCore

final class LLMEventTests: XCTestCase {
    /// Test 2: LLMEvent has exactly ten cases — exhaustive switch confirms.
    func testLLMEventExhaustiveSwitch() {
        let events: [LLMEvent] = [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .textDelta("a"),
            .thinkingDelta("t"),
            .toolUseRequested(ToolUseRequest(id: "t1", name: "n", argsJSON: Data())),
            .toolUseBuffering(toolUseId: "t1"),
            .partialToolUseAtDisconnect(ToolUseRequest(id: "t1", name: "n", argsJSON: Data())),
            .stopReason(.endTurn),
            .usage(.zero),
            .providerError(.transport(description: "x")),
            .messageStop,
        ]
        var seen = 0
        for event in events {
            switch event {
            case .messageStart: seen += 1
            case .textDelta: seen += 1
            case .thinkingDelta: seen += 1
            case .toolUseRequested: seen += 1
            case .toolUseBuffering: seen += 1
            case .partialToolUseAtDisconnect: seen += 1
            case .stopReason: seen += 1
            case .usage: seen += 1
            case .providerError: seen += 1
            case .messageStop: seen += 1
            }
        }
        XCTAssertEqual(seen, 10)
    }

    /// Test 3: StopReason has exactly five cases.
    func testStopReasonExhaustiveSwitch() {
        let reasons: [StopReason] = [.endTurn, .toolUse, .maxTokens, .refusal, .streamTruncated]
        var seen = 0
        for reason in reasons {
            switch reason {
            case .endTurn: seen += 1
            case .toolUse: seen += 1
            case .maxTokens: seen += 1
            case .refusal: seen += 1
            case .streamTruncated: seen += 1
            }
        }
        XCTAssertEqual(seen, 5)
    }

    /// Test 4: ModelID literals match RESEARCH-DELTAS D1 + D3.
    func testModelIDLiterals() {
        XCTAssertEqual(ModelID.opus47.rawValue, "claude-opus-4-7")
        XCTAssertEqual(ModelID.qwen25coder32b.rawValue, "qwen2.5-coder:32b-instruct-q8_0")
    }

    func testModelIDEquality() {
        XCTAssertEqual(ModelID.opus47, ModelID(rawValue: "claude-opus-4-7"))
        XCTAssertNotEqual(ModelID.opus47, ModelID.qwen25coder32b)
    }

    func testTurnUsageZero() {
        XCTAssertEqual(TurnUsage.zero.inputTokens, 0)
        XCTAssertEqual(TurnUsage.zero.outputTokens, 0)
        XCTAssertEqual(TurnUsage.zero.cacheCreationInputTokens, 0)
        XCTAssertEqual(TurnUsage.zero.cacheReadInputTokens, 0)
    }

    func testToolUseRequestEquality() {
        let a = ToolUseRequest(id: "t", name: "n", argsJSON: Data("{}".utf8))
        let b = ToolUseRequest(id: "t", name: "n", argsJSON: Data("{}".utf8))
        XCTAssertEqual(a, b)
    }

    func testCacheHintsEquality() {
        XCTAssertEqual(CacheHints(systemPromptTTL: .extended1h),
                       CacheHints(systemPromptTTL: .extended1h))
        XCTAssertNotEqual(CacheHints(systemPromptTTL: .extended1h),
                          CacheHints(systemPromptTTL: .ephemeral5m))
    }

    func testTurnIDFreshUnique() {
        let a = TurnID.fresh()
        let b = TurnID.fresh()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.rawValue.isEmpty)
    }

    func testLLMMessageRoles() {
        XCTAssertEqual(LLMMessage.Role.system.rawValue, "system")
        XCTAssertEqual(LLMMessage.Role.user.rawValue, "user")
        XCTAssertEqual(LLMMessage.Role.assistant.rawValue, "assistant")
        XCTAssertEqual(LLMMessage.Role.tool.rawValue, "tool")
    }

    func testLLMProviderErrorEquality() {
        XCTAssertEqual(LLMProviderError.api(statusCode: 401, body: "x"),
                       LLMProviderError.api(statusCode: 401, body: "x"))
        XCTAssertNotEqual(LLMProviderError.api(statusCode: 401, body: "x"),
                          LLMProviderError.api(statusCode: 500, body: "x"))
        XCTAssertEqual(LLMProviderError.streamTruncatedFinal,
                       LLMProviderError.streamTruncatedFinal)
    }
}
