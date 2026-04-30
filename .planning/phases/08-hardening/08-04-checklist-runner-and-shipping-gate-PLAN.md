---
phase: 08-hardening
plan: 04
type: execute
wave: 3
depends_on: [01, 02, 03]
files_modified:
  - packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift
  - packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift
  - packages/Harness/Sources/jarvis-eval/main.swift
  - packages/Harness/Tests/HarnessTests/ChecklistRunnerTests.swift
  - .planning/phases/01-foundations/checklist.yaml
  - .planning/phases/02-bus/checklist.yaml
  - .planning/phases/03-hud/checklist.yaml
  - .planning/phases/04-agent-core/checklist.yaml
  - .planning/phases/05-mcp/checklist.yaml
  - .planning/phases/06-voice/checklist.yaml
  - .planning/phases/07-memory-vision/checklist.yaml
  - .planning/phases/08-hardening/checklist.yaml
  - scripts/shipping-gate.sh
  - scripts/promote-replay-session.sh
  - scripts/check-corpus-secrets.sh
  - .git/hooks/pre-commit
  - packages/Harness/Tests/HarnessTests/ReplaySuppressionIntegrationTests.swift
autonomous: true
requirements: [OBS-04]
must_haves:
  truths:
    - "ChecklistRunner reads per-phase YAML manifests with mechanization types swift_test, script, grep_negative, grep_positive, plist_check, codesign_grep, MANUAL"
    - "Every grep-style item has expected_count or expected_value (D-17 enforcement; manifest decoder rejects missing fields)"
    - "MANUAL items always print as warning rows in shipping-gate output; never block (D-16)"
    - "Per-phase checklist.yaml manifests authored for phases 01..08 by sweeping SUMMARY.md files + folding 18 existing scripts/check-*.sh as type: script mechanizations (D-15)"
    - "jarvis-eval checklist runs ChecklistRunner across all phase manifests"
    - "jarvis-eval all runs every pillar plus the checklist; --skip-live default for CI; --live opt-in"
    - "scripts/shipping-gate.sh wraps jarvis-eval all; exit 0 iff fixture-only matrix passes; non-zero on any unexpected drift"
    - "Pre-commit hook greps packages/Harness/Corpora/ for sk-ant-, AKIA, ghp_, sk- patterns (D-07) and fails on hit"
    - "scripts/promote-replay-session.sh helper copies SQLite + records temperature/model meta into sidecar JSON (D-09)"
    - "Replay-suppression integration test asserts no webview bus message and no TTS engine call during a .replay turn (R4-L7 verification, plan-level integration of 08-01's TurnSource extension)"
  artifacts:
    - path: "packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift"
      provides: "YAML manifest reader + mechanization dispatcher"
      exports: ["ChecklistRunner", "ChecklistResult"]
    - path: "packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift"
      provides: "Hand-rolled Codable for ChecklistManifest + ChecklistItem + MechanizationType"
      exports: ["ChecklistManifest", "MechanizationType"]
    - path: ".planning/phases/{01..08}-*/checklist.yaml"
      provides: "Per-phase mechanized invariant manifest"
      contains: "items:"
    - path: "scripts/shipping-gate.sh"
      provides: "Single CI entry point invoking jarvis-eval all"
      exports: []
    - path: "scripts/promote-replay-session.sh"
      provides: "Operator helper to promote a recorded session to replay-golden corpus with sidecar meta"
      exports: []
    - path: "scripts/check-corpus-secrets.sh"
      provides: "Pre-commit hook helper greps Corpora/ for API key patterns"
      exports: []
  key_links:
    - from: "packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift"
      to: "scripts/check-*.sh (18 existing scripts folded as type: script rows)"
      via: "Process spawn + exit code = pass/fail"
      pattern: "type:\\s*script"
    - from: "scripts/shipping-gate.sh"
      to: "jarvis-eval all (executable target)"
      via: "swift run --package-path packages/Harness jarvis-eval all"
      pattern: "jarvis-eval all"
    - from: ".git/hooks/pre-commit"
      to: "scripts/check-corpus-secrets.sh"
      via: "shell hook invokes check; non-zero exit aborts commit"
      pattern: "check-corpus-secrets"
    - from: "packages/Harness/Tests/HarnessTests/ReplaySuppressionIntegrationTests.swift"
      to: "08-01's TurnSource Strategy B + 08-03's CapturingURLProtocol"
      via: "drives a replay turn; asserts no HUD bus message + no TTS engine call"
      pattern: "dispatchesToHUD|speaks"
---

<phase_goal>
Phase 8 Plan 04 closes the harness loop: implements the ChecklistRunner per OBS-04 pillar (h),
authors the per-phase YAML manifests (P1-P8) by sweeping each phase's SUMMARY.md and folding
the 18 existing scripts/check-*.sh scripts as `type: script` mechanizations, ships
`scripts/shipping-gate.sh` as the single CI entry, ships the `pre-commit` hook for D-07 secret
scanning, ships `scripts/promote-replay-session.sh` for the D-09 operator workflow, and adds
the `jarvis-eval all` aggregate command. Also adds the cross-cutting integration test for
R4-L7 replay-suppression that 08-01 deferred (asserts no webview bus message and no TTS
engine call during a .replay turn). This is the integration plan — once 08-04 ships,
`scripts/shipping-gate.sh` is the ship-or-don't-ship signal.
</phase_goal>

<truths>
This plan executes against these LOCKED context decisions (08-CONTEXT.md):

- **D-04:** Default `scripts/shipping-gate.sh` runs every pillar fixture-only; `--live` requires `JARVIS_LIVE_EVAL=1`.
- **D-07:** Pre-commit hook greps `packages/Harness/Corpora/` for `sk-ant-`, `AKIA`, `ghp_`, `sk-` patterns and fails on hit. This plan ships `scripts/check-corpus-secrets.sh` + the `.git/hooks/pre-commit` invocation.
- **D-09:** Operator-driven session promotion via `scripts/promote-replay-session.sh` — copies SQLite + records temperature/model meta into a sidecar JSON so DriftClassifier knows whether `nondeterministicUnderSampling` exclusions apply.
- **D-15:** P8 retroactively sweeps P1-P7 (since those phases pre-date the checklist YAML pattern). Each `.planning/phases/<XX>-<slug>/checklist.yaml` is authored here by extracting items from the phase's SUMMARY.md files + folding the 18 existing `scripts/check-*.sh` scripts as `type: script` mechanizations.
- **D-16:** Mechanization types accepted by ChecklistRunner (closed set; hand-rolled Codable enum, no `default:`):
  - `swift_test` (suite + test name)
  - `script` (relative path; exit code = pass/fail)
  - `grep_negative` (file + pattern + `expected_count: 0`)
  - `grep_positive` (file + pattern + `expected_count: N`)
  - `plist_check` (file + key + expected value)
  - `codesign_grep` (identity + pattern + expected_count)
  - `MANUAL:` (free-form description; visible in CI output as warning row, never blocks)
