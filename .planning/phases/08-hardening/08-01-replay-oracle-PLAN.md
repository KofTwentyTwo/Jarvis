---
phase: 08-hardening
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - packages/Harness/Package.swift
  - packages/Harness/Sources/Harness/Oracle/ExclusionList.swift
  - packages/Harness/Sources/Harness/Oracle/DriftReport.swift
  - packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift
  - packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift
  - packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift
  - packages/Harness/Sources/Harness/Runners/ReplayRunner.swift
  - packages/Harness/Sources/jarvis-eval/main.swift
  - packages/Harness/Tests/HarnessTests/DriftClassifierTests.swift
  - packages/Harness/Tests/HarnessTests/ExclusionListTests.swift
  - packages/Harness/Corpora/replay-golden/exclusions.json
  - packages/Replay/Sources/Replay/ReplayEvent.swift
  - project.yml
autonomous: true
requirements: [OBS-03]
must_haves:
  truths:
    - "D-01: covered by this plan (citation for decision-coverage gate)"
    - "D-02: covered by this plan (citation for decision-coverage gate)"
    - "D-03: covered by this plan (citation for decision-coverage gate)"
    - "D-08: covered by this plan (citation for decision-coverage gate)"
    - "D-11: covered by this plan (citation for decision-coverage gate)"
    - "D-20: covered by this plan (citation for decision-coverage gate)"
    - "packages/Harness SPM module exists with library + executable targets"
    - "TurnSource enum extended with .replay(sessionId:) and .evaluation(scenarioId:) per Strategy B"
    - "Replay and evaluation cases suppress dispatchesToHUD and speaks (return false)"
    - "ReplayMCPAdapter conforms to MCPToolDispatcher and reads recorded tool results from a SQLite replay row"
    - "MockLLMProvider conforms to LLMProvider and reads SSE/NDJSON fixture bytes through real decoders"
    - "DriftClassifier separates expected (alwaysExcluded + nondeterministicUnderSampling under temp>0) vs unexpected drift"
    - "DriftReport.passed iff unexpected.isEmpty"
    - "jarvis-eval replay <session.sqlite> CLI subcommand exists and returns drift report (single-session today; --all flag for full historical replay deferred per D-10 opt-in audit)"
    - "Replay schema versioning: oracle rejects logs with replaySchemaVersion < pinned constant with re-record error"
  artifacts:
    - path: "packages/Harness/Package.swift"
      provides: "library + executable + test target manifest"
      contains: "Harness"
    - path: "packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift"
      provides: "pure classify() function over recorded vs actual replay DBs"
      exports: ["DriftClassifier", "classify"]
    - path: "packages/Harness/Sources/Harness/Oracle/ExclusionList.swift"
      provides: "OBS-02 alwaysExcluded set + nondeterministicUnderSampling set"
      exports: ["ExclusionList"]
    - path: "packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift"
      provides: "MCPToolDispatcher conformance reading from recorded session"
      exports: ["ReplayMCPAdapter"]
    - path: "packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift"
      provides: "LLMProvider conformance over fixture bytes"
      exports: ["MockLLMProvider"]
    - path: "packages/Harness/Sources/jarvis-eval/main.swift"
      provides: "@main JarvisEval AsyncParsableCommand with replay subcommand"
      exports: ["JarvisEval", "Replay"]
    - path: "packages/Replay/Sources/Replay/ReplayEvent.swift"
      provides: "TurnSource extended with replay/evaluation cases (Strategy B)"
      contains: "case replay(sessionId:"
    - path: "packages/Harness/Corpora/replay-golden/exclusions.json"
      provides: "JSON-encoded ExclusionList seed (alwaysExcluded from OBS-02 + empty nondeterministicUnderSampling)"
      contains: "row_id"
  key_links:
    - from: "packages/Harness/Sources/Harness/Runners/ReplayRunner.swift"
      to: "packages/AgentCore (AgentOrchestrator.submit with .replay TurnSource)"
      via: "real orchestrator submit, not a simulator"
      pattern: "submit.*\\.replay"
    - from: "packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift"
      to: "packages/AgentCore (SSEDecoder + OllamaProvider NDJSON decoder)"
      via: "real decoders over fixture bytes"
      pattern: "SSEDecoder|NDJSON"
    - from: "packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift"
      to: "packages/MCP (MCPToolDispatcher protocol)"
      via: "protocol conformance"
      pattern: "MCPToolDispatcher"
    - from: "packages/Harness/Sources/jarvis-eval/main.swift"
      to: "packages/Harness Runners + Oracle"
      via: "ArgumentParser AsyncParsableCommand subcommand dispatch"
      pattern: "AsyncParsableCommand"
---

<phase_goal>
Phase 8 delivers shipping gates over the v1 pipeline. Plan 08-01 builds the harness substrate
(packages/Harness SPM module + jarvis-eval CLI shell + replay-roundtrip oracle) that all
subsequent plans (08-02, 08-03, 08-04) consume. Proves OBS-03 in full: a replay viewer that
re-runs recorded sessions through the REAL AgentOrchestrator via .replay TurnSource, and a
DriftClassifier that separates expected drift (IDs/timestamps/sampling under temp>0) from
unexpected drift (schema/ordering/truncation/value bugs). PASS iff `unexpected.isEmpty`.
</phase_goal>

<truths>
This plan executes against these LOCKED context decisions (08-CONTEXT.md):

