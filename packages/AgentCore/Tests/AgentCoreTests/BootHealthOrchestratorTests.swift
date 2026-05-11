import XCTest
import os
@testable import AgentCore

final class BootHealthOrchestratorTests: XCTestCase {

    // MARK: - Mock probe (records calls + returns scripted outcome)

    /// `Mock*` per CLAUDE.md §Test naming conventions — records every
    /// `probe()` invocation so tests can assert call counts.
    final class MockProbe: BootHealthProbe, Sendable {
        let name: String
        private let scripted: ProbeOutcome
        private let counter = OSAllocatedUnfairLock(initialState: 0)

        init(name: String, scripted: ProbeOutcome) {
            self.name = name
            self.scripted = scripted
        }

        var callCount: Int {
            counter.withLock { $0 }
        }

        func probe() async -> ProbeOutcome {
            counter.withLock { $0 += 1 }
            return scripted
        }
    }

    /// `Fake*` per CLAUDE.md §Test naming conventions — realistic stateful
    /// behavior with an actual sleep. Used to confirm probes run in
    /// parallel (3× 100ms parallel should finish in well under 300ms).
    final class FakeSleepingProbe: BootHealthProbe, @unchecked Sendable {
        let name: String
        private let sleepNanos: UInt64
        init(name: String, sleepMs: Int) {
            self.name = name
            self.sleepNanos = UInt64(sleepMs) * 1_000_000
        }
        func probe() async -> ProbeOutcome {
            try? await Task.sleep(nanoseconds: sleepNanos)
            return ProbeOutcome(status: .ok, evidence: "slept")
        }
    }

    // MARK: - Tests