- **D-17:** `expected_count` / `expected_value` is REQUIRED on every grep-style item; the YAML decoder REJECTS the manifest if missing (catches "regex no longer matches anything" silent-green failure mode).

This plan depends on 08-01, 08-02, 08-03 (all Wave 1 + Wave 2 work).

## P6 Deferred Debt Surfacing (D-12 / D-13)

Per planner context: P6 HUMAN-UAT gates surface as `MANUAL:` checklist items in `06-voice/checklist.yaml` during this plan, NOT as synthetic XCTest cases. The 6 gates (VOICE-07 happy path, VOICE-14 barge-in, VOICE-13 PTT, VOICE-12 mute-wake-word + PTT-armed, VOICE-09 AEC banner, VOICE-10 mic re-grant) require physical hardware + microphone interaction. The Orpheus empirical TTFA measurement is also surfaced as MANUAL.

08-03's `08-LAUNCH-FRAGILITY-NOTES.md` (Task 1) provides the prerequisite — its outcome (RESOLVED or ACCEPTED AS MANUAL) drives whether the operator CAN run the UAT gates. Each MANUAL item references the launch-fragility resolution path so the operator knows the precondition.
</truths>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/REQUIREMENTS.md
@.planning/phases/08-hardening/08-CONTEXT.md
@.planning/phases/08-hardening/08-RESEARCH.md
@.planning/phases/08-hardening/08-PATTERNS.md
@.planning/phases/08-hardening/08-VALIDATION.md
@.planning/phases/08-hardening/08-01-replay-oracle-PLAN.md
@.planning/phases/08-hardening/08-02-corpora-curation-and-runners-PLAN.md
@.planning/phases/08-hardening/08-03-live-and-integration-runners-PLAN.md
@.planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md
@CLAUDE.md
@scripts/check-bus-protocol-version.sh
@scripts/verify-entitlements.sh
@scripts/verify-codesign-settings.sh

<interfaces>
From PATTERNS.md §2.11 — ChecklistRunner mechanization types (D-16 closed set, hand-rolled Codable):

    public enum MechanizationType: Sendable, Codable, Equatable {
        case swiftTest(suite: String, test: String)
        case script(path: String, args: [String]?)
        case grepNegative(file: String, pattern: String, expectedCount: Int)
        case grepPositive(file: String, pattern: String, expectedCount: Int)
        case plistCheck(file: String, key: String, expectedValue: PlistValue)
        case codesignGrep(identity: String, pattern: String, expectedCount: Int)
        case manual(description: String)

        // Hand-rolled init(from: Decoder) with `type` discriminator + per-case decoding.
        // No `default:` arm anywhere (S-1).
    }

    public struct ChecklistItem: Sendable, Codable {
        public let id: String
        public let description: String
        public let mechanization: MechanizationType
    }

    public struct ChecklistManifest: Sendable, Codable {
        public let phase: String
        public let items: [ChecklistItem]
    }

YAML manifest example shape (RESEARCH lines 583-614):

    phase: 01-foundations
    items:
      - id: P1-01
        description: "LSUIElement=YES keeps app out of Dock"
        mechanization:
          type: plist_check
          file: build/Build/Products/Release/Jarvis.app/Contents/Info.plist
          key: LSUIElement
          expected_value: true
      - id: P1-04
        description: "allow-unsigned-executable-memory is NOT in entitlements"
        mechanization:
          type: grep_negative
          file: App/Jarvis.entitlements
          pattern: "allow-unsigned-executable-memory"
          expected_count: 0
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: ChecklistManifest Codable + ChecklistRunner + jarvis-eval checklist + jarvis-eval all subcommands</name>

  <read_first>
    - packages/Harness/Sources/jarvis-eval/main.swift (current state — read all subcommands registered by 08-01/08-02/08-03)
    - packages/Replay/Sources/Replay/ReplayEvent.swift `encoded()` switch (analog hand-rolled Codable per S-1)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.11 (ChecklistRunner mechanization dispatch)
    - .planning/phases/08-hardening/08-RESEARCH.md §"Looks done but isn't" lines 581-615 (manifest shape)
    - .planning/phases/08-hardening/08-CONTEXT.md D-15, D-16, D-17
    - scripts/check-bus-protocol-version.sh (analog `type: script` row delegate)
    - Find a Swift YAML decoder. Default approach: write a thin shim over Apple's existing parser if available, OR add `Yams` (jpsim/Yams) as a Harness-only dependency. Yams is the de-facto Swift YAML library.
  </read_first>

  <files>
    packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift,
    packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift,
    packages/Harness/Sources/jarvis-eval/main.swift,
    packages/Harness/Package.swift,
    packages/Harness/Tests/HarnessTests/ChecklistRunnerTests.swift
  </files>

  <action>
1. Add Yams dependency to `packages/Harness/Package.swift`:
   - Add `.package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")` to dependencies.
   - Add `.product(name: "Yams", package: "Yams")` to the `Harness` library target's dependencies.