- **D-01:** Four-plan decomposition; 08-01 builds the harness substrate + ReplayRunner + DriftClassifier + ExclusionList + DriftReport + ReplayMCPAdapter + MockLLMProvider + jarvis-eval CLI shell with `replay` subcommand + TurnSource extension.
- **D-02:** New `packages/Harness` SPM module — library target `Harness` + executable target `jarvis-eval` + tests-of-the-harness target `HarnessTests` + `Corpora/` directory copied as resources.
- **D-03:** New P8 suites use `swift-testing` (Xcode 26 bundled). DriftClassifierTests, ExclusionListTests use `import Testing` + `@Test(arguments:)`.
- **D-08:** Replay golden corpus at `packages/Harness/Corpora/replay-golden/` will hold 5–10 hand-selected sessions covering archetypes (short turn, long multi-tool turn, cap-recovery, confirmation-approved, confirmation-denied, voice barge-in, stream-truncation retry, vision frame-attach). 08-01 ships the empty directory + the JSON-format `exclusions.json` sidecar; sessions are operator-promoted later via `scripts/promote-replay-session.sh` (ships in 08-04 sweep).
- **D-10:** Full historical replay (`--all`) is opt-in audit only. The shipping gate runs only the curated subset.
- **D-11:** Replay schema versioning. ReplayRunner reads `replaySchemaVersion` from the log header and rejects older-version logs with a clear `"re-record after refactor X"` error rather than failing on every historical session. P4's writer already emits this field (verify at first compile; if absent, this plan adds the read-side check that requires it; the writer-side change is a separate cross-cutting plan, not P8 scope).
- **D-20:** Drift classifier exclusion list inherits OBS-02 set verbatim (`row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce`). The `nondeterministicUnderSampling` set starts empty in `Corpora/replay-golden/exclusions.json` and is populated empirically when golden corpus replays surface false positives (08-02+).

**TurnSource Strategy: Strategy B (LOCKED).** Per orchestrator's locked decision in the planner context (overrides PATTERNS.md §2.2 Strategy A recommendation): associated-value cases `case replay(sessionId: UUID)` and `case evaluation(scenarioId: String)` on TurnSource (the case is named "evaluation" rather than the reserved word, but its scenarioId payload is what carries the eval-mode discriminator); drop `String, RawRepresentable, CaseIterable` conformances; hand-roll the SQLite raw-string mapping; migrate every call site found via `grep -rn "switch.*source\\b" packages/ App/`. Rationale: replay's `sessionId` payload is consumed by ReplayMCPAdapter to look up recorded tool results; passing it via separate context (Strategy A) defeats the suppression-by-construction safety. PATTERNS.md §2.2 enumerates the call sites to migrate (`Replay/ReplayLog.swift` line 85 SQLite source column writer, `Memory/ExtractionJob.swift`, `Bus/BusOutbound.swift`, every `switch source` in AgentOrchestrator).

NOTE on naming: throughout this plan, "the eval case" and "the eval mode" refer to `TurnSource.evaluation(scenarioId:)`. The CLI executable is named `jarvis-eval` per D-02 / RESEARCH.md §System Architecture Diagram — this is a hyphenated executable name, not a Swift identifier. Inside Swift, prefer `evaluation` (full word) for the TurnSource case to avoid any tooling conflicts; the CLI tool's filesystem name remains `jarvis-eval`.
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
@CLAUDE.md
@packages/Memory/Package.swift
@packages/Replay/Sources/Replay/ReplayEvent.swift
@packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift
@packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift

<interfaces>
Key types and contracts the executor needs. Extracted from PATTERNS.md + RESEARCH.md.
Executor uses these directly — no codebase exploration needed for these specifics.

From packages/Replay/Sources/Replay/ReplayEvent.swift (current state, lines 7-11):

    public enum TurnSource: String, Sendable, Equatable, Hashable, CaseIterable {
        case text
        case voice
        case memoryExtraction
    }

After Strategy B migration:

    public enum TurnSource: Sendable, Equatable, Hashable {
        case text
        case voice
        case memoryExtraction
        case replay(sessionId: UUID)
        case evaluation(scenarioId: String)

        /// SQLite source column raw value. Hand-rolled because associated-value
        /// cases break String raw-representability synthesis.
        public var rawValue: String {
            switch self {
            case .text: return "text"
            case .voice: return "voice"
            case .memoryExtraction: return "memoryExtraction"
            case .replay: return "replay"
            case .evaluation: return "evaluation"
            }
        }

        /// R4-L7 suppression: replay/evaluation do not dispatch HUD events or speak.
        public var dispatchesToHUD: Bool {
            switch self {
            case .text, .voice: return true
            case .memoryExtraction, .replay, .evaluation: return false
            }
        }

        public var speaks: Bool {
            switch self {
            case .text, .voice: return true
            case .memoryExtraction, .replay, .evaluation: return false
            }
        }
    }

From packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift (analog state machine for DriftClassifier):

    struct SSEDecoder: Sendable {
        struct State { /* ... */ }
        static func dispatch(frame: SSEFrame, state: inout State, emit: (LLMEvent) -> Void) {
            switch frame.event {
            case "message_start": ...
            // exhaustive switch over event types, no default
            }
        }
    }

OBS-02 exclusion list seed (D-20):

    alwaysExcluded = { row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce }
    nondeterministicUnderSampling = {} (empty seed; populated empirically)

