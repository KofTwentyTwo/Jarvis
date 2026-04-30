import ArgumentParser
import Foundation
import Harness

/// `jarvis-eval` CLI entry — Phase 8 evaluation harness.
///
/// Plan 08-01 ships the `replay` subcommand. Remaining subcommands
/// (corpus-injection / corpus-sse / corpus-ndjson / cap-recovery /
/// wake-corpus / mcp-crash / audio-rebuild / checklist / all) land in plans
/// 08-02 / 08-03 / 08-04.
@main
struct JarvisEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jarvis-eval",
        abstract: "Phase 8 evaluation harness",
        subcommands: [Replay.self]
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
