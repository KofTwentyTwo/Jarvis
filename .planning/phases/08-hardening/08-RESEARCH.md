# Phase 8: Hardening — Research

**Researched:** 2026-04-22
**Domain:** Shipping gates — deterministic replay oracle + eval matrix across the full Jarvis pipeline
**Confidence:** HIGH on replay-oracle architecture (industry patterns converged 2025–2026; OBS-02 already pins nothing-masked replay); HIGH on injection-corpus shape (OWASP LLM01:2025 + AgentDojo/InjecAgent public benchmarks); MEDIUM on macOS-specific harness plumbing (FD-leak detection, audio-graph rebuild integration-test harness — these are bespoke, no off-the-shelf package).

---

## Summary

Phase 8 is "shipping gate, not shipping polish." The pipeline already emits a nothing-masked replay log (OBS-02 in P4) and has a DevOverlay (OBS-01) wired across every seam. What P8 adds is the *verification* harness that proves the pipeline is real: a **replay viewer** that re-runs recorded sessions through the actual code paths (not a simulator) and a **byte-match oracle** that classifies any divergence as expected (temp>0 sampling) or unexpected (schema / ordering / truncation bugs); and an **eval matrix** with 8 sub-suites covering injection-corpus defense, SSE/NDJSON fixture decoding, live-Ollama tool-calling, tool-cap regression, wake-hysteresis FAR/FRR, MCP crash-recovery with FD-leak detection, audio-graph rebuild across 4 triggers, and the "looks done but isn't" checklist accumulated across every prior phase's SUMMARY.

Two requirements on paper (OBS-03, OBS-04), eight distinct harness components in practice, each of which exercises a surface that was decided in an earlier phase but never end-to-end exercised against a corpus. This is where Claude Opus 4.5's measured-prompt-injection-resistance numbers (1.4% successful attacks with Anthropic's safeguards; 10.8% without [VERIFIED: venturebeat.com]) become locally measurable rather than aspirational.

**Primary recommendation:** Build P8 as 4 plans — (1) replay-oracle with drift classifier, (2) injection corpus + fixture corpora, (3) live-Ollama + crash-recovery + audio-graph integration tests, (4) checklist runner + shipping-gate CI target. Every sub-suite must be runnable in isolation (`swift test --filter <SuiteName>`) AND as a single top-level `scripts/shipping-gate.sh` that is the CI entry point.

---

## User Constraints

*(No 08-CONTEXT.md exists yet — this RESEARCH.md is spawned directly by `/gsd-research-phase 8` ahead of discuss/plan. Constraints inherited from project-level sources only.)*

### Locked Decisions (from PROJECT.md / CLAUDE.md / STATE.md)

- **Personal use, single machine, no commercial ship.** Shipping gate means "usable daily without silent regressions," not "pass an external compliance audit."
- **Eval pinned to `qwen2.5-coder:32b`** for local-model evaluation. Qwen3/3.5 are NOT opt-in baselines (RESEARCH-DELTAS D3).
- **Replay log is nothing-masked** modulo the OBS-02 exclusion list: `row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce`. P8 inherits and extends this list; does not replace it.
- **Observability is not introduced in P8.** DevOverlay + ReplayLog + structured logs land in P4. P8 adds the *oracle* over the replay log and the eval harness *runner*.
- **No cloud services for voice;** Ollama bound to localhost (AGENT-05). Live-eval components must respect these network constraints — the Anthropic eval pillar (b) is the only cloud egress; the Ollama pillar (c) hits `127.0.0.1:11434` only.

### Claude's Discretion

- Harness structure (one monolithic test target vs per-pillar targets). Recommendation below.
- Drift-classifier confidence thresholds and categorization rules. Recommendation below.
- Injection-corpus specific items (20+ attempts, all blocked). Curate from OWASP LLM01:2025 + AgentDojo/InjecAgent plus Jarvis-specific vectors (AppleScript confirmation bypass, bus-versioned-handshake, turnNonce-aware attacks).
- Wake-hysteresis corpus composition (ratio of TP / TN clips, background-noise profiles).
- "Looks done but isn't" checklist mechanization — free-form or structured YAML per-phase?

### Deferred Ideas (OUT OF SCOPE for v1 P8)

- **Automated daily eval run** with regression alerts — OBS-V2-02, v2 only.
- **Multi-model regression grid** (Opus vs Haiku vs Qwen3 when fixed vs Llama 4) — v2.
- **Automated fuzzing / mutation-based injection generation** — v2. P8 uses curated static corpus.
- **Formal coverage metrics** (branch coverage, mutation score) — overkill for personal project.
- **Production observability stack** (Datadog / OTel export) — single-user, local logs only.

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| **OBS-03** | Replay viewer re-runs past recorded session through the real pipeline deterministically; byte-match oracle flags drift. | §Replay Oracle Architecture; §Drift Classification; §OBS-02 Exclusion List (inherited) |
| **OBS-04** | Eval harness runs 15–25 hand-written scenarios on demand; pinned to `qwen2.5-coder:32b` for local-model eval; 8-pillar matrix. | §Eval Matrix (all 8 pillars); §Injection Corpus; §Fixture Corpora; §Live Ollama; §Tool-Cap Regression; §Wake Corpus; §Crash-Recovery; §Audio-Graph Rebuild; §"Looks Done But Isn't" Checklist |

Both REQs depend on infrastructure landed in P1–P7. P8 adds the harness over the top; it **does not** fix bugs found by the harness in earlier phases — those produce regressions that route back to the owning phase's codebase (with P8 suite serving as the regression test).

---

## Project Constraints (from CLAUDE.md)

Actionable directives from the authoritative project spec relevant to P8:

- **Non-functional requirements are not "nice to haves."** Dev overlay, replay log, eval harness, feature flags, structured logs are mandatory and built in from the start.
- **Eval harness: 15–25 hand-written scenarios**, run after significant changes, pinned to `qwen2.5-coder:32b`.
- **Prompt-injection defense is structural** (nonces, policy at dispatch) — NOT string-matching. The P8 injection corpus must exercise the nonce path; string-match defenses are explicitly called out as wrong (AUDIT-R2 themes).
- **Opus 4.7 footguns** that the SSE fixture corpus must exercise: tokenizer inflation (~35%), `cache_control ttl: "1h"` + `anthropic-beta: extended-cache-ttl-2025-04-11` header round-trip, `content_block_start` with `input_json_delta` for tool args, close on `message_stop` (not `message_delta`), swallow `ping`, route `thinking_delta` separately, treat `stop_reason: "refusal"` first-class, emit `partial_tool_use_at_disconnect` on mid-delta disconnect.
- **Ollama `/api/chat` NDJSON quirk**: `tool_calls` emits on the chunk **preceding** `done: true`. Fixture corpus must encode both a clean-path AND a done-terminator-without-tool_calls path to prevent regression.
- **Tool-choice discipline (R4-L1):** cap-recovery call sets `.none` → Anthropic `{type:"none"}`, Ollama drop `tools` array entirely. P8 asserts zero `.toolUseRequested` on recovery turn.
- **`qwen2.5-coder:32b` is the pinned local tool-calling baseline.** Any newer-model swap requires full Tier-A P8 pass before adoption.
- **Architecturally forbidden:** presence-triggered auto-speak, AppleScript skip-allowlist, silent memory mutations, modals on `@MainActor` presentation paths, two writers for HudState. P8 checklist asserts none exist (grep + structural tests).

---

## Architectural Responsibility Map

