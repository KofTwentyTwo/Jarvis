import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

/// **#24 — assistant text blocks alongside tool_use must not be dropped.**
///
/// Opus 4.7 frequently narrates before invoking a tool ("Let me check the
/// time for you..." → `tool_use(get_time)`). Before this fix, the
/// orchestrator appended only the `.toolUse` block to `messages`, so on
/// the next round-trip the model had no record of saying anything — a
/// user follow-up like "what did you say before checking the time?"
/// would get a denial.
///
/// These tests assert the assistant message at the round-trip boundary
/// contains BOTH the preceding text and the tool_use block. D-02's
/// cumulative `assistantTextSoFar` is preserved separately; only the
/// per-flush buffer is consumed.
@MainActor
final class AssistantTextWithToolUseTests: XCTestCase {

    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    private func buildOrchestrator(
        provider: MockLLMProvider,
        dispatcher: any ToolDispatcher
    ) async throws -> AgentOrchestrator {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        return AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in provider },
            toolDispatcher: dispatcher,
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: []
        )
    }

    private func collectUntilIdle(orch: AgentOrchestrator, timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            if case .stateChange(.idle) = event { return }
            if Date() > deadline { return }
        }
    }

    // MARK: - ATU-1

    /// Single text-then-tool sequence: model emits "Let me check..." then
    /// `tool_use(get_time)`. The assistant message in the second provider
    /// call must contain a `.text` block AND a `.toolUse` block.
    func test_ATU1_textBeforeToolUseBundledIntoSameAssistantMessage() async throws {
        let toolReq = ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data("{}".utf8))
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .textDelta("Let me check the time for you... "),
                .toolUseRequested(toolReq),
                .stopReason(.toolUse),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .textDelta("It's 12:34."),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let dispatcher = StubToolDispatcher(dispatch: { _ in Data("12:34".utf8) })

        let orch = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)
        _ = await orch.submit(.text("what time"))
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "expected 2 provider calls (tool-use loop)")

        // Find the assistant message containing the tool_use block in the
        // second call's history.
        let secondCall = calls[1].messages
        guard let assistantWithTool = secondCall.first(where: { msg in
            msg.role == .assistant && msg.content.contains(where: { block in
                if case .toolUse(id: "tu1", _, _) = block { return true }
                return false
            })
        }) else {
            return XCTFail("no assistant message with the tool_use block found in second call")
        }

        // Block ordering: text first, then tool_use.
        let blockKinds = assistantWithTool.content.map { block -> String in
            switch block {
            case .text: return "text"
            case .toolUse: return "toolUse"
            case .toolResult: return "toolResult"
            }
        }
        XCTAssertEqual(blockKinds, ["text", "toolUse"],
            "assistant block sequence must be [text, toolUse] — got \(blockKinds)")

        // The text content matches what the model streamed (trimmed).
        if case .text(let txt) = assistantWithTool.content[0] {
            XCTAssertEqual(txt, "Let me check the time for you...",
                "text block must contain the streamed narration (trimmed)")
        } else {
            XCTFail("expected first block to be .text")
        }
    }

    // MARK: - ATU-2

    /// If the model emits a tool_use with NO preceding text (Opus
    /// occasionally does this — straight to tool), the assistant message
    /// must contain ONLY the toolUse block (no empty `.text("")` block,
    /// which Anthropic rejects with a 400).
    func test_ATU2_noPrecedingTextOnlyToolUseBlock() async throws {
        let toolReq = ToolUseRequest(id: "tu2", name: "get_time", argsJSON: Data("{}".utf8))
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .toolUseRequested(toolReq),
                .stopReason(.toolUse),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .textDelta("done"),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let dispatcher = StubToolDispatcher(dispatch: { _ in Data("12:34".utf8) })

        let orch = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)
        _ = await orch.submit(.text("time"))
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        guard let assistantWithTool = calls[1].messages.first(where: { msg in
            msg.role == .assistant && msg.content.contains(where: { block in
                if case .toolUse(id: "tu2", _, _) = block { return true }
                return false
            })
        }) else {
            return XCTFail("expected assistant message with tool_use block")
        }

        XCTAssertEqual(assistantWithTool.content.count, 1,
            "no preceding text — assistant message must contain only the toolUse block, got \(assistantWithTool.content.count) blocks")
        if case .toolUse = assistantWithTool.content[0] {
            // ok
        } else {
            XCTFail("expected sole content block to be .toolUse")
        }
    }

    // MARK: - ATU-3

    /// Whitespace-only preceding text must NOT be emitted as a `.text`
    /// block (Anthropic rejects empty/whitespace-only text blocks). The
    /// implementation trims whitespace before testing for emptiness.
    func test_ATU3_whitespaceOnlyTextNotEmitted() async throws {
        let toolReq = ToolUseRequest(id: "tu3", name: "get_time", argsJSON: Data("{}".utf8))
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
                .textDelta("   \n\t  "),  // whitespace only
                .toolUseRequested(toolReq),
                .stopReason(.toolUse),
                .messageStop,
            ]),
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
                .stopReason(.endTurn),
                .messageStop,
            ]),
        ])
        let dispatcher = StubToolDispatcher(dispatch: { _ in Data("ok".utf8) })

        let orch = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)
        _ = await orch.submit(.text("hi"))
        await collectUntilIdle(orch: orch)

        let calls = await mock.getRecordedCalls()
        guard let assistantWithTool = calls[1].messages.first(where: { msg in
            msg.role == .assistant && msg.content.contains(where: { block in
                if case .toolUse(id: "tu3", _, _) = block { return true }
                return false
            })
        }) else {
            return XCTFail("expected assistant message with tool_use block")
        }

        XCTAssertEqual(assistantWithTool.content.count, 1,
            "whitespace-only preceding text must be dropped, leaving only the toolUse block")
    }
}