From packages/MCP MCPToolDispatcher protocol — extract via grep at task start:

    grep -A 10 "protocol MCPToolDispatcher" packages/MCP/Sources/MCP/*.swift

From packages/AgentCore LLMProvider protocol — extract via grep at task start:

    grep -A 20 "protocol LLMProvider" packages/AgentCore/Sources/AgentCore/*.swift
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Scaffold packages/Harness SPM module + extend TurnSource (Strategy B)</name>

  <read_first>
    - packages/Memory/Package.swift (analog manifest — multi-dependency package shape)
    - packages/Replay/Sources/Replay/ReplayEvent.swift (TurnSource current shape, lines 1-50; ReplayLog source column writer line ~85)
    - packages/Replay/Sources/Replay/ReplayLog.swift (find `source.rawValue` write site)
    - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift (every `switch source` site)
    - packages/Memory/Sources/Memory/ExtractionJob.swift (TurnSource consumer)
    - packages/Bus/Sources/Bus/BusOutbound.swift (TurnSource consumer if present)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.1 (Package.swift template) and §2.2 (Strategy B shape)
    - project.yml (read top to find packages: block layout)
  </read_first>

  <files>packages/Harness/Package.swift, packages/Replay/Sources/Replay/ReplayEvent.swift, project.yml, packages/Harness/Sources/Harness/Placeholder.swift, packages/Harness/Sources/jarvis-eval/main.swift, packages/Harness/Tests/HarnessTests/PlaceholderTests.swift, packages/Harness/Corpora/.gitkeep</files>

  <action>
1. Create `packages/Harness/Package.swift` per PATTERNS.md §2.1 (full template). Required dependencies (mirror Memory/Package.swift exactly): `../Logging`, `../Config`, `../AgentCore`, `../Replay`, `../MCP`, `../Voice`, `../Memory`, `../DevOverlay`, `apple/swift-log 1.5.0+`, `apple/swift-argument-parser 1.5.0+`. Three targets:
   - `.target(name: "Harness", dependencies: [...all of the above as products...], path: "Sources/Harness", resources: [.copy("../../Corpora")], swiftSettings: [.swiftLanguageMode(.v6)])`
   - `.executableTarget(name: "jarvis-eval", dependencies: ["Harness", .product(name: "ArgumentParser", package: "swift-argument-parser")], path: "Sources/jarvis-eval", swiftSettings: [.swiftLanguageMode(.v6)])`
   - `.testTarget(name: "HarnessTests", dependencies: ["Harness"], path: "Tests/HarnessTests", swiftSettings: [.swiftLanguageMode(.v6)])`
   Platforms: `[.macOS(.v14)]` (matches Voice/Memory).
   tools-version line 1: `// swift-tools-version:6.0`.

2. Create stub source files so `swift build --package-path packages/Harness` succeeds before tasks 2-3 add real code:
   - `packages/Harness/Sources/Harness/Placeholder.swift` — single `public enum HarnessVersion { public static let value = "0.1.0" }` so the library target compiles.
   - `packages/Harness/Sources/jarvis-eval/main.swift` — minimal `@main struct JarvisEval: AsyncParsableCommand` with `static let configuration = CommandConfiguration(commandName: "jarvis-eval", abstract: "Phase 8 evaluation harness")` and an empty `subcommands: []` array. Add `import ArgumentParser` and `import Harness`. Real subcommands land in tasks 2-3 of this plan + 08-02/08-03/08-04.
   - `packages/Harness/Tests/HarnessTests/PlaceholderTests.swift` — single `import Testing` + `@Test func smoke() { #expect(HarnessVersion.value == "0.1.0") }`.
   - `packages/Harness/Corpora/.gitkeep` (empty file so the directory exists for resource copying).

3. Migrate TurnSource per Strategy B. Replace lines 7-11 of `packages/Replay/Sources/Replay/ReplayEvent.swift` with the exact shape in the `<interfaces>` block above (TurnSource enum with associated-value cases `.replay(sessionId: UUID)` and `.evaluation(scenarioId: String)`, hand-rolled `rawValue`, `dispatchesToHUD`, `speaks`). Drop `String, RawRepresentable, CaseIterable` conformances; keep `Sendable, Equatable, Hashable`. Use `UUID` for `sessionId` (NOT a typealias to `SessionID` unless `SessionID` already aliases `UUID` — confirm by reading the existing imports at the top of ReplayEvent.swift before deciding; if `SessionID = UUID` is not already defined, use `UUID` directly).

4. Migrate every TurnSource consumer that breaks under Strategy B:
   - `packages/Replay/Sources/Replay/ReplayLog.swift`: any `source.rawValue` write site continues to compile (rawValue is now hand-rolled — same string output for `.text/.voice/.memoryExtraction`; new strings `"replay"` / `"evaluation"` for the new cases).
   - Every `switch source` over `TurnSource` in `packages/AgentCore/`, `packages/Memory/`, `packages/Bus/`: add `case .replay`, `case .evaluation` arms. For HUD/TTS dispatch sites, gate on `source.dispatchesToHUD` / `source.speaks` instead of explicit case matching where applicable. Run `grep -rn "switch.*source\\b" packages/ App/` after migration; every hit must compile.
   - DO NOT modify the bodies of orchestrator/MCP/Voice/Memory beyond adding the new exhaustive `case` arms (per cross-cutting concern §5.1 — Harness is read-only against runtime code outside this surgical TurnSource extension).
   - For any consumer that previously relied on `TurnSource.allCases` (CaseIterable), add a hand-rolled static `public static let cohortCases: [TurnSource] = [.text, .voice, .memoryExtraction]` ONLY if a consumer needs it; otherwise delete the dependency. The `.replay`/`.evaluation` cases are runtime-only and not enumerable (each carries a unique payload).

5. Add `Harness:` package entry to `project.yml` `packages:` block, mirroring the `Memory:` and `Voice:` rows verbatim (path: `packages/Harness`, products: `Harness`). Also add `jarvis-eval` as a separate executable target reference if the project's xcodegen supports it; otherwise leave the executable target SPM-only and consumed by `swift run jarvis-eval ...` (the shipping-gate.sh path).
  </action>

  <acceptance_criteria>
    - `swift build --package-path packages/Harness` exits 0
    - `swift test --package-path packages/Harness --filter PlaceholderTests` exits 0 and the test passes
    - `swift run --package-path packages/Harness jarvis-eval --help` exits 0 and prints "Phase 8 evaluation harness"
    - `grep -c "case replay(sessionId:" packages/Replay/Sources/Replay/ReplayEvent.swift` returns 1
    - `grep -c "case evaluation(scenarioId:" packages/Replay/Sources/Replay/ReplayEvent.swift` returns 1
    - `grep -c "var dispatchesToHUD: Bool" packages/Replay/Sources/Replay/ReplayEvent.swift` returns 1
    - `grep -c "var speaks: Bool" packages/Replay/Sources/Replay/ReplayEvent.swift` returns 1
    - `grep -c ": String, Sendable, Equatable, Hashable, CaseIterable" packages/Replay/Sources/Replay/ReplayEvent.swift` returns 0 (Strategy B drops these conformances)
    - `grep -c "Harness:" project.yml` returns at least 1
    - Top-level repo `swift build` (or `xcodebuild -scheme Jarvis build` if SPM-only build is unavailable) exits 0 — proves every TurnSource consumer migrated cleanly
    - `grep -rn "switch.*source\\b" packages/ App/ | wc -l` is non-zero AND every hit compiles
    - File `packages/Harness/Package.swift` contains the strings `"Harness"`, `"jarvis-eval"`, `"HarnessTests"`, `"swift-argument-parser"`, `.copy("../../Corpora")`
  </acceptance_criteria>

  <verify>
    <automated>swift build --package-path packages/Harness && swift test --package-path packages/Harness --filter PlaceholderTests && swift run --package-path packages/Harness jarvis-eval --help</automated>
  </verify>

  <done>packages/Harness SPM module compiles with library + executable + test targets. TurnSource migrated to Strategy B with associated-value .replay / .evaluation cases, hand-rolled rawValue/dispatchesToHUD/speaks. project.yml lists Harness. Every TurnSource consumer migrated; whole-project build is green.</done>
</task>


<task type="auto">
  <name>Task 2: ExclusionList, DriftReport, DriftClassifier with unit tests</name>

  <read_first>
    - packages/Harness/Package.swift (just authored)
    - packages/Replay/Sources/Replay/ReplayEvent.swift (read post-Strategy-B; understand the row shape)
    - packages/Replay/Sources/Replay/ReplayLog.swift (read full file; understand SQLite row schema for the recorded vs actual diff)
    - packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift (analog state-machine pattern for DriftClassifier per PATTERNS.md §2.3)
    - packages/Replay/Sources/Replay/ReplayEvent.swift `encoded()` switch (analog for hand-rolled Codable, no `default` per S-1)
    - .planning/phases/08-hardening/08-RESEARCH.md §Pattern 2 (Drift Classification with Exclusion List) lines 278-318
    - .planning/phases/08-hardening/08-RESEARCH.md §Anti-Patterns line 350 (no string-diff)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.3 (DriftClassifier shape)
  </read_first>

  <files>
    packages/Harness/Sources/Harness/Oracle/ExclusionList.swift,
    packages/Harness/Sources/Harness/Oracle/DriftReport.swift,
    packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift,
    packages/Harness/Tests/HarnessTests/ExclusionListTests.swift,
    packages/Harness/Tests/HarnessTests/DriftClassifierTests.swift,
    packages/Harness/Corpora/replay-golden/exclusions.json
  </files>

  <action>
1. Create `packages/Harness/Sources/Harness/Oracle/ExclusionList.swift` with the following Swift content:

    import Foundation

    public struct ExclusionList: Sendable, Codable, Equatable {
        /// Fields whose drift is always expected (IDs, timestamps, nonces).
        /// Inherits OBS-02 list verbatim per D-20.
        public let alwaysExcluded: Set<String>

        /// Fields whose drift is expected ONLY if recording temperature > 0.
        /// Seed empty per D-20; populated empirically when golden replays surface false positives.
        public let nondeterministicUnderSampling: Set<String>

        public init(alwaysExcluded: Set<String>, nondeterministicUnderSampling: Set<String>) {
            self.alwaysExcluded = alwaysExcluded
            self.nondeterministicUnderSampling = nondeterministicUnderSampling
        }

        public static let obs02Default = ExclusionList(
            alwaysExcluded: [
                "row_id", "session_id", "turn_id", "tool_use_id",
                "message_id", "ts", "monotonic_ns", "turn_nonce"
            ],
            nondeterministicUnderSampling: []
        )

        public static func load(from url: URL) throws -> ExclusionList {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ExclusionList.self, from: data)
        }
    }

2. Create `packages/Harness/Sources/Harness/Oracle/DriftReport.swift`:

    import Foundation

    public enum DriftCategory: String, Sendable, Codable, CaseIterable {
        case idOrTimestamp           // in alwaysExcluded
        case samplingNondeterminism  // in nondeterministicUnderSampling AND temperature > 0
        case schemaChange            // JSON shape differs (key added/removed)
        case orderingBug             // same set, different order
        case truncationBug           // one side ends early
        case valueBug                // deterministic field changed
    }

    public struct DriftItem: Sendable, Codable, Equatable {
        public let rowOrdinal: Int
        public let field: String
        public let category: DriftCategory
        public let recorded: String
        public let actual: String
    }

    public struct DriftReport: Sendable, Codable, Equatable {
        public let expected: [DriftItem]    // idOrTimestamp + samplingNondeterminism
        public let unexpected: [DriftItem]  // schemaChange + orderingBug + truncationBug + valueBug
        public var passed: Bool { unexpected.isEmpty }
        public init(expected: [DriftItem], unexpected: [DriftItem]) {
            self.expected = expected; self.unexpected = unexpected
        }
    }

3. Create `packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift`. Pattern: pure static `classify` function per PATTERNS.md §2.3. Walks paired rows by ordinal position; for each field, consults `ExclusionList` and the `recordingTemperature`. Categorizes into the 6 `DriftCategory` cases. Static constant `supportedSchemaVersion: Int = 1` for D-11 enforcement. Skeleton:

    import Foundation
    import Replay

    public enum DriftClassifier {
        public static let supportedSchemaVersion: Int = 1

        public static func classify(
            recordedRows: [ReplayRow],
            actualRows: [ReplayRow],
            exclusions: ExclusionList,
            recordingTemperature: Double
        ) -> DriftReport {
            var expected: [DriftItem] = []
            var unexpected: [DriftItem] = []

            // Truncation: row counts differ
            if recordedRows.count != actualRows.count {
                unexpected.append(DriftItem(
                    rowOrdinal: min(recordedRows.count, actualRows.count),
                    field: "row_count",
                    category: .truncationBug,
                    recorded: String(recordedRows.count),
                    actual: String(actualRows.count)
                ))
            }
            for ((ordinal, recRow), actRow) in zip(recordedRows.enumerated(), actualRows) {
                classifyRow(ordinal: ordinal, rec: recRow, act: actRow,
                            exclusions: exclusions, temperature: recordingTemperature,
                            emitExpected: { expected.append($0) },
                            emitUnexpected: { unexpected.append($0) })
            }
            return DriftReport(expected: expected, unexpected: unexpected)
        }

        private static func classifyRow(
            ordinal: Int, rec: ReplayRow, act: ReplayRow,
            exclusions: ExclusionList, temperature: Double,
            emitExpected: (DriftItem) -> Void,
            emitUnexpected: (DriftItem) -> Void
        ) {
            // For each comparable field on ReplayRow:
            // 1. If field in exclusions.alwaysExcluded -> emitExpected(idOrTimestamp) iff differs
            // 2. Else if field in exclusions.nondeterministicUnderSampling AND temperature > 0
            //    -> emitExpected(samplingNondeterminism) iff differs
            // 3. Else if shape mismatch (different keys present) -> emitUnexpected(schemaChange)
            // 4. Else if value differs -> emitUnexpected(valueBug)
            // (orderingBug detection: separate pass over event_index sets per turn_id)
        }
    }

   Note: `ReplayRow` is whatever struct ReplayLog.swift exposes for read access. If it's not currently public, this task does NOT add a public reader; instead, define a local `ReplayRow` struct INSIDE Harness that mirrors the SQLite columns and is constructed from a SQLite query. The DriftClassifier signature can take `[ReplayRow]` defined in the Harness module; ReplayRunner (Task 3) handles the SQLite read.

4. Create `packages/Harness/Tests/HarnessTests/ExclusionListTests.swift` using swift-testing per D-03:

    import Testing
    import Foundation
    @testable import Harness

    @Suite("ExclusionListTests")
    struct ExclusionListTests {
        @Test("OBS-02 default contains all 8 OBS-02 fields")
        func obs02DefaultHasEightFields() {
            let list = ExclusionList.obs02Default
            let expected: Set<String> = ["row_id", "session_id", "turn_id", "tool_use_id",
                                          "message_id", "ts", "monotonic_ns", "turn_nonce"]
            #expect(list.alwaysExcluded == expected)
            #expect(list.nondeterministicUnderSampling.isEmpty)
        }

        @Test("Decodes from JSON sidecar")
        func decodesFromJSON() throws {
            let json = """
            {"alwaysExcluded":["row_id","ts"],"nondeterministicUnderSampling":["textDelta"]}
            """.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(ExclusionList.self, from: json)
            #expect(decoded.alwaysExcluded == ["row_id", "ts"])
            #expect(decoded.nondeterministicUnderSampling == ["textDelta"])
        }
    }

5. Create `packages/Harness/Tests/HarnessTests/DriftClassifierTests.swift` covering the 6 categories. Use `@Test(arguments:)` parameterization for the table-driven case set. At minimum write tests for:
   - Identical rows → empty drift report, passed = true
   - Drift in `row_id` only → categorized as `idOrTimestamp`, expected non-empty, unexpected empty, passed = true
   - Drift in `textDelta` with temperature > 0 AND `textDelta` in `nondeterministicUnderSampling` → categorized as `samplingNondeterminism`, passed = true
   - Drift in `textDelta` with temperature == 0 (greedy) → categorized as `valueBug`, passed = false
   - Recorded has 5 rows, actual has 3 → `truncationBug`, passed = false
   - Schema change (extra key in actual) → `schemaChange`, passed = false
   - Value change in `tool_call_args.command` (deterministic field) → `valueBug`, passed = false
   - Ordering bug: same set of tool_calls in different order → `orderingBug`, passed = false (write only if your row pairing algorithm supports the detection; otherwise document as a known limitation in the test file's `@Suite` doc-comment and add a `@Test(.disabled)` placeholder)

6. Create `packages/Harness/Corpora/replay-golden/exclusions.json` with the OBS-02 default seed:

    {
      "alwaysExcluded": ["row_id", "session_id", "turn_id", "tool_use_id", "message_id", "ts", "monotonic_ns", "turn_nonce"],
      "nondeterministicUnderSampling": []
    }
  </action>

  <acceptance_criteria>
    - File `packages/Harness/Sources/Harness/Oracle/ExclusionList.swift` contains `public struct ExclusionList: Sendable, Codable`
    - File `packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift` contains `public enum DriftClassifier` and `public static func classify(`
    - File `packages/Harness/Sources/Harness/Oracle/DriftReport.swift` contains `public struct DriftReport` and `public var passed: Bool { unexpected.isEmpty }`
    - `grep -c "case idOrTimestamp" packages/Harness/Sources/Harness/Oracle/DriftReport.swift` returns 1
    - `grep -c "case samplingNondeterminism" packages/Harness/Sources/Harness/Oracle/DriftReport.swift` returns 1
    - `grep -c "case schemaChange" packages/Harness/Sources/Harness/Oracle/DriftReport.swift` returns 1
    - `grep -c "case orderingBug" packages/Harness/Sources/Harness/Oracle/DriftReport.swift` returns 1
    - `grep -c "case truncationBug" packages/Harness/Sources/Harness/Oracle/DriftReport.swift` returns 1
    - `grep -c "case valueBug" packages/Harness/Sources/Harness/Oracle/DriftReport.swift` returns 1
    - File `packages/Harness/Corpora/replay-golden/exclusions.json` exists; `jq -r '.alwaysExcluded | length' packages/Harness/Corpora/replay-golden/exclusions.json` returns 8
    - `swift test --package-path packages/Harness --filter ExclusionListTests` exits 0
    - `swift test --package-path packages/Harness --filter DriftClassifierTests` exits 0
    - DriftClassifier never uses `default:` in its `switch` over `DriftCategory` (S-1 invariant): `grep -E '^\s*default:' packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift | grep -v '^#' | wc -l` returns 0
  </acceptance_criteria>

  <verify>
    <automated>swift test --package-path packages/Harness --filter ExclusionListTests && swift test --package-path packages/Harness --filter DriftClassifierTests</automated>
  </verify>

  <done>ExclusionList + DriftReport + DriftClassifier compile and unit tests pass for all 6 drift categories. exclusions.json sidecar committed with OBS-02 default seed.</done>
</task>


<task type="auto">
  <name>Task 3: ReplayMCPAdapter + MockLLMProvider + ReplayRunner + jarvis-eval replay subcommand</name>

  <read_first>
    - packages/MCP/Sources/MCP/MCPToolDispatcher.swift (or equivalent — find via `grep -rn "protocol MCPToolDispatcher" packages/MCP/`)
    - packages/AgentCore/Sources/AgentCore/LLMProvider.swift (find via `grep -rn "protocol LLMProvider" packages/AgentCore/`)
    - packages/AgentCore/Tests/AnthropicProviderTests/FixtureReplayTests.swift lines 30-58 (analog for MockLLMProvider per PATTERNS.md §2.4)
    - packages/AgentCore/Sources/AnthropicProvider/SSELineReader.swift (read full)
    - packages/AgentCore/Sources/AnthropicProvider/SSEDecoder.swift (read full)
    - packages/AgentCore/Sources/OllamaProvider/OllamaProvider.swift (find the NDJSON decoder shape for the OllamaProvider mock variant)
    - packages/Memory/Sources/Memory/MemoryOrchestrator.swift (analog for ReplayRunner per PATTERNS.md §2.10 — background actor driving AgentOrchestrator)
    - packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift (find `submit` signature; understand how TurnSource is consumed)
    - packages/Replay/Sources/Replay/ReplayLog.swift (SQLite read API; find existing reader OR implement read via raw SQLite calls)
    - packages/Harness/Sources/Harness/Oracle/{ExclusionList,DriftReport,DriftClassifier}.swift (just authored)
    - .planning/phases/08-hardening/08-PATTERNS.md §2.4, §2.10, §2.12
    - .planning/phases/08-hardening/08-RESEARCH.md §Code Examples (lines 466-505 — Replay subcommand seed)
  </read_first>

  <files>
    packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift,
    packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift,
    packages/Harness/Sources/Harness/Runners/ReplayRunner.swift,
    packages/Harness/Sources/jarvis-eval/main.swift
  </files>

  <action>
1. Create `packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift`. Conforms to whichever protocol the production MCPClient implements (find via `grep`; expected name `MCPToolDispatcher`). Reads recorded tool results from the input session's SQLite by `(turn_id, tool_use_id)` lookup. On a `callTool` request, returns the recorded `tool_result` content bytes; if no match, throws `ReplayMCPAdapter.Error.recordedResultNotFound(turnId:, toolUseId:)`. No process spawning — this is the pure replay adapter. Skeleton:

    import Foundation
    import MCP  // or whatever module hosts MCPToolDispatcher

    public actor ReplayMCPAdapter: MCPToolDispatcher {
        private let recordedDB: ReplayDB

        public enum Error: Swift.Error, Equatable {
            case recordedResultNotFound(turnId: UUID, toolUseId: String)
            case schemaVersionMismatch(found: Int, expected: Int)
        }

        public init(recordedSessionURL: URL) throws {
            self.recordedDB = try ReplayDB.open(url: recordedSessionURL)
            guard recordedDB.schemaVersion == DriftClassifier.supportedSchemaVersion else {
                throw Error.schemaVersionMismatch(
                    found: recordedDB.schemaVersion,
                    expected: DriftClassifier.supportedSchemaVersion
                )
            }
        }

        public func callTool(...) async throws -> ToolResult {
            // Look up recorded row by (turnId, toolUseId); return its tool_result bytes
        }
    }

   Define `ReplayDB` as a tiny local read-only SQLite wrapper. If `packages/Replay` exposes a public reader API, use it; otherwise add a small `internal struct ReplayDB` here that opens the SQLite via raw `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)`. Capture `replaySchemaVersion` from the meta table at open.

2. Create `packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift` per PATTERNS.md §2.4. Conforms to `LLMProvider`. Reads SSE bytes from a `.sse` file OR NDJSON bytes from a `.ndjson` file (kind discriminated by an explicit init parameter). Streams `LLMEvent` through the REAL `SSEDecoder` (Anthropic) or REAL OllamaProvider's NDJSON decoder. Skeleton:

    import Foundation
    import AgentCore
    import AnthropicProvider
    import OllamaProvider

    public actor MockLLMProvider: LLMProvider {
        public enum FixtureKind: Sendable {
            case anthropicSSE
            case ollamaNDJSON
        }

        private let fixtureURL: URL
        private let kind: FixtureKind

        public init(fixtureURL: URL, kind: FixtureKind) {
            self.fixtureURL = fixtureURL
            self.kind = kind
        }

        public nonisolated func stream(/* match LLMProvider.stream signature exactly */)
            -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        let data = try Data(contentsOf: self.fixtureURL)
                        switch self.kind {
                        case .anthropicSSE:
                            try await self.streamSSE(bytes: data, to: continuation)
                        case .ollamaNDJSON:
                            try await self.streamNDJSON(bytes: data, to: continuation)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        private func streamSSE(bytes: Data, to continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
            // Mirror FixtureReplayTests.swift lines 33-58 verbatim:
            // AsyncStream<UInt8> over data → SSELineReader → SSEDecoder.dispatch → emit
        }

        private func streamNDJSON(bytes: Data, to continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
            // Mirror OllamaProviderTests/FixtureReplayTests.swift counterpart
        }
    }

   Caveat per PATTERNS.md §2.4: do NOT use a vacuous mock that returns `"OK"`. The fixture-bytes path goes through the REAL decoders so the SSE/NDJSON byte-level contract is exercised.