Phase 8 is a **test harness** at its core — it does not add runtime tiers. The table below reflects *which runtime tier the harness exercises*, not where harness code lives.

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Replay viewer (re-run recorded session) | Swift host / CLI | — | Invokes real `AgentOrchestrator` via a `.replay` `TurnSource`; webview is suppressed for replay runs (per R4-L7). |
| Drift classifier (byte-match oracle) | Swift host | — | Pure function over two `Data` blobs + exclusion-list JSON; lives in a new `packages/Harness` SPM module. |
| Injection corpus runner | Swift host + AnthropicProvider OR OllamaProvider | MCP helpers (for tool-path injection) | Exercises `SEC-06` nonce wrap + `SEC-07` sanitize pipeline; routes through real orchestrator; blocks are asserted at turn output + replay-log inspection. |
| SSE fixture corpus runner | Swift host (unit-level) | — | Pure-decoder test: reads static SSE bytes → expected `LLMEvent` stream. No network. |
| Ollama NDJSON fixture + live eval | Swift host | Local Ollama daemon (`127.0.0.1:11434`) | Fixture path is offline; live path spawns/assumes a running `qwen2.5-coder:32b`. |
| Tool-cap recovery regression | Swift host | LLMProvider (Anthropic + Ollama, both) | Exercises R4-L1: `toolChoice: .none` on recovery; asserts zero `.toolUseRequested`. |
| Wake-hysteresis corpus | Swift host | Voice pipeline (ONNX Runtime + Silero v6.2.1) | Feeds prerecorded 16 kHz clips through `VoiceController` fixture path; measures FAR/FRR. |
| MCP crash-recovery load test | Swift host | MCP helpers (actual spawned processes) | Injects `SIGKILL` into helper; asserts restart mutex + no FD leaks via `lsof` pre/post. |
| Audio-graph rebuild test matrix | Swift host | `AVAudioEngine` (real or mocked device-change notifications) | 4 triggers × canonical 6-step teardown; integration harness. |
| "Looks done but isn't" checklist runner | Swift host | Build system (grep/structural checks) | Reads per-phase YAML manifest; fails build if any item regresses. |

**Tier sanity check:** All P8 harness code lives in the Swift host process (either as XCTest targets or as a CLI `jarvis-eval` tool). No JS / webview / Python. Keeps the single-binary shipping-gate story clean.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `XCTest` / `swift-testing` | bundled (Xcode 26) | Test runner for per-pillar suites | `swift-testing` is Apple-blessed 2026; new suites use it. Existing XCTest suites (from P1–P7) remain. [CITED: developer.apple.com/swift-testing] |
| `apple/swift-log` | 1.5.3+ | Harness structured logging; same channels as runtime | Already bootstrapped in P1 (OBS-06). Harness uses `system` channel. [VERIFIED: consumed in 01-02-SUMMARY.md] |
| Built-in `Foundation` | — | `Process` (for MCP helper spawn tests); `FileManager`; `URLSession` | No third-party lib needed for P8 harness plumbing. [ASSUMED — based on Swift stdlib] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `apple/swift-argument-parser` | 1.5.0+ | CLI surface for `jarvis-eval` / `jarvis-replay` | Needed for the CLI entry points that the shipping-gate script invokes. Add to `packages/Harness/Package.swift`. [CITED: github.com/apple/swift-argument-parser] |
| `apple/swift-async-algorithms` | 1.0+ | `AsyncChannel` for replay stream comparison | Already a transitive dep via agent-core. [VERIFIED: consumed in ARCHITECTURE.md] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `swift-testing` | Keep everything in `XCTest` | XCTest is uniform with earlier phases; `swift-testing` is newer and has nicer parameterized-test ergonomics for corpus-driven suites (inject N corpus items as N distinct tests). Recommendation: `swift-testing` for new P8 suites; XCTest for anything that must share fixtures with earlier phases. |
| Custom drift classifier | `swift-snapshot-testing` (`pointfreeco/swift-snapshot-testing`) | Snapshot testing snapshots *outputs against disk files*; it doesn't know the semantic difference between "timestamp drifted" (expected) and "tool_call reordered" (bug). We need an oracle with a typed exclusion list, not a string-diff. Build it. |
| `promptfoo` (JS) | Use promptfoo as the injection-corpus runner | Promptfoo is the 2026-current industry standard for LLM red-teaming [CITED: promptfoo.dev/red-team-claude]; but it's a Node CLI that doesn't know our orchestrator, `SEC-06` turnNonce wrap, or `SEC-07` sanitize pipeline. Curating corpus items from promptfoo's library while running them through *our* orchestrator is the right split. |
| AgentDojo as runner | Use ethz-spylab/agentdojo | Same issue as promptfoo — it's a Python framework that doesn't wrap our Swift orchestrator. Use its **task taxonomy** (1,054 test cases across 17 tools) as corpus source material [CITED: github.com/uiuc-kang-lab/InjecAgent], not as a runner. |
| Live Opus call in eval | Fixture-only eval | Live call catches cache-TTL regressions, `anthropic-beta` header acceptance, actual streaming behavior — but costs money and is flaky. Recommendation: fixture corpus is the gate; live eval is opt-in (`--live` flag) for manual release checks. |

**Installation (additions to P8):**
```bash
# Already present from earlier phases:
#   apple/swift-log 1.5.3+       (from P1 01-02)
#   apple/swift-async-algorithms (from P4)

# New to P8:
#   apple/swift-argument-parser 1.5.0+
#   (swift-testing is bundled in Xcode 26 — no SPM dep needed)
```

**Version verification deferred to plan phase.** No new dep versions locked here — planner should `swift package show-dependencies` and verify current stable before authoring `packages/Harness/Package.swift`.

---

## Architecture Patterns

### System Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│ scripts/shipping-gate.sh   ← single CI entry; runs all 8 pillars in order  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ jarvis-eval CLI (packages/Harness) — swift-argument-parser subcmds   │  │
│  │                                                                       │  │
│  │  jarvis-eval replay     [session.sqlite]  → ReplayOracle + Classifier│  │
│  │  jarvis-eval corpus-injection              → InjectionCorpusRunner   │  │
│  │  jarvis-eval corpus-sse   [--anthropic]    → SSEFixtureRunner        │  │
│  │  jarvis-eval corpus-ndjson [--ollama-live] → NDJSONFixtureRunner     │  │
│  │  jarvis-eval cap-recovery                  → ToolCapRecoveryRunner   │  │
│  │  jarvis-eval wake-corpus                   → WakeHysteresisRunner    │  │
│  │  jarvis-eval mcp-crash                     → MCPCrashRecoveryRunner  │  │
│  │  jarvis-eval audio-rebuild                 → AudioGraphRebuildRunner │  │
│  │  jarvis-eval checklist                     → LooksDoneChecklistRunner│  │
│  │  jarvis-eval all                           → run every pillar        │  │
│  └──┬───────────────────────────────────────────────────────────────────┘  │
│     │                                                                       │
│     │ invokes real runtime components (not simulators):                     │
│     ▼                                                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ AgentOrchestrator (actor)   ← .replay / .eval TurnSource              │  │
│  │   └─► suppresses TTS subscription, webview bus                        │  │
│  │   └─► routes LLMProvider → MockAnthropicProvider | MockOllamaProvider │  │
│  │         | LiveAnthropicProvider | LiveOllamaProvider (live flag)      │  │
│  │   └─► routes MCPClient → ReplayMCPAdapter | real MCP helpers          │  │
│  │   └─► ReplayLog writes to /tmp/jarvis-eval-{uuid}.sqlite              │  │
│  └──┬───────────────────────────────────────────────────────────────────┘  │
│     │                                                                       │
│     │ produces: new replay log (actual)                                     │
│     ▼                                                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ DriftClassifier (pure Swift function)                                 │  │
│  │   inputs: recorded.sqlite, actual.sqlite, exclusion-list.json         │  │
│  │   output: DriftReport {                                               │  │
│  │             expected: [(field, recorded, actual)]                     │  │
│  │             unexpected: [(category, field, recorded, actual)]         │  │
│  │           }                                                           │  │
│  │   PASS iff unexpected.isEmpty                                         │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

