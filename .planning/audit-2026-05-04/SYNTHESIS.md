# Audit Synthesis — 2026-05-04

Six-auditor parallel clean-room audit of the Jarvis project after the 2026-05-03 → 2026-05-04 audit-fix cycle (22 commits closing Tracks A, B-1..B-7, cleanup batch, C-1..C-6, D-1..D-4 + scaffolds).

Auditor reports under `.planning/audit-2026-05-04/`:
- `code-functionality.md` — does the production path actually work?
- `code-style.md` — style + project-convention adherence
- `documentation.md` — docs accuracy vs reality
- `concurrency.md` — race conditions, actor boundaries, real-time safety
- `security.md` — secrets, entitlements, attack surface
- `test-quality.md` — tautologies, coverage holes, false positives

## Verdict

**STRUCTURALLY SOUND, with three real production gaps and one diffuse documentation problem.**

Today's audit-fix work substantially closed the 2026-05-03 "wired but dead" pattern. The fixes are real, not theatrical — each is exercised by load-bearing tests with fakes only at the I/O boundaries. Five of six auditors gave verdicts in the favorable half (`SAFE`/`MOSTLY-SAFE`/`CLEAN`/`MIXED-strong`/`MINOR-ISSUES`); only documentation lands in `STALE-IN-PLACES`.

But three real gaps remain that the user must address (or accept):

1. **Memory subsystem is functionally OFF** until `vec0.dylib` ships (acknowledged, scaffolded by D-5/D-6, requires user environment work).
2. **AudioLevelEmitter is unwired in production** — the listening-state HUD ring doesn't pulse on real audio. Worse: its API takes a raw `RingBuffer`, not a `BufferBroadcaster.Subscription`, which invites re-introducing the sample-stealing bug Track B-7 just fixed.
3. **Debug build entitlements drift** — `Jarvis.Debug.entitlements` is missing `com.apple.developer.speech-recognition-assets`, which CLAUDE.md flags as load-bearing for SpeechAnalyzer asset download.

Plus diffuse doc rot in three high-traffic files that lie about project state.

## Cross-cutting themes (multiple auditors flagged)

These are the findings that came up in 2+ reports independently — usually a sign of higher signal:

### T1 — AudioLevelEmitter is a latent bug

- code-functionality §2: not wired in production; HUD ring won't pulse
- concurrency HIGH-4: takes a raw `RingBuffer`; future re-wiring will re-introduce sample-stealing
- test-quality §critical-gaps: only test fixture references it
- **Fix:** change `AudioLevelEmitter.init` signature to take `BufferBroadcaster.Subscription` (not `RingBuffer`). Wire production constructor in `installVoice`. ~30 min.

### T2 — Production chunkPump closure has no test

- code-functionality: tests use synthetic pumps; production AppDelegate-wired pump (`audioGraphOwner.subscribe()` + `ring.readMono16k`) is unverified
- test-quality §critical-gaps: same finding, called out as the largest remaining test gap
- **Fix:** integration test that spins up a real `AudioGraphOwner` (with mock `GraphBuilder` that publishes scripted buffers), constructs the production chunkPump, and asserts the consumer side receives the published bytes. ~1 hour.

### T3 — Documentation rot in three high-traffic files

- documentation flagged: `.planning/STATE.md` (says "Phase 1 ready to execute" while frontmatter says 100% complete), root `CLAUDE.md:5-7` (says "Pre-implementation. Phase 1 next." while v0.12.0 + Track A/B/C/D shipped), `.planning/phases/06-voice/06-05-controller-wiring-SUMMARY.md` (claims null adapters still in production).
- code-style §3: 503 `Plan/Track/Phase` and 102 ticket-ID comments in production code reference work that's done — adds noise but not bugs
- **Fix:** rewrite the three docs to match reality. 30 min for the critical three; longer for the comment scrub which is best done lazily as code is touched.

### T4 — Two pre-existing test failures with concrete root-causes

- test-quality §pre-existing-failures: triaged both
- `TTSInterruptTests.testI3` (10s deterministic timeout) is a **test-fixture bug**, not production. `ScriptedSpeechModel.makeStream` doesn't propagate consumer cancellation. One-line fix at `OrpheusSerializationTests.swift:155-170`: add `continuation.onTermination = { @Sendable _ in producerTask.cancel() }`.
- `InputMonitoringDenialTests` compile failure is a **1-line fix**: `MockProbe` missing `isListenEventAccessGranted() -> Bool` required by `HIDAccessProbe` protocol. Existence on develop indicates the Shell package isn't in pre-merge CI.
- **Fix both:** ~10 min total.

## Priority-ordered punch list

### P0 (do first — small fixes that close real gaps)

| # | Fix | Source | ETA |
|---|-----|--------|-----|
| 1 | Add `speech-recognition-assets` entitlement to `Jarvis.Debug.entitlements` | code-functionality | 5 min |
| 2 | Fix `TTSInterruptTests.testI3` — add `continuation.onTermination = { producerTask.cancel() }` to `ScriptedSpeechModel.makeStream` | test-quality | 5 min |
| 3 | Fix `InputMonitoringDenialTests` compile error — add missing `isListenEventAccessGranted()` to `MockProbe` | test-quality | 5 min |
| 4 | Rewrite `.planning/STATE.md` body to match v0.12.0 reality | documentation | 15 min |
| 5 | Rewrite root `CLAUDE.md:5-7` lede + populate the build/test commands section | documentation | 20 min |
| 6 | Add postscript to `.planning/phases/06-voice/06-05-controller-wiring-SUMMARY.md` pointing to today's Track B-4..B-7 fixes | documentation | 10 min |

