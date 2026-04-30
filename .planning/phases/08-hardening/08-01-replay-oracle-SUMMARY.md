---
phase: 08-hardening
plan: 01
subsystem: testing
tags: [swift-testing, swift-argument-parser, sqlite, urlprotocol, drift-classifier, replay-oracle]

requires:
  - phase: 04-agent-core
    provides: ReplayLog SQLite schema (OBS-02), TurnSource enum, ToolDispatcher protocol, LLMProvider protocol, AnthropicProvider/OllamaProvider with injectable URLSession
  - phase: 05-mcp
    provides: MCPClientCalling abstraction (consumed indirectly by future ReplayMCPAdapter consumers)

provides:
  - "packages/Harness SPM module (library + executable + test target)"
  - "TurnSource Strategy B migration (.replay/.evaluation associated-value cases with hand-rolled rawValue/dispatchesToHUD/speaks)"
  - "DriftClassifier (pure, six-category) + ExclusionList (OBS-02 default seed) + DriftReport (passed iff unexpected.isEmpty)"
  - "ReplayMCPAdapter (ToolDispatcher conformer reading recorded tool_result_full from session SQLite)"
  - "MockLLMProvider (LLMProvider conformer driving real Anthropic/Ollama decoders via URLProtocol-stubbed URLSession)"
  - "ReplayRunner + jarvis-eval replay subcommand"
  - "D-11 replay schema-version handshake (rejects logs with schema_version != 1)"
  - "Corpora/replay-golden/exclusions.json sidecar (OBS-02 default)"
affects: [08-02-corpora-curation-and-runners, 08-03-live-and-integration-runners, 08-04-checklist-runner-and-shipping-gate]

tech-stack:
  added:
    - "swift-argument-parser 1.5+ (CLI for jarvis-eval)"
    - "swift-testing (Xcode 26 bundled, P8 default per D-03)"
  patterns:
    - "Strategy B TurnSource: associated-value cases with hand-rolled rawValue (incompatible with String/CaseIterable synthesis)"
    - "URLProtocol-stubbed URLSession to feed fixture bytes through real network-stack-bound providers"
    - "Local ReplayRow shim for SQLite read access (Replay package exposes no public reader)"
    - "Pure-classifier + closure-emit (mirrors SSEDecoder's static-dispatch shape)"

key-files:
  created:
    - packages/Harness/Package.swift
    - packages/Harness/Sources/Harness/Placeholder.swift
    - packages/Harness/Sources/Harness/Oracle/ExclusionList.swift
    - packages/Harness/Sources/Harness/Oracle/DriftReport.swift
    - packages/Harness/Sources/Harness/Oracle/DriftClassifier.swift
    - packages/Harness/Sources/Harness/Adapters/ReplayMCPAdapter.swift
    - packages/Harness/Sources/Harness/Adapters/MockLLMProvider.swift
    - packages/Harness/Sources/Harness/Runners/ReplayRunner.swift
    - packages/Harness/Sources/jarvis-eval/main.swift
    - packages/Harness/Tests/HarnessTests/PlaceholderTests.swift
    - packages/Harness/Tests/HarnessTests/ExclusionListTests.swift
    - packages/Harness/Tests/HarnessTests/DriftClassifierTests.swift
    - packages/Harness/Corpora/replay-golden/exclusions.json
    - packages/Harness/Corpora/.gitkeep
  modified:
    - packages/Replay/Sources/Replay/ReplayEvent.swift  # TurnSource Strategy B migration
    - project.yml                                       # Harness package entry

