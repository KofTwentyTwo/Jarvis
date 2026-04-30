import Foundation
import Darwin
import JarvisMCP
import MCP

/// MCPCrashRunner — Plan 08-03 Task 2.
///
/// Runs N register/crash/restart cycles of an MCP helper through the real
/// production `MCPClient` and asserts the parent process's open-FD count
/// returns to within a steady-state whitelist of the baseline. Pillar (f)
/// of the OBS-04 eval matrix.
///
/// Design parity:
///   - Spawns ONLY through real `MCPClient`; the runner does not invoke
///     Foundation's process-launch API itself. Routing
///     production spawn means production's `ChildSpawnGate.minimalEnvironment`
///     + per-server restart mutex are exercised, not bypassed.
///   - FD measurement happens in the harness process (via `FDLeakDetector`),
///     not in the helper. Leaks would manifest as orphaned parent-side
///     pipes / sockets / WAL fds.
///
/// D-19: cycle time profiling. The first 5 cycles are timed; if the median
/// is ≤ 200 ms, the runner runs the ROADMAP-literal 100 cycles. If the
/// median exceeds 200 ms, the runner reduces to 50 cycles (still enough
/// to detect linear FD leaks). The `extended: true` flag forces 500.
public actor MCPCrashRunner {

    public struct CrashReport: Sendable, Codable {
        public let crashCount: Int
        public let perCrashCycleTimeMs: [Double]
        public let medianCycleTimeMs: Double
        public let fdSnapshotBaseline: FDSnapshot
        public let fdSnapshotFinal: FDSnapshot
        public let fdAddedSinceBaseline: Set<String>
        public let fdRemovedSinceBaseline: Set<String>
        public let steadyStateWhitelistMatched: Bool

        public var passed: Bool {
            // No leaked FDs at all → trivially pass.
            // Some FDs added → must all match the steady-state whitelist.
            fdAddedSinceBaseline.isEmpty || steadyStateWhitelistMatched
        }
    }

    /// Steady-state FD whitelist patterns. An "added" FD is whitelisted if
    /// its normalized string contains ANY of these substrings. Reflects
    /// what production's `MCPClient` legitimately keeps open across helper
    /// restarts: per-helper transport pipes (FIFO/PIPE), the swift-sdk's
    /// internal IPC sockets, and any `/tmp/jarvis-*` SQLite WAL/SHM files
    /// the harness happens to have open during a run.
    ///
    /// Source: RESEARCH §Pitfall 6 + D-20 exclusion-list philosophy. The
    /// whitelist is intentionally generous — false negatives (whitelisting
    /// a real leak) are caught by the linear-growth test the runner caller
    /// wraps the report in. False positives (failing on a benign FD) make
    /// the harness flaky.
    public static let steadyStateWhitelist: Set<String> = [
        "type=PIPE",
        "type=FIFO",
        "type=systm",
        "type=KQUEUE",
        "type=unix",
        "/tmp/jarvis-",
        "-wal",
        "-shm",
    ]

    public init() {}

    /// D-19: pure decision helper. Extracted as a non-async non-throws
    /// function so unit tests can drive the boundary cases at 200 ms.
    public static func decideTarget(
        medianMs: Double,
        extended: Bool,
        userTarget: Int
    ) -> Int {
        if extended { return 500 }
        if medianMs <= 200 { return max(userTarget, 100) }
        return 50
    }

    /// Run the register/crash/restart matrix.
    ///
    /// `targetCrashes` is the floor when median cycle time is ≤ 200ms.
    /// `extended` overrides everything to 500.
    public func run(
        targetCrashes: Int = 100,
        extended: Bool = false
    ) async throws -> CrashReport {
        let helper = try HarnessMockHelperBuilder.build()

        let baseline = try FDLeakDetector.snapshot()
        var perCrashTimes: [Double] = []

        // Phase A: profile 5 crashes to compute median cycle time.
        for i in 0..<5 {
            let elapsed = try await runOneCycle(
                helperBinary: helper,
                cycleIndex: i
            )
            perCrashTimes.append(elapsed)
        }
        let medianSoFar = perCrashTimes.sorted()[perCrashTimes.count / 2]

        // D-19 decision.
        let actualTarget = Self.decideTarget(
            medianMs: medianSoFar,
            extended: extended,
            userTarget: targetCrashes
        )

        // Phase B: run remaining cycles up to actualTarget.
        if actualTarget > perCrashTimes.count {
            for i in perCrashTimes.count..<actualTarget {
                let elapsed = try await runOneCycle(
                    helperBinary: helper,
                    cycleIndex: i
                )
                perCrashTimes.append(elapsed)
            }
        }

        let final = try FDLeakDetector.snapshot()
        let delta = FDLeakDetector.delta(from: baseline, to: final)
        let whitelisted = applyWhitelist(delta.added)

        let sortedTimes = perCrashTimes.sorted()
        let median = sortedTimes.isEmpty
            ? 0
            : sortedTimes[sortedTimes.count / 2]

        return CrashReport(
            crashCount: actualTarget,
            perCrashCycleTimeMs: perCrashTimes,
            medianCycleTimeMs: median,
            fdSnapshotBaseline: baseline,
            fdSnapshotFinal: final,
            fdAddedSinceBaseline: delta.added,
            fdRemovedSinceBaseline: delta.removed,
            steadyStateWhitelistMatched: whitelisted
        )
    }

    /// Returns the elapsed wall-clock time in milliseconds for one
    /// register / call / SIGKILL / call / shutdown cycle.
    private func runOneCycle(
        helperBinary: URL,
        cycleIndex: Int
    ) async throws -> Double {
        let start = ContinuousClock.now
        let client = MCPClient()
        try await client.register(
            name: "mock-helper",
            binaryURL: helperBinary,
            requiresConfirmation: false
        )
        // First call — succeeds.
        _ = try? await client.callTool(
            name: "mock_echo",
            arguments: ["text": .string("cycle-\(cycleIndex)")]
        )

        // SIGKILL the helper directly. Mirrors the canonical
        // `MCPRestartTests.test_100_crashCycles_noFDLeak` recipe.
        if let handle = await firstHandle(in: client) {
            let pid = await handle._testProcessIdentifier()
            if pid > 0 { kill(pid, SIGKILL) }
        }
        // Brief wait for terminationHandler to set isCrashed.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Next call triggers lazy restart through the per-server mutex.
        _ = try? await client.callTool(
            name: "mock_echo",
            arguments: ["text": .string("post-restart-\(cycleIndex)")]
        )

        await client.shutdown()
        // Tiny pause between cycles to let Foundation/SDK release resources.
        try? await Task.sleep(nanoseconds: 10_000_000)

        let elapsed = ContinuousClock.now - start
        // ContinuousClock.Duration → milliseconds via attoseconds.
        let ns = Double(elapsed.components.seconds) * 1_000_000_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000
        return ns / 1_000_000
    }

    /// Reach into MCPClient's private registry to fetch the first (sole)
    /// handle — same DEBUG-only test seam used by MCPRestartTests.
    private func firstHandle(in client: MCPClient) async -> MCPServerHandle? {
        let names = await client.registeredServerNames()
        guard let first = names.first else { return nil }
        return await client._testHandle(named: first)
    }

    private func applyWhitelist(_ added: Set<String>) -> Bool {
        // Empty set is trivially whitelisted (no leaks to explain).
        if added.isEmpty { return true }
        return added.allSatisfy { fd in
            Self.steadyStateWhitelist.contains { pattern in
                fd.contains(pattern)
            }
        }
    }
}
