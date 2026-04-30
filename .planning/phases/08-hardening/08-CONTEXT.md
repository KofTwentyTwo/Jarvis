# Phase 8: Hardening - Context

**Gathered:** 2026-04-30
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 8 delivers the **shipping gate** over the v1 pipeline — not new runtime tiers. Two REQ-IDs (OBS-03, OBS-04), eight distinct harness pillars in practice. The gate proves the pipeline works end-to-end against curated corpora and historical sessions, and that none of the architectural invariants from earlier phases have silently regressed:

1. **OBS-03 — Replay-roundtrip oracle.** A replay viewer re-runs a recorded session through the **real** `AgentOrchestrator` (not a simulator) via a `.replay` `TurnSource` that suppresses TTS + webview dispatch (R4-L7 pattern). A drift classifier compares recorded vs actual replay logs against a typed exclusion list, categorizing each diff as expected (IDs/timestamps/sampling under temp>0) or unexpected (schema, ordering, truncation, value bugs). PASS iff `unexpected.isEmpty`.

2. **OBS-04 — 8-pillar evaluation matrix** runnable per-pillar (`swift test --filter <SuiteName>`) AND as a single `scripts/shipping-gate.sh`:
   - (a) 20+ prompt-injection corpus attempts, all blocked at their declared vector (SEC-06 nonce wrap + SEC-07 sanitize)
   - (b) SSE fixture corpus byte-replays cleanly through the Anthropic decoder (offline)
   - (c) Ollama NDJSON fixtures + opt-in live evaluation against `qwen2.5-coder:32b`
   - (d) Tool-cap recovery produces zero `.toolUseRequested` AND request body inspection confirms `.none` serialization (R4-L1 regression guard)
   - (e) Wake-hysteresis corpus FAR/FRR within targets (FAR < 0.5/hr, FRR < 5%)
   - (f) MCP crash-recovery: at least 50 helper crashes with FD-leak delta = 0 (steady-state whitelist)
   - (g) Audio-graph rebuild across the four canonical triggers (device change / AEC fallback / mic re-grant / sustained ring overflow)
   - (h) "Looks done but isn't" checklist per phase, mechanized via YAML + structural checks

P8 is a **harness** — it does not introduce observability (DevOverlay + ReplayLog + structured logs all land in P4). It does not fix bugs found by the harness; failures route back to the owning phase, with the P8 suite serving as the regression test thereafter.

</domain>

<spec_lock>
## Locked Requirements (ROADMAP.md)

ROADMAP.md §Phase 8 success criteria 1–2 are the contract. Success criteria are NOT re-derived in planning; they are inputs. The 8-pillar matrix labels (a)–(h) are stable and used as plan/test naming anchors throughout downstream work.

</spec_lock>

<decisions>
## Implementation Decisions

### Plan Structure (Area 0 — locked from research recommendation)
- **D-01:** **Four plans**, decomposed by harness substrate rather than by REQ-ID:
  - `08-01-replay-oracle` — `packages/Harness` SPM scaffolding, `ReplayRunner`, `DriftClassifier`, `ExclusionList`, `DriftReport`, `ReplayMCPAdapter`, `MockLLMProvider` for fixture-driven LLM streams (OBS-03 + harness substrate)
  - `08-02-corpora-curation-and-runners` — Injection corpus (20+ items), SSE/NDJSON fixture corpora, wake-hysteresis corpus + runners; pillars (a)/(b)/(c-fixture)/(e) (OBS-04 sub-suites)
  - `08-03-live-and-integration-runners` — Live Ollama runner + MCP crash-recovery runner with `FDLeakDetector` + audio-graph rebuild matrix + tool-cap recovery; pillars (c-live)/(d)/(f)/(g) (OBS-04 sub-suites)
  - `08-04-checklist-runner-and-shipping-gate` — `ChecklistRunner` reading per-phase YAML manifests, sweep authoring of P1–P7 manifests, `jarvis-eval` CLI subcommand wiring, `scripts/shipping-gate.sh` (OBS-04 pillar (h) + integration of all pillars)