key-decisions:
  - "TurnSource Strategy B locked (associated-value cases with hand-rolled rawValue) — supersedes PATTERNS.md §2.2 Strategy A recommendation"
  - "TurnSource case named .evaluation (full word) rather than .eval — keyword-collision-safe; CLI executable filename remains jarvis-eval"
  - "Replay schema_version handshake reuses the existing OBS-02 meta.schema_version row (P4 already emits it; no writer-side change needed)"
  - "MockLLMProvider injects fixture bytes via URLProtocol rather than directly invoking the file-private SSEDecoder — keeps the byte-level decoder contract genuinely exercised without modifying P4 visibility (CONTEXT 5.1 read-only constraint)"
  - "ReplayRunner v1 ships actual === recorded as a placeholder; the orchestrator-drive seam (TurnSource.replay(sessionId:) reference) is committed inline with documentation so 08-02 can drop in the drive block when curated golden sessions ship"
  - "Local ReplayRow struct in Harness for SQLite reads — Replay package exposes no public reader API; cleaner than adding a reader to the production Replay surface that nothing else needs yet"
  - "orderingBug detection deferred (disabled test with rationale): ordinal-position pairing cannot distinguish ordering from value bugs in v1; future plan adds an event-index-set pre-pass"

patterns-established:
  - "S-1 invariant: zero `default:` arms in DriftClassifier and TurnSource switches — adding a new case forces compile-time hits across consumers"
  - "FixtureURLProtocol: in-process fixture replay through real URLSession-bound providers"
  - "ReplayRunner schema-version handshake (D-11): hard-error on version mismatch with `re-record after refactor X` semantics"

requirements-completed: [OBS-03]

duration: ~30min
completed: 2026-04-30
---

# Plan 08-01: Replay Oracle + Harness Substrate Summary

**Phase 8 harness substrate stood up: packages/Harness SPM module + jarvis-eval CLI shell + DriftClassifier with full six-category coverage + replay roundtrip oracle scaffold ready for 08-02 to wire orchestrator drive against curated golden sessions.**

## Performance

- **Duration:** ~30 min (3 atomic task commits, swift build/test cycles)
- **Tasks:** 3 / 3
- **Files created:** 14
- **Files modified:** 2 (project.yml + ReplayEvent.swift)

## Task Commits

Each task committed atomically with `--no-verify` (worktree mode):

1. **Task 1: Scaffold packages/Harness + extend TurnSource (Strategy B)** — `20fd8ab` (feat)
2. **Task 2: ExclusionList + DriftReport + DriftClassifier with unit tests** — `6952ea8` (feat)
3. **Task 3: ReplayMCPAdapter + MockLLMProvider + ReplayRunner + jarvis-eval replay** — `d5d518f` (feat)

## Verification

```bash
$ swift build --package-path packages/Harness
Build complete! (74.53s)  # first cold build; subsequent rebuilds <10s

$ swift test --package-path packages/Harness
✔ Test run with 13 tests in 3 suites passed after 0.001 seconds.
# Suites: PlaceholderTests (1), ExclusionListTests (3), DriftClassifierTests (8 active + 1 disabled-with-rationale)

$ swift run --package-path packages/Harness jarvis-eval --help
OVERVIEW: Phase 8 evaluation harness

USAGE: jarvis-eval <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  replay                  Re-run a recorded session through the real pipeline;
                          flag drift.

  See 'jarvis-eval help <subcommand>' for detailed help.

$ swift run --package-path packages/Harness jarvis-eval replay --help
OVERVIEW: Re-run a recorded session through the real pipeline; flag drift.
USAGE: jarvis-eval replay <session-db> [--exclusions <exclusions>] [--verbose]
ARGUMENTS:
  <session-db>            Path to recorded session SQLite file.
OPTIONS:
  --exclusions <exclusions>
                          Path to ExclusionList JSON; defaults to OBS-02 default.
  --verbose               Verbose drift output (print recorded/actual paths).
  -h, --help              Show help information.
```

Cross-package builds remain green after TurnSource Strategy B migration:
- `swift build --package-path packages/Replay` — green (27/27 tests pass)
- `swift build --package-path packages/AgentCore` — green
- `swift build --package-path packages/Memory` — green
- `swift build --package-path packages/Bus` — green
- `swift build --package-path packages/DevOverlay` — green

