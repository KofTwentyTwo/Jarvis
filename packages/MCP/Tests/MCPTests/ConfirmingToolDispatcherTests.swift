// ConfirmingToolDispatcherTests.swift
//
// Plan 05-05 Task 3 — RED tests for ConfirmingToolDispatcher.
//
// Validates:
//   - Pass-through for non-confirmation tools (no broker, no awaiting-approval bus emission).
//   - The MCP-04 args-redaction seal: pre-approval bus emission is exactly
//     `{"awaitingApproval":true}` and contains zero overlap with raw argsJSON.
//   - Ordering invariant: bus toolCallStart fires BEFORE broker.request,
//     which fires BEFORE inner.dispatch.
//   - Each of the four broker outcomes produces the right thrown error,
//     bus toolCallEnd, and (for .timeout) WARNING log.
//   - test_OC_T1_timeoutLogsWarning name is fixed by the plan medium-finding.

import XCTest
import Foundation
import AgentCore
import AgentOrchestrator
@testable import JarvisMCP

final class ConfirmingToolDispatcherTests: XCTestCase {

    // MARK: - Spies

    /// Records every bus emission, preserving order. Conforms to the
    /// dispatcher's BusGateway protocol.
    actor SpyBus: BusGateway {
        enum Event: Equatable {
            case toolCallStart(toolUseId: UUID, name: String, argsPreview: String)
            case argsPreviewUpdate(toolUseId: UUID, name: String, argsPreview: String)
            case toolCallEnd(toolUseId: UUID, name: String, ok: Bool, previewOrError: String)
        }
        private(set) var events: [Event] = []

        func emitToolCallStart(toolUseId: UUID, name: String, argsPreview: String) async {
            events.append(.toolCallStart(toolUseId: toolUseId, name: name, argsPreview: argsPreview))
        }
        func updateArgsPreview(toolUseId: UUID, name: String, argsPreview: String) async {
            events.append(.argsPreviewUpdate(toolUseId: toolUseId, name: name, argsPreview: argsPreview))
        }
        func emitToolCallEnd(toolUseId: UUID, name: String, ok: Bool, previewOrError: String) async {
            events.append(.toolCallEnd(toolUseId: toolUseId, name: name, ok: ok, previewOrError: previewOrError))
        }

        func snapshot() -> [Event] { events }
    }

    /// Scripted broker that returns a pre-decided outcome. NOT a
    /// ConfirmationBroker subclass — the dispatcher takes the broker by
    /// nominal type (concrete actor), so we make a real broker with a
    /// scripted-presenter that auto-fires the desired response.
    actor ScriptedPresenter: ConfirmationPresenting {
        private let outcome: ConfirmationOutcome
        weak var broker: ConfirmationBroker?

        init(outcome: ConfirmationOutcome) { self.outcome = outcome }

        nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
            // Fire the scripted outcome back to the broker on a slight
            // delay so the dispatcher can observe the bus emit -> broker
            // request ordering.
            try? await Task.sleep(nanoseconds: 5_000_000)
            await self.broker?.response(id: id, outcome: outcome)
        }