**Key architectural principle:** the harness exercises the **real pipeline**, not a reimplementation. The only substitutions permitted are (a) LLMProvider swaps (mock vs live), (b) `.replay` / `.eval` TurnSource suppressing TTS + webview per R4-L7, and (c) `ReplayMCPAdapter` replaying recorded tool results instead of spawning helpers. Every other component — orchestrator, sanitize pipeline, turnNonce generator, tool-result truncation, retry-on-stream-truncation, confirmation broker, HudStateCoordinator — runs as it does in production.

### Recommended Project Structure

```
packages/
└── Harness/                          ← NEW in P8
    ├── Package.swift                 # depends on: Agent, LLM, MCP, Voice, Memory, Config, Logging, ReplayLog
    ├── Sources/
    │   ├── Harness/                  # library target — reusable test plumbing
    │   │   ├── Corpus/
    │   │   │   ├── InjectionCorpus.swift        # 20+ attempts + expected-blocked-outcome
    │   │   │   ├── SSEFixtureCorpus.swift       # recorded .sse byte arrays + expected event streams
    │   │   │   ├── NDJSONFixtureCorpus.swift    # recorded .ndjson byte arrays + expected event streams
    │   │   │   └── WakeHysteresisCorpus.swift   # WAV manifests + TP/TN labels
    │   │   ├── Oracle/
    │   │   │   ├── DriftClassifier.swift        # expected vs unexpected drift categorization
    │   │   │   ├── ExclusionList.swift          # OBS-02 field set, extensible
    │   │   │   └── DriftReport.swift            # structured output
    │   │   ├── Runners/
    │   │   │   ├── ReplayRunner.swift
    │   │   │   ├── InjectionCorpusRunner.swift
    │   │   │   ├── SSEFixtureRunner.swift
    │   │   │   ├── NDJSONFixtureRunner.swift
    │   │   │   ├── LiveOllamaRunner.swift
    │   │   │   ├── ToolCapRecoveryRunner.swift
    │   │   │   ├── WakeHysteresisRunner.swift
    │   │   │   ├── MCPCrashRunner.swift         # includes FDLeakDetector via lsof
    │   │   │   ├── AudioGraphRebuildRunner.swift
    │   │   │   └── ChecklistRunner.swift
    │   │   ├── Adapters/
    │   │   │   ├── ReplayMCPAdapter.swift       # substitutes for MCPClient in replay mode
    │   │   │   └── MockLLMProvider.swift        # reads fixture bytes
    │   │   └── FDLeakDetector.swift             # lsof wrapper; snapshot before/after
    │   └── jarvis-eval/               # executable target (swift-argument-parser subcommands)
    │       └── main.swift
    ├── Tests/
    │   └── HarnessTests/              # tests of the harness itself
    │       ├── DriftClassifierTests.swift
    │       ├── ExclusionListTests.swift
    │       └── FDLeakDetectorTests.swift
    └── Corpora/                       # committed corpus data; resource-copied into bundle
        ├── injection/                 # JSON manifest + individual attempts
        ├── sse-anthropic/             # .sse fixture files
        ├── ndjson-ollama/             # .ndjson fixture files
        ├── wake-hysteresis/           # .wav files + labels.json
        └── checklist/                 # YAML manifests per phase

scripts/
├── shipping-gate.sh                   ← NEW; invokes jarvis-eval all
└── capture-anthropic-sse.sh           ← NEW; record new SSE fixtures from live API (opt-in)
```

### Pattern 1: Replay with Suppression (R4-L7)

**What:** `.replay` and `.eval` TurnSources suppress TTS subscription and webview dispatch, so replayed turns produce deterministic output without interfering with a running HUD. `.replay` routes `callTool` through `ReplayMCPAdapter` which reads recorded tool results; `.eval` routes through real MCP helpers (for integration-test shape).

**When to use:** All P8 runners. `.replay` for OBS-03 oracle; `.eval` for pillars (a), (c)-live, (f), (g).

**Example:**
```swift
// Source: ARCHITECTURE.md §Data flow — turn execution + R4-L7 triage
actor AgentOrchestrator {
    func submit(_ userMessage: String, source: TurnSource) async -> SubmitOutcome {
        let snapshot = await configStore.perTurn()
        let turnId = UUID()
        let turnNonce = UUID()

        // R4-L7: replay / eval suppress TTS + webview dispatch
        let shouldDispatchToHUD = source.dispatchesToHUD  // true for .user/.wake only
        let shouldSpeak = source.speaks                    // true for .user/.wake only

        // R4-L7: .replay swaps MCPClient for ReplayMCPAdapter;
        //        .eval uses real MCPClient for integration tests
        let mcp: MCPToolDispatcher = source == .replay ? replayAdapter : liveMCPClient

        // ... remainder of turn loop unchanged ...
    }
}

enum TurnSource: Sendable {
    case user
    case wake
    case memoryExtraction  // from P7
    case replay(sessionId: UUID)
    case eval(scenarioId: String)

    var dispatchesToHUD: Bool { self == .user || self == .wake }
    var speaks: Bool { self == .user || self == .wake }
}
```

### Pattern 2: Drift Classification with Exclusion List

**What:** Two replay-log SQLite files (recorded vs actual). For each row, compare payloads byte-for-byte; per-field, consult the exclusion list. Categorize remaining diffs as "expected" (model sampling under temp>0; listed under `expectedNondeterministicFields`) or "unexpected" (everything else).

**When to use:** OBS-03 oracle.

**Example:**
```swift
// Source: Harness/Oracle/DriftClassifier.swift (new)
public struct ExclusionList: Sendable, Codable {
    /// Fields whose drift is always expected (IDs, timestamps, nonces).
    /// Inherits OBS-02 list; extensible.
    public let alwaysExcluded: Set<String>  // row_id, session_id, turn_id, tool_use_id,
                                             // message_id, ts, monotonic_ns, turn_nonce
    /// Fields whose drift is expected ONLY if temperature > 0.
    public let nondeterministicUnderSampling: Set<String>
    // e.g., textDelta content, tool-call arguments text, embedding vectors
}

public struct DriftReport: Sendable {
    public var expected: [DriftItem]
    public var unexpected: [DriftItem]
    public var passed: Bool { unexpected.isEmpty }
}

public enum DriftCategory: String, Sendable {
    case idOrTimestamp          // in alwaysExcluded
    case samplingNondeterminism // in nondeterministicUnderSampling AND recording.temperature > 0
    case schemaChange           // JSON shape differs
    case orderingBug            // same set, different order
    case truncationBug          // one side ends early
    case valueBug               // deterministic-field changed
}

public func classify(
    recorded: ReplayDB,
    actual: ReplayDB,
    exclusions: ExclusionList,
    recordingTemperature: Double
) -> DriftReport { ... }
```

### Pattern 3: Corpus-Driven Parameterized Tests (swift-testing)

**What:** `swift-testing` parameterized tests take a corpus collection and emit one test per item. Failures are per-item, not batch.

**When to use:** Injection corpus (20+ items), SSE fixtures (N scenarios), wake corpus (N clips).

**Example:**
```swift
// Source: https://developer.apple.com/documentation/testing/parameterizedtesting
import Testing

struct InjectionCorpusTests {
    @Test(arguments: InjectionCorpus.all)
    func blockedOrSanitized(_ attempt: InjectionAttempt) async throws {
        let harness = await TestOrchestrator.make()
        let outcome = await harness.runTurn(toolResultContent: attempt.payload)

        // Block criterion: model-facing history shows wrapped <UNTRUSTED_CONTENT id=...> wrapper
        // around payload; sanitize stripped C0/bidi/zero-width; no AppleScript confirmation
        // was approved without user action.
        #expect(outcome.untrustedWrapWasApplied, "SEC-06 nonce wrap missing")
        #expect(outcome.sanitizePassMarked, "SEC-07 pipeline not run")
        #expect(!outcome.modelRequestedDestructiveTool || outcome.confirmationSheetShown,
                "Attack \(attempt.id) reached destructive tool dispatch without user confirmation")
    }
}
```