    func testRunAllInvokesEveryRegisteredProbe() async {
        let a = MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "0 facts"))
        let b = MockProbe(name: "voice", scripted: ProbeOutcome(status: .ok, evidence: "AudioGraph running"))
        let c = MockProbe(name: "mcp", scripted: ProbeOutcome(status: .ok, evidence: "8 tools"))

        let orch = BootHealthOrchestrator()
        await orch.register(a)
        await orch.register(b)
        await orch.register(c)

        _ = await orch.runAll()

        XCTAssertEqual(a.callCount, 1)
        XCTAssertEqual(b.callCount, 1)
        XCTAssertEqual(c.callCount, 1)
    }

    func testSnapshotPreservesRegistrationOrder() async {
        let p1 = MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "e1"))
        let p2 = MockProbe(name: "voice", scripted: ProbeOutcome(status: .ok, evidence: "e2"))
        let p3 = MockProbe(name: "mcp", scripted: ProbeOutcome(status: .ok, evidence: "e3"))
        let p4 = MockProbe(name: "webview", scripted: ProbeOutcome(status: .ok, evidence: "e4"))

        let orch = BootHealthOrchestrator()
        for probe in [p1, p2, p3, p4] {
            await orch.register(probe)
        }

        let snapshot = await orch.runAll()

        XCTAssertEqual(snapshot.subsystems.map(\.name), ["memory", "voice", "mcp", "webview"])
    }

    func testProbesRunInParallel() async {
        // 3 × 200ms sleeping probes. Serial would take ~600ms; parallel
        // should finish in well under 400ms (cushion for CI scheduler noise).
        let orch = BootHealthOrchestrator()
        await orch.register(FakeSleepingProbe(name: "a", sleepMs: 200))
        await orch.register(FakeSleepingProbe(name: "b", sleepMs: 200))
        await orch.register(FakeSleepingProbe(name: "c", sleepMs: 200))

        let start = Date()
        _ = await orch.runAll()
        let elapsedMs = Date().timeIntervalSince(start) * 1000.0

        XCTAssertLessThan(
            elapsedMs, 400.0,
            "3 × 200ms parallel probes should finish well under 400ms, got \(elapsedMs)ms — likely serialized"
        )
    }

    func testLastSnapshotReturnsMostRecent() async {
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "first")))

        let preRun = await orch.lastSnapshot()
        XCTAssertNil(preRun)

        let snap1 = await orch.runAll()
        let stored1 = await orch.lastSnapshot()
        XCTAssertEqual(stored1, snap1)

        let snap2 = await orch.runAll()
        let stored2 = await orch.lastSnapshot()
        XCTAssertEqual(stored2, snap2)
    }

    func testFailedProbesPropagateToSnapshotAndFailedList() async {
        let ok = MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "fine"))
        let dead = MockProbe(
            name: "ollama",
            scripted: ProbeOutcome(status: .failed(reason: "connection refused", severity: .loud), evidence: "127.0.0.1:11434 unreachable")
        )
        let degraded = MockProbe(
            name: "anthropic",
            scripted: ProbeOutcome(status: .degraded(reason: "rate limit", severity: .loud), evidence: "HTTP 429")
        )

        let orch = BootHealthOrchestrator()
        await orch.register(ok)
        await orch.register(dead)
        await orch.register(degraded)

        let snapshot = await orch.runAll()

        XCTAssertEqual(snapshot.subsystems.count, 3)
        XCTAssertEqual(snapshot.failed.map(\.name), ["ollama"])
        XCTAssertEqual(snapshot.failed.first?.status, .failed(reason: "connection refused", severity: .loud))
        XCTAssertEqual(snapshot.failed.first?.evidence, "127.0.0.1:11434 unreachable")
    }

    func testUnknownStatusPreservedNotCoercedToOK() async {
        // Anti-fake-status invariant: a probe that can't execute reports
        // .unknown with a reason — the orchestrator must not promote it
        // to .ok just because the probe didn't throw.
        let probe = MockProbe(
            name: "anthropic",
            scripted: ProbeOutcome(status: .unknown(reason: "no API key in Keychain", severity: .critical), evidence: "probe skipped")
        )

        let orch = BootHealthOrchestrator()
        await orch.register(probe)

        let snapshot = await orch.runAll()

        XCTAssertEqual(snapshot.subsystems.count, 1)
        XCTAssertEqual(snapshot.subsystems[0].status, .unknown(reason: "no API key in Keychain", severity: .critical))
        XCTAssertTrue(snapshot.failed.isEmpty, ".unknown must not appear in .failed — banner enqueue would be wrong")
    }

    // MARK: - Round 4 — severity model

    func testOverallHealthAllOkReturnsOk() async {
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "a", scripted: ProbeOutcome(status: .ok, evidence: "x")))
        await orch.register(MockProbe(name: "b", scripted: ProbeOutcome(status: .ok, evidence: "y")))
        let snapshot = await orch.runAll()
        XCTAssertEqual(snapshot.overallHealth, .ok)
    }

    func testOverallHealthWorstSeverityWins() async {
        // soft + loud + critical → critical
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "vision", scripted: ProbeOutcome(status: .unknown(reason: "TCC", severity: .soft), evidence: "")))
        await orch.register(MockProbe(name: "ollama", scripted: ProbeOutcome(status: .degraded(reason: "missing model", severity: .loud), evidence: "")))
        await orch.register(MockProbe(name: "memory", scripted: ProbeOutcome(status: .failed(reason: "vec0 missing", severity: .critical), evidence: "")))
        let snap = await orch.runAll()
        XCTAssertEqual(snap.overallHealth, .critical)
    }

    func testOverallHealthLoudWhenNoCritical() async {
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "vision", scripted: ProbeOutcome(status: .unknown(reason: "TCC", severity: .soft), evidence: "")))
        await orch.register(MockProbe(name: "ollama", scripted: ProbeOutcome(status: .degraded(reason: "missing model", severity: .loud), evidence: "")))
        await orch.register(MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "fine")))
        let snap = await orch.runAll()
        XCTAssertEqual(snap.overallHealth, .loud)
    }

    func testOverallHealthSoftWhenNoLoudOrCritical() async {
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "vision", scripted: ProbeOutcome(status: .unknown(reason: "TCC", severity: .soft), evidence: "")))
        await orch.register(MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "fine")))
        let snap = await orch.runAll()
        XCTAssertEqual(snap.overallHealth, .soft)
    }

    func testStatusSeverityAccessor() {
        XCTAssertNil(ProbeStatus.ok.severity)
        XCTAssertEqual(ProbeStatus.degraded(reason: "x", severity: .loud).severity, .loud)
        XCTAssertEqual(ProbeStatus.failed(reason: "x", severity: .critical).severity, .critical)
        XCTAssertEqual(ProbeStatus.unknown(reason: "x", severity: .soft).severity, .soft)
    }

    func testInjectedClockDrivesLastProbedAtAndLatency() async {
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "x")))

        // Inject a clock that returns a fixed offset on each call.
        // Call sequence per probe: start, end, then snapshot producedAt.
        // We want latency = 25ms reliably regardless of system clock.
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamps: [Date] = [
            baseDate,                                  // probe start
            baseDate.addingTimeInterval(0.025),        // probe end (25ms later)
            baseDate.addingTimeInterval(0.030)         // snapshot producedAt
        ]
        let counter = AtomicCounter()
        let snapshot = await orch.runAll(clock: {
            let idx = counter.next()
            return idx < timestamps.count ? timestamps[idx] : timestamps.last!
        })

        XCTAssertEqual(snapshot.subsystems[0].latencyMs, 25)
        XCTAssertEqual(snapshot.subsystems[0].lastProbedAt, baseDate.addingTimeInterval(0.025))
        XCTAssertEqual(snapshot.producedAt, baseDate.addingTimeInterval(0.030))
    }

    func testSnapshotRoundTripsThroughJSON() async throws {
        // Round 3 "Copy report" pastes the snapshot as JSON. Verify
        // every ProbeStatus variant survives encode → decode intact.
        let orch = BootHealthOrchestrator()
        await orch.register(MockProbe(name: "memory", scripted: ProbeOutcome(status: .ok, evidence: "fine")))
        await orch.register(MockProbe(name: "ollama", scripted: ProbeOutcome(status: .degraded(reason: "missing model", severity: .loud), evidence: "qwen ok, nomic missing")))
        await orch.register(MockProbe(name: "anthropic", scripted: ProbeOutcome(status: .failed(reason: "401", severity: .critical), evidence: "key invalid")))
        await orch.register(MockProbe(name: "voice", scripted: ProbeOutcome(status: .unknown(reason: "skipped", severity: .soft), evidence: "dormant")))

        let snapshot = await orch.runAll()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BootHealthSnapshot.self, from: data)

        XCTAssertEqual(decoded.subsystems.count, 4)
        XCTAssertEqual(decoded.subsystems[0].status, .ok)
        XCTAssertEqual(decoded.subsystems[1].status, .degraded(reason: "missing model", severity: .loud))
        XCTAssertEqual(decoded.subsystems[2].status, .failed(reason: "401", severity: .critical))
        XCTAssertEqual(decoded.subsystems[3].status, .unknown(reason: "skipped", severity: .soft))
    }
}

/// Lightweight atomic counter used by the deterministic-clock test.
private final class AtomicCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    func next() -> Int {
        state.withLock { value in
            let v = value
            value += 1
            return v
        }
    }
}
