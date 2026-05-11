import Foundation

// MARK: - ProbeStatus

/// Live state of a single subsystem.
///
/// The "NOT FAKED" mandate is a type-level constraint: every non-`.ok` case
/// carries a reason string so a snapshot can never report `state=unknown`
/// without explaining why. A probe that can't execute *must* return
/// `.unknown(reason:)`, never `.ok`.
public enum ProbeStatus: Sendable, Equatable, Codable {
    /// Subsystem is healthy. Evidence on `SubsystemHealth.evidence` describes
    /// what was verified (e.g., "vec_version=v0.1.6, sqlite=3.51.0").
    case ok

    /// Subsystem is partially functional. Used when one capability of a
    /// multi-capability subsystem is broken but the rest work — e.g.,
    /// Ollama reachable but a required model is missing.
    case degraded(reason: String)

    /// Subsystem is non-functional and a critical dependency failed.
    /// Triggers banner enqueue in the App layer.
    case failed(reason: String)

    /// Probe could not execute. NOT a fallback for "looks okay" — only
    /// for cases like "API key not configured, so we can't probe Anthropic"
    /// or "voice never installed because dormantVoiceContinuation was nil."
    case unknown(reason: String)
}

// MARK: - ProbeOutcome

/// What a probe returns. The orchestrator wraps this with timing metadata
/// to produce `SubsystemHealth`. Keeping the probe-facing type lean means
/// probe authors can't forget to instrument latency.
public struct ProbeOutcome: Sendable, Equatable {
    public let status: ProbeStatus
    /// One-line, human-readable concrete evidence. Examples:
    /// `"6 turns, 0 facts, vec_version=v0.1.6"` (memory),
    /// `"qwen3.6:latest, qwen2.5-coder:32b-instruct-q8_0"` (ollama).
    /// MUST be concrete — never `"ok"` or `"reachable"`.
    public let evidence: String

    public init(status: ProbeStatus, evidence: String) {
        self.status = status
        self.evidence = evidence
    }
}

// MARK: - BootHealthProbe

/// Each subsystem registers one of these. The probe is responsible for
/// performing a real live round-trip against its target (DB query, network
/// reachability, TCC status read) — never reading a cached install flag.
public protocol BootHealthProbe: Sendable {
    /// Stable identifier used as the dictionary key, log field, and Status
    /// menu row label. Lowercase, no spaces: `"memory"`, `"anthropic"`,
    /// `"ollama"`, `"voice"`, `"vision"`, `"mcp"`, `"replay"`, `"webview"`.
    var name: String { get }

    /// Run a live probe. MUST NOT return `.ok` unless the probe actually
    /// proved the subsystem works end-to-end. MUST NOT throw — translate
    /// failures into `.failed(reason:)` or `.unknown(reason:)`.
    func probe() async -> ProbeOutcome
}

// MARK: - SubsystemHealth

/// One row of the boot-health snapshot. Codable so the Round 3 "Copy report"
/// button can dump the snapshot as JSON to NSPasteboard.
public struct SubsystemHealth: Sendable, Equatable, Codable {
    public let name: String
    public let status: ProbeStatus
    public let evidence: String
    public let lastProbedAt: Date
    public let latencyMs: Int

    public init(
        name: String,
        status: ProbeStatus,
        evidence: String,
        lastProbedAt: Date,
        latencyMs: Int
    ) {
        self.name = name
        self.status = status
        self.evidence = evidence
        self.lastProbedAt = lastProbedAt
        self.latencyMs = latencyMs
    }
}

// MARK: - BootHealthSnapshot

/// Output of `BootHealthOrchestrator.runAll()`. Subsystem order matches
/// the order in which probes were `register`ed — deterministic for the
/// Status panel rendering and the system log lines.
public struct BootHealthSnapshot: Sendable, Equatable, Codable {
    public let producedAt: Date
    public let subsystems: [SubsystemHealth]

    public init(producedAt: Date, subsystems: [SubsystemHealth]) {
        self.producedAt = producedAt
        self.subsystems = subsystems
    }

    /// Subsystems whose `status` is `.failed`. The App layer enqueues a
    /// banner for each.
    public var failed: [SubsystemHealth] {
        subsystems.filter { health in
            if case .failed = health.status { return true }
            return false
        }
    }
}

// MARK: - BootHealthOrchestrator

/// Owns registered probes and a snapshot. Runs probes in parallel via a
/// `TaskGroup` so total wall time approaches `max(probe latency)` rather
/// than the sum. Re-probes on demand from the Round 3 Status panel.
///
/// **Thread safety:** actor isolation. `runAll` snapshots the probe array
/// before releasing isolation for the parallel run, so a concurrent
/// `register` call can't tear the iteration.
public actor BootHealthOrchestrator {
    private var probes: [BootHealthProbe] = []
    private var lastSnapshotValue: BootHealthSnapshot?

    public init() {}

    /// Register a probe. Order matters — the snapshot preserves it for
    /// the Status panel rendering. Call `register` for all probes before
    /// the first `runAll`.
    public func register(_ probe: BootHealthProbe) {
        probes.append(probe)
    }

    /// Snapshot of the currently registered probes (for tests + debugging).
    public func registeredNames() -> [String] {
        probes.map(\.name)
    }

    /// Most recent snapshot, or `nil` if `runAll` hasn't completed yet.
    public func lastSnapshot() -> BootHealthSnapshot? {
        lastSnapshotValue
    }

    /// Run every registered probe in parallel. The returned snapshot's
    /// subsystem order matches the registration order regardless of which
    /// probe completed first.
    ///
    /// - Parameter clock: Time source. Tests inject a deterministic clock
    ///   so `lastProbedAt` and `latencyMs` are reproducible. Production
    ///   passes `{ Date() }` (the default).
    @discardableResult
    public func runAll(clock: @escaping @Sendable () -> Date = { Date() }) async -> BootHealthSnapshot {
        let pinned = probes
        let results: [SubsystemHealth] = await withTaskGroup(
            of: (Int, SubsystemHealth).self
        ) { group in
            for (idx, probe) in pinned.enumerated() {
                group.addTask {
                    let start = clock()
                    let outcome = await probe.probe()
                    let end = clock()
                    let latency = Int((end.timeIntervalSince(start) * 1000.0).rounded())
                    let health = SubsystemHealth(
                        name: probe.name,
                        status: outcome.status,
                        evidence: outcome.evidence,
                        lastProbedAt: end,
                        latencyMs: max(0, latency)
                    )
                    return (idx, health)
                }
            }
            var buf: [(Int, SubsystemHealth)] = []
            for await pair in group { buf.append(pair) }
            return buf.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
        let snapshot = BootHealthSnapshot(producedAt: clock(), subsystems: results)
        self.lastSnapshotValue = snapshot
        return snapshot
    }
}