### Anti-Patterns to Avoid

- **Simulating the pipeline instead of running it.** A "replay" that reconstructs events from the log without invoking the real orchestrator will pass while the real code is broken. Hard rule: harness always invokes real `AgentOrchestrator.submit(..., source: .replay(...))`.
- **String-match drift classification.** Comparing two replay logs with `diff` and failing on any divergence is useless — IDs and timestamps always differ. Exclusion-list + typed classifier is the only correct shape.
- **Running injection corpus against a mocked LLM.** Injection defenses are structural (turnNonce wrap, sanitize pipeline) — they run upstream of the LLM. A mocked LLM that unconditionally returns `"OK"` will pass every injection test vacuously. Use a **real or fixture-recorded** Anthropic / Ollama stream so the nonce-wrap boundary is actually exercised.
- **FD-leak detection via assertion at end of test run.** By that point every helper has been respawned and the leaked FD is lost in noise. Snapshot `lsof -p <main-pid>` before the 100-crash loop AND after each 10th crash; delta must stay at 0.
- **Audio-graph rebuild test that calls `AVAudioEngine` without reset.** XCTest lifecycle does not reset audio engine between tests; one failing test leaves the engine in a bad state and poisons subsequent ones. Each rebuild scenario gets its own `@MainActor` test method with explicit `tearDown { engine.reset() }`.
- **"Looks done but isn't" checklist as hand-maintained markdown.** Drift between phases is guaranteed. YAML manifest per phase that `ChecklistRunner` reads and asserts is the only form that stays honest.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Parameterized test emission (1 test per corpus item) | Hand-rolled `for attempt in corpus { XCTAssertTrue(...) }` | `swift-testing` `@Test(arguments:)` | One-failure-doesn't-stop-the-suite; per-item diagnostics; Xcode 26 native. [CITED: developer.apple.com/swift-testing] |
| CLI argument parsing (`jarvis-eval`) | Hand-rolled `CommandLine.arguments` | `apple/swift-argument-parser` | Subcommands + help + validation for free. Already blessed by Apple. [CITED: github.com/apple/swift-argument-parser] |
| Injection-corpus curation from scratch | Inventing 20+ novel attack strings | Cherry-pick from OWASP LLM01:2025 cheat sheet + InjecAgent (1,054 test cases) + AgentDojo + Anthropic prompt-injection red-team public reports | 2026-current taxonomy; actually-seen-in-the-wild payloads; adding Jarvis-specific vectors (AppleScript confirmation bypass, MCP tool-result injection) on top. [CITED: owasp.org/llm01-prompt-injection; github.com/uiuc-kang-lab/InjecAgent; arxiv.org/abs/2406.13352 AgentDojo] |
| SSE fixture recording | Writing Anthropic SSE streams by hand | `scripts/capture-anthropic-sse.sh` — curl + `tee` to capture live streams into `.sse` files | Hand-rolled fixtures drift from actual Anthropic payload shapes. Real capture from a live Opus 4.7 call is the ground truth. Commit as frozen fixtures. [ASSUMED — standard fixture-recording pattern] |
| Wake-word corpus generation | Recording new speech clips | openWakeWord community `hey_jarvis` TP/TN corpora + synthetic augmentation (add noise, reverb) | Published corpora exist for benchmarking. 2026-standard: FAR < 0.5/hr, FRR < 5%. [CITED: picovoice.ai/blog/benchmarking-a-wake-word-detection-engine; medium.com/neural-engineer openwakeword evaluation] |
| FD-leak tracking | Ad-hoc `stat /proc/self/fd` (Linux-only; macOS differs) | `lsof -p <pid>` snapshot + Swift `Process` wrapper | macOS doesn't expose `/proc`; `lsof` is the portable option. Snapshot → diff → assert delta == 0. [CITED: andy-pearce.com tracing-macos-filesystem-events] |
| Deterministic LLM mocking across processes | Writing a stub inside XCTest | `CopilotKit/llmock` (OSS deterministic mock LLM with SSE streaming) — or port its fixture-routing pattern into `MockLLMProvider` | llmock is 2026-purpose-built for this. Either adopt it or mirror its pattern. [CITED: github.com/CopilotKit/llmock; llmock.copilotkit.dev] |
| Checklist mechanization | Hand-maintained markdown checklist | YAML manifest + ChecklistRunner that grep/structural-checks at build time | Markdown drifts silently; YAML + runner fails the build. |