        nonisolated func dismiss(id: UUID) async {}
    }

    /// Inner tool dispatcher mock. Records calls and returns scripted bytes
    /// or throws scripted errors. Reports requiresConfirmation per name.
    actor SpyInnerDispatcher: ToolDispatcher {
        struct Call: Equatable { let id: String; let name: String }
        private(set) var calls: [Call] = []
        private let confirmationFor: [String: Bool]
        private let scriptedResult: Result<Data, ScriptedError>

        enum ScriptedError: Error, Equatable {
            case crash
        }

        init(
            confirmationFor: [String: Bool],
            scriptedResult: Result<Data, ScriptedError> = .success(Data("ok".utf8))
        ) {
            self.confirmationFor = confirmationFor
            self.scriptedResult = scriptedResult
        }

        func dispatch(toolUse: ToolUseRequest) async throws -> Data {
            calls.append(Call(id: toolUse.id, name: toolUse.name))
            switch scriptedResult {
            case .success(let data): return data
            case .failure(let err): throw err
            }
        }

        nonisolated func requiresConfirmation(toolName: String) -> Bool {
            confirmationFor[toolName] ?? false
        }

        func snapshot() -> [Call] { calls }
    }

    // MARK: - Helpers

    /// Build a broker that auto-resolves with the given outcome on first
    /// request. Returns the broker; the presenter holds the back-ref.
    private func makeScriptedBroker(outcome: ConfirmationOutcome) async -> ConfirmationBroker {
        let presenter = ScriptedPresenter(outcome: outcome)
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        await presenter.setBroker(broker)
        return broker
    }

    // Trivial sanitizer used by all tests: passes argsJSON through as
    // UTF-8 string (truncated at 256 bytes for parity with the production
    // sanitizer in MCPRuntimeWiring).
    private let passthroughSanitizer: @Sendable (Data) -> String = { argsJSON in
        guard let s = String(data: argsJSON, encoding: .utf8) else { return "{}" }
        return s.count <= 256 ? s : String(s.prefix(256)) + "…[args-truncated]"
    }

    // MARK: - Tests

    /// Fast path: non-confirmation tool dispatches directly through the
    /// inner dispatcher. No broker, no awaiting-approval bus emission.
    func test_dispatch_nonConfirmTool_passesThroughUnchanged() async throws {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(
            confirmationFor: ["get_time": false],
            scriptedResult: .success(Data("now".utf8))
        )
        let broker = await makeScriptedBroker(outcome: .deny)  // would fire if called
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let req = ToolUseRequest(id: "tu1", name: "get_time", argsJSON: Data("{}".utf8))
        let result = try await dispatcher.dispatch(toolUse: req)
        XCTAssertEqual(String(data: result, encoding: .utf8), "now")

        let busEvents = await bus.snapshot()
        XCTAssertTrue(busEvents.isEmpty, "non-confirm tools must NOT emit awaiting-approval bus traffic")

        let calls = await inner.snapshot()
        XCTAssertEqual(calls, [.init(id: "tu1", name: "get_time")])
    }

    /// MCP-04 headline invariant: pre-approval bus emission is exactly
    /// `{"awaitingApproval":true}` and the raw args bytes never appear in
    /// the bus traffic before approval.
    func test_dispatch_confirmTool_emitsAwaitingApprovalPreview_BEFORE_callingInner() async throws {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(
            confirmationFor: ["run_applescript": true],
            scriptedResult: .success(Data("approved-result".utf8))
        )
        let broker = await makeScriptedBroker(outcome: .approve)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let argsJSON = Data(#"{"source":"tell application \"Safari\" to activate"}"#.utf8)
        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: argsJSON)
        _ = try await dispatcher.dispatch(toolUse: req)

        let busEvents = await bus.snapshot()
        // First event must be toolCallStart with the awaiting-approval seal.
        guard case .toolCallStart(_, let name, let preview) = busEvents.first else {
            XCTFail("first bus event must be toolCallStart, got \(String(describing: busEvents.first))")
            return
        }
        XCTAssertEqual(name, "run_applescript")
        XCTAssertEqual(preview, #"{"awaitingApproval":true}"#)
        // Inner must have been called AFTER the bus emission landed.
        let calls = await inner.snapshot()
        XCTAssertEqual(calls.count, 1)
    }

    /// On approve, dispatcher emits a follow-up sanitized argsPreview AND
    /// calls inner.dispatch.
    func test_dispatch_confirmTool_onApprove_emitsPostApprovalPreview_AND_callsInner() async throws {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(
            confirmationFor: ["run_applescript": true],
            scriptedResult: .success(Data("approved-result".utf8))
        )
        let broker = await makeScriptedBroker(outcome: .approve)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let argsJSON = Data(#"{"source":"echo hi"}"#.utf8)
        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: argsJSON)
        let result = try await dispatcher.dispatch(toolUse: req)
        XCTAssertEqual(String(data: result, encoding: .utf8), "approved-result")

        let busEvents = await bus.snapshot()
        // Expect: toolCallStart(awaitingApproval) → argsPreviewUpdate(sanitized).
        XCTAssertEqual(busEvents.count, 2)
        if case .argsPreviewUpdate(_, _, let preview) = busEvents[1] {
            XCTAssertEqual(preview, #"{"source":"echo hi"}"#)
        } else {
            XCTFail("second bus event must be argsPreviewUpdate, got \(busEvents[1])")
        }
        let calls = await inner.snapshot()
        XCTAssertEqual(calls.count, 1)
    }

    /// On deny: throws ConfirmationError.denied, emits toolCallEnd(ok:false),
    /// inner is never called.
    func test_dispatch_confirmTool_onDeny_throwsConfirmationError_denied_AND_emitsToolCallEnd_failed() async {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(confirmationFor: ["run_applescript": true])
        let broker = await makeScriptedBroker(outcome: .deny)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: Data("{}".utf8))
        do {
            _ = try await dispatcher.dispatch(toolUse: req)
            XCTFail("expected ConfirmationError.denied")
        } catch let err as ConfirmationError {
            XCTAssertEqual(err, .denied)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let busEvents = await bus.snapshot()
        guard let last = busEvents.last,
              case .toolCallEnd(_, _, let ok, let preview) = last else {
            XCTFail("last bus event must be toolCallEnd")
            return
        }
        XCTAssertEqual(ok, false)
        XCTAssertTrue(preview.lowercased().contains("deni"))
        let calls = await inner.snapshot()
        XCTAssertTrue(calls.isEmpty, "inner.dispatch must NOT be called on .deny")
    }

    /// AGENT-11 headline test: timeout outcome logs WARNING to
    /// JarvisLogChannel.mcp. Test name is FIXED by plan medium-finding.
    func test_OC_T1_timeoutLogsWarning() async {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(confirmationFor: ["run_applescript": true])
        let broker = await makeScriptedBroker(outcome: .timeout)

        // Recording log seam — production default uses swift-log's
        // Logger(label: JarvisLogChannel.mcp.rawValue).warning(...).
        let recordedWarnings: SpyLogRecorder = SpyLogRecorder()
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer,
            logWarning: { msg in Task { await recordedWarnings.record(msg) } }
        )

        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: Data("{}".utf8))
        do {
            _ = try await dispatcher.dispatch(toolUse: req)
            XCTFail("expected ConfirmationError.timedOut")
        } catch let err as ConfirmationError {
            if case .timedOut = err {
                // ok
            } else {
                XCTFail("expected .timedOut, got \(err)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        // Settle the logging Task that the dispatcher fires.
        try? await Task.sleep(nanoseconds: 30_000_000)

        let warnings = await recordedWarnings.snapshot()
        XCTAssertEqual(warnings.count, 1, "exactly one WARNING log line on .timeout")
        let line = warnings.first ?? ""
        XCTAssertTrue(line.lowercased().contains("timeout"),
                      "WARNING line must contain 'timeout' (got: \(line))")
        XCTAssertTrue(line.contains("ConfirmingToolDispatcher"),
                      "WARNING line must mention subsystem (got: \(line))")

        let busEvents = await bus.snapshot()
        guard let last = busEvents.last,
              case .toolCallEnd(_, _, let ok, _) = last else {
            XCTFail("last bus event must be toolCallEnd")
            return
        }
        XCTAssertEqual(ok, false)

        let calls = await inner.snapshot()
        XCTAssertTrue(calls.isEmpty, "inner.dispatch must NOT be called on .timeout")
    }

    /// Barge-in: throws ConfirmationError.barged, emits toolCallEnd, no inner.
    func test_dispatch_confirmTool_onBarge_throwsConfirmationError_barged_AND_emitsToolCallEnd_failed() async {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(confirmationFor: ["run_applescript": true])
        let broker = await makeScriptedBroker(outcome: .barge)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: Data("{}".utf8))
        do {
            _ = try await dispatcher.dispatch(toolUse: req)
            XCTFail("expected ConfirmationError.barged")
        } catch let err as ConfirmationError {
            XCTAssertEqual(err, .barged)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let busEvents = await bus.snapshot()
        guard let last = busEvents.last,
              case .toolCallEnd(_, _, let ok, _) = last else {
            XCTFail("last bus event must be toolCallEnd")
            return
        }
        XCTAssertEqual(ok, false)

        let calls = await inner.snapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    /// After approval, errors thrown by the inner dispatcher propagate
    /// verbatim (the orchestrator's existing thrown-error path handles them).
    func test_dispatch_confirmTool_innerError_propagatesAfterApproval() async {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(
            confirmationFor: ["run_applescript": true],
            scriptedResult: .failure(.crash)
        )
        let broker = await makeScriptedBroker(outcome: .approve)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: Data("{}".utf8))
        do {
            _ = try await dispatcher.dispatch(toolUse: req)
            XCTFail("expected SpyInnerDispatcher.ScriptedError.crash")
        } catch let err as SpyInnerDispatcher.ScriptedError {
            XCTAssertEqual(err, .crash)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// `requiresConfirmation` delegates synchronously without an actor hop.
    func test_requiresConfirmation_delegatesToInner_synchronously() async {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(confirmationFor: [
            "run_applescript": true,
            "get_time": false,
        ])
        let broker = await makeScriptedBroker(outcome: .approve)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        XCTAssertTrue(dispatcher.requiresConfirmation(toolName: "run_applescript"))
        XCTAssertFalse(dispatcher.requiresConfirmation(toolName: "get_time"))
    }

    /// Defense-in-depth: under no condition does the pre-approval bus
    /// emission contain the raw argsJSON.
    func test_argsPreview_seal_neverContainsRawArgs_prior_to_approval() async throws {
        let bus = SpyBus()
        let inner = SpyInnerDispatcher(
            confirmationFor: ["run_applescript": true],
            scriptedResult: .success(Data())
        )
        let broker = await makeScriptedBroker(outcome: .approve)
        let dispatcher = ConfirmingToolDispatcher(
            inner: inner,
            broker: broker,
            bus: bus,
            argsPreviewSanitizer: passthroughSanitizer
        )

        let secret = "forbidden-string-for-test"
        let argsJSON = Data(#"{"source":"\#(secret)"}"#.utf8)
        let req = ToolUseRequest(id: UUID().uuidString, name: "run_applescript", argsJSON: argsJSON)
        _ = try await dispatcher.dispatch(toolUse: req)

        let busEvents = await bus.snapshot()
        guard case .toolCallStart(_, _, let firstPreview) = busEvents.first else {
            XCTFail("first event must be toolCallStart")
            return
        }
        XCTAssertEqual(firstPreview, #"{"awaitingApproval":true}"#,
                       "pre-approval seal must be exactly the awaitingApproval literal")
        XCTAssertFalse(firstPreview.contains(secret),
                       "pre-approval bus traffic must not leak the raw args bytes")
    }
}

// MARK: - Test helpers

/// Records warning log lines for assertion in test_OC_T1_timeoutLogsWarning.
actor SpyLogRecorder {
    private var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
    func snapshot() -> [String] { lines }
}

/// ScriptedPresenter helper — sets the broker back-ref. Defined as an
/// extension so the actor's stored `broker` weak-var can be assigned from
/// outside the actor's init (initial creation is `nil`).
extension ConfirmingToolDispatcherTests.ScriptedPresenter {
    func setBroker(_ b: ConfirmationBroker) { self.broker = b }
}
