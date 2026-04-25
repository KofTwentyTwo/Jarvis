// ConfirmationBrokerTests.swift
//
// Plan 05-05 Task 1 — RED tests for the ConfirmationBroker FSM.
//
// MCP-09 invariant (first-write-wins) + AGENT-11 (60s timeout, with sub-second
// injection knob for deterministic test runs).

import XCTest
@testable import JarvisMCP

final class ConfirmationBrokerTests: XCTestCase {

    // MARK: - Test fixtures

    /// In-memory presenter that records every show/dismiss call. Conforms to
    /// `ConfirmationPresenting` so it can be plugged into the broker without
    /// pulling AppKit.
    actor SpyPresenter: ConfirmationPresenting {
        private(set) var showCount: Int = 0
        private(set) var dismissCount: Int = 0
        private(set) var lastShownID: UUID?

        nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
            await record(show: id)
        }

        nonisolated func dismiss(id: UUID) async {
            await record(dismiss: id)
        }

        private func record(show id: UUID) {
            showCount += 1
            lastShownID = id
        }

        private func record(dismiss id: UUID) {
            dismissCount += 1
        }

        func snapshot() -> (show: Int, dismiss: Int, lastShown: UUID?) {
            (showCount, dismissCount, lastShownID)
        }
    }

    // MARK: - Tests

    /// Headline happy path: the awaiter resumes with `.approve` once
    /// `response(id:.approve)` lands.
    func test_request_returnsApprove_whenResponseApproveCalled() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        let id = UUID()

        async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")

        // Give the request task a chance to suspend on its continuation.
        try? await Task.sleep(nanoseconds: 10_000_000)
        await broker.response(id: id, outcome: .approve)

        let result = await outcome
        XCTAssertEqual(result, .approve)
    }

    func test_request_returnsDeny_whenResponseDenyCalled() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        let id = UUID()

        async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await broker.response(id: id, outcome: .deny)

        let result = await outcome
        XCTAssertEqual(result, .deny)
    }

    func test_request_returnsBarge_whenResponseBargeCalled() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        let id = UUID()

        async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await broker.response(id: id, outcome: .barge)

        let result = await outcome
        XCTAssertEqual(result, .barge)
    }

    /// AGENT-11: timeout fires when no response comes. Sub-second injection
    /// (`timeoutSeconds: 0.05`) keeps the test deterministic without 60s waits.
    func test_request_returnsTimeout_whenNoResponseInSubSecond() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 0.05, presenter: presenter)
        let id = UUID()

        let outcome = await broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        XCTAssertEqual(outcome, .timeout)
    }

    /// MCP-09 (the headline first-write-wins invariant): a second response
    /// after the broker has already resolved is silently dropped.
    func test_lateResponse_afterApprove_isNoOp() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        let id = UUID()

        async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await broker.response(id: id, outcome: .approve)
        let first = await outcome
        XCTAssertEqual(first, .approve)

        // Late hop: must NOT crash, must NOT cause a double-resume.
        await broker.response(id: id, outcome: .deny)

        // Give any (incorrectly-spawned) follow-up dismiss a chance to land.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let snap = await presenter.snapshot()
        // dismiss called exactly once across the lifecycle.
        XCTAssertEqual(snap.dismiss, 1, "late .deny after .approve must be a silent no-op")
    }

    /// A response that arrives AFTER the timeout already fired must no-op.
    /// Otherwise we'd double-resume the awaiter (Swift fatal).
    func test_lateResponse_afterTimeout_isNoOp() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 0.05, presenter: presenter)
        let id = UUID()

        let outcome = await broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        XCTAssertEqual(outcome, .timeout)

        // Late hop: must NOT crash.
        await broker.response(id: id, outcome: .approve)

        try? await Task.sleep(nanoseconds: 20_000_000)
        let snap = await presenter.snapshot()
        XCTAssertEqual(snap.dismiss, 1, "late .approve after .timeout must be a silent no-op")
    }

    /// Two concurrent responses race the actor's serial executor; only one
    /// wins, the other is silently dropped.
    func test_concurrentResponses_firstWins() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        let id = UUID()

        async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        try? await Task.sleep(nanoseconds: 10_000_000)

        async let _ = broker.response(id: id, outcome: .approve)
        async let _ = broker.response(id: id, outcome: .deny)

        let result = await outcome
        XCTAssertTrue(result == .approve || result == .deny,
                      "broker resolved with the first-arrived outcome (\(result))")

        try? await Task.sleep(nanoseconds: 20_000_000)
        let snap = await presenter.snapshot()
        XCTAssertEqual(snap.dismiss, 1)
    }

    /// `response` for an unknown id must NOT crash (e.g., late timeout
    /// firing after the broker forgot the entry).
    func test_unknownId_response_isSilentNoOp() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)

        // No request issued for this id.
        await broker.response(id: UUID(), outcome: .approve)

        let snap = await presenter.snapshot()
        XCTAssertEqual(snap.show, 0)
        XCTAssertEqual(snap.dismiss, 0)
    }

    /// WR-03 (REVIEW 05) regression: at a sub-second timeout, a `.deny`
    /// arriving microseconds before the timer fires must not cause a
    /// double-resolve. The first-write-wins guard already covers this,
    /// but the explicit do/catch on Task.sleep cancellation removes the
    /// silent race window between Task.sleep returning and Task.isCancelled
    /// being read. Repeated runs to absorb scheduler jitter.
    func test_response_atTimerBoundary_firstWriteWins_noDoubleResolve() async {
        for _ in 0..<10 {
            let presenter = SpyPresenter()
            let broker = ConfirmationBroker(timeoutSeconds: 0.05, presenter: presenter)
            let id = UUID()

            async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
            // Race: send .deny ≈ at the timer boundary. Some runs land
            // pre-timer (deny wins); some land post-timer (timeout wins).
            // EITHER outcome is OK — we're asserting the broker resolves
            // EXACTLY ONCE, not which one wins.
            try? await Task.sleep(nanoseconds: 49_000_000)
            await broker.response(id: id, outcome: .deny)

            let result = await outcome
            XCTAssertTrue(
                result == .deny || result == .timeout,
                "broker must resolve to deny or timeout (got \(result))"
            )

            // Settle any stragglers — dismiss must fire exactly once.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let snap = await presenter.snapshot()
            XCTAssertEqual(snap.dismiss, 1, "dismiss must fire exactly once even at the timer boundary")
        }
    }

    /// Lifecycle invariant: `dismiss(id:)` is called exactly once across the
    /// resolve lifecycle (not 0, not 2).
    func test_dismissCalledExactlyOnce_perRequest() async {
        let presenter = SpyPresenter()
        let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenter)
        let id = UUID()

        async let outcome = broker.request(id: id, toolName: "run_applescript", argsPreview: "{}")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await broker.response(id: id, outcome: .approve)
        _ = await outcome

        // Allow the dismiss task to land.
        try? await Task.sleep(nanoseconds: 30_000_000)
        let snap = await presenter.snapshot()
        XCTAssertEqual(snap.show, 1, "show called once on request")
        XCTAssertEqual(snap.dismiss, 1, "dismiss called exactly once after resolve")
    }
}
