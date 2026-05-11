import Foundation

// MARK: - FailureSeverity

/// Round 4 — how loudly a non-ok subsystem must announce itself.
///
/// The Toby-the-dog incident (Jarvis said "Got it" while the embedder
/// model was missing and the fact never persisted) motivated this: probes
/// were already reporting `.degraded` correctly, but the banner was
/// dismissible and the agent's system prompt didn't know, so the model
/// confidently lied about remembering. Severity drives:
///   * banner non-dismissibility (critical)
///   * menu-bar icon tint (loud + critical)
///   * the agent's system-prompt "DO NOT promise" preamble (loud + critical)
///
/// Soft is the default for "can't probe yet" states — not red, just a row
/// in the Status panel.
public enum FailureSeverity: Sendable, Equatable, Codable {
    /// Subsystem failure prevents core agent function (e.g., memory off,
    /// no API key, no MCP tools, webview never armed). Non-dismissible
    /// banner; red menu-bar icon; agent system prompt warns the model.
    case critical
    /// Subsystem partially functional — main function works, but at least
    /// one capability is broken (e.g., Ollama reachable but embedder
    /// missing → chat works, fact extraction doesn't). Dismissible red
    /// banner; red menu-bar icon; agent preamble lists the gap.
    case loud
    /// Subsystem can't be probed right now (TCC not yet requested, dormant
    /// install path). Status panel shows it as `?`; no banner.
    case soft
}

// MARK: - ProbeStatus

/// Live state of a single subsystem.
///
/// The "NOT FAKED" mandate is a type-level constraint: every non-`.ok` case
/// carries a reason string so a snapshot can never report `state=unknown`
/// without explaining why. A probe that can't execute *must* return
/// `.unknown(reason:)`, never `.ok`.
///
/// Round 4 — every non-ok case also carries a `FailureSeverity` so the App
/// layer can route the failure correctly (non-dismissible banner vs. quiet
/// Status-panel row).
public enum ProbeStatus: Sendable, Equatable, Codable {
    /// Subsystem is healthy. Evidence on `SubsystemHealth.evidence` describes
    /// what was verified (e.g., "vec_version=v0.1.6, sqlite=3.51.0").
    case ok

    /// Subsystem is partially functional. Used when one capability of a
    /// multi-capability subsystem is broken but the rest work — e.g.,
    /// Ollama reachable but a required model is missing.
    case degraded(reason: String, severity: FailureSeverity)

    /// Subsystem is non-functional and a critical dependency failed.
    /// Triggers banner enqueue in the App layer.
    case failed(reason: String, severity: FailureSeverity)

    /// Probe could not execute. NOT a fallback for "looks okay" — only
    /// for cases like "API key not configured, so we can't probe Anthropic"
    /// or "voice never installed because dormantVoiceContinuation was nil."
    /// Default severity is `.soft` — a probe that can't run yet doesn't
    /// usually warrant red.
    case unknown(reason: String, severity: FailureSeverity)

    /// Round 4 — severity of this status. `.ok` reports `nil`; every other
    /// case returns its carried severity.
    public var severity: FailureSeverity? {
        switch self {
        case .ok: return nil
        case .degraded(_, let s), .failed(_, let s), .unknown(_, let s):
            return s
        }
    }
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

    /// Round 4 — worst severity present in the snapshot. `.ok` only if
    /// every subsystem reported `.ok`; otherwise the worst severity wins
    /// (`.critical` > `.loud` > `.soft`). Drives menu-bar icon tint and
    /// agent preamble injection.
    public var overallHealth: OverallHealth {
        var worst: OverallHealth = .ok
        for health in subsystems {
            switch health.status.severity {
            case .none:
                continue
            case .some(.soft):
                if worst == .ok { worst = .soft }
            case .some(.loud):
                if worst == .ok || worst == .soft { worst = .loud }
            case .some(.critical):
                worst = .critical
                return worst
            }
        }
        return worst
    }
}

// MARK: - OverallHealth

/// Round 4 — rollup of the worst severity in a snapshot. `.ok` means every
/// subsystem reported `.ok`; otherwise the worst non-ok severity wins.
public enum OverallHealth: Sendable, Equatable, Codable {
    case ok
    case soft
    case loud
    case critical
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