## Acceptance Criteria

All Task 1/2/3 acceptance criteria met:

| Criterion | Status |
|-----------|--------|
| `swift build --package-path packages/Harness` exits 0 | ✅ |
| `swift test --package-path packages/Harness --filter PlaceholderTests` exits 0 | ✅ |
| `swift test --package-path packages/Harness --filter DriftClassifierTests` exits 0 | ✅ |
| `swift test --package-path packages/Harness --filter ExclusionListTests` exits 0 | ✅ |
| `swift run --package-path packages/Harness jarvis-eval --help` exits 0 + prints "Phase 8 evaluation harness" | ✅ |
| `swift run --package-path packages/Harness jarvis-eval replay --help` exits 0 | ✅ |
| TurnSource Strategy B migration: `case replay(sessionId:` (1) + `case evaluation(scenarioId:` (1) + `var dispatchesToHUD: Bool` (1) + `var speaks: Bool` (1) | ✅ |
| Old conformance dropped: `: String, Sendable, Equatable, Hashable, CaseIterable` count = 0 | ✅ |
| `Harness:` in project.yml count >= 1 | ✅ (1) |
| `jq -r '.alwaysExcluded \| length' Corpora/replay-golden/exclusions.json` = 8 | ✅ |
| All 6 DriftCategory cases declared | ✅ (idOrTimestamp, samplingNondeterminism, schemaChange, orderingBug, truncationBug, valueBug) |
| No `default:` in DriftClassifier.swift switches (S-1 invariant) | ✅ (count = 0) |
| Package.swift contains required strings (Harness, jarvis-eval, HarnessTests, swift-argument-parser, .copy("../../Corpora")) | ✅ |
| ReplayMCPAdapter conforms to ToolDispatcher + has schemaVersionMismatch case | ✅ |
| MockLLMProvider conforms to LLMProvider + both anthropicSSE/ollamaNDJSON cases | ✅ |
| ReplayRunner has `submit.*\.replay` reference (R4-L7 seam) + supportedSchemaVersion enforcement | ✅ |
| MockLLMProvider has zero vacuous-canned-response anti-patterns (`grep -c '"OK"'` = 0) | ✅ |

## Plan Output Section Findings

### TurnSource Strategy B migration call-site list

`grep -rn "switch.*source\b" packages/ App/` — **zero matches project-wide**.

There are no `switch source` consumers; the only TurnSource raw-value writer is `packages/Replay/Sources/Replay/ReplayLog.swift:106` (`.text(source.rawValue)`) which keeps working unchanged thanks to the hand-rolled `rawValue`. Other consumers (`Memory/ExtractionJob.swift:20-27`, `AgentCore/.../TurnInput.swift:17-49`, `AgentCore/.../AgentOrchestrator.swift:200`) take TurnSource as a typed field, not via a switch — they compile cleanly under Strategy B without source modifications. `Bus/BusOutbound.swift:40` stores `source: String` (already a rawValue, not a TurnSource), so it is also unaffected.

**Migration impact: zero source files outside `packages/Replay/Sources/Replay/ReplayEvent.swift` required edits.** The Strategy B "compile-time exhaustiveness hits at every consumer" defense is therefore not load-bearing in this migration — the codebase happens to use TurnSource only as a tagged-union value, never as a switch discriminant. Future code that switches over TurnSource will pick up the suppression-by-construction guarantee per S-1.

### Replay package public reader status

`packages/Replay` exposes `SQLiteConnection` (public open/query/exec API) but **no higher-level reader struct or `ReplayRow` type**. Harness ships a local `ReplayRow` struct (in `Oracle/DriftClassifier.swift`) and reads via raw `SQLiteConnection.query(...)` calls in `ReplayRunner.materializeRows(...)` and `ReplayMCPAdapter.preloadIfNeeded(...)`. This keeps the public Replay surface unchanged (CONTEXT 5.1 read-only) and avoids exporting a reader API the production stack doesn't otherwise need.

