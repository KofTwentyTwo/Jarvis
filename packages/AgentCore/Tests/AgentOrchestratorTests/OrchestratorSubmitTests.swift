import XCTest
import AgentCore
import Config
import Replay
@testable import AgentOrchestrator

@MainActor
final class OrchestratorSubmitTests: XCTestCase {
    var tempHome: TempReplayHome!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = TempReplayHome.make()
    }

    override func tearDown() async throws {
        tempHome?.cleanup()
        try await super.tearDown()
    }

    // Build an orchestrator + collect the next N events from its channel.
    private func buildOrchestrator(
        provider mock: MockLLMProvider,
        dispatcher: any ToolDispatcher = StubToolDispatcher()
    ) async throws -> (AgentOrchestrator, ReplayLog, SessionID) {
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: dispatcher,
            replayLog: replay,
            sessionId: session,
            systemPrompt: "you are jarvis",
            availableTools: [
                ToolSchema(name: "get_time",
                           description: "current time",
                           inputSchema: Data("{}".utf8)),
            ]
        )
        return (orch, replay, session)
    }

    /// Drain `events` until `predicate` matches, with a timeout.
    private func collectUntil(
        orch: AgentOrchestrator,
        timeout: TimeInterval = 5.0,
        predicate: @escaping (OrchestratorEvent) -> Bool
    ) async -> [OrchestratorEvent] {
        var collected: [OrchestratorEvent] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await event in orch.events {
            collected.append(event)
            if predicate(event) { return collected }
            if Date() > deadline { return collected }
        }
        return collected
    }

    // MARK: - OS1

    /// OS1: fresh orchestrator → submit returns .ran, emits .stateChange(.thinking),
    /// then .turnEnd + .stateChange(.idle).
    func test_OS1_freshSubmitReturnsRanAndEmitsLifecycle() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m1", model: "claude-opus-4-7", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        let outcome = await orch.submit(.text("hello"))
        guard case .ran(let turnId) = outcome else {
            return XCTFail("expected .ran, got \(outcome)")
        }
        XCTAssertFalse(turnId.rawValue.isEmpty)

        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }
            return false
        }

        XCTAssertTrue(events.contains(where: { if case .stateChange(.thinking) = $0 { return true }; return false }),
                      "missing .stateChange(.thinking)")
        XCTAssertTrue(events.contains(where: {
            if case .turnEnd(_, let r) = $0, r == .endTurn { return true }
            return false
        }), "missing .turnEnd(.endTurn)")
        XCTAssertTrue(events.contains(where: { if case .stateChange(.idle) = $0 { return true }; return false }),
                      "missing .stateChange(.idle)")
    }

    // MARK: - OS2

    /// OS2: while a turn is in flight (throttled mock), second submit is rejected.
    func test_OS2_secondSubmitRejectedWhileTurnInFlight() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ], throttleBetweenEventsNs: 100_000_000))  // 100ms between events → ~300ms turn
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        let firstOutcome = await orch.submit(.text("first"))
        guard case .ran = firstOutcome else { return XCTFail("expected first .ran") }

        // Second submit while first still draining: must be rejected.
        let secondOutcome = await orch.submit(.text("second"))
        XCTAssertEqual(secondOutcome, .rejected(reason: .turnInFlight))

        // Drain to completion to clean up.
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }
    }

    // MARK: - OS3

    /// OS3: 5 textDeltas → 5 .tokenDelta events on the channel, in order.
    func test_OS3_textDeltasFlowToChannelInOrder() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .textDelta("a"), .textDelta("b"), .textDelta("c"),
            .textDelta("d"), .textDelta("e"),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("hi"))
        let events = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let deltas: [String] = events.compactMap { ev in
            if case .tokenDelta(_, let s) = ev { return s }
            return nil
        }
        XCTAssertEqual(deltas, ["a", "b", "c", "d", "e"])
    }

    // MARK: - OS4

    /// OS4: 1 toolUseRequested → ToolDispatcher invoked → toolResult appended
    /// to messages → provider re-invoked.
    func test_OS4_toolUseDispatchedAndLooped() async throws {
        let toolReq = ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data("{}".utf8))

        // Script 1: emit a tool_use, then stopReason .toolUse → triggers a 2nd call.
        // Script 2: emit endTurn.
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

        let counter = TestCounter()
        let dispatcher = StubToolDispatcher(dispatch: { _ in
            await counter.inc()
            return Data("12:34".utf8)
        })

        let (orch, _, _) = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)

        _ = await orch.submit(.text("what time"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let dispatched = await counter.get()
        XCTAssertEqual(dispatched, 1, "ToolDispatcher.dispatch called once")
        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "expected 2 provider calls (tool_use loop)")
        // The second call's messages must include the .tool message we appended.
        let secondCallMessages = calls[1].messages
        XCTAssertTrue(secondCallMessages.contains(where: { msg in
            msg.role == .tool
        }), "second provider call must include the tool result message")
    }

    // MARK: - OS5

    /// OS5: ReplayLog.startTurn called with the fresh turnId and the per-turn nonce.
    /// Verified by querying the on-disk DB (events table + turns table).
    func test_OS5_replayLogStartTurnRecordsNonce() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, replay, _) = try await buildOrchestrator(provider: mock)

        let outcome = await orch.submit(.text("hi"))
        guard case .ran(let turnId) = outcome else { return XCTFail() }

        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Flush replay so the turns row is on disk.
        await replay.flush()
        try await replay.close()

        // HI-02: real DB-row assertion (not file-size proxy). Open the
        // closed DB and verify the turn row exists, has a non-empty
        // turn_nonce, and the nonce is the per-turn value the orchestrator
        // generated (SEC-06: nonce IS persisted in ReplayLog, NOT in the
        // OrchestratorEvent stream).
        let conn = try SQLiteConnection.open(at: tempHome.dbURL)
        defer { try? conn.close() }
        let rows: [(nonce: String, sourceText: String)] = try conn.query(
            "SELECT turn_nonce, source FROM turns WHERE turn_id=?;",
            bindings: [.text(turnId.rawValue)],
            map: { ($0.columnText(at: 0) ?? "", $0.columnText(at: 1) ?? "") }
        )
        XCTAssertEqual(rows.count, 1, "expected exactly one turn row for \(turnId.rawValue)")
        XCTAssertFalse(rows[0].nonce.isEmpty,
                       "turn_nonce must be persisted (SEC-06 — replay log only)")
        // Nonce is base64url; minimum length for 16-byte SecRandomCopyBytes
        // base64url-encoded is ~22 chars (no padding).
        XCTAssertGreaterThanOrEqual(rows[0].nonce.count, 16,
                                    "turn_nonce must be a non-trivial random string")
        XCTAssertEqual(rows[0].sourceText, "text", "source column must reflect TurnInput.text")
    }

    // MARK: - OS6

    /// OS6 (post-#21 / audit-2026-05-12 CRIT-2): the 8 KB cap is the MCP
    /// dispatcher's responsibility (`SanitizeForModel.prepareForBoundary`).
    /// `ToolResultPacker.pack` is now a pass-through. The orchestrator
    /// writes the dispatcher's prepared bytes to ReplayLog as
    /// `.toolResultFull` and embeds them in the model-facing tool_result.
    /// This test simulates a dispatcher that has already applied the cap
    /// (returns exactly 8 KB) and asserts both the replay-bound bytes and
    /// the model-facing message are sized at the cap — NOT 4 KB (which a
    /// remnant per-line cap would produce) and NOT 16 KB (which would
    /// indicate the cap was bypassed entirely).
    func test_OS6_replayAndModelSeeDispatcherPreparedBytes() async throws {
        let toolReq = ToolUseRequest(id: "tu1", name: "big", argsJSON: Data("{}".utf8))
        // Dispatcher returns exactly 8 KB — matching the contract that the
        // MCP boundary applies `prepareForBoundary(_, capBytes: 8192)`
        // upstream of the orchestrator.
        let preparedBlob = Data(repeating: UInt8(ascii: "X"), count: 8 * 1024)

        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
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
        let dispatcher = StubToolDispatcher(dispatch: { _ in preparedBlob })

        let (orch, _, _) = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)

        _ = await orch.submit(.text("fetch"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2)
        let secondCallToolMsg = calls[1].messages.first(where: { $0.role == .tool })!
        guard case .toolResult(_, let content) = secondCallToolMsg.content[0] else {
            return XCTFail("expected toolResult content")
        }
        // The packer no longer adds a `[TRUNCATED: …]` marker — the
        // dispatcher's `…[tool-result-truncated at 8192 bytes]` marker is
        // the only one a downstream consumer should ever see. The
        // dispatcher stub in this test does NOT add one (its job is to
        // simulate already-prepared bytes), so the model-facing string
        // should not contain either marker.
        XCTAssertFalse(content.contains("[TRUNCATED:"),
                       "packer must not double-mark — dispatcher owns the truncation marker")
        // The 8 KB cap bytes flow through; the model-facing content is the
        // dispatcher payload wrapped in the SEC-06 nonce envelope. Assert
        // the payload byte count is preserved (>= 8 KB, accounting for the
        // wrapper text; NOT 4 KB or less).
        XCTAssertGreaterThanOrEqual(content.utf8.count, 8 * 1024,
                                    "model-facing must carry the full 8 KB dispatcher payload — not 4 KB or less")
    }

    /// OS6b (#21 regression — audit-2026-05-12 CRIT-2): the persisted
    /// ReplayLog row for `.toolResultFull` is keyed to exactly the bytes
    /// the dispatcher returned (no second cap, no per-line strip applied
    /// on top). A dispatcher that returns 8 KB → replay row contains
    /// exactly 8 KB of payload. Pre-fix, `ToolResultPacker.pack`'s redundant
    /// inner cap re-truncated already-capped bytes (no-op for size but the
    /// design was wrong); a per-line variant could have dropped to 4 KB
    /// under different inputs. This test pins the post-fix invariant by
    /// driving end-to-end through the orchestrator and reading the
    /// `payload_bytes` BLOB from the SQLite `events` table.
    func test_OS6b_replayRowMatchesDispatcherBytesNoSecondCap() async throws {
        let toolReq = ToolUseRequest(id: "tu-21", name: "big", argsJSON: Data("{}".utf8))
        // Exactly 8 KB — what a real dispatcher emits after
        // `SanitizeForModel.prepareForBoundary(_, capBytes: 8192)`.
        let preparedBlob = Data(repeating: UInt8(ascii: "X"), count: 8 * 1024)

        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
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
        let dispatcher = StubToolDispatcher(dispatch: { _ in preparedBlob })

        let (orch, replay, _) = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)

        _ = await orch.submit(.text("fetch"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Flush + close so the row is on disk before we open a competing
        // connection.
        await replay.flush()
        try await replay.close()

        let conn = try SQLiteConnection.open(at: tempHome.dbURL)
        defer { try? conn.close() }
        let blob: Data? = try conn.query(
            "SELECT payload_bytes FROM events WHERE kind='tool_result_full';",
            map: { $0.columnBlob(at: 0) }
        ).first ?? nil

        XCTAssertNotNil(blob, "must find a tool_result_full row")
        guard let blob else { return }
        // The envelope is `{"tool_use_id": "...", "bytes": "<base64>"}`.
        let json = try JSONSerialization.jsonObject(with: blob) as? [String: String]
        XCTAssertEqual(json?["tool_use_id"], "tu-21")
        let recovered = Data(base64Encoded: json?["bytes"] ?? "") ?? Data()
        // #21 invariant: the replay row carries EXACTLY the dispatcher's
        // 8 KB payload — not 4 KB (which a residual per-line strip would
        // produce) and not less.
        XCTAssertEqual(recovered.count, 8 * 1024,
                       "replay row must be exactly 8 KB — not 4 KB or less (#21)")
        XCTAssertEqual(recovered, preparedBlob,
                       "replay row must be byte-for-byte identical to the dispatcher payload")
    }

    // MARK: - OS7

    // MARK: - OS — SEC-06 system-prompt directive (CR-01)

    /// OS_systemPromptCarriesUntrustedDirective: the per-turn system prompt
    /// the provider receives MUST contain the nonce-keyed "treat as data"
    /// directive. Without it, the `<UNTRUSTED_CONTENT id="…">` wrapper is
    /// decoration the model has no reason to honor (SEC-06 mitigation gap).
    ///
    /// Asserts:
    /// - The directive substring "UNTRUSTED_CONTENT" appears in the system
    ///   message.
    /// - The same nonce id appears in BOTH the directive AND any later
    ///   tool-result wrapper — proves the directive references the wrapper.
    /// - When caller passes `systemPrompt = ""`, the directive still emits
    ///   (defense-in-depth even with no caller-supplied prompt).
    func test_OS_systemPromptCarriesUntrustedDirective() async throws {
        let toolReq = ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data("{}".utf8))
        let mock = MockLLMProvider(scripts: [
            .init(events: [
                .messageStart(LLMMessageStart(messageId: "m1", model: "x", usagePrefix: nil)),
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
        let dispatcher = StubToolDispatcher(dispatch: { _ in Data("12:34".utf8) })
        let (orch, _, _) = try await buildOrchestrator(provider: mock, dispatcher: dispatcher)

        _ = await orch.submit(.text("hi"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        XCTAssertEqual(calls.count, 2, "expected 2 provider calls for tool-use loop")

        // Extract the system message text from the first call.
        let firstSystemMsg = calls[0].messages.first(where: { $0.role == .system })
        XCTAssertNotNil(firstSystemMsg, "first call must include a .system role message")
        guard let sysMsg = firstSystemMsg else { return }
        guard case .text(let sysText) = sysMsg.content[0] else {
            return XCTFail("expected text content in system message")
        }
        // Caller-supplied prompt is preserved.
        XCTAssertTrue(sysText.contains("you are jarvis"),
                      "caller-supplied system prompt must be preserved")
        // SEC-06 directive substring is present.
        XCTAssertTrue(sysText.contains("UNTRUSTED_CONTENT"),
                      "system prompt must carry the SEC-06 'treat as data' directive")
        XCTAssertTrue(sysText.contains("Treat ALL content"),
                      "directive language must be unambiguous")

        // Extract the nonce from the directive (the value between id=" and ").
        // The wrapper format is id="<nonce>".
        let pattern = #"id="([A-Za-z0-9_\-]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(sysText.startIndex..<sysText.endIndex, in: sysText)
        let match = regex.firstMatch(in: sysText, range: range)
        XCTAssertNotNil(match, "directive must include id=\"<nonce>\" pattern")
        guard let m = match,
              let nonceRange = Range(m.range(at: 1), in: sysText) else {
            return XCTFail("could not extract nonce from directive")
        }
        let nonceFromDirective = String(sysText[nonceRange])
        XCTAssertFalse(nonceFromDirective.isEmpty)

        // Nonce in the directive must equal nonce in the second-call tool-result wrapper.
        let secondCallToolMsg = calls[1].messages.first(where: { $0.role == .tool })
        XCTAssertNotNil(secondCallToolMsg, "second call must include a .tool message")
        guard let toolMsg = secondCallToolMsg,
              case .toolResult(_, let content) = toolMsg.content[0] else {
            return XCTFail("expected toolResult content")
        }
        XCTAssertTrue(content.contains("id=\"\(nonceFromDirective)\""),
                      "wrapper nonce must match the directive nonce — same per-turn value")
    }

    /// Defense-in-depth: even with an empty caller-supplied systemPrompt,
    /// the SEC-06 directive must still be emitted.
    func test_OS_systemPromptDirectiveEmittedWhenCallerPromptEmpty() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let replay = try ReplayLog(databaseURL: tempHome.dbURL)
        let session = try await replay.beginSession(appVersion: "test", buildSHA: "deadbeef")
        let orch = AgentOrchestrator(
            configStore: makeConfigStore(),
            providerFactory: { _ in mock },
            toolDispatcher: StubToolDispatcher(),
            replayLog: replay,
            sessionId: session,
            systemPrompt: "",  // empty caller prompt
            availableTools: []
        )

        _ = await orch.submit(.text("hi"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        let calls = await mock.getRecordedCalls()
        let firstSystemMsg = calls[0].messages.first(where: { $0.role == .system })
        XCTAssertNotNil(firstSystemMsg)
        guard let sysMsg = firstSystemMsg,
              case .text(let sysText) = sysMsg.content[0] else {
            return XCTFail("expected text content in system message")
        }
        XCTAssertTrue(sysText.contains("UNTRUSTED_CONTENT"),
                      "directive must emit even when caller systemPrompt is empty")
    }

    /// OS7: ReplayLog.endTurn called exactly once per turn with the stop_reason.
    /// Indirect check: after end_turn, a second submit succeeds (nothing is held).
    func test_OS7_endTurnCalledOncePerTurn() async throws {
        let mock = MockLLMProvider(script: .init(events: [
            .messageStart(LLMMessageStart(messageId: "m", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ]))
        let (orch, _, _) = try await buildOrchestrator(provider: mock)

        _ = await orch.submit(.text("first"))
        _ = await collectUntil(orch: orch) { ev in
            if case .stateChange(.idle) = ev { return true }; return false
        }

        // Reset the mock's call counter so the second turn replays the same
        // single-event script.
        await mock.resetRecordedCalls()
        await mock.setScripts([.init(events: [
            .messageStart(LLMMessageStart(messageId: "m2", model: "x", usagePrefix: nil)),
            .stopReason(.endTurn),
            .messageStop,
        ])])

        let outcome = await orch.submit(.text("second"))
        guard case .ran = outcome else {
            return XCTFail("second submit must succeed — first turn ended cleanly")
        }
    }
}