3. Create `packages/Harness/Sources/Harness/Runners/ReplayRunner.swift`. Background actor per PATTERNS.md §2.10 (analog: `MemoryOrchestrator`). Drives `AgentOrchestrator.submit(.replay(sessionId: recorded.sessionId))` against:
   - LLMProvider: `MockLLMProvider` over the recorded SSE/NDJSON bytes (extracted from the recorded session's SQLite blob columns OR embedded fixtures — details depend on whether `packages/Replay` stores raw SSE or just decoded events; if just decoded events, this runner takes a separate `--fixture` path argument or replays from the events directly without re-running the decoder).
   - MCPDispatcher: `ReplayMCPAdapter(recordedSessionURL: input)`.
   - ReplayLog destination: `/tmp/jarvis-eval-{UUID}.sqlite` (the "actual" log).
   On completion, opens both SQLite files (recorded + actual), loads the OBS-02 default `ExclusionList` (or sidecar `exclusions.json` if present next to the recorded session), and calls `DriftClassifier.classify(...)`. Skeleton:

    import Foundation
    import AgentCore
    import Replay

    public actor ReplayRunner {
        public struct ReplayResult: Sendable {
            public let recordedURL: URL
            public let actualURL: URL
            public let report: DriftReport
        }

        public func run(recordedSessionURL: URL, exclusionsURL: URL?) async throws -> ReplayResult {
            // 1. Open recorded SQLite, read meta (sessionId, temperature, replaySchemaVersion)
            // 2. Verify replaySchemaVersion == DriftClassifier.supportedSchemaVersion (D-11 reject older)
            // 3. Build orchestrator with MockLLMProvider over recorded fixture bytes + ReplayMCPAdapter
            // 4. Submit replay turns: source = .replay(sessionId: recorded.sessionId)
            // 5. Wait for orchestrator drain; capture actual replay log URL
            // 6. Load exclusions (default or sidecar)
            // 7. classify(recorded, actual, exclusions, recordingTemperature: recorded.meta.temperature)
        }
    }

4. Update `packages/Harness/Sources/jarvis-eval/main.swift` to register the `Replay` subcommand. Replace the empty `subcommands: []` list with `subcommands: [Replay.self]`. Implement `Replay`:

    import ArgumentParser
    import Foundation
    import Harness

    struct Replay: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "replay",
            abstract: "Re-run a recorded session through the real pipeline; flag drift."
        )

        @Argument(help: "Path to recorded session SQLite file.")
        var sessionDB: String

        @Option(help: "Path to ExclusionList JSON; defaults to OBS-02 default.")
        var exclusions: String?

        @Flag(help: "Verbose drift output.")
        var verbose: Bool = false

        func run() async throws {
            let recordedURL = URL(fileURLWithPath: sessionDB)
            let exclusionsURL = exclusions.map { URL(fileURLWithPath: $0) }
            let runner = ReplayRunner()
            let result = try await runner.run(recordedSessionURL: recordedURL, exclusionsURL: exclusionsURL)

            if result.report.passed {
                print("REPLAY PASS: \(result.report.expected.count) expected drifts (ID/timestamp/sampling).")
            } else {
                print("REPLAY FAIL:")
                for item in result.report.unexpected {
                    print("  [\(item.category.rawValue)] \(item.field): \(item.recorded) -> \(item.actual)")
                }
                throw ExitCode.failure
            }
            if verbose {
                print("Recorded: \(result.recordedURL.path)")
                print("Actual:   \(result.actualURL.path)")
            }
        }
    }
  </action>

  <acceptance_criteria>
    - File `packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift` exists and contains `: MCPToolDispatcher` conformance (substring); contains `case schemaVersionMismatch` enum case
    - File `packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift` exists and contains `: LLMProvider` conformance; contains both `case anthropicSSE` and `case ollamaNDJSON`
    - File `packages/Harness/Sources/Harness/Runners/ReplayRunner.swift` exists and contains `public actor ReplayRunner`
    - `grep -c "DriftClassifier.classify" packages/Harness/Sources/Harness/Runners/ReplayRunner.swift` returns at least 1
    - `grep -cE "submit.*\.replay" packages/Harness/Sources/Harness/Runners/ReplayRunner.swift` returns at least 1
    - `grep -cE "schemaVersionMismatch|supportedSchemaVersion" packages/Harness/Sources/Harness/Runners/ReplayRunner.swift` returns at least 1 (D-11 enforcement)
    - `swift run --package-path packages/Harness jarvis-eval replay --help` exits 0 and prints "Re-run a recorded session"
    - `swift build --package-path packages/Harness` exits 0
    - `swift run --package-path packages/Harness jarvis-eval --help | grep -c "replay"` returns at least 1
    - MockLLMProvider does NOT use a vacuous "OK" return (anti-pattern guard): `grep -c '"OK"' packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift` returns 0
  </acceptance_criteria>

  <verify>
    <automated>swift build --package-path packages/Harness && swift run --package-path packages/Harness jarvis-eval replay --help && swift run --package-path packages/Harness jarvis-eval --help | grep -q replay</automated>
  </verify>

  <done>ReplayMCPAdapter + MockLLMProvider + ReplayRunner compile and integrate with the real AgentOrchestrator via .replay TurnSource. jarvis-eval replay subcommand wires the runner to a CLI entry. D-11 schema-version check rejects older replays. End-to-end replay against a synthetic minimal session returns a DriftReport.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Harness CLI -> file system | `jarvis-eval replay <path>` reads arbitrary user-supplied SQLite paths. Path traversal not a concern (single-user host, operator-supplied). |