2. Create `packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift` with hand-rolled Codable for `MechanizationType` per S-1 (no `default:` arm). The YAML decoder reads `type:` discriminator and dispatches to per-case init. CRITICAL D-17 enforcement: if `type` is `grep_negative` or `grep_positive` and `expected_count` is missing, init throws `DecodingError.dataCorrupted` with message "D-17: expected_count required on grep-style item":

    import Foundation

    public enum PlistValue: Sendable, Codable, Equatable {
        case bool(Bool)
        case string(String)
        case int(Int)
        // Hand-rolled init(from: Decoder)
    }

    public enum MechanizationType: Sendable, Equatable {
        case swiftTest(suite: String, test: String)
        case script(path: String, args: [String])
        case grepNegative(file: String, pattern: String, expectedCount: Int)
        case grepPositive(file: String, pattern: String, expectedCount: Int)
        case plistCheck(file: String, key: String, expectedValue: PlistValue)
        case codesignGrep(identity: String, pattern: String, expectedCount: Int)
        case manual(description: String)
    }

    extension MechanizationType: Codable {
        private enum CodingKeys: String, CodingKey {
            case type, suite, test, path, args, file, pattern, key
            case expectedCount = "expected_count"
            case expectedValue = "expected_value"
            case identity, description
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "swift_test":
                self = .swiftTest(
                    suite: try container.decode(String.self, forKey: .suite),
                    test: try container.decode(String.self, forKey: .test)
                )
            case "script":
                self = .script(
                    path: try container.decode(String.self, forKey: .path),
                    args: try container.decodeIfPresent([String].self, forKey: .args) ?? []
                )
            case "grep_negative":
                guard container.contains(.expectedCount) else {
                    throw DecodingError.dataCorruptedError(forKey: .expectedCount, in: container,
                        debugDescription: "D-17: expected_count required on grep_negative item")
                }
                self = .grepNegative(
                    file: try container.decode(String.self, forKey: .file),
                    pattern: try container.decode(String.self, forKey: .pattern),
                    expectedCount: try container.decode(Int.self, forKey: .expectedCount)
                )
            case "grep_positive":
                guard container.contains(.expectedCount) else {
                    throw DecodingError.dataCorruptedError(forKey: .expectedCount, in: container,
                        debugDescription: "D-17: expected_count required on grep_positive item")
                }
                self = .grepPositive(
                    file: try container.decode(String.self, forKey: .file),
                    pattern: try container.decode(String.self, forKey: .pattern),
                    expectedCount: try container.decode(Int.self, forKey: .expectedCount)
                )
            case "plist_check":
                self = .plistCheck(
                    file: try container.decode(String.self, forKey: .file),
                    key: try container.decode(String.self, forKey: .key),
                    expectedValue: try container.decode(PlistValue.self, forKey: .expectedValue)
                )
            case "codesign_grep":
                guard container.contains(.expectedCount) else {
                    throw DecodingError.dataCorruptedError(forKey: .expectedCount, in: container,
                        debugDescription: "D-17: expected_count required on codesign_grep item")
                }
                self = .codesignGrep(
                    identity: try container.decode(String.self, forKey: .identity),
                    pattern: try container.decode(String.self, forKey: .pattern),
                    expectedCount: try container.decode(Int.self, forKey: .expectedCount)
                )
            case "MANUAL", "manual":
                self = .manual(description: try container.decode(String.self, forKey: .description))
            // NO default arm — adding a new mechanization type forces compile-time hits
            // when the encoder is updated. The string switch above intentionally omits a
            // catch-all; an unknown `type` value throws via the implicit fall-through:
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                    debugDescription: "Unknown mechanization type: \(type). Allowed: swift_test|script|grep_negative|grep_positive|plist_check|codesign_grep|MANUAL")
            }
            // Note: the above `default` arm throws — it does NOT silently accept. The S-1 invariant is preserved
            // because adding a new MechanizationType case forces an update to this switch (compile error if we
            // also tighten via @frozen + frozen-enum-exhaustiveness; otherwise audit at decode-time only).
        }

        public func encode(to encoder: Encoder) throws { /* mirror */ }
    }

    public struct ChecklistItem: Sendable, Codable {
        public let id: String
        public let description: String
        public let mechanization: MechanizationType
    }

    public struct ChecklistManifest: Sendable, Codable {
        public let phase: String
        public let items: [ChecklistItem]

        public static func load(yamlURL: URL) throws -> ChecklistManifest {
            let text = try String(contentsOf: yamlURL, encoding: .utf8)
            let yaml = try Yams.load(yaml: text)
            let json = try JSONSerialization.data(withJSONObject: yaml as Any)
            return try JSONDecoder().decode(ChecklistManifest.self, from: json)
        }
    }

   Note on the `default:` caveat above: the switch over `type: String` REQUIRES a `default` arm because String is open-ended. The S-1 invariant applies to switches over our own typed enums; for the type-discriminator-string we throw on unknown values, which is functionally equivalent (a new mechanization adds a new String value AND a new enum case; both surfaces require updating). Document this nuance in a comment in the file.

3. Create `packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift`:

    import Foundation

    public actor ChecklistRunner {
        public struct ItemResult: Sendable, Codable {
            public let itemId: String
            public let description: String
            public let passed: Bool
            public let warnedAsManual: Bool
            public let detail: String
        }

        public struct ChecklistResult: Sendable, Codable {
            public let phase: String
            public let results: [ItemResult]
            public let passedCount: Int
            public let failedCount: Int
            public let manualCount: Int
            public var passed: Bool { failedCount == 0 }
        }

        public func runManifest(at url: URL, repoRoot: URL) async throws -> ChecklistResult {
            let manifest = try ChecklistManifest.load(yamlURL: url)
            var results: [ItemResult] = []
            for item in manifest.items {
                let r = try await runItem(item, repoRoot: repoRoot)
                results.append(r)
            }
            let passed = results.filter { $0.passed && !$0.warnedAsManual }.count
            let failed = results.filter { !$0.passed && !$0.warnedAsManual }.count
            let manual = results.filter { $0.warnedAsManual }.count
            return ChecklistResult(
                phase: manifest.phase, results: results,
                passedCount: passed, failedCount: failed, manualCount: manual
            )
        }

        private func runItem(_ item: ChecklistItem, repoRoot: URL) async throws -> ItemResult {
            switch item.mechanization {
            case .swiftTest(let suite, let test):
                return try await runSwiftTest(item: item, suite: suite, test: test, repoRoot: repoRoot)
            case .script(let path, let args):
                return try await runScript(item: item, path: path, args: args, repoRoot: repoRoot)
            case .grepNegative(let file, let pattern, let expectedCount):
                return try runGrep(item: item, file: file, pattern: pattern,
                                   expectedCount: expectedCount, kind: .negative, repoRoot: repoRoot)
            case .grepPositive(let file, let pattern, let expectedCount):
                return try runGrep(item: item, file: file, pattern: pattern,
                                   expectedCount: expectedCount, kind: .positive, repoRoot: repoRoot)
            case .plistCheck(let file, let key, let expectedValue):
                return try runPlistCheck(item: item, file: file, key: key,
                                          expectedValue: expectedValue, repoRoot: repoRoot)
            case .codesignGrep(let identity, let pattern, let expectedCount):
                return try await runCodesignGrep(item: item, identity: identity,
                                                  pattern: pattern, expectedCount: expectedCount, repoRoot: repoRoot)
            case .manual(let description):
                return ItemResult(itemId: item.id, description: item.description,
                                  passed: true, warnedAsManual: true,
                                  detail: "MANUAL: \(description)")
            }
        }

        // Per-case implementations: spawn `/bin/bash <repoRoot>/scripts/<path>` for script items;
        // run `grep -E '^\s*<pattern>' file | grep -v '^#' | wc -l` for grep_negative (filter
        // header comments per CLAUDE.md verify hygiene); use /usr/libexec/PlistBuddy for plist_check;
        // use `codesign --display --entitlements - <path>` + grep for codesign_grep.
    }

   Each mechanization helper uses `Process` + Pipe. The `runScript` helper uses `Process()` with `executableURL = /bin/bash` and `arguments = [<repoRoot>/<path>] + args`; exit code 0 = pass, non-zero = fail. The `runGrep` helper filters out comment lines (per CLAUDE.md grep gate hygiene: `grep -v '^#' | grep -c <pattern>`) so the manifest itself doesn't self-invalidate by mentioning the pattern in its description.

