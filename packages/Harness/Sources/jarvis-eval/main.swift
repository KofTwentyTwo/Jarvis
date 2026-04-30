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
            AudioRebuild.self,
            CapRecovery.self,
            CorpusNDJSONLive.self,
            CorpusInjection.self,
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

/// `jarvis-eval audio-rebuild` — pillar (g). Four canonical triggers ×
/// six-step teardown matrix. Per D-14, the deviceChange trigger may
/// gracefully degrade to MANUAL if synthetic injection is unavailable;
/// the AVAudioEngine probe in 08-LAUNCH-FRAGILITY-NOTES.md confirmed
/// it IS available, so all four triggers run automated.
struct AudioRebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio-rebuild",
        abstract: "4 canonical triggers x 6-step teardown matrix (D-14 graceful degradation)."
    )

    func run() async throws {
        let runner = AudioGraphRebuildRunner()
        let reports = try await runner.run()
        var sawAutomatedFail = false
        for r in reports {
            if r.degradedToManual {
                print("MANUAL: \(r.trigger.rawValue) — \(r.manualOperatorInstructions ?? "")")
            } else if r.passed {
                print("\(r.trigger.rawValue): PASS")
            } else {
                sawAutomatedFail = true
                print("\(r.trigger.rawValue): FAIL")
                print("  expected: \(r.teardownStepsExpected)")
                print("  observed: \(r.teardownStepsObserved)")
            }
        }
        if sawAutomatedFail { throw ExitCode.failure }
    }
}

/// `jarvis-eval cap-recovery` — D-21 dual assertion (pillar (d)).
struct CapRecovery: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cap-recovery",
        abstract: "R4-L1 regression: tool-cap recovery (D-21 dual assertion)."
    )

    @Option(help: "Provider: anthropic | ollama")
    var provider: String = "anthropic"

    func run() async throws {
        let p: ToolCapRecoveryRunner.Provider =
            (provider == "ollama") ? .ollama : .anthropic
        let report = try await ToolCapRecoveryRunner().run(provider: p)
        print("Provider: \(report.provider.rawValue)")
        print("Tool-use events on recovery: \(report.toolUseEventCount) (must be 0)")
        print("tool_choice serialized as none: \(report.toolChoiceSerializedAsNone)")
        print("tools array present on recovery: \(report.toolsArrayPresent)")
        if !report.passed { throw ExitCode.failure }
    }
}

/// `jarvis-eval corpus-ndjson-live` — pillar (c-live). D-04 dual-gated;
/// D-06 preflight; never auto-pulls. Plan 08-02 owns the offline
/// `corpus-ndjson` subcommand; this command is the live extension.
struct CorpusNDJSONLive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus-ndjson-live",
        abstract: "Live Ollama corpus run (qwen2.5-coder:32b) — D-04 dual-gated, D-06 preflight."
    )

    @Flag(help: "Required: --live AND env JARVIS_LIVE_EVAL=1 to run.")
    var live: Bool = false

    @Option(help: "Comma-separated scenario IDs from the live corpus (default: all).")
    var scenarios: String?

    func run() async throws {
        guard live else {
            print("live-ollama skipped — run with --live JARVIS_LIVE_EVAL=1 to include")
            return
        }
        let runner = LiveOllamaRunner()
        let scenarioList = (scenarios?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) })
            ?? []
        do {
            let report = try await runner.run(scenarios: scenarioList)
            print("Live Ollama: model=\(report.modelId) scenarios=\(report.scenarioCount) passed=\(report.passedCount)")
            if !report.passed { throw ExitCode.failure }
        } catch let error as LiveOllamaRunner.LiveError {
            switch error {
            case .liveGateNotEnabled:
                print("live-ollama skipped — env JARVIS_LIVE_EVAL=1 not set")
                return
            case .daemonUnreachable(let advice):
                print("live-ollama FAIL: \(advice)")
                throw ExitCode.failure
            case .modelMissing(let id, let advice):
                print("live-ollama FAIL: model \(id) missing — \(advice)")
                throw ExitCode.failure
            }
        }
    }
}
// MARK: - corpus-injection (Plan 08-02 Task 1)

struct CorpusInjection: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus-injection",
        abstract: "Run the 20+-item injection corpus through the real sanitize + nonce-wrap pipeline."
    )

    @Flag(help: "Print per-item observed/expected outcomes.")
    var verbose: Bool = false

    func run() async throws {
        let corpus = try InjectionCorpus.loadFromBundle()
        let runner = InjectionCorpusRunner()
        let report = try await runner.run(corpus: corpus)

        print("INJECTION CORPUS: \(report.totalAttempts) attempts, \(report.blockedCount) blocked.")
        if verbose {
            for attempt in corpus {
                if let actual = report.byAttemptId[attempt.id] {
                    let mark = actual.matches(expected: attempt.expectedOutcome) ? "OK" : "MISMATCH"
                    print("  [\(mark)] \(attempt.id): expected=\(attempt.expectedOutcome) observed=\(actual.observedOutcome)")
                }
            }
        }
        if !report.passed {
            print("FAIL: \(report.mismatches.count) mismatch(es): \(report.mismatches.joined(separator: ", "))")
            throw ExitCode.failure
        }
        print("PASS")
    }
}

// CorpusSSE / CorpusNDJSON / WakeCorpus subcommands land in Plan 08-02
// Tasks 2-3 (next commits in this worktree).