- **D-02:** All harness code lives in a **new `packages/Harness` SPM module**. Library target `Harness` for reusable plumbing; executable target `jarvis-eval` (swift-argument-parser-driven CLI) for the eight subcommands. Tests-of-the-harness in `Tests/HarnessTests/`. Corpora in `Corpora/` directory copied into the bundle as resources.
- **D-03:** New P8 suites use **`swift-testing`** (Xcode 26 bundled) for parameterized one-test-per-corpus-item emission with per-item diagnostics. Existing XCTest suites in P1–P7 are not migrated.

### Live-Mode Policy (Area 1 — locked from research recommendation)
- **D-04:** **Fixture is the shipping gate; live is opt-in.** Default `scripts/shipping-gate.sh` runs every pillar fixture-only (no Anthropic egress, no Ollama daemon required). Live runs require `--live` flag AND `JARVIS_LIVE_EVAL=1` environment variable (or interactive y/N prompt) — defends against accidental Anthropic burn in CI or autonomous loops.
- **D-05:** **Live Anthropic SSE evaluation** is `jarvis-eval corpus-sse --live` — operator runs manually before releasing a new Jarvis build (think calendar reminder, not CI cron). Catches Anthropic-side API-shape regressions (new field, cache-TTL default shift) that fixture-only would miss.
- **D-06:** **Live Ollama evaluation** preflights with `curl http://127.0.0.1:11434/api/tags`; fails loud with "Ollama not running; start `ollama serve`" if unreachable AND fails loud with "run `ollama pull qwen2.5-coder:32b`" if model missing. **Never auto-pulls.** Default shipping gate skips live-Ollama with a visible "live-ollama skipped — run with `--live` to include" line so silent skip cannot masquerade as pass.
- **D-07:** **Anthropic API key sourcing for `--live`** uses the existing P1 Keychain path (`SystemKeychainStore`). Pre-commit hook greps `packages/Harness/Corpora/` for `sk-ant-`, `AKIA`, `ghp_`, `sk-` patterns and fails on hit — defends against accidental capture-script artifact commits.

### Replay Golden Corpus (Area 2 — locked from research recommendation)
- **D-08:** **5–10 hand-selected sessions** committed under `packages/Harness/Corpora/replay-golden/`, covering at minimum:
  1. Short single-turn (no tool calls)
  2. Long multi-tool turn (at least 2 tool calls)
  3. Tool-cap recovery turn (R4-L1 path)
  4. Confirmation-approved AppleScript turn
  5. Confirmation-denied AppleScript turn
  6. Voice barge-in turn (`cancelAndSubmit` displacement)
  7. Stream-truncation retry turn (`retry_of` re-snapshot path)
  8. Vision frame-attach turn (T1 Gemma 4 routing — once P7 sessions exist)
- **D-09:** Sessions are **captured live during normal use** by the operator on the host Mac, then promoted to `replay-golden/` via a `scripts/promote-replay-session.sh` helper that copies the SQLite + records the temperature/model meta into a sidecar JSON (so the drift classifier knows whether `samplingNondeterminism` exclusions apply). Promotion is a deliberate manual step — no auto-collection.
- **D-10:** **Full historical replay** (every session ever recorded) is **opt-in audit only**, not the gate. `jarvis-eval replay --all` runs it; `scripts/shipping-gate.sh` runs only the curated subset. Rationale: CI-style budget on a personal-project shipping check.
- **D-11:** **Replay schema versioning.** Replay log writers (P4) and `ReplayOracle` agree on a `replaySchemaVersion` field in the log header. Shape-changing refactors bump the version; oracle rejects older-version logs with a clear "re-record after refactor X" error rather than failing on every historical session.

### Inherited P6/P7 Debt (Area 3 — STATE.md locks scope; treatment locked from researcher A6 + recommendation)
- **D-12:** **P8 inherits the three deferred items** from STATE.md "Phase 6 → Phase 8 Deferred Items" — they are in scope:
  1. Resolve Xcode 26 ad-hoc Debug bundle launch fragility (`SWIFT_ENABLE_DEBUG_DYLIB=NO` ignored; Info.plist marker reverted post-build; `codesign --verify` reports `invalid Info.plist` after BUILD SUCCEEDED)
  2. Drive Plan 06-05's six UAT gates (VOICE-07/09/12/13/14) on a Release-signed Developer ID archive
  3. Empirical Orpheus TTFA measurement (target 150–250 ms); flip `features.tts.tier2 = "ttskit"` if > 250 ms