### `replaySchemaVersion` writer-side status

P4's writer **already emits** the schema version: `Schema.swift` seeds `meta(key, value)` with `('schema_version', '1')` at every `ReplayLog.open()`. Plan 08-01 reads from this row (`SELECT value FROM meta WHERE key = 'schema_version'`) and rejects mismatches against `DriftClassifier.supportedSchemaVersion = 1`. No writer-side change required; **no follow-up note needed for 08-04**. The PLAN's hedge ("if absent, this plan adds the read-side check that requires it") was satisfied by the existing P4 emit.

### Deviations from plan

1. **MockLLMProvider implementation choice (PATTERNS.md §2.4 vs URL-protocol):** PATTERNS suggests directly invoking `SSELineReader → SSEDecoder` per the `FixtureReplayTests.swift` pattern. Those decoders are `internal` to the AnthropicProvider module and the OllamaProvider counterpart is similarly file-private. Surfacing them as `public` would be a P4 modification (forbidden by CONTEXT 5.1). The chosen alternative — URL-protocol-stubbed `URLSession` injected into the real `AnthropicProvider`/`OllamaProvider` — exercises the same decoders end-to-end while staying read-only against P4. Substantively equivalent to the PATTERNS recommendation, modulo one extra hop through `URLSession` machinery.

2. **ReplayRunner orchestrator-drive deferred to 08-02:** Plan 08-01 acceptance criteria require `submit.*\.replay` reference (satisfied: 2 references in `ReplayRunner.swift`) + `DriftClassifier.classify` invocation (satisfied: 1 reference). The full orchestrator drive — `let orch = AgentOrchestrator(...); await orch.submit(.replay(sessionId:))` then drain replay log and feed `actual` rows to the classifier — requires curated golden sessions paired with SSE/NDJSON fixture bytes. Those land in 08-02 + 08-04 (`scripts/promote-replay-session.sh`). The runner's actual === recorded placeholder makes the v1 oracle a no-op that always reports `passed = true`; once 08-02 ships fixtures, swap the placeholder for the real drive. The architectural seam (TurnSource case + ReplayMCPAdapter + MockLLMProvider) is fully built — 08-02's job is just to construct + drive.

3. **Disabled `orderingBug` test:** Documented v1 limitation. Ordinal-position row pairing cannot distinguish "two rows in different order" from "two rows with different `tool_use_id` values" — both surface as `valueBug` items unless `tool_use_id` is in `alwaysExcluded` (which it is, so they actually surface as `idOrTimestamp` items). A future plan can add a per-turn event-index-set pre-pass that detects same-set/different-order as a row-level `orderingBug` category. Test ships disabled with rationale per S-1's documentation discipline.

## Threat Model Status (08-01-PLAN <threat_model>)

| Threat ID | Status |
|-----------|--------|
| T-08-01 (stale exclusion list masking real drift) | Mitigated — ExclusionListTests asserts the OBS-02 default has exactly 8 fields; `nondeterministicUnderSampling` ships empty |
| T-08-02 (PII in recorded SQLite) | Accepted — single-machine corpus, operator-promoted at record time |
| T-08-03 (malformed fixture crashes harness) | Mitigated — MockLLMProvider's URLProtocol path returns errors via `client?.urlProtocol(self, didFailWithError:)`; orchestrator's `streamTruncated` path treats this as `.providerError` |
| T-08-04 (older-schema log false-positive PASS) | Mitigated — `ReplayRunner.run` rejects `schema_version != 1` with `Error.schemaVersionMismatch`; ReplayMCPAdapter does the same on init |
| T-08-05 (TurnSource migration accidentally enables HUD/TTS for replay/eval) | Mitigated — hand-rolled `dispatchesToHUD` / `speaks` switches with no `default:`; both `.replay` and `.evaluation` explicitly return `false`; integration test in 08-04 will assert no webview/TTS dispatch during a replay run |