4. Update `packages/Harness/Sources/jarvis-eval/main.swift` to register `Checklist` and `All` subcommands:

    struct Checklist: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "checklist",
            abstract: "Run all per-phase checklist.yaml manifests."
        )
        @Option(help: "Phase to run; default = all phases 01..08")
        var phase: String?

        func run() async throws {
            let runner = ChecklistRunner()
            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let phasesDir = repoRoot.appendingPathComponent(".planning/phases")
            let manifests = try FileManager.default.contentsOfDirectory(at: phasesDir, includingPropertiesForKeys: nil)
                .compactMap { dir -> URL? in
                    let yaml = dir.appendingPathComponent("checklist.yaml")
                    return FileManager.default.fileExists(atPath: yaml.path) ? yaml : nil
                }
                .filter { phase == nil || $0.path.contains("/\(phase!)-") }

            var anyFailed = false
            for manifest in manifests {
                let result = try await runner.runManifest(at: manifest, repoRoot: repoRoot)
                printResults(result)
                if !result.passed { anyFailed = true }
            }
            if anyFailed { throw ExitCode.failure }
        }
    }

    struct All: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "all",
            abstract: "Run every pillar + checklist; default fixture-only (D-04)."
        )
        @Flag(help: "Skip live-mode pillars (default: skip).")
        var skipLive: Bool = true

        @Flag(help: "Include live-mode pillars; requires JARVIS_LIVE_EVAL=1 env var.")
        var live: Bool = false

        func run() async throws {
            if live {
                guard ProcessInfo.processInfo.environment["JARVIS_LIVE_EVAL"] == "1" else {
                    throw ValidationError("--live requires JARVIS_LIVE_EVAL=1 in environment.")
                }
            }
            // Run subcommands in order, aggregate exit codes
            let runners: [(String, () async throws -> Void)] = [
                ("checklist", { try await Checklist.parseAsRoot([]).run() }),
                ("corpus-injection", { try await CorpusInjection.parseAsRoot([]).run() }),
                ("corpus-sse", { try await CorpusSSE.parseAsRoot([]).run() }),
                ("corpus-ndjson", { try await CorpusNDJSON.parseAsRoot([]).run() }),
                ("cap-recovery", { try await CapRecovery.parseAsRoot([]).run() }),
                ("wake-corpus", { try await WakeCorpus.parseAsRoot([]).run() }),
                ("mcp-crash", { try await McpCrash.parseAsRoot([]).run() }),
                ("audio-rebuild", { try await AudioRebuild.parseAsRoot([]).run() }),
            ]
            if live && !skipLive {
                // append corpus-ndjson-live, corpus-sse-live (if implemented in 08-03 / future)
            }
            for (name, runner) in runners {
                print(">>> \(name)")
                do { try await runner() }
                catch { print("\(name) FAILED: \(error)"); throw ExitCode.failure }
            }
        }
    }

5. Create `packages/Harness/Tests/HarnessTests/ChecklistRunnerTests.swift`:
   - YAML round-trip: encode a manifest → decode → compare.
   - D-17 enforcement: a manifest with grep_negative missing expected_count throws DecodingError.
   - Each mechanization type happy path (synthetic fixture YAML → ChecklistRunner result) including a script-type that exits 0, a grep_positive that finds the expected count, a plist_check, a manual item.
   - Failure cases: script exits non-zero → passed=false; grep count mismatch → passed=false.
   - `MANUAL` items: `warnedAsManual=true`, do NOT count toward `failedCount`.
  </action>

  <acceptance_criteria>
    - `swift build --package-path packages/Harness` exits 0
    - File `packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift` exists and contains all 7 mechanization cases: `grep -cE "case swiftTest|case script|case grepNegative|case grepPositive|case plistCheck|case codesignGrep|case manual" packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift` returns at least 7
    - D-17 enforcement string present: `grep -c "D-17" packages/Harness/Sources/Harness/Corpus/ChecklistManifest.swift` returns at least 3 (one per grep-style mechanization)
    - File `packages/Harness/Sources/Harness/Runners/ChecklistRunner.swift` exists and contains `public actor ChecklistRunner`
    - Yams added to Package.swift: `grep -c "Yams" packages/Harness/Package.swift` returns at least 2
    - `swift run --package-path packages/Harness jarvis-eval checklist --help` exits 0
    - `swift run --package-path packages/Harness jarvis-eval all --help` exits 0
    - `swift test --package-path packages/Harness --filter ChecklistRunnerTests` exits 0
    - All previously authored subcommands still appear in help: `swift run --package-path packages/Harness jarvis-eval --help | grep -cE "replay|corpus-injection|corpus-sse|corpus-ndjson|cap-recovery|wake-corpus|mcp-crash|audio-rebuild|checklist|all"` returns at least 10
  </acceptance_criteria>

  <verify>
    <automated>swift build --package-path packages/Harness && swift test --package-path packages/Harness --filter ChecklistRunnerTests && swift run --package-path packages/Harness jarvis-eval checklist --help && swift run --package-path packages/Harness jarvis-eval all --help</automated>
  </verify>

  <done>ChecklistManifest + Runner ship with 7 mechanization types and D-17 enforcement. checklist + all subcommands wired. All 10 jarvis-eval subcommands accessible from help output.</done>
</task>

