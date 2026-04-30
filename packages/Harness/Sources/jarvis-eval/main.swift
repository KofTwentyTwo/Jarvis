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
            CorpusSSE.self,
            CorpusNDJSON.self,
            WakeCorpus.self,
            Checklist.self,
            All.self,
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

// MARK: - corpus-sse / corpus-ndjson (Plan 08-02 Task 2)

/// `jarvis-eval corpus-sse` — pillar (b). Replay every Anthropic SSE
/// fixture through the production `AnthropicProvider` SSE state machine
/// (via `MockLLMProvider` URL-protocol stub). Fixture-only; no network.
struct CorpusSSE: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus-sse",
        abstract: "Replay Anthropic SSE fixture corpus through the real SSEDecoder."
    )

    @Flag(help: "Print per-fixture tag sequences on mismatch.")
    var verbose: Bool = false

    func run() async throws {
        let corpus = try SSEFixtureCorpus.loadManifest()
        let runner = SSEFixtureRunner()
        let report = try await runner.run(corpus: corpus)

        let passed = report.results.filter { $0.passed }.count
        print("SSE CORPUS: \(passed)/\(report.results.count) fixtures passed.")
        for result in report.results {
            if result.passed {
                if verbose {
                    print("  [OK]       \(result.fixtureId) (\(result.actualEventCount) events)")
                }
            } else {
                print("  [MISMATCH] \(result.fixtureId)")
                print("    expected (\(result.expectedEventCount)): \(result.expectedEventTags)")
                print("    actual   (\(result.actualEventCount)): \(result.actualEventTags)")
                if let i = result.firstMismatchIndex {
                    print("    firstMismatchIndex: \(i)")
                }
            }
        }
        if !report.passed { throw ExitCode.failure }
    }
}

/// `jarvis-eval corpus-ndjson` — pillar (c-fixture). Replay every Ollama
/// NDJSON / OpenAI-compat fixture through the production `OllamaProvider`
/// decoders. Fixture-only; the live counterpart lives in 08-03's
/// `corpus-ndjson-live`.
struct CorpusNDJSON: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus-ndjson",
        abstract: "Replay Ollama NDJSON + OpenAI-compat fixture corpus through real decoders."
    )

    @Flag(help: "Print per-fixture tag sequences on mismatch.")
    var verbose: Bool = false

    func run() async throws {
        let corpus = try NDJSONFixtureCorpus.loadManifest()
        let runner = NDJSONFixtureRunner()
        let report = try await runner.run(corpus: corpus)

        let passed = report.results.filter { $0.passed }.count
        print("NDJSON CORPUS: \(passed)/\(report.results.count) fixtures passed.")
        for result in report.results {
            if result.passed {
                if verbose {
                    print("  [OK]       \(result.fixtureId) (\(result.actualEventCount) events)")
                }
            } else {
                print("  [MISMATCH] \(result.fixtureId)")
                print("    expected (\(result.expectedEventCount)): \(result.expectedEventTags)")
                print("    actual   (\(result.actualEventCount)): \(result.actualEventTags)")
                if let i = result.firstMismatchIndex {
                    print("    firstMismatchIndex: \(i)")
                }
            }
        }
        if !report.passed { throw ExitCode.failure }
    }
}

// MARK: - wake-corpus (Plan 08-02 Task 3)

/// `jarvis-eval wake-corpus` — pillar (e). Compute wake-word FAR/FRR over
/// the per-host labeled WAV corpus against the production
/// `OpenWakeWordSession` (real ONNX). D-18 thresholds enforced.
struct WakeCorpus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wake-corpus",
        abstract: "Wake-word FAR/FRR over labeled WAV corpus (D-18 thresholds)."
    )

    func run() async throws {
        let corpus = try WakeHysteresisCorpus.loadFromBundle()
        let runner = WakeHysteresisRunner()
        let report = try await runner.run(corpus: corpus)

        print("WAKE CORPUS:")
        print("  clips: \(report.totalClips)  duration: \(String(format: "%.1f", report.totalDurationSeconds))s")
        print("  TP=\(report.truePositives) FN=\(report.falseNegatives) FP=\(report.falsePositives) TN=\(report.trueNegatives)")
        print("  FAR: \(String(format: "%.3f", report.farPerHour))/hr  FRR: \(String(format: "%.2f", report.frrPercent))%")
        print("  D-18: passed=\(report.passed)  warned=\(report.warned)")
        if let diagnostic = report.diagnostic {
            print("  diagnostic: \(diagnostic)")
        }
        if report.warned && report.passed {
            print("  WARNING: D-18 warn thresholds tripped (FAR > 0.5/hr or FRR > 5.0%) — does not block ship.")
        }
        if !report.passed { throw ExitCode.failure }
    }
}