| ReplayMCPAdapter -> recorded SQLite | Recorded tool_result bytes are replayed verbatim into the orchestrator's sanitize+wrap pipeline; the SEC-07 boundary remains in front of the LLM, so no new ingress trust. |
| MockLLMProvider -> SSE/NDJSON fixture file | Fixture bytes are decoded by the REAL decoder; an attacker who can plant a malicious fixture file could drive arbitrary LLMEvent sequences into the orchestrator. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-08-01 | Tampering | DriftClassifier exclusion list (regex/field whitelist) becomes stale, masking real drift as "expected" | mitigate | `ExclusionListTests` asserts the OBS-02 default set has exactly 8 fields; any addition forces a test update + commit-message audit trail (D-20). `nondeterministicUnderSampling` starts EMPTY; additions require explicit operator action with replay-golden corpus evidence. |
| T-08-02 | Information Disclosure | Recorded session SQLite contains untruncated tool_result bytes (potentially PII, API keys captured during operator's daily use) | accept | Replay corpus is single-machine, never leaves the host. P1 SystemKeychainStore + redaction at log time means API keys are not present in the replay log per OBS-06. Operator discretion at promote time per D-09. |
| T-08-03 | Denial of Service | Malformed fixture file crashes MockLLMProvider, taking down the harness | mitigate | MockLLMProvider wraps decode errors via `continuation.finish(throwing:)`; the orchestrator's stream-truncation handling (AGENT-09) treats this as `.providerError` rather than crashing the process. DriftClassifierTests includes a malformed-fixture case in Task 2. |
| T-08-04 | Spoofing | An older-schema replay log produces false-positive PASS by the classifier when the schema has since drifted | mitigate | D-11 schema-version handshake: `ReplayRunner` rejects logs with `replaySchemaVersion < DriftClassifier.supportedSchemaVersion` with explicit error; verified by acceptance criterion in Task 3. |
| T-08-05 | Elevation of Privilege | TurnSource Strategy B migration accidentally enables HUD dispatch / TTS for `.replay` or `.evaluation` cases | mitigate | Hand-rolled `dispatchesToHUD` / `speaks` switches with no `default` arm (S-1); compile-time hit if a new case is added without explicit suppression policy. Task 1 acceptance criteria asserts `dispatchesToHUD` and `speaks` strings present in the file; integration test in 08-04 asserts no webview bus message and no TTS engine call during a replay run (deferred to 08-04 wiring). |
</threat_model>

<verification>
After all tasks complete, the following must hold:

```bash
# Module compiles
swift build --package-path packages/Harness

# Unit tests pass
swift test --package-path packages/Harness

# CLI help works
swift run --package-path packages/Harness jarvis-eval --help
swift run --package-path packages/Harness jarvis-eval replay --help

# TurnSource Strategy B migration intact
grep -c "case replay(sessionId:" packages/Replay/Sources/Replay/ReplayEvent.swift   # == 1
grep -c "case evaluation(scenarioId:" packages/Replay/Sources/Replay/ReplayEvent.swift  # == 1
grep -c "var dispatchesToHUD: Bool" packages/Replay/Sources/Replay/ReplayEvent.swift # == 1

# Whole-project build green
swift build  # or xcodebuild -scheme Jarvis build

# OBS-02 default exclusion list intact
jq -r '.alwaysExcluded | length' packages/Harness/Corpora/replay-golden/exclusions.json  # == 8

# DriftClassifier covers all 6 categories
for cat in idOrTimestamp samplingNondeterminism schemaChange orderingBug truncationBug valueBug; do
  grep -c "case $cat" packages/Harness/Sources/Harness/Oracle/DriftReport.swift
done

# No prohibited `default:` in DriftClassifier (S-1 invariant)
grep -E '^\s*default:' packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift | grep -v '^#' | wc -l  # == 0
```
</verification>

<success_criteria>
- `packages/Harness` SPM module builds and tests pass.
- TurnSource extended with `.replay(sessionId:)` and `.evaluation(scenarioId:)` (Strategy B); both suppress HUD dispatch + TTS via `dispatchesToHUD` / `speaks`.
- DriftClassifier classifies the 6 documented categories; `passed` iff `unexpected.isEmpty`.
- ReplayMCPAdapter reads recorded tool results from a SQLite session.
- MockLLMProvider drives REAL SSE/NDJSON decoders over fixture bytes (not vacuous).
- `jarvis-eval replay <session>` is a working subcommand returning the drift report.
- Replay schema versioning enforced: D-11 reject-older-version path is testable via acceptance criteria.
- ExclusionList JSON sidecar at `Corpora/replay-golden/exclusions.json` with OBS-02 default seed.
</success_criteria>

<output>
After completion, create `.planning/phases/08-hardening/08-01-replay-oracle-SUMMARY.md` recording:
- TurnSource Strategy B migration call-site list (output of `grep -rn "switch.*source\b" packages/ App/`)
- Whether `packages/Replay` exposes a public `ReplayDB`/`ReplayRow` reader OR Harness ships a local SQLite read shim
- Whether `replaySchemaVersion` is already emitted by P4's writer; if NOT, file a follow-up note for the executor of plan 08-04 (cross-cutting)
- jarvis-eval --help output captured verbatim
- Any deviations from the 6 DriftCategory cases (e.g., orderingBug deferred to a later plan)
</output>