- **D-13:** **These land in plan `08-03-live-and-integration-runners` as a Wave-1 prerequisite**, not in the harness substrate. Rationale: pillar (g) audio-graph rebuild + the manual-checklist Orpheus TTFA item both transitively depend on the launch blocker being resolved. Resolving it once unblocks both. UAT gates surface as `MANUAL:` checklist items in `phase=06-voice/checklist.yaml` rather than synthetic XCTest cases — they require physical hardware + microphone interaction.
- **D-14:** **Audio-graph rebuild pillar (g) graceful degradation** if `AVAudioEngine` synthetic device-change injection API is unavailable (researcher A6, MEDIUM risk): planner probes the API early in `08-03`; if missing, the device-change trigger downgrades to a `MANUAL:` checklist item with explicit operator instructions ("plug in / unplug USB-C audio interface mid-utterance"). The other three triggers (AEC fallback / mic re-grant / sustained ring overflow) remain automated. **No degradation is silent** — visible in shipping-gate output.

### Checklist Bootstrap (Area 4 — locked from research Q5 recommendation)
- **D-15:** **P8 retroactively sweeps P1–P7** (since those phases pre-date this pattern). Each `.planning/phases/<XX>-<slug>/checklist.yaml` is authored during plan `08-04` by extracting items from the phase's `SUMMARY.md` files + folding the existing 18 `scripts/check-*.sh` scripts as `type: script` mechanizations. Going forward, each phase's `/gsd-verify-phase` owns adding its own YAML.
- **D-16:** **Mechanization types accepted by `ChecklistRunner`:** `swift_test` (suite + test name), `script` (relative path; exit code = pass/fail), `grep_negative` (file + pattern + `expected_count: 0`), `grep_positive` (file + pattern + `expected_count: N`), `plist_check` (file + key + expected value), `codesign_grep` (identity + pattern + expected_count), `MANUAL:` (free-form description; visible in CI output as warning row, never blocks).
- **D-17:** **`expected_count` / `expected_value` is required** on every grep-style item (catches "regex no longer matches anything" silent-green failure mode per researcher §Security Domain). MANUAL items are explicitly listed in every shipping-gate run output — never hidden in summaries.

### Pillar-Specific Threshold Decisions (Area 5 — locked from research Q3/Q4 recommendations)
- **D-18:** **Wake hysteresis** (pillar e) — fail at `FAR > 1.0/hr` OR `FRR > 10%` (clearly broken line); warn between 2026-published targets (`FAR < 0.5/hr`, `FRR < 5%`) and the fail line. Warnings are visible in shipping-gate output but don't block ship. Corpus is recorded per-host on the operator's Mac (background-noise profile is personal); openWakeWord community TP/TN clips seed the corpus, augmented with synthetic noise/reverb.
- **D-19:** **MCP crash-recovery** (pillar f) — first plan profiles per-crash cycle time. If at most 200 ms/crash, run **100 crashes** as ROADMAP specifies. If above 200 ms/crash, reduce to **50 crashes** (still enough to detect linear FD leaks) with `--extended` flag for 500. Any reduction below 100 is documented in REQUIREMENTS.md OBS-04 commentary.
- **D-20:** **Drift classifier exclusion list** inherits the OBS-02 set verbatim (`row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce`) AND adds an `nondeterministicUnderSampling` set populated empirically when capturing the golden corpus (e.g., `textDelta` content under `temperature > 0`, `embedding` vectors). The set is in `Corpora/replay-golden/exclusions.json` so future fields can be added without code changes.
- **D-21:** **Tool-cap recovery test** (pillar d) asserts BOTH (a) zero `.toolUseRequested` events on the recovery turn AND (b) outbound HTTP request body bytes captured by a URL-protocol mock confirm `tool_choice: {"type": "none"}` (Anthropic) / no `tools` key (Ollama). Event-count assertion alone is necessary-but-not-sufficient (researcher Pitfall 5).