// MARK: - checklist (Plan 08-04 Task 1) — pillar (h)

/// `jarvis-eval checklist` — load every `.planning/phases/<NN>-*/checklist.yaml`
/// (or a single phase via `--phase`), dispatch each item to its mechanization,
/// print a per-phase results block, and exit non-zero if any non-MANUAL item
/// fails. MANUAL items always print as warning rows (D-16) but never block.
struct Checklist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checklist",
        abstract: "Run per-phase checklist.yaml manifests (D-16 / D-17)."
    )

    @Option(help: "Phase slug to run; default = all phases under .planning/phases/.")
    var phase: String?

    @Flag(help: "Print every result row, not just failures and MANUAL.")
    var verbose: Bool = false

    func run() async throws {
        let runner = ChecklistRunner()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repoRoot = Self.resolveRepoRoot(from: cwd)
        let phasesDir = repoRoot.appendingPathComponent(".planning/phases")
        guard FileManager.default.fileExists(atPath: phasesDir.path) else {
            print("checklist: .planning/phases/ not found at \(phasesDir.path); skipping.")
            return
        }
        let phaseDirs = try FileManager.default.contentsOfDirectory(
            at: phasesDir, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let manifests: [URL] = phaseDirs
            .compactMap { dir in
                let yaml = dir.appendingPathComponent("checklist.yaml")
                guard FileManager.default.fileExists(atPath: yaml.path) else { return nil }
                if let phase, !dir.lastPathComponent.contains(phase) { return nil }
                return yaml
            }
        if manifests.isEmpty {
            print("checklist: no manifests matched (phase=\(phase ?? "all"))")
            return
        }
        var anyFailed = false
        for manifest in manifests {
            do {
                let result = try await runner.runManifest(at: manifest, repoRoot: repoRoot)
                Self.printResult(result, verbose: verbose)
                if !result.passed { anyFailed = true }
            } catch {
                print("checklist DECODE FAIL [\(manifest.path)]: \(error)")
                anyFailed = true
            }
        }
        if anyFailed { throw ExitCode.failure }
    }

    private static func printResult(_ r: ChecklistRunner.ChecklistResult, verbose: Bool) {
        print(">>> \(r.phase): passed=\(r.passedCount) failed=\(r.failedCount) manual=\(r.manualCount)")
        for item in r.results {
            if item.warnedAsManual {
                print("    [MANUAL] \(item.itemId): \(item.detail)")
            } else if !item.passed {
                print("    [FAIL]   \(item.itemId): \(item.detail)")
            } else if verbose {
                print("    [OK]     \(item.itemId): \(item.detail)")
            }
        }
    }

    /// Walk up from the executable's CWD to find a directory that contains
    /// `.planning/`. Falls back to the CWD itself.
    private static func resolveRepoRoot(from cwd: URL) -> URL {
        var dir = cwd
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".planning").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return cwd
    }
}

// MARK: - all (Plan 08-04 Task 1) — aggregate gate

