import XCTest
@testable import Harness

final class MCPCrashRunnerTests: XCTestCase {

    // MARK: - D-19 decision logic

    func test_decideTarget_extendedAlwaysReturns500() {
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 50, extended: true, userTarget: 100),
            500)
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 5_000, extended: true, userTarget: 100),
            500)
    }

    func test_decideTarget_belowOrAt200msUses100AsFloor() {
        // ROADMAP literal — not less than 100 when fast.
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 50, extended: false, userTarget: 100),
            100)
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 200, extended: false, userTarget: 100),
            100)
        // user can demand more.
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 50, extended: false, userTarget: 250),
            250)
    }

    func test_decideTarget_above200msReducesTo50() {
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 201, extended: false, userTarget: 100),
            50)
        XCTAssertEqual(
            MCPCrashRunner.decideTarget(medianMs: 1_000, extended: false, userTarget: 1_000),
            50)
    }

    // MARK: - Whitelist semantics

    func test_steadyStateWhitelist_isNonEmpty() {
        // Whitelist must enumerate the production-expected steady-state
        // FDs (PIPE/FIFO/SQLite WAL/SHM). Empty would over-flag legitimate
        // production state.
        XCTAssertFalse(MCPCrashRunner.steadyStateWhitelist.isEmpty)
        XCTAssertTrue(MCPCrashRunner.steadyStateWhitelist.contains("type=PIPE"))
        XCTAssertTrue(MCPCrashRunner.steadyStateWhitelist.contains("-wal"))
    }

    // MARK: - Report shape

    func test_crashReport_passed_isTrueOnEmptyAddedSet() {
        let baseline = FDSnapshot(pid: 1, fds: ["fd=0", "fd=1"])
        let final = FDSnapshot(pid: 1, fds: ["fd=0", "fd=1"])
        let r = MCPCrashRunner.CrashReport(
            crashCount: 50,
            perCrashCycleTimeMs: [10, 20, 30],
            medianCycleTimeMs: 20,
            fdSnapshotBaseline: baseline,
            fdSnapshotFinal: final,
            fdAddedSinceBaseline: [],
            fdRemovedSinceBaseline: [],
            steadyStateWhitelistMatched: true
        )
        XCTAssertTrue(r.passed)
    }

    func test_crashReport_passed_isFalseOnUnwhitelistedAddedFD() {
        // A non-whitelisted leak (synthetic /home/leaky.dat REG file)
        // must fail the report.
        let baseline = FDSnapshot(pid: 1, fds: [])
        let final = FDSnapshot(pid: 1, fds: ["fd=42 type=REG path=/home/leaky.dat"])
        let r = MCPCrashRunner.CrashReport(
            crashCount: 50,
            perCrashCycleTimeMs: [10],
            medianCycleTimeMs: 10,
            fdSnapshotBaseline: baseline,
            fdSnapshotFinal: final,
            fdAddedSinceBaseline: ["fd=42 type=REG path=/home/leaky.dat"],
            fdRemovedSinceBaseline: [],
            steadyStateWhitelistMatched: false
        )
        XCTAssertFalse(r.passed)
    }

    func test_crashReport_passed_isTrueWhenAllAddedAreWhitelisted() {
        // PIPE + WAL FDs are expected steady-state churn.
        let baseline = FDSnapshot(pid: 1, fds: [])
        let added: Set<String> = [
            "fd=10 type=PIPE",
            "fd=11 type=REG path=/tmp/jarvis-replay-foo.sqlite-wal",
        ]
        let r = MCPCrashRunner.CrashReport(
            crashCount: 100,
            perCrashCycleTimeMs: [],
            medianCycleTimeMs: 0,
            fdSnapshotBaseline: baseline,
            fdSnapshotFinal: FDSnapshot(pid: 1, fds: added),
            fdAddedSinceBaseline: added,
            fdRemovedSinceBaseline: [],
            steadyStateWhitelistMatched: true
        )
        XCTAssertTrue(r.passed)
    }
}