### Injection Corpus Composition (Area 6 — locked from research recommendation)
- **D-22:** **20+ injection corpus items** sourced from OWASP LLM01:2025 + InjecAgent (Apache-2.0) + AgentDojo (MIT) + Jarvis-specific vectors. **Majority must be `.toolResult` or `.mcpHelperOutput` vectors** (where SEC-06 nonce wrap + SEC-07 sanitize actually live), not `.userInput` (researcher Pitfall 2 — `.userInput` placement tests the test harness, not the defenses).
- **D-23:** **Jarvis-specific corpus items** (mandatory inclusion):
  - AppleScript description claiming the script is safe
  - MCP tool output containing `</UNTRUSTED_CONTENT>` probe for nonce-leak attempts
  - Clipboard containing fake confirmation-sheet text
  - Tool result with `U+2028` / C0 controls / bidi / zero-width characters to defeat naive sanitize
  - Memory-extraction turn attacked via prior-turn content
  - Bus message shaped to resemble `BUS_PROTOCOL_VERSION` handshake
- **D-24:** **2–3 corpus items expected to penetrate to the confirmation-sheet layer** then get blocked by the user confirmation requirement — defends against research A8 ("100% pass first run is itself a red flag"). These items confirm deep-defense (MCP-04 confirmation broker) is exercised, not just the perimeter.

