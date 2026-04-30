import ArgumentParser
import Foundation
import Harness

/// `jarvis-eval` CLI entry — Phase 8 evaluation harness.
///
/// Plan 08-01 shipped `replay`; plan 08-03 adds `mcp-crash`,
/// `audio-rebuild`, `cap-recovery`, and `corpus-ndjson-live`. Plan 08-02
/// adds the offline corpus runners; plan 08-04 adds `checklist` and `all`.
@main
struct JarvisEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jarvis-eval",
        abstract: "Phase 8 evaluation harness",
        subcommands: [
            Replay.self,
            McpCrash.self,
        ]
    )
}

struct Replay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Re-run a recorded session through the real pipeline; flag drift."
    )

    @Argument(help: "Path to recorded session SQLite file.")
    var sessionDB: String

    @Option(help: "Path to ExclusionList JSON; defaults to OBS-02 default.")
    var exclusions: String?

    @Flag(help: "Verbose drift output (print recorded/actual paths).")
    var verbose: Bool = false

    func run() async throws {
        let recordedURL = URL(fileURLWithPath: sessionDB)
        let exclusionsURL = exclusions.map { URL(fileURLWithPath: $0) }
        let runner = ReplayRunner()
        let result = try await runner.run(
            recordedSessionURL: recordedURL,
            exclusionsURL: exclusionsURL
        )

        if result.report.passed {
            print("REPLAY PASS: \(result.report.expected.count) expected drifts (ID/timestamp/sampling).")
        } else {
            print("REPLAY FAIL:")
            for item in result.report.unexpected {
                print("  [row \(item.rowOrdinal)] [\(item.category.rawValue)] \(item.field): \(item.recorded) -> \(item.actual)")
            }
            throw ExitCode.failure
        }
        if verbose {
            print("Recorded: \(result.recordedURL.path)")
            print("Actual:   \(result.actualURL.path)")
        }
    }
}

// MARK: - Plan 08-03 subcommands

/// `jarvis-eval mcp-crash` — pillar (f). 50–100 helper crash cycles
/// against the production `MCPClient`; assert no FD leaks.
struct McpCrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-crash",
        abstract: "Inject N MCP helper crashes; assert no FD leaks (D-19)."
    )

    @Option(help: "Target crash count. D-19: 100 if median cycle <= 200ms, else 50.")
    var crashes: Int = 100

    @Flag(help: "Extended 500-crash mode (operator-driven longevity test).")
    var extended: Bool = false

    func run() async throws {
        let runner = MCPCrashRunner()
        let report = try await runner.run(
            targetCrashes: crashes,
            extended: extended
        )
        print("Crashes: \(report.crashCount), median cycle: \(String(format: "%.2f", report.medianCycleTimeMs)) ms")
        print("FD delta: added=\(report.fdAddedSinceBaseline.count) removed=\(report.fdRemovedSinceBaseline.count)")
        print("Steady-state whitelist match: \(report.steadyStateWhitelistMatched)")
        if !report.passed {
            print("FAIL: unexpected FDs:")
            for fd in report.fdAddedSinceBaseline { print("  \(fd)") }
            throw ExitCode.failure
        }
    }
}

// Plan 08-03 Task 3 will append: AudioRebuild, CapRecovery, CorpusNDJSONLive.