**Key insight:** The 2026-standard LLM eval stack is a **fractured ecosystem** — promptfoo (JS), AgentDojo (Python), InjecAgent (Python), llmock (Node). None wraps our Swift orchestrator. The right play is **curate corpora from these sources** (they're the ground-truth taxonomies) but **run them through Jarvis's real pipeline** via a Swift-native harness. This is the only way the `SEC-06` turnNonce + `SEC-07` sanitize + `MCP-04` confirmation path actually gets exercised by the tests.

---

## Runtime State Inventory

*Not applicable — P8 is greenfield harness code. No rename/refactor/migration. No runtime state from prior phases moves or transforms; the harness reads the replay log produced by P4 (OBS-02) and the corpus artifacts committed in `packages/Harness/Corpora/`.*

**Category verification:**
- Stored data: None — harness reads replay logs, writes new ones to `/tmp`.
- Live service config: None.
- OS-registered state: None.
- Secrets/env vars: Anthropic key (Keychain, from P1) is consumed when `--live` flag is set; no new keys. Live Ollama eval uses the existing `127.0.0.1:11434` binding (no change).
- Build artifacts: `packages/Harness/.build/` — stock SPM, standard `.gitignore`-covered.

---

## Common Pitfalls

### Pitfall 1: Replay Bit-Rot After Refactors

**What goes wrong:** A refactor changes a deterministic field's format (e.g., `toolCallId` serialization). Every recorded session's replay now fails the oracle, blocking shipping gate for reasons unrelated to regressions.

**Why it happens:** Replay logs capture the *runtime shape* at record time. Refactor migrates the runtime shape without migrating historical logs.

**How to avoid:** Every shape-change PR must either (a) include a replay-log migration that rewrites historical logs, or (b) bump a `replaySchemaVersion` in the log header and have `ReplayOracle` reject older-version logs with a clear "re-record after refactor X" error. Policy: prefer (b) unless the historical logs are load-bearing for regression tracking.

**Warning signs:** Replay oracle fails across every historical session simultaneously after a merge. (Single-session failures are likely real regressions.)

### Pitfall 2: Injection Corpus That Tests the Test Harness, Not the App

**What goes wrong:** Corpus attacks phrased as direct overrides of system instructions (the classic "please disregard earlier guidance and ..." family) fail vacuously because the LLM never saw them — they were stripped by the sanitize pipeline or wrapped in a nonce that the model ignored. The harness reports "all blocked" but the defense is untested because the payload was never presented in the attacker's intended position.

**Why it happens:** Corpus items placed as *user input* hit `AgentOrchestrator.submit(userMessage: ...)` and get treated as trusted instructions. Real attackers place payloads in *tool results* (indirect prompt injection) where `SEC-06` wrap + `SEC-07` sanitize actually live.

**How to avoid:** Every injection-corpus item declares a `vector` field: `.userInput`, `.toolResult(toolName:)`, `.mcpHelperOutput`, `.clipboardContent`, `.appleScriptDescription`. Runner places the payload at the declared vector. Majority of the 20+ corpus items should be `.toolResult` or `.mcpHelperOutput` — these are the vectors our architecture spends effort defending.

**Warning signs:** 100% pass rate on first run. Real injection corpora against real defenses hover at 85–99% pass with 1–15% representing paths you hadn't considered (Anthropic measures 1.4–10.8% success against Claude depending on safeguard level [VERIFIED: venturebeat.com anthropic-prompt-injection-failure-rates]).

### Pitfall 3: Live Ollama Eval That's Actually a Compile-Time Assumption

**What goes wrong:** `LiveOllamaRunner` assumes `qwen2.5-coder:32b` is pulled locally and the daemon is running. On a fresh checkout / CI machine, it either (a) silently skips because `127.0.0.1:11434` refuses connection, or (b) pulls the 20 GB model (1 hr) on first run, poisoning CI time.

**Why it happens:** Writing the runner in isolation and testing on the author's machine where Ollama is warm.

**How to avoid:** Preflight check at runner start: (1) `curl http://127.0.0.1:11434/api/tags` → 200 OR fail loud with "Ollama not running; start `ollama serve`" message; (2) `qwen2.5-coder:32b` in the returned `models` array OR fail loud with "run `ollama pull qwen2.5-coder:32b`". **Do NOT auto-pull.** Live eval is opt-in (`--live` flag); default shipping-gate skips it with clear "live-ollama skipped — run with `--live` to include" message.

**Warning signs:** CI pass rate mysteriously drops from 100% to ~88% on machines other than the author's.

### Pitfall 4: "Looks Done But Isn't" Checklist Entries That Bit-Rot

**What goes wrong:** A phase's checklist item was added in P2 SUMMARY.md: "bus-protocol-version handshake refuses mismatched bundles." Six months later, a refactor in P6 touches a shared Swift file and the refusal path is silently broken. The markdown checklist still says "done." Nobody notices until a real user hits the mismatch.

**Why it happens:** Markdown is documentation; it doesn't execute.

**How to avoid:** Each checklist item has (a) a natural-language description for humans, (b) a **mechanization path**: either a Swift test name, a grep/structural check, or an explicit "MANUAL:" marker with instructions. `ChecklistRunner` reads the YAML, runs or greps, fails build on any item that regressed. MANUAL items are allowed but must be visibly listed in every CI run output.

**Warning signs:** Checklist has items like "voice loop works end-to-end" with no mechanization path. Either write the test, or mark it MANUAL and accept that it doesn't block CI.

### Pitfall 5: Tool-Cap Recovery Test That Doesn't Distinguish "No Tools Offered" from "Tools Offered But Not Called"

**What goes wrong:** R4-L1 regression is "cap-recovery turn must pass `tool_choice: .none`." A test that only asserts "zero `.toolUseRequested` events" passes even if the test setup accidentally omitted the `tools` array entirely — that's indistinguishable from the correct `.none` path, and if a refactor stops passing `tool_choice` but *also* accidentally stops passing `tools`, the test stays green while the regression ships.

**Why it happens:** The event-count assertion is necessary but not sufficient.

**How to avoid:** Test asserts **both** (a) zero `.toolUseRequested` events AND (b) the outbound HTTP request body is inspected: Anthropic request body has `tool_choice: {"type": "none"}` field; Ollama request body has NO `tools` key. Use a URL-protocol mock that captures the request body bytes for inspection, not just response scripting.

**Warning signs:** R4-L1 test passes after a refactor that removed the `ToolChoice` parameter from `LLMProvider.stream(...)`. If that's possible, your test is incomplete.

### Pitfall 6: MCP Crash-Recovery Test Leaks Across Restarts

**What goes wrong:** 100-crash loop injects `SIGKILL`. After each crash, MCPClient lazy-restarts. If `FD_CLOEXEC` is missing on the parent's replay-log FD (MCP-08 regression), each helper inherits the FD and it stays open. By iter 50, the parent process has 50 dup'd FDs. `lsof` delta at end = 50 — catch.

**Why it happens:** FD_CLOEXEC enforcement is in `ChildSpawnGate` (MCP-08). A refactor that changes `posix_spawn` call site without going through the gate silently bypasses it.

**How to avoid:** `FDLeakDetector` snapshots `lsof -p <main-pid>` at iter 0, 10, 50, 100. Delta at iter 100 from iter 0 must equal the expected steady-state (replay-log FD, SQLite journal FD, etc — enumerate in a whitelist). Any unexpected FD fails the test with the FD name.

**Warning signs:** Steady-state FD count grows linearly with iteration count. Means a per-iteration FD is leaking.

### Pitfall 7: Audio-Graph Rebuild Test That Doesn't Reset Between Triggers

**What goes wrong:** Trigger 1 (device change) test rebuilds the graph. Test 2 (AEC fallback) starts from the post-rebuild state, not a clean one. A bug that only manifests on AEC-fallback from a **fresh** graph stays hidden because the prior test pre-warmed the path.

**Why it happens:** XCTest class-level setup instead of method-level.

**How to avoid:** Each of the 4 triggers gets its own test method with `setUp { engine = AVAudioEngine(); ... }` and `tearDown { engine.reset(); engine = nil }`. No shared engine state.

**Warning signs:** Re-ordering test methods changes pass/fail outcome. Means hidden state dependency.

---

## Code Examples

### Replay viewer invocation (OBS-03 entry)

```swift
// Source: jarvis-eval/main.swift (new)
import ArgumentParser
import Harness

struct JarvisEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jarvis-eval",
        subcommands: [Replay.self, CorpusInjection.self, /* … */, All.self]
    )
}

struct Replay: AsyncParsableCommand {
    @Argument var sessionDB: String
    @Flag var verbose: Bool = false

    func run() async throws {
        let recorded = try ReplayDB.open(path: sessionDB)
        let actual = try await ReplayRunner.run(recorded: recorded)

        let exclusions = ExclusionList.obs02Default
        let report = DriftClassifier.classify(
            recorded: recorded,
            actual: actual,
            exclusions: exclusions,
            recordingTemperature: recorded.meta.temperature
        )

        if report.passed {
            print("REPLAY PASS: \(report.expected.count) expected drifts (ID/timestamp/sampling).")
        } else {
            print("REPLAY FAIL:")
            for item in report.unexpected {
                print("  [\(item.category.rawValue)] \(item.field): \(item.recorded) → \(item.actual)")
            }
            throw ExitCode.failure
        }
    }
}
```

### Injection corpus item shape

```swift
// Source: Harness/Corpus/InjectionCorpus.swift (new)
public struct InjectionAttempt: Sendable, Identifiable {
    public let id: String
    public let category: Category  // direct, indirect, jailbreak, tool-result, encoded, etc.
    public let vector: Vector
    public let payload: String
    public let expectedOutcome: ExpectedOutcome

    public enum Vector: Sendable {
        case userInput
        case toolResult(toolName: String)
        case mcpHelperOutput(helperName: String)
        case clipboardContent
        case appleScriptSourceDescription
    }

    public enum ExpectedOutcome: Sendable {
        case blockedBySanitize          // SEC-07 strips it
        case wrappedInNonce             // SEC-06 wraps and model follows the system prompt
        case reachesModelButModelResists // model sees wrapped payload, declines
        case triggersConfirmationSheet  // reaches dispatch, MCP-04 sheet intercepts
    }
}

// 20+ items curated from:
//   - OWASP LLM01:2025 direct-injection examples
//   - InjecAgent's 1,054 test cases (sampling representative cases)
//   - AgentDojo tasks
//   - Jarvis-specific:
//     * AppleScript description claiming the script is safe
//     * MCP tool output containing </UNTRUSTED_CONTENT> probe for nonce leak
//     * Clipboard containing fake confirmation-sheet text
//     * Tool result with U+2028 / C0 controls to defeat naive sanitize
//     * Memory-extraction turn attacked via prior-turn content
//     * Bus message shaped to resemble BUS_PROTOCOL_VERSION handshake
public enum InjectionCorpus {
    public static let all: [InjectionAttempt] = [
        // 20+ entries
    ]
}
```

### FD-leak detector

```swift
// Source: Harness/FDLeakDetector.swift (new)
public struct FDSnapshot: Equatable {
    public let pid: Int32
    public let fds: Set<String>  // normalized "fd=7 path=/tmp/jarvis-replay.sqlite" style strings
}

public enum FDLeakDetector {
    public static func snapshot(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> FDSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", "\(pid)", "-F", "ftn"]   // terse machine-readable
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return FDSnapshot(pid: pid, fds: parseLsofTerse(data))
    }

    public static func delta(from before: FDSnapshot, to after: FDSnapshot) -> (added: Set<String>, removed: Set<String>) {
        (added: after.fds.subtracting(before.fds), removed: before.fds.subtracting(after.fds))
    }
}
```

### "Looks done but isn't" checklist manifest shape

```yaml
# .planning/phases/01-foundations/checklist.yaml
phase: 01-foundations
items:
  - id: P1-01
    description: "LSUIElement=YES keeps app out of Dock"
    mechanization:
      type: plist_check
      file: build/Build/Products/Release/Jarvis.app/Contents/Info.plist
      key: LSUIElement
      expected: true
  - id: P1-02
    description: "com.apple.developer.speech-recognition-assets entitlement present in signed archive"
    mechanization:
      type: codesign_grep
      identity: "Developer ID Application"
      pattern: "com.apple.developer.speech-recognition-assets"
      expected_count: 1
  - id: P1-03
    description: "Input Monitoring TCC denial surfaces HUD banner, not silent no-op (R4-S2)"
    mechanization:
      type: swift_test
      suite: ShellTests
      test: test_inputMonitoringDenialSurfacesBanner
  - id: P1-04
    description: "com.apple.security.cs.allow-unsigned-executable-memory is NOT in entitlements (forbidden)"
    mechanization:
      type: grep_negative
      file: App/Jarvis.entitlements
      pattern: "allow-unsigned-executable-memory"
      expected_count: 0
  # ... etc; each phase's SUMMARY.md feeds items here
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hand-rolled snapshot-diff as "eval" | Structured drift classifier with exclusion list + typed categorization | 2025 (industry convergence around deterministic replay) | Prevents both false positives (every ID drift ≠ bug) and false negatives (ordering bugs masked by "all fields present") |
| XCTest for everything | `swift-testing` for new parameterized corpus suites, XCTest retained for legacy | 2024 (`swift-testing` shipped) | Per-item diagnostics for corpus-driven tests; better Xcode 26 integration [CITED: developer.apple.com/swift-testing] |
| Cloud LLM in CI | Fixture-recorded SSE/NDJSON for deterministic runs; live mode opt-in via flag | 2024–2025 (cost + flakiness pressure) | CI is reproducible; fixture-capture scripts record new fixtures when real shapes change |
| Prompt-injection as "just keep trying examples" | OWASP LLM01:2025 taxonomy + AgentDojo/InjecAgent benchmarks as corpus source; structural defenses (nonces, sanitize) instead of string-match | 2024 (OWASP LLM Top 10) → 2025 (agent-specific benchmarks) | Corpus is reproducible and grounded in public taxonomy; defenses are auditable structurally rather than by example [CITED: genai.owasp.org/llmrisk/llm01-prompt-injection; github.com/uiuc-kang-lab/InjecAgent; arxiv.org/abs/2406.13352] |
| Sampled eval runs on commit | Gate at shipping only; dev-cycle eval via individual pillars | 2024 onward (full-matrix too slow for inner loop) | Faster iteration; shipping gate still comprehensive |
| FAR/FRR measured informally for wake word | Explicit corpus + targets (FAR < 0.5/hr, FRR < 5%) [CITED: picovoice.ai benchmarks; medium.com/neural-engineer openwakeword] | 2020–2023 industry baselines; Jarvis adopts 2026 | Voice-pipeline changes have measurable regression guard |

**Deprecated/outdated:**
- **String-match "substring-of-known-injection → blocked" defenses.** Every modern taxonomy (OWASP LLM01:2025, Anthropic red-team) shows these fail trivially against obfuscated/encoded attacks. Structural defenses (turnNonce-wrapped untrusted content + model trained to respect nonce boundary) are 2026-standard.
- **Single-shot eval "does the model answer correctly."** Replaced by multi-axis eval: correctness, injection resistance, tool-call discipline (no extra `.toolUseRequested` on recovery), streaming correctness, crash-recovery, audio-rebuild.
- **"CI = green" as shipping gate.** Shipping gate = `scripts/shipping-gate.sh` passes locally on the host machine on the same macOS version and hardware the daily user runs. Personal-project-scale: no cross-platform matrix needed, but the single-machine shipping-gate run IS load-bearing.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `swift-testing` parameterized tests support corpus-driven one-test-per-item emission with per-item diagnostics in Xcode 26 | §Pattern 3 | Fall back to XCTest `XCTContext.runActivity(named:)`; no behavior change, lose some Xcode UI polish |
| A2 | `lsof -p <pid> -F ftn` is available on macOS 26 Tahoe (has been stable since 10.x) | §FD-Leak Detector | Low — lsof is BSD-core; API has been stable for 20 years |
| A3 | Anthropic SSE capture script can safely record live streams into `.sse` fixtures — no PII in the test prompts used for capture | §Fixture recording | Requires review of capture prompts before commit; accept as discipline rather than automation |
| A4 | AgentDojo / InjecAgent corpus items are re-usable as-is into our corpus (license compatibility) | §Don't Hand-Roll row for corpus curation | InjecAgent is Apache-2.0 per its GitHub — license-compatible [CITED: github.com/uiuc-kang-lab/InjecAgent]; AgentDojo is MIT [CITED: github.com/ethz-spylab/agentdojo]; both permit derivative corpus use with attribution |
| A5 | `qwen2.5-coder:32b` tool-calling remains stable through Ollama patch releases between P6 and P8 | §Live Ollama eval | Run P8 local-eval AGAINST the Ollama version pinned in P4/P5; capture Ollama version in replay-log meta so regressions point at the right cause |
| A6 | `AVAudioEngine` supports synthetic device-change notification injection via private API or mock layer for integration testing | §Pitfall 7 / §Audio-Graph Rebuild | MEDIUM risk — if no injection API, the 4-trigger matrix degrades to 3 triggers with device-change being manual. Planner should probe `AVAudioSession` notification-posting API early. |
| A7 | OBS-02 exclusion list is finalized in P4 (`row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce`) and needs no extension in P8 | §Drift Classification | LOW — if extension is needed (e.g., embedding vectors added in P7 prove nondeterministic), add to `ExclusionList.nondeterministicUnderSampling` as a P8 addition |
| A8 | The 20+ injection corpus items cover enough vectors that first-run-all-pass is itself a red flag (per §Pitfall 2 warning sign) | §Common Pitfalls | MEDIUM — if first-run-all-pass IS accurate (our defenses are genuinely strong), the pitfall warning is overly conservative. Mitigate by including 2–3 items we EXPECT to succeed in penetrating to the confirmation-sheet layer (then get blocked by the user confirmation requirement — which is the correct deep-defense behavior). |

---

## Open Questions (RESOLVED)

1. **How many historical sessions should the OBS-03 replay oracle run in CI?** **RESOLVED: D-08 + D-10** — 5–10 hand-selected golden sessions covering 8 archetypes; full historical replay is opt-in audit via `--all`, not the gate.
   - What we know: Each session is a SQLite file; running one replay takes roughly as long as the original turn (LLM stream + tool calls). CI budget is finite.
   - What's unclear: 10 sessions? 100? All sessions?
   - Recommendation: Define a `Corpora/replay-golden/` subset (5–10 hand-selected sessions covering: short turn, long multi-tool turn, cap-recovery turn, confirmation-approved turn, confirmation-denied turn, barge-in turn, stream-truncation retry turn). Running this subset is the gate; full historical replay is an opt-in audit.

2. **Should the eval matrix gate on BOTH fixture AND live Anthropic, or fixture only?** **RESOLVED: D-04 + D-05** — fixture-only is the shipping gate; `--live` is opt-in for manual release checks (`JARVIS_LIVE_EVAL=1` env-var or interactive confirmation).
   - What we know: Fixture gives deterministic CI; live catches API-shape regressions from Anthropic side (e.g., new field in response, cache-ttl default shift).
   - What's unclear: Is live-Anthropic a shipping gate or a manual release check?
   - Recommendation: Fixture is the shipping gate. Live Anthropic is `jarvis-eval corpus-sse --live` — run manually before releasing a new Jarvis build. Add a calendar reminder, not a CI automation.

3. **When wake-hysteresis corpus FAR exceeds 0.5/hr or FRR exceeds 5%, does the build fail or warn?** **RESOLVED: D-18** — fail at FAR > 1.0/hr OR FRR > 10% (clearly broken line); warn between 2026-published targets and the fail line.
   - What we know: 2026-standard targets are published [CITED: picovoice.ai wake-word-benchmarks].
   - What's unclear: Personal-project tolerance.
   - Recommendation: Fail at FAR > 1.0/hr OR FRR > 10% (the "clearly broken" line); warn between published targets and fail line. Warnings are visible in shipping-gate output, don't block ship.

4. **Should MCP crash-recovery load test run 100 crashes, or something smaller for CI time budget?** **RESOLVED: D-19** — profile-then-decide; 100 if at most 200 ms/crash, 50 with `--extended` for 500 if higher.
   - What we know: Requirement in ROADMAP says 100 injected helper crashes. Each crash = spawn + IPC handshake + kill, ~100ms-1s each.
   - What's unclear: 100s total for this pillar is reasonable; 10s per crash × 100 = 17 min is not.
   - Recommendation: Profile in first plan; if cycle time is > 200ms/crash, reduce to 50 crashes (still enough to detect linear FD leaks) and add a `--extended` flag that runs 500. Document the target in REQUIREMENTS.md if it's mutated.

5. **How is the "looks done but isn't" checklist bootstrapped from already-completed phases?** **RESOLVED: D-15** — P8 retroactively sweeps P1–P7 SUMMARY.md files into per-phase `checklist.yaml` manifests during plan 08-04; per-phase ownership going forward.
   - What we know: P1 is partially complete. P1's 01-01-SUMMARY and 01-02-SUMMARY have implicit items (see §Pitfall 4).
   - What's unclear: Does the P8 planner author checklist YAMLs retroactively for P1–P7, or does each phase's `/gsd-verify-phase` own populating its own YAML?
   - Recommendation: Each phase's `/gsd-verify-phase` output adds its own `checklist.yaml`. P8 planner authors the `ChecklistRunner` that reads all YAMLs + runs mechanizations; it does NOT author retroactively. If a phase finished before this pattern existed (P1 in flight), P8 executes a sweep pass across P1–P7 SUMMARY.md files to extract items and propose YAMLs for user review.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Ollama daemon | Live Ollama eval pillar (c) | ✓ assumed (CLAUDE.md) | Whatever was pinned in P4/P5 | NDJSON fixture path covers offline case |
| `qwen2.5-coder:32b` pulled | Live Ollama eval pillar (c) | ✓ assumed (CLAUDE.md) | 32B GGUF | Skip live pillar with `--live` flag absent |
| Anthropic API key (Keychain) | Live Anthropic eval (opt-in) | ✓ written by P1-04 wizard | — | SSE fixture path covers offline case |
| `/usr/sbin/lsof` | FD-leak detector | ✓ BSD-core on macOS | stable | None needed |
| `AVAudioEngine` device-change injection API | Audio-graph rebuild pillar (g) | ?? — probe at planning | — | Degrade to 3/4 triggers; mark device-change as MANUAL checklist item |
| Xcode 26 (`swift-testing`) | New P8 suites | ✓ (project requirement) | 26.4.1 | Use XCTest for everything; lose parameterized diagnostics |
| `git` + `.planning/phases/**/checklist.yaml` | ChecklistRunner | ✓ (project invariant) | — | None |

**Missing dependencies with no fallback:**
- None — every pillar has a fallback path or is opt-in.

**Missing dependencies with fallback:**
- Live Ollama without `qwen2.5-coder:32b` pulled → fixture path.
- Live Anthropic without API key → fixture path.
- `AVAudioEngine` synthetic device-change → manual test.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `swift-testing` (Xcode 26 bundled) for new P8 suites; XCTest for inherited infrastructure |
| Config file | `packages/Harness/Package.swift` (new); existing `Package.swift` files in each package |
| Quick run command | `cd packages/Harness && swift test --filter <SuiteName>` |
| Full suite command | `scripts/shipping-gate.sh` (wraps `jarvis-eval all`) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| OBS-03 | Replay viewer re-runs recorded session deterministically | integration | `jarvis-eval replay <session>` | Wave 0 (new) |
| OBS-03 | Drift classifier separates expected from unexpected drift | unit | `swift test --filter DriftClassifierTests` | Wave 0 |
| OBS-03 | Drift oracle PASS on golden-replay corpus (5–10 sessions) | integration | `jarvis-eval replay --all Corpora/replay-golden/` | Wave 0 |
| OBS-04 | Injection corpus: 20+ attempts all blocked per declared vector | integration | `jarvis-eval corpus-injection` | Wave 0 |
| OBS-04 | SSE fixture corpus byte-replays cleanly through Anthropic decoder | unit | `jarvis-eval corpus-sse` | Wave 0 |
| OBS-04 | Ollama NDJSON fixtures + live eval vs `qwen2.5-coder:32b` | integration | `jarvis-eval corpus-ndjson [--live]` | Wave 0 |
| OBS-04 | Tool-cap recovery: zero `.toolUseRequested` on recovery turn (R4-L1) | integration | `jarvis-eval cap-recovery` | Wave 0 |
| OBS-04 | Wake hysteresis FAR/FRR within targets | integration | `jarvis-eval wake-corpus` | Wave 0 |
| OBS-04 | MCP crash-recovery: 100 crashes, zero FD leak delta | integration | `jarvis-eval mcp-crash` | Wave 0 |
| OBS-04 | Audio-graph rebuild: 4 triggers × canonical 6-step teardown | integration | `jarvis-eval audio-rebuild` | Wave 0 |
| OBS-04 | "Looks done but isn't" checklist all pass | structural | `jarvis-eval checklist` | Wave 0 |
| OBS-04 | Entire matrix passes as a shipping gate | integration | `scripts/shipping-gate.sh` | Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --filter <SuiteUnderDevelopment>` — individual pillar being worked on
- **Per wave merge:** `jarvis-eval all --skip-live` — full matrix minus opt-in live pillars
- **Phase gate:** `scripts/shipping-gate.sh --live` — full matrix including live Anthropic + live Ollama (before declaring P8 complete)

### Wave 0 Gaps
- [ ] `packages/Harness/Package.swift` — new package manifest
- [ ] `packages/Harness/Sources/jarvis-eval/main.swift` — CLI entry
- [ ] `packages/Harness/Sources/Harness/**` — runners, oracle, adapters
- [ ] `packages/Harness/Tests/HarnessTests/**` — tests of the harness
- [ ] `packages/Harness/Corpora/**` — corpus data committed
- [ ] `scripts/shipping-gate.sh` — CI entry
- [ ] `scripts/capture-anthropic-sse.sh` — fixture-capture helper
- [ ] `packages/Harness/Corpora/replay-golden/` — 5–10 hand-selected session SQLite files
- [ ] `.planning/phases/*/checklist.yaml` — per-phase checklist manifests (authoring pattern during sweep pass)
- [ ] Add `packages/Harness` to top-level `project.yml` as local SPM + add `jarvis-eval` executable target

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Personal single-user; no multi-tenant auth |
| V3 Session Management | no | Same reason |
| V4 Access Control | partial | Confirmation broker gates destructive MCP tools (MCP-04); P8 corpus validates this boundary holds |
| V5 Input Validation | **yes** | Injection corpus exercises `SEC-07` sanitize pipeline + `SEC-06` nonce wrap across all untrusted boundaries (MCP tool results, clipboard, AppleScript source) |
| V6 Cryptography | no | No net-new crypto in P8; Keychain access delegates to Apple's Security.framework |
| V7 Error Handling & Logging | **yes** | Harness output uses same redaction (`Redact.apply`) so harness logs don't leak API keys when CI output is captured |

### Known Threat Patterns for harness code

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Corpus data contains real API key from capture session | Information Disclosure | `scripts/capture-anthropic-sse.sh` redacts `Authorization: Bearer` before writing; pre-commit hook greps `packages/Harness/Corpora/` for common key patterns (`sk-ant-`, `AKIA`, `ghp_`, `sk-`) and fails if found |
| `--live` flag accidentally run in CI burning Anthropic budget | Denial of Service (financial) | CI explicitly invokes `--skip-live`; `--live` requires `JARVIS_LIVE_EVAL=1` env var OR interactive confirmation; default-off |
| Injection corpus items leak into training data if accidentally sent to Anthropic | Information Disclosure | Corpus items never leave the local machine except when running `jarvis-eval corpus-injection --live` (explicit opt-in); default fixture-only run is offline |
| Test harness gains code-execution via a malicious injection corpus item | Elevation of Privilege | Harness runs in normal user context; MCP helpers already sandboxed per-helper TCC; corpus items are data, not code; confirmation broker gates destructive tool dispatch regardless of payload origin |
| ChecklistRunner regex patterns become stale and always-pass | Tampering (via neglect) | Each YAML item MUST include an `expected_count` or `expected_value`; runner fails on missing field (not just missing match). Catches "grep pattern no longer matches anything" silent-green failure mode. |

---

## Sources

### Primary (HIGH confidence)

- [OWASP LLM01:2025 Prompt Injection](https://genai.owasp.org/llmrisk/llm01-prompt-injection/) — canonical taxonomy for injection corpus curation
- [OWASP LLM Prompt Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html) — structural-defense recommendations that align with our `SEC-06` + `SEC-07`
- [InjecAgent benchmark (uiuc-kang-lab)](https://github.com/uiuc-kang-lab/InjecAgent) — 1,054 test cases; Apache-2.0 licensed; corpus source
- [AgentDojo (ethz-spylab)](https://github.com/ethz-spylab/agentdojo) — dynamic env for tool-integrated agent injection testing; MIT; corpus source
- [AgentDojo paper](https://arxiv.org/abs/2406.13352) — methodology for context-dependent agent injection evaluation
- [Anthropic: prompt-injection failure rates published](https://venturebeat.com/security/prompt-injection-measurable-security-metric-one-ai-developer-publishes-numbers) — measured 1.4% successful attacks with safeguards on Claude Opus 4.5 vs 10.8% without — informs our "100% first-run pass is a red flag" warning
- [swift-testing documentation](https://developer.apple.com/documentation/testing) — parameterized test pattern
- [swift-argument-parser (apple)](https://github.com/apple/swift-argument-parser) — CLI subcommands
- [openWakeWord main repo](https://github.com/dscripka/openWakeWord) — `hey_jarvis` model + evaluation methodology
- [Evaluation of OpenWakeWord Engine (Neural Engineer)](https://medium.com/neural-engineer/evaluation-of-openwakeword-engine-false-reject-performance-4d440ee8c4b4) — FAR/FRR measurement methodology
- [Wake Word Benchmarks: How to Verify Vendor Claims (2025)](https://picovoice.ai/blog/wake-word-benchmarks/) — 2026-standard benchmarking practice
- [.planning/research/ARCHITECTURE.md](../../research/ARCHITECTURE.md) — internal; data-flow + R4-L7 routing
- [.planning/research/RESEARCH-DELTAS.md](../../research/RESEARCH-DELTAS.md) — internal; Opus 4.7 / Qwen3 / Orpheus / Silero deltas
- [.planning/REQUIREMENTS.md](../../REQUIREMENTS.md) — OBS-02, OBS-03, OBS-04, SEC-06, SEC-07 language
- [.planning/ROADMAP.md §Phase 8](../../ROADMAP.md) — success criteria (a) through (h)

### Secondary (MEDIUM confidence)

- [CopilotKit/llmock](https://github.com/CopilotKit/llmock) — deterministic mock LLM with SSE streaming; 2026-current; pattern reference
- [TanStack AI testing across 7 providers](https://tanstack.com/blog/how-we-test-tanstack-ai-across-7-providers) — fixture/mock pattern across providers
- [Sakura Sky — Trustworthy AI Agents: Deterministic Replay](https://www.sakurasky.com/blog/missing-primitives-for-trustworthy-ai-part-8/) — 2026 replay architecture commentary
- [Promptfoo — Red Team Claude](https://www.promptfoo.dev/blog/red-team-claude/) — industry-standard LLM red-team tooling; pattern reference
- [Anthropic streaming docs](https://docs.anthropic.com/en/docs/build-with-claude/streaming) — SSE event-type reference for fixture corpus
- [Tracing macOS Filesystem Events (Andy Pearce)](https://www.andy-pearce.com/blog/posts/2019/Jun/tracing-macos-filesystem-events/) — lsof on macOS

### Tertiary (LOW confidence — flagged for validation at plan time)

- [Prompt Injection in Production Agents: 2026 Taxonomy (DigitalApplied)](https://www.digitalapplied.com/blog/prompt-injection-production-agents-2026-taxonomy) — blog-tier; cross-verify taxonomy items against OWASP before adopting
- [Anthropic anthropic-sdk-typescript#842 — streaming drop without message_stop](https://github.com/anthropics/anthropic-sdk-typescript/issues/842) — bug reference; informs fixture corpus "mid-disconnect" case but hasn't been independently replicated on Opus 4.7
- [Anthropic anthropic-sdk-typescript#867 — streaming idle timeout](https://github.com/anthropics/anthropic-sdk-typescript/issues/867) — same; informs timeout pillar
- [`AgentDyn` benchmark (SaFo-Lab)](https://github.com/SaFo-Lab/AgentDyn) — 2026 dynamic open-ended injection benchmark; consider for corpus augmentation v2

---

## Metadata

**Confidence breakdown:**
- Replay oracle architecture: HIGH — pattern converged in 2025–2026 industry practice; OBS-02 exclusion list already locked in P4
- Drift classification logic: HIGH — pure Swift function; unit-testable; no external dependencies
- Injection corpus sourcing: HIGH — OWASP + InjecAgent + AgentDojo are public, taxonomized, license-compatible
- SSE/NDJSON fixture decoding: HIGH — provider SSE/NDJSON shapes are documented; capture-and-replay is a well-trodden pattern
- Live Ollama eval: HIGH — `qwen2.5-coder:32b` is the locked baseline; `/api/chat` contract documented
- Tool-cap regression test: HIGH — R4-L1 specification is unambiguous; URL-protocol mock for request-body inspection is standard
- Wake-hysteresis corpus: MEDIUM — FAR/FRR targets are industry-standard, but our specific background-noise profile is personal (Mac microphone) and corpus must be recorded per-host for real accuracy
- MCP crash-recovery + FD-leak detection: MEDIUM — lsof parsing is shell-fragile; `-F ftn` terse output is stable but edge cases (FIFOs, socket inheritance) need empirical probing
- Audio-graph rebuild test matrix: MEDIUM — `AVAudioEngine` synthetic device-change injection API availability is unconfirmed; A6 assumption may force degradation
- "Looks done but isn't" checklist mechanization: MEDIUM — YAML manifest pattern is clean, but retroactively extracting items from P1–P7 SUMMARY.md is a judgment call per item

**Research date:** 2026-04-22
**Valid until:** 2026-05-22 (30 days for stable fields; shorter for Ollama version pin and injection taxonomy which evolve)