### P1 (do soon — real correctness gaps)

| # | Fix | Source | ETA |
|---|-----|--------|-----|
| 7 | Wire `AudioLevelEmitter` in production via `audioGraphOwner.subscribe()`; change init signature to take `BufferBroadcaster.Subscription` not `RingBuffer` | T1 | 30 min |
| 8 | Add integration test for the production chunkPump closure | T2 | 1 hour |
| 9 | Fix `VoiceController.swift:374-386` — store the partials/finalize Task; cancel it in `endSTTSession` and `shutdown`; add per-session generation guard against stale-text reentry | concurrency HIGH-1 | 30 min |
| 10 | `RingBuffer.swift:148-150` — switch `writeIdx`/`readIdx` to `Atomic<UInt64>` from swift-atomics (or document why the current pattern is OK with explicit acquire/release semantics) | concurrency HIGH-3 | 1 hour |

### P2 (do when convenient — quality + hygiene)

| # | Fix | Source | ETA |
|---|-----|--------|-----|
| 11 | `SpeechAnalyzerSTT.swift:89-92` — re-evaluate the fire-and-forget `Task { try await bridge.finish() }`; the anti-pattern reason doesn't apply at this site | concurrency HIGH-2 | 30 min |
| 12 | `HybridSearch.swift:51` — stop logging raw `search_memory` query at debug level (T-06-05-03 analog for memory) | security MEDIUM-1 | 5 min |
| 13 | `WhisperKitSTT.swift` lines 83/93/101 — replace `try?` with `try { } catch { logger.warning(...) }` | code-style | 15 min |
| 14 | Move `VoiceController._forceState` / `_testFireSpeechEnd` and `MCPClient._testHandle` from `public` to `internal` + `@testable import` | code-style | 15 min |
| 15 | Pick one mock-naming convention (`Mock` / `Fake` / `Stub`) for the project; document in CLAUDE.md; rename ~15 stragglers | code-style | 30 min |

### P3 (refactor — bigger wins, lower urgency)

| # | Fix | Source | ETA |
|---|-----|--------|-----|
| 16 | Split `App/AppDelegate.swift` (2112 LOC) into `AppDelegate+Voice.swift`, `+Vision.swift`, `+Memory.swift`, `+Agent.swift` | code-style | 2-3 hours |
| 17 | Pick XCTest OR swift-testing for the Voice test target; convert the minority. (Current 11 swift-testing + 18 XCTest mix is an annoyance, not a bug.) | code-style | 1-2 hours |
| 18 | Build-time grep gate on `requiresConfirmation: true` for `run_applescript` registration paths (defense-in-depth) | security LOW-3 | 30 min |

### Acknowledged-not-fixed (user environment work)

- D-5: build custom `libsqlite3.dylib` with extension loading
- D-6: bundle `vec0.dylib` (skeleton script ready)
- D-7: `ollama pull nomic-embed-text` + `ollama pull qwen2.5-coder:32b`
- HUMAN-UAT for voice + vision flows

## What's actually good (cross-auditor consensus)

These came up positively in multiple reports — worth preserving:

- **`BufferBroadcaster` real-time threading** (concurrency, code-style, test-quality) — genuinely lock-free on the publish path; subscribers receive distinct copies; concurrent publish+subscribe doesn't crash. Code is the cleanest of today's churn.
- **`MCPBusGatewayAdapter`** (code-functionality, security, test-quality) — replaces `NoopBusGateway` with real wiring; `start.id == end.id` invariant proven; consumes already-sanitized inputs.
- **`MissingT2Provider` explicit-missing pattern** (code-style, security) — preserves the bug fix without committing to bigger build-out.
- **`UntrustedWrapper` + `ToolResultPacker` + `ChildSpawnGate`** (security) — defense-in-depth done right; FD_CLOEXEC enforced; 8 KB tool-result cap honored; prompt-injection wrapping order correct.
- **Bidirectional REQUIRED + FORBIDDEN entitlement verification** (security) — single biggest force-multiplier in the project.
- **`replayLog.beginSession` now called before turns** (code-functionality) — was BLOCKER from prior audit; fixed and verified.
- **`cancelInFlight` wired in production at `AppDelegate.swift:812`** (code-functionality) — the teardown cancellation slot is real.
- **`requiresConfirmation: true` enforced at TWO sites** (security) — `run_applescript` confirmation isn't bypassable via single-point edit.

## Next-session orientation

Do the P0 list (≤1 hour total). Then T1+T2 (90 min) closes the diffuse-but-real production gaps. After that, the project is genuinely structurally complete pending environment work.

Honest take: nothing in this audit is alarming. The 2026-05-03 cycle did real work; today's audit confirms it. The P0 fixes are mostly cosmetic-or-trivial (3 of 6 are 5-minute fixes). The remaining gaps are honest deferrals (vec0.dylib, Ollama pulls, HUMAN-UAT) plus one wiring miss (AudioLevelEmitter) and one test gap (production chunkPump).

The lurking risk this audit didn't catch: **anything that only fails on Apple Silicon hardware with real entitlements**. Live-mic + live-camera + real-Anthropic + real-Ollama is still HUMAN-UAT territory. Plan to run the voice / vision UAT skeletons before declaring the audit-fix workstream truly closed.