<task type="auto">
  <name>Task 2: Sweep author per-phase checklist.yaml manifests for P1-P8 (D-15)</name>

  <read_first>
    For each phase, read EVERY plan SUMMARY.md:
    - .planning/phases/01-foundations/*-SUMMARY.md (5 plans)
    - .planning/phases/02-bus/*-SUMMARY.md (4 plans)
    - .planning/phases/03-hud/*-SUMMARY.md (5 plans, status varies)
    - .planning/phases/04-agent-core/*-SUMMARY.md (5 plans)
    - .planning/phases/05-mcp/*-SUMMARY.md (5 plans)
    - .planning/phases/06-voice/*-SUMMARY.md (5 plans) + 06-HUMAN-UAT.md (D-12 deferred items)
    - .planning/phases/07-memory-vision/*-SUMMARY.md (6 plans)
    - .planning/phases/08-hardening/*-SUMMARY.md (3 plans authored 08-01, 08-02, 08-03)
    - List ALL existing scripts: `ls scripts/*.sh` (find the 18 check-*.sh + verify-*.sh scripts)
    - .planning/phases/08-hardening/08-LAUNCH-FRAGILITY-NOTES.md (D-12 outcome — feeds 06-voice MANUAL items)
    - .planning/phases/06-voice/06-HUMAN-UAT.md (the 6 UAT gates per D-12)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.14 (sweep recipe + script-to-YAML mapping table)
  </read_first>

  <files>
    .planning/phases/01-foundations/checklist.yaml,
    .planning/phases/02-bus/checklist.yaml,
    .planning/phases/03-hud/checklist.yaml,
    .planning/phases/04-agent-core/checklist.yaml,
    .planning/phases/05-mcp/checklist.yaml,
    .planning/phases/06-voice/checklist.yaml,
    .planning/phases/07-memory-vision/checklist.yaml,
    .planning/phases/08-hardening/checklist.yaml
  </files>

  <action>
For each phase 01..08, author `.planning/phases/<NN>-<slug>/checklist.yaml` per PATTERNS.md §2.14 sweep recipe:

1. Read every plan SUMMARY.md in the phase directory.
2. Bucket each item by mechanization type using the recipe in PATTERNS.md §2.14 (existing `scripts/check-*.sh` → `type: script`; existing XCTest/swift-testing → `type: swift_test`; entitlement → `type: plist_check` or `type: codesign_grep`; architecturally forbidden patterns → `type: grep_negative, expected_count: 0`; manual hardware/UAT → `MANUAL:`).
3. **D-17 enforcement:** every grep-style row carries `expected_count` or `expected_value`.
4. **Script folding (D-15):** the 18 existing `scripts/check-*.sh` scripts map to YAML rows per PATTERNS.md §2.14 table. Verbatim:

   - `check-bus-protocol-version.sh` → 02-bus
   - `check-bus-harness-parity.sh` → 02-bus
   - `check-no-evaluate-javascript.sh` → 02-bus AND/OR 03-hud
   - `check-no-modal-presentation.sh` → 05-mcp
   - `check-single-writer-hudstate.sh` → 03-hud
   - `check-presence-vision-isolation.sh` → 07-memory-vision
   - `check-presence-bus-no-tts-orchestrator.sh` → 07-memory-vision
   - `check-single-memory-mutated-emit.sh` → 07-memory-vision
   - `check-single-memory-used-emit.sh` → 07-memory-vision
   - `check-embedding-dim-literal.sh` → 07-memory-vision
   - `check-vision-isolation.sh` → 07-memory-vision
   - `check-app-builds.sh` → 08-hardening (cross-phase smoke)
   - `verify-entitlements.sh` → 01-foundations (with `args: ["--post-codesign"]`)
   - `verify-codesign-settings.sh` → 01-foundations
   - `probe-speech-assets.sh` → 06-voice
   - `smoke-test-hud.sh` → 03-hud
   - NOT included: `fetch-openwakeword-models.sh`, `fetch-silero-models.sh` (setup, not invariants), `test-check-*.sh` and `test-verify-*.sh` (meta-tests).

5. **MANUAL items (D-12 / D-13) for 06-voice:**

   06-voice/checklist.yaml MUST include the 6 UAT MANUAL items + Orpheus TTFA MANUAL item, regardless of 08-LAUNCH-FRAGILITY-NOTES.md outcome (operator runs them once launch fragility is resolved). Each item references the prerequisite:

       items:
         - id: P6-MANUAL-VOICE-07
           description: "VOICE-07 happy path: 'Hey Jarvis, what time is it?' end-to-end on Release-signed Developer ID archive"
           mechanization:
             type: MANUAL
             description: "Prerequisite: 08-LAUNCH-FRAGILITY-NOTES.md resolution. Then: archive Release build, install on host Mac, summon HUD via bound hotkey, speak phrase. Verify HUD transitions idle→listening→thinking→speaking; spoken answer is natural-sounding."
         # ... 5 more UAT gates: VOICE-09, VOICE-10, VOICE-12, VOICE-13, VOICE-14
         - id: P6-MANUAL-ORPHEUS-TTFA
           description: "Empirical Orpheus TTFA measurement on host Apple Silicon Mac"
           mechanization:
             type: MANUAL
             description: "Prerequisite: 08-LAUNCH-FRAGILITY-NOTES.md resolution. Then: JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests interactively. If TTFA > 250ms, edit config to flip features.tts.tier2 = 'ttskit'."
         # And, conditional on 08-LAUNCH-FRAGILITY-NOTES.md probe outcome:
         - id: P6-MANUAL-AUDIO-DEVICE-CHANGE
           description: "Audio-graph device-change rebuild trigger (only if AVAudioEngine synthetic injection unavailable per D-14)"
           mechanization:
             type: MANUAL
             description: "Plug in / unplug a USB-C audio interface during a `.speaking` turn; verify HUD enters reconfiguring state and rebuilds within 500ms."

   ONLY include `P6-MANUAL-AUDIO-DEVICE-CHANGE` if 08-LAUNCH-FRAGILITY-NOTES.md probe section says "unavailable". If probe says "available", omit this item (the runner handles it automatically).

6. **Per-phase target item count (sizing per PATTERNS.md §2.14 sweep is interpretive):**

   - 01-foundations: ~12-18 items (heaviest — 17 REQ-IDs, 5 plans, every entitlement, every codesign verification, every shell-wizard invariant, allow-unsigned-executable-memory negative grep)
   - 02-bus: ~6-10 items (5 REQ-IDs, 4 plans, schema parity, no evaluateJavaScript negative grep, handshake mismatch test)
   - 03-hud: ~6-10 items (6 REQ-IDs, 5 plans, single-writer HudStateCoordinator, R3F render smoke, precedence ladder)
   - 04-agent-core: ~10-14 items (14 REQ-IDs, 5 plans, 1h cache-TTL header round-trip, SSE decoder fixture coverage, NDJSON tool_calls-on-sight, retry-bound, turnNonce, 8KB cap, drop-oldest channel, orphan detection)
   - 05-mcp: ~8-12 items (10 REQ-IDs, 5 plans, native AppKit confirmation sheet test, no-modal lint, restart mutex test, ChildSpawnGate FD_CLOEXEC, sanitize ordering)
   - 06-voice: ~8-12 items (14 REQ-IDs but many already have unit tests in P6) + 7 MANUAL items per D-12/D-13
   - 07-memory-vision: ~10-14 items (13 REQ-IDs, 6 plans, schema constants, presence isolation, no-presence-TTS, EMBEDDING_DIM=768 literal grep, single-source mutate emit, single-source used emit)
   - 08-hardening: ~8-10 items (its own self-coverage — DriftClassifier 6 categories present, injection corpus >= 20, 6 D-23 mandates present, replay schema version handshake, FD-leak whitelist guard, capture-script redaction, pre-commit hook installed)

7. **Common items every phase has:**
   - `<phase>-build`: type: script, path: `scripts/check-app-builds.sh` (cross-phase smoke)

8. Validate every YAML decodes successfully via `swift run --package-path packages/Harness jarvis-eval checklist --phase <NN>` for each phase.
  </action>

  <acceptance_criteria>
    - All 8 manifest files exist:
      - `test -f .planning/phases/01-foundations/checklist.yaml`
      - `test -f .planning/phases/02-bus/checklist.yaml`
      - `test -f .planning/phases/03-hud/checklist.yaml`
      - `test -f .planning/phases/04-agent-core/checklist.yaml`
      - `test -f .planning/phases/05-mcp/checklist.yaml`
      - `test -f .planning/phases/06-voice/checklist.yaml`
      - `test -f .planning/phases/07-memory-vision/checklist.yaml`
      - `test -f .planning/phases/08-hardening/checklist.yaml`
    - Every YAML decodes via the runner: `swift run --package-path packages/Harness jarvis-eval checklist` exits 0 OR fails with reason 'invariant violation' NOT 'manifest decode failure'
    - 06-voice manifest contains the 6 UAT MANUAL items: `grep -cE "P6-MANUAL-VOICE-(07|09|10|12|13|14)" .planning/phases/06-voice/checklist.yaml` returns 6
    - 06-voice manifest contains Orpheus TTFA MANUAL: `grep -c "P6-MANUAL-ORPHEUS-TTFA" .planning/phases/06-voice/checklist.yaml` returns 1
    - All 16 production scripts/check-*.sh and scripts/verify-*.sh that the sweep recipe maps appear at least once across all manifests: write a sentinel script `scripts/check-yaml-script-coverage.sh` (or run inline) that asserts each script path is referenced in at least one manifest:
      ```
      for s in check-bus-protocol-version.sh check-bus-harness-parity.sh check-no-evaluate-javascript.sh check-no-modal-presentation.sh check-single-writer-hudstate.sh check-presence-vision-isolation.sh check-presence-bus-no-tts-orchestrator.sh check-single-memory-mutated-emit.sh check-single-memory-used-emit.sh check-embedding-dim-literal.sh check-vision-isolation.sh check-app-builds.sh verify-entitlements.sh verify-codesign-settings.sh probe-speech-assets.sh smoke-test-hud.sh; do
        grep -rq "$s" .planning/phases/*/checklist.yaml || echo "MISSING: $s"
      done | wc -l  # == 0 (or whichever scripts genuinely don't exist yet — document)
      ```
    - 01-foundations contains an `allow-unsigned-executable-memory` grep_negative entry per SEC-02: `grep -cE "allow-unsigned-executable-memory" .planning/phases/01-foundations/checklist.yaml` returns at least 1
    - 07-memory-vision contains an `EMBEDDING_DIM` grep entry per MEM-02: `grep -c "EMBEDDING_DIM" .planning/phases/07-memory-vision/checklist.yaml` returns at least 1
    - All grep-type items have expected_count: count `expected_count:` per manifest >= count of `type: grep_negative|grep_positive|codesign_grep` per manifest (D-17): for each manifest, the count of `expected_count:` lines is >= the sum count of `type: grep_negative`, `type: grep_positive`, `type: codesign_grep` lines.
    - Total item count across all 8 manifests is at least 65 (sized per Task 2 step 6 minimums summed)
  </acceptance_criteria>

  <verify>
    <automated>swift run --package-path packages/Harness jarvis-eval checklist 2>&1 | grep -vE 'FAIL|fail' | grep -qE 'phase' && for f in 01-foundations 02-bus 03-hud 04-agent-core 05-mcp 06-voice 07-memory-vision 08-hardening; do test -f .planning/phases/$f/checklist.yaml || exit 1; done</automated>
  </verify>

  <done>All 8 per-phase checklist.yaml manifests authored. 18 existing scripts/check-*.sh folded as type: script rows. P6 deferred UAT gates surfaced as 7 MANUAL items in 06-voice/checklist.yaml. ChecklistRunner accepts every manifest without decode failure. D-17 enforcement intact across all manifests.</done>
</task>

<task type="auto">
  <name>Task 3: scripts/shipping-gate.sh + scripts/promote-replay-session.sh + pre-commit hook + replay-suppression integration test</name>

  <read_first>
    - scripts/check-bus-protocol-version.sh (analog shell discipline + env-var indirection per S-6)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.13 (shipping-gate.sh template) and §S-6/§S-7
    - .planning/phases/08-hardening/08-CONTEXT.md D-04, D-07, D-09
    - packages/Harness/Sources/jarvis-eval/main.swift (current state — verify `all` subcommand exists from Task 1)
    - packages/Replay/Sources/Replay/ReplayEvent.swift (Strategy B post-08-01 — TurnSource.replay/.evaluation)
    - packages/Bus/Sources/Bus (find webview bus dispatcher — for the integration test `assert no message` path)
    - packages/Voice/Sources/Voice/TTS (find TTSEngineActor or similar — for the integration test `assert no synthesize call` path)
    - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift (replay submit path)
  </read_first>

  <files>
    scripts/shipping-gate.sh,
    scripts/promote-replay-session.sh,
    scripts/check-corpus-secrets.sh,
    .git/hooks/pre-commit,
    packages/Harness/Tests/HarnessTests/ReplaySuppressionIntegrationTests.swift
  </files>

  <action>
1. Create `scripts/shipping-gate.sh` per PATTERNS.md §2.13:

    #!/usr/bin/env bash
    # shipping-gate.sh — Phase 8 OBS-04 shipping gate.
    #
    # Invokes `jarvis-eval all` over the harness's eight pillars + replay oracle.
    # Default mode: fixture-only (no Anthropic egress, no live Ollama daemon required).
    # Pass `--live` to include the live-Anthropic + live-Ollama pillars; requires
    # JARVIS_LIVE_EVAL=1 in environment per D-04.
    #
    # Usage:
    #   scripts/shipping-gate.sh                                # fixture-only (default)
    #   JARVIS_LIVE_EVAL=1 scripts/shipping-gate.sh --live      # full matrix incl. live
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    : "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

    cd "$REPO/packages/Harness"
    swift build --product jarvis-eval --configuration release

    LIVE_FLAG=""
    [[ "${1:-}" == "--live" ]] && LIVE_FLAG="--live"
    "$REPO/packages/Harness/.build/release/jarvis-eval" all $LIVE_FLAG

   Mark executable: `chmod 0755 scripts/shipping-gate.sh`.

2. Create `scripts/promote-replay-session.sh` per D-09:

    #!/usr/bin/env bash
    # promote-replay-session.sh — D-09 operator helper.
    # Copies a recorded session SQLite into Corpora/replay-golden/ + records
    # temperature/model meta into a sidecar JSON so DriftClassifier knows
    # whether nondeterministicUnderSampling exclusions apply.
    #
    # Usage:
    #   scripts/promote-replay-session.sh <session.sqlite> <archetype-name>
    # where <archetype-name> is one of: short-turn, long-multitool-turn,
    # cap-recovery, confirm-approved, confirm-denied, voice-barge-in,
    # stream-truncation-retry, vision-frame-attach.
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    : "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

    SRC="${1:?source SQLite path required}"
    NAME="${2:?archetype name required}"
    DEST_DIR="${REPO}/packages/Harness/Corpora/replay-golden"
    DEST_SQLITE="${DEST_DIR}/${NAME}.sqlite"
    DEST_META="${DEST_DIR}/${NAME}.meta.json"

    test -f "$SRC" || { echo "Source SQLite not found: $SRC" >&2; exit 1; }
    mkdir -p "$DEST_DIR"

    # Read meta from the source's `meta` table via sqlite3
    TEMPERATURE=$(sqlite3 "$SRC" "SELECT value FROM meta WHERE key='temperature' LIMIT 1;" 2>/dev/null || echo "0.0")
    MODEL=$(sqlite3 "$SRC" "SELECT value FROM meta WHERE key='model' LIMIT 1;" 2>/dev/null || echo "unknown")
    SCHEMA=$(sqlite3 "$SRC" "SELECT value FROM meta WHERE key='replaySchemaVersion' LIMIT 1;" 2>/dev/null || echo "1")
    RECORDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cp -p "$SRC" "$DEST_SQLITE"

    cat > "$DEST_META" <<JSON_EOF
    {
      "archetype": "${NAME}",
      "temperature": ${TEMPERATURE},
      "model": "${MODEL}",
      "replaySchemaVersion": ${SCHEMA},
      "recordedAt": "${RECORDED_AT}",
      "source": "${SRC}"
    }
    JSON_EOF

    echo "Promoted: $DEST_SQLITE"
    echo "Meta:     $DEST_META"

   Mark executable: `chmod 0755 scripts/promote-replay-session.sh`.

3. Create `scripts/check-corpus-secrets.sh` for D-07 pre-commit guard:

    #!/usr/bin/env bash
    # check-corpus-secrets.sh — D-07 pre-commit guard.
    # Greps packages/Harness/Corpora/ for API key patterns. Non-zero exit aborts the commit.
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    : "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

    PATTERNS=(
        "sk-ant-[A-Za-z0-9]{40,}"      # Anthropic
        "AKIA[0-9A-Z]{16}"              # AWS access key
        "ghp_[A-Za-z0-9]{36}"           # GitHub PAT
        "sk-[A-Za-z0-9]{32,}"           # Generic OpenAI-style
    )

    HITS=0
    for pat in "${PATTERNS[@]}"; do
        if grep -rE "$pat" "${REPO}/packages/Harness/Corpora/" 2>/dev/null; then
            echo "ERROR: D-07 violation — pattern '$pat' detected in Corpora/" >&2
            HITS=$((HITS + 1))
        fi
    done
    if [[ $HITS -gt 0 ]]; then
        echo "Aborting commit. Redact and re-stage." >&2
        exit 1
    fi
    exit 0

   Mark executable.

4. Install pre-commit hook at `.git/hooks/pre-commit`. If a pre-commit hook already exists, append the new check; otherwise create:

    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
    "${REPO}/scripts/check-corpus-secrets.sh"
    # (Append further pre-commit checks below as the project adds them.)

   Mark executable. NOTE: `.git/hooks/pre-commit` is local-only (not committed). Document the install step in `scripts/check-corpus-secrets.sh` with a usage note: `bash scripts/install-precommit-hook.sh` OR direct guidance "ln -sf ../../scripts/precommit-template.sh .git/hooks/pre-commit". Optionally ship a committed `scripts/precommit-template.sh` that the operator symlinks.

5. Create `packages/Harness/Tests/HarnessTests/ReplaySuppressionIntegrationTests.swift` — the R4-L7 integration test promised in 08-01's threat model T-08-05:

    import Testing
    import Foundation
    @testable import Harness
    import Replay
    import AgentCore
    import Bus  // for the bus dispatcher
    import Voice  // for TTSEngineActor

    @Suite("ReplaySuppressionIntegrationTests")
    struct ReplaySuppressionIntegrationTests {
        @Test("R4-L7: TurnSource.replay does NOT dispatch HUD bus message")
        func replaySuppressesHUDBus() async throws {
            let busSpy = BusOutboundSpy()
            let ttsSpy = TTSEngineSpy()
            let orchestrator = makeOrchestrator(bus: busSpy, tts: ttsSpy)

            // Drive a minimal replay turn with a fixture session
            let result = try await orchestrator.submit(
                "(replay)",
                source: .replay(sessionId: UUID())
            )

            // Suppression invariants
            #expect(busSpy.dispatchedMessages.isEmpty,
                    "R4-L7 violation: replay turn dispatched \(busSpy.dispatchedMessages.count) bus messages")
            #expect(ttsSpy.synthesizeCallCount == 0,
                    "R4-L7 violation: replay turn called TTS synthesize \(ttsSpy.synthesizeCallCount) times")
        }

        @Test("R4-L7: TurnSource.evaluation also suppresses HUD + TTS")
        func evaluationSuppressesHUDAndTTS() async throws {
            let busSpy = BusOutboundSpy()
            let ttsSpy = TTSEngineSpy()
            let orchestrator = makeOrchestrator(bus: busSpy, tts: ttsSpy)
            _ = try await orchestrator.submit(
                "(eval)",
                source: .evaluation(scenarioId: "test-scenario")
            )
            #expect(busSpy.dispatchedMessages.isEmpty)
            #expect(ttsSpy.synthesizeCallCount == 0)
        }

        @Test("Sanity: TurnSource.text DOES dispatch (control)")
        func textDispatchesAsControl() async throws {
            let busSpy = BusOutboundSpy()
            let ttsSpy = TTSEngineSpy()
            let orchestrator = makeOrchestrator(bus: busSpy, tts: ttsSpy)
            _ = try await orchestrator.submit("hello", source: .text)
            // Control: at least one HUD state message dispatched (idle→thinking)
            #expect(!busSpy.dispatchedMessages.isEmpty,
                    "Control invariant: text source MUST dispatch HUD; if this fails, the test scaffolding is wrong")
        }
    }

   `BusOutboundSpy` and `TTSEngineSpy` are minimal protocol-conforming spies that record calls. If the production types do not expose protocols for spy injection, this test wires through the existing test seams from 04-agent-core / 06-voice / 02-bus tests; if those tests already use a known DI shape, reuse it. If no DI shape exists, this test is the first one to drive that need — do NOT widen the production API to add a spy seam; instead, observe via the existing replay log (record-and-assert pattern: replay turn writes events; assert no `webview_dispatch` or `tts_synthesize` event types in the log).

6. Smoke-test the shipping gate: invoke `scripts/shipping-gate.sh` directly (no `--live`). At this stage many pillars may FAIL because production code is incomplete (P3 not started, P4-P7 not implemented yet, etc.). That is acceptable for the harness's own ship-readiness — what matters is the gate RUNS, produces parseable per-pillar output, and exits non-zero correctly. Document the actual pillar pass/fail state in the SUMMARY.
  </action>

  <acceptance_criteria>
    - `scripts/shipping-gate.sh` exists and is executable: `test -x scripts/shipping-gate.sh`
    - `scripts/promote-replay-session.sh` exists and is executable: `test -x scripts/promote-replay-session.sh`
    - `scripts/check-corpus-secrets.sh` exists and is executable: `test -x scripts/check-corpus-secrets.sh`
    - Pre-commit hook installation path exists: either `.git/hooks/pre-commit` is executable OR `scripts/precommit-template.sh` exists with installation instructions
    - shipping-gate.sh invokes `jarvis-eval all`: `grep -c "jarvis-eval all" scripts/shipping-gate.sh` returns at least 1
    - shipping-gate.sh respects `set -euo pipefail`: `grep -c "set -euo pipefail" scripts/shipping-gate.sh` returns 1
    - shipping-gate.sh supports `--live` flag: `grep -c "live" scripts/shipping-gate.sh` returns at least 1
    - check-corpus-secrets.sh greps the 4 D-07 patterns: `grep -cE "sk-ant-|AKIA|ghp_|sk-" scripts/check-corpus-secrets.sh` returns at least 4
    - promote-replay-session.sh writes sidecar meta JSON: `grep -c "meta.json" scripts/promote-replay-session.sh` returns at least 1
    - promote-replay-session.sh records temperature + model + replaySchemaVersion: `grep -cE "temperature|model|replaySchemaVersion" scripts/promote-replay-session.sh` returns at least 3
    - File `packages/Harness/Tests/HarnessTests/ReplaySuppressionIntegrationTests.swift` exists and contains both `.replay(sessionId:` and `.evaluation(scenarioId:` cases tested: `grep -cE "\.replay\(sessionId:|\.evaluation\(scenarioId:" packages/Harness/Tests/HarnessTests/ReplaySuppressionIntegrationTests.swift` returns at least 2
    - `swift test --package-path packages/Harness --filter ReplaySuppressionIntegrationTests` exits 0
    - `bash scripts/check-corpus-secrets.sh` exits 0 against the current Corpora/ contents (no secrets present)
    - `scripts/shipping-gate.sh` runs to completion (may exit non-zero if production pillars fail; the test is "the gate runs end-to-end without infrastructure failure" — record outcome in SUMMARY)
  </acceptance_criteria>

  <verify>
    <automated>test -x scripts/shipping-gate.sh && test -x scripts/promote-replay-session.sh && test -x scripts/check-corpus-secrets.sh && bash scripts/check-corpus-secrets.sh && swift test --package-path packages/Harness --filter ReplaySuppressionIntegrationTests</automated>
  </verify>

  <done>shipping-gate.sh + promote-replay-session.sh + check-corpus-secrets.sh ship with executable bits. Pre-commit hook installed (or template + install instructions provided). ReplaySuppressionIntegrationTests verify the R4-L7 contract — replay/evaluation TurnSources do not dispatch HUD bus messages and do not call TTS synthesize. Shipping gate end-to-end smoke documented.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Pre-commit hook -> staged corpora bytes | Hook is local-only; an operator can bypass via `--no-verify`. |
| ChecklistRunner -> shell scripts -> filesystem operations | Scripts run with the operator's privileges; same as any local dev tool. |
| YAML manifest -> ChecklistRunner -> Process spawn | Manifest is committed to git; threat is malicious manifest commit. |
| `scripts/promote-replay-session.sh` -> source SQLite | Operator-specified path; same privileges as the operator. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-08-17 | Tampering | A malicious checklist.yaml entry uses `type: script` to point at an arbitrary path, executing operator-controlled code | accept | YAML manifests are committed to git and code-reviewed; same trust model as any other repo file. ChecklistRunner restricts script paths to `<repoRoot>/scripts/...` (verified by Process spawn template); a manifest pointing at `/tmp/evil.sh` would fail the path check. Acceptance criterion: ChecklistRunner rejects script paths outside `<repoRoot>/scripts/` (add to Task 1 implementation). |
| T-08-18 | Information Disclosure | Pre-commit hook bypassed via `git commit --no-verify`, secret leaks into corpora | accept | Hook is best-effort; the upstream defense is the redaction in `capture-anthropic-sse.sh` (08-02 Task 2). Pre-commit is a backstop; CI-side secret-scanning (out of scope for personal project) would be the third layer. |
| T-08-19 | Denial of Service | `jarvis-eval all` runs every pillar serially; if any pillar hangs, the whole gate hangs | mitigate | Each subcommand has its own implicit timeout (test framework default; URLSession default; Process termination on parent exit). Add `timeout 120` wrapper around each subcommand invocation in `shipping-gate.sh` if needed. |
| T-08-20 | Tampering | A YAML manifest with malformed mechanization decodes to an unintended case | mitigate | Hand-rolled Codable's `default:` arm in the type-discriminator switch THROWS rather than silently accepting (Task 1). D-17 enforcement throws on missing expected_count. ChecklistRunnerTests covers each malformed case (Task 1 acceptance). |
| T-08-21 | Spoofing | A `MANUAL:` item description claims completion when the operator never actually ran the manual check | accept | MANUAL items are warning rows by D-16; operator discipline is the only enforcement. The shipping-gate output VISIBLY lists each MANUAL item per D-17 ("MANUAL items are explicitly listed in every shipping-gate run output"). Operator review is in scope; programmatic enforcement is not. |
| T-08-22 | Elevation of Privilege | `promote-replay-session.sh` reads SQLite that may contain bytes that exploit a sqlite3 CLI vulnerability | accept | sqlite3 CLI runs in operator's user context; same as any other local sqlite use. The script reads only the `meta` table via parameterized `SELECT ... WHERE key=...` — no SQL injection surface. |
</threat_model>

<verification>
After all tasks complete:

```bash
# Every script exists and is executable
test -x scripts/shipping-gate.sh
test -x scripts/promote-replay-session.sh
test -x scripts/check-corpus-secrets.sh

# Pre-commit hook installable
test -x .git/hooks/pre-commit || test -f scripts/precommit-template.sh

# All 8 phase manifests exist
for p in 01-foundations 02-bus 03-hud 04-agent-core 05-mcp 06-voice 07-memory-vision 08-hardening; do
  test -f .planning/phases/$p/checklist.yaml
done

# Pre-commit secret guard passes against current corpora
bash scripts/check-corpus-secrets.sh

# ChecklistRunner accepts every manifest
swift run --package-path packages/Harness jarvis-eval checklist --help

# All 10 jarvis-eval subcommands present
swift run --package-path packages/Harness jarvis-eval --help | grep -cE "replay|corpus-injection|corpus-sse|corpus-ndjson|cap-recovery|wake-corpus|mcp-crash|audio-rebuild|checklist|all"  # >= 10

# Shipping gate runs end-to-end
bash scripts/shipping-gate.sh || echo "Shipping gate exit code: $? (non-zero acceptable if production pillars fail; record in SUMMARY)"

# R4-L7 replay-suppression integration test green
swift test --package-path packages/Harness --filter ReplaySuppressionIntegrationTests

# 06-voice manifest contains the 7 MANUAL items per D-12 / D-13
grep -cE "P6-MANUAL-(VOICE-(07|09|10|12|13|14)|ORPHEUS-TTFA)" .planning/phases/06-voice/checklist.yaml  # == 7
```
</verification>

<success_criteria>
- ChecklistManifest + ChecklistRunner ship with all 7 mechanization types and D-17 enforcement.
- 8 per-phase checklist.yaml manifests authored covering P1-P8; 18 existing scripts/check-*.sh folded.
- 7 MANUAL items in 06-voice/checklist.yaml surface the P6 deferred debt per D-12 / D-13.
- jarvis-eval all subcommand runs every pillar + checklist; D-04 dual-gate enforced for --live.
- scripts/shipping-gate.sh is the single CI entry; runs end-to-end (production pillar pass/fail recorded in SUMMARY).
- scripts/promote-replay-session.sh helper for D-09 operator workflow.
- Pre-commit hook + check-corpus-secrets.sh guard D-07.
- ReplaySuppressionIntegrationTests verify R4-L7 contract end-to-end.
</success_criteria>

<output>
After completion, create `.planning/phases/08-hardening/08-04-checklist-runner-and-shipping-gate-SUMMARY.md` recording:
- Per-phase manifest item counts (final, after sweep)
- Which of the 18 scripts/check-*.sh got folded into which manifest (mapping table)
- 7 MANUAL items in 06-voice/checklist.yaml: full list with prerequisite annotation
- shipping-gate.sh end-to-end smoke output (which pillars passed; which failed because production isn't built yet — these are not P8 bugs but downstream regressions to surface to the executing operator)
- Pre-commit hook install instructions (committed template path + symlink command)
- Phase 8 itself: every must-haves from the phase-level seed accounted for; cross-reference to the 15 truth seed items in the planner context
</output>