/// `jarvis-eval all` — runs every fixture-only pillar plus the checklist.
/// Default skips live pillars; `--live` requires `JARVIS_LIVE_EVAL=1` per
/// D-04 dual-gate.
struct All: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "Run every pillar + checklist (fixture-only by default; D-04)."
    )

    @Flag(help: "Include live-mode pillars; requires JARVIS_LIVE_EVAL=1 in environment.")
    var live: Bool = false

    @Flag(help: "Print per-pillar verbose output.")
    var verbose: Bool = false

    func run() async throws {
        if live {
            guard ProcessInfo.processInfo.environment["JARVIS_LIVE_EVAL"] == "1" else {
                throw ValidationError("--live requires JARVIS_LIVE_EVAL=1 in environment (D-04 dual-gate; defends vs accidental Anthropic burn).")
            }
        }
        let pillars: [(name: String, run: () async throws -> Void)] = [
            ("checklist", { try await runChecklistPillar(verbose: self.verbose) }),
            ("corpus-injection", { try await runCorpusInjectionPillar(verbose: self.verbose) }),
            ("corpus-sse", { try await runCorpusSSEPillar(verbose: self.verbose) }),
            ("corpus-ndjson", { try await runCorpusNDJSONPillar(verbose: self.verbose) }),
            ("cap-recovery", { try await runCapRecoveryPillar() }),
            ("wake-corpus", { try await runWakeCorpusPillar() }),
            ("mcp-crash", { try await runMcpCrashPillar() }),
            ("audio-rebuild", { try await runAudioRebuildPillar() }),
        ]
        var failed: [String] = []
        for pillar in pillars {
            print("=== \(pillar.name) ===")
            do {
                try await pillar.run()
                print("\(pillar.name): PASS")
            } catch {
                print("\(pillar.name): FAIL — \(error)")
                failed.append(pillar.name)
            }
        }
        if live {
            print("=== corpus-ndjson-live ===")
            do {
                try await runCorpusNDJSONLivePillar()
                print("corpus-ndjson-live: PASS")
            } catch {
                print("corpus-ndjson-live: FAIL — \(error)")
                failed.append("corpus-ndjson-live")
            }
        } else {
            print("corpus-ndjson-live: SKIPPED — run with --live + JARVIS_LIVE_EVAL=1 to include")
        }
        print("=== summary ===")
        if failed.isEmpty {
            print("ALL PILLARS PASSED")
        } else {
            print("FAILED: \(failed.joined(separator: ", "))")
            throw ExitCode.failure
        }
    }
}

// MARK: - per-pillar dispatch helpers
//
// Each helper invokes the same subcommand via `parseAsRoot([])` so that
// swift-argument-parser populates every @Flag/@Option/@Argument property's
// backing storage with the declared defaults. Direct `.init()` + property
// assignment doesn't traverse the property-wrapper init path and trips the
// "Can't read a value from a parsable argument definition" guard.

private func runChecklistPillar(verbose: Bool) async throws {
    let argv: [String] = verbose ? ["--verbose"] : []
    let cmd = try Checklist.parse(argv)
    try await cmd.run()
}

private func runCorpusInjectionPillar(verbose: Bool) async throws {
    let argv: [String] = verbose ? ["--verbose"] : []
    let cmd = try CorpusInjection.parse(argv)
    try await cmd.run()
}

private func runCorpusSSEPillar(verbose: Bool) async throws {
    let argv: [String] = verbose ? ["--verbose"] : []
    let cmd = try CorpusSSE.parse(argv)
    try await cmd.run()
}

private func runCorpusNDJSONPillar(verbose: Bool) async throws {
    let argv: [String] = verbose ? ["--verbose"] : []
    let cmd = try CorpusNDJSON.parse(argv)
    try await cmd.run()
}

private func runCapRecoveryPillar() async throws {
    let cmd = try CapRecovery.parse([])
    try await cmd.run()
}

private func runWakeCorpusPillar() async throws {
    let cmd = try WakeCorpus.parse([])
    try await cmd.run()
}

private func runMcpCrashPillar() async throws {
    // 50 crashes per D-19 (cycle-time threshold default).
    let cmd = try McpCrash.parse(["--crashes", "50"])
    try await cmd.run()
}

private func runAudioRebuildPillar() async throws {
    let cmd = try AudioRebuild.parse([])
    try await cmd.run()
}

private func runCorpusNDJSONLivePillar() async throws {
    let cmd = try CorpusNDJSONLive.parse(["--live"])
    try await cmd.run()
}