### Claude's Discretion
- Exact corpus item count beyond 20+ minimum (planner's call based on coverage of attack vectors)
- `swift-testing` vs XCTest split for any borderline suite (planner picks; default is `swift-testing` for new corpus-driven suites)
- `lsof` parsing details and FD whitelist composition for the steady-state assertion (researcher §Pitfall 6 has the seed)
- Drift classifier `nondeterministicUnderSampling` set population — start empty, add fields empirically as golden-corpus replays surface false positives
- Wake corpus exact composition (TP / TN ratio, specific noise profiles) — operator records during plan `08-02`
- Per-phase YAML item count — sweep across SUMMARY.md is interpretive; planner exercises judgment
- `jarvis-eval` CLI ergonomics (subcommand naming, flag shape) — plan `08-04` finalizes
- Whether the Xcode 26 launch-fragility blocker resolves via `SWIFT_ENABLE_DEBUG_DYLIB=NO` enforcement, post-codesign Info.plist re-write, or upgrading the Debug-bundle layout — investigation drives the fix; no commitment locked here

</decisions>

<specifics>
## Specific Ideas

- "Shipping gate = `scripts/shipping-gate.sh` passes locally on the host Mac on the same macOS version and hardware the daily user runs." Personal-project-scale: no cross-platform matrix needed, but the single-machine shipping-gate run IS load-bearing.
- "Harness exercises the **real pipeline**, not a reimplementation." The only substitutions permitted are (a) LLMProvider mock vs live, (b) `.replay` / `.eval` `TurnSource` suppressing TTS + webview, (c) `ReplayMCPAdapter` for replaying recorded tool results. Every other component runs as in production.
- "100% first-run pass rate is itself a red flag." Anthropic measures 1.4–10.8% successful injection against Claude Opus 4.5 depending on safeguard level — corpus that passes 100% first time means the corpus tests the harness, not the app.
- Treat the existing 18 `scripts/check-*.sh` files as the **first-class checklist mechanization seed**. They already encode invariants — fold them into YAML rather than re-authoring.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 8 specifics
- `.planning/phases/08-hardening/08-RESEARCH.md` — 827-line research artifact: replay-oracle architecture, drift classification, 8-pillar evaluation matrix, injection corpus sourcing, fixture-recording pattern, FD-leak detection, audio-graph rebuild, checklist mechanization, 7 pitfalls, 8 assumptions, 5 open questions resolved here. **Authoritative for the harness substrate.**

### Project-level (reread for cross-phase invariants)
- `CLAUDE.md` — Non-functional requirements section (eval harness 15–25 scenarios pinned to `qwen2.5-coder:32b`; structural injection defense not string-matching; Opus 4.7 footguns the SSE corpus must exercise; Ollama `/api/chat` `tool_calls`-on-sight quirk; `qwen2.5-coder:32b` as locked baseline; architecturally forbidden invariants the checklist asserts).
- `.planning/PROJECT.md` — Personal-use single-machine constraint (frames "shipping gate" as "doesn't silently regress on my Mac", not "passes external compliance audit").
- `.planning/REQUIREMENTS.md` — OBS-03, OBS-04 language; SEC-06 (turnNonce), SEC-07 (sanitize at MCP boundary); AGENT-07 (cap-recovery `tool_choice: .none`).
- `.planning/ROADMAP.md` §Phase 8 — Success criteria 1 & 2 verbatim; the 8-pillar matrix labels (a)–(h) anchor plan/test naming.
- `.planning/STATE.md` — Phase 6 → Phase 8 Deferred Items section (D-12 inherits these); Scaffold-Time Verifications section (Orpheus TTFA, AEC post-format, Silero contract parity owned by P6 originally; AEC + TTFA carry over per D-12/D-13).
- `.planning/research/RESEARCH-DELTAS.md` — D3 (Qwen3/3.5 NOT opt-in baseline); D7 (Orpheus mlx-audio-swift in-process — sets pattern that `--live` Anthropic key handling mirrors).

### Phase-cross-cutting (must hold; checklist asserts each)
- `.planning/phases/04-agent-core/` — OBS-02 ReplayLog schema + exclusion list (P8 inherits exactly); AGENT-07 cap-recovery contract; SEC-06 turnNonce wrap; AGENT-08 8 KB tool-result cap; AGENT-09 retry-on-stream-truncation; AGENT-10 bounded `AsyncChannel` topology.
- `.planning/phases/05-mcp/` — MCP-04 confirmation broker (native AppKit, never webview modal); MCP-07 per-server restart mutex; MCP-08 `ChildSpawnGate` `FD_CLOEXEC` + minimal env; SEC-07 sanitize pipeline ordering.
- `.planning/phases/06-voice/` — VOICE-08 `isVoiceProcessingEnabled = true` ordering invariant; VOICE-09 AEC-off as distinct graph variant; VOICE-10 canonical 6-step teardown across 4 triggers; VOICE-11 atomic TTS interrupt; VOICE-14 single `cancelAndSubmit` entry; HUMAN-UAT.md (D-12 inherits these gates).
- `.planning/phases/07-memory-vision/` — MEM-04 zero-egress for memory extraction (network-sandbox test extends to harness); VISION-03 presence-triggered auto-speak architecturally forbidden (checklist greps `PresenceSignalBus` subscribers).

### External taxonomy sources (corpus curation; NOT runners)
- OWASP LLM01:2025 Prompt Injection — https://genai.owasp.org/llmrisk/llm01-prompt-injection/
- InjecAgent (Apache-2.0) — https://github.com/uiuc-kang-lab/InjecAgent — 1,054 test cases, license-compatible derivative use
- AgentDojo (MIT) — https://github.com/ethz-spylab/agentdojo
- Anthropic measured injection failure rates — https://venturebeat.com/security/prompt-injection-measurable-security-metric-one-ai-developer-publishes-numbers
- swift-testing — https://developer.apple.com/documentation/testing
- swift-argument-parser — https://github.com/apple/swift-argument-parser
- openWakeWord FAR/FRR methodology — https://medium.com/neural-engineer/evaluation-of-openwakeword-engine-false-reject-performance-4d440ee8c4b4

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`packages/Replay/`** (P4 OBS-02): SQLite WAL replay log, `OrphanDetector`, `TokenDeltaDropOldestChannel`. P8 oracle reads its output; no schema changes from P8.
- **`packages/AgentCore/`** (P4): `AgentOrchestrator`, `LLMProvider`, `LLMEvent`, `BoundedAsyncChannel`, `TurnSource` enum (must extend with `.replay(sessionId:)` and `.eval(scenarioId:)` cases per R4-L7).
- **`packages/MCP/`** (P5): `MCPClient`, `ChildSpawnGate`, `ConfirmationBroker`, sanitize pipeline. P8 crash-recovery + injection corpus exercise these directly.
- **`packages/Voice/`** (P6): `VoiceController`, `WakeWordDetector`, audio-graph builders. Wake-hysteresis pillar feeds prerecorded WAVs through the fixture path; audio-rebuild pillar exercises the canonical 6-step teardown.
- **`packages/DevOverlay/`** (P4 OBS-01): replay-log row formatter. Drift classifier output formatter mirrors this for visual consistency.
- **`scripts/check-*.sh`** (18 scripts across P1–P7): `check-bus-protocol-version.sh`, `check-no-evaluate-javascript.sh`, `check-no-modal-presentation.sh`, `check-single-writer-hudstate.sh`, `check-presence-vision-isolation.sh`, `check-single-memory-mutated-emit.sh`, `check-embedding-dim-literal.sh`, `verify-entitlements.sh`, etc. **Each is a natural `type: script` mechanization for `phase=<NN>/checklist.yaml`** — fold them in rather than re-authoring grep rules.

### Established Patterns
- **R4-L7 `.replay` / `.eval` TurnSource suppression** — already designed; P8 adds the cases to the `TurnSource` enum and gates `dispatchesToHUD` / `speaks` properties accordingly. No webview/HUD code modification.
- **Hand-written `Codable` with exhaustive switches, no `default` branches** — bus pattern from P2; P8 corpus item `Vector` / `Category` / `ExpectedOutcome` enums follow the same shape so adding a new vector forces a compile-time hit on every consumer.
- **Per-helper TCC identity + nested `.app` bundles** — MCP-05/06 invariants the crash-recovery pillar (f) must preserve under sustained restart load.
- **`MainActor.assumeIsolated` + actor serialization** — pattern for harness components that touch shared state (replay log writes, oracle output formatting).

### Integration Points
- **`AgentOrchestrator.submit(_:source:)`** signature gains `.replay` / `.eval` source variants that suppress TTS + bus dispatch — single seam, no new orchestrator surface.
- **`MCPToolDispatcher` protocol** — `ReplayMCPAdapter` is a new conforming type that reads recorded tool results from a SQLite replay row instead of spawning a helper. Selected at orchestrator init based on `TurnSource`.
- **`LLMProvider` protocol** — `MockLLMProvider` (new in P8) reads SSE/NDJSON fixture bytes from `Corpora/sse-anthropic/*.sse` or `Corpora/ndjson-ollama/*.ndjson` and emits `LLMEvent` stream identically to live providers. Selected at orchestrator init based on `--fixture` flag.
- **`scripts/shipping-gate.sh`** is a new top-level entry; invokes `jarvis-eval all`. Fits alongside existing `scripts/check-*.sh` and `scripts/verify-*.sh`.
- **`project.yml`** — adds `packages/Harness` as local SPM dependency on the App target's test bundle (so tests can spawn `jarvis-eval`); `jarvis-eval` itself is a standalone executable target.

### Net-new files (P8 greenfield)
- `packages/Harness/Package.swift`
- `packages/Harness/Sources/Harness/{Corpus,Oracle,Runners,Adapters,FDLeakDetector.swift}/...`
- `packages/Harness/Sources/jarvis-eval/main.swift`
- `packages/Harness/Tests/HarnessTests/{DriftClassifierTests, ExclusionListTests, FDLeakDetectorTests}.swift`
- `packages/Harness/Corpora/{injection,sse-anthropic,ndjson-ollama,wake-hysteresis,replay-golden,checklist}/...`
- `scripts/shipping-gate.sh` (new)
- `scripts/capture-anthropic-sse.sh` (new; opt-in operator helper)
- `scripts/promote-replay-session.sh` (new; D-09 operator helper)
- `.planning/phases/{01..07}-*/checklist.yaml` (new during sweep in plan `08-04`)

</code_context>

<deferred>
## Deferred Ideas

- **Automated daily evaluation run with regression alerts** — researcher §User Constraints lists this as v2 (OBS-V2-02). P8 ships the harness; running it regularly is operator discipline.
- **Multi-model regression grid** (Opus vs Haiku vs Qwen3 when fixed vs Llama 4) — v2; P8 evaluates only `qwen2.5-coder:32b` (locked baseline) + Opus 4.7.
- **Automated fuzzing / mutation-based injection generation** — v2; P8 uses curated static corpus.
- **Formal coverage metrics** (branch coverage, mutation score) — overkill for personal-use scope.
- **Production observability stack** (Datadog, OTel export) — single-user local logs only.
- **Cross-platform CI matrix** — macOS-only target by design.
- **Full historical replay against every recorded session** — D-10 makes this `--all` opt-in audit, not the gate.

</deferred>

---

*Phase: 08-hardening*
*Context gathered: 2026-04-30*
