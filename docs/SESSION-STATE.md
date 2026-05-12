# Session State

**Last Updated:** 2026-05-12 end-of-day (Rounds 2/3/4 + audits + tracking migration + roadmap + branding)

> **Live state lives in GitHub Issues:** https://github.com/KofTwentyTwo/Jarvis/issues
>
> This file preserves session-handoff narrative. The bullet-list pending-work sections have been replaced with crosswalks to issue numbers. Read narrative paragraphs for historical context; check GitHub for current state of any item.

## ▶ Next Session: read `docs/HANDOFF-2026-05-12-end-of-day.md` FIRST

`develop` HEAD: `0cc94c6`. 141 open issues across 6 milestones. PR [#149](https://github.com/KofTwentyTwo/Jarvis/pull/149) is draft and is **first action** for next session (BUILDING.md + README MIT cleanup).

**Shipped today (delta since this file last said "▶ Next Session: M-0"):**
- **Rounds 2 + 3 + 4 strict-mode arc** — Round 2 boot-phase health probes (NOT FAKED, `687b80b`), Round 3 Status… NSPanel (`67748f5`), Round 4 severity model + non-dismissible banners + agent self-awareness preamble + red menu-bar icon (`cfd469f`, `79955b6`, `23b4ca7`, `a9531e6`). The "Toby fix" — agent refuses to lie about remembering when memory is degraded — validated mid-dogfood.
- **Latent fact-persistence FK fix** (`a5999e2`) — facts.source_turn_id FK incompatible with FNV-hash strategy; dropped FK; facts now persist.
- **Xcode 26 build race fix** (`1557302`) — ProcessInfoPlistFile scheduled after pre-codesign verify, silently reverting `JarvisEntitlementsVerified`. Declared Info.plist as input.
- **Full audit pass** (`.planning/audit-2026-05-12/`) — 5 parallel agents, ~37 findings filed as issues.
- **Dev Overlay built** (`8d94c1c` → `50c2783` → `6ea2852`) — 4-tab AppKit NSPanel + live log stream via `LogBroadcaster` / `BroadcastLogHandler`.
- **Tracking migration to GitHub Issues** — 141 issues filed; `docs/TODO.md` deprecated; CLAUDE.md declares Issues canonical.
- **Code-commenting style guide** (`b763273`, 583 lines) + AppDelegate exemplar (`281b909`).
- **User-outcome milestone roadmap** at `.planning/ROADMAP-2026-05-12.md` (v0.1 / v0.2 / v0.5 / v0.8 / v1.0 / v1.1).
- **MIT license confirmed** (`.planning/decisions/license.md`) + standard repo files (LICENSE, SECURITY, CHANGELOG, issue/PR templates, dependabot, branding).

**Next session actions in order:**
1. Read `docs/HANDOFF-2026-05-12-end-of-day.md` + `.planning/ROADMAP-2026-05-12.md` to orient.
2. Merge PR #149 (BUILDING.md + README MIT cleanup).
3. Decide repo visibility (still PRIVATE; marketing pass assumed public).
4. Start v0.1 fan-out: Voice CRIT (#28–#36), Memory CRIT (#12–#16), MCP CRIT (#20–#22), Bus/HUD S1 (#40–#42), Vision (#1–#3), B-06 (#51), v1-hole PTT/InputMonitoring/startup (#87/#88/#89).
5. After v0.1 lands, M-0 starts on its own feature branch.

The pre-existing M-0..M-7 migration plan is unchanged — still locked at `.planning/architecture/JARVIS-API-DESIGN-v0.1.md` + `v0.2.md`; epics #4–#11; M-0 directly on `develop`, M-1+ on feature branches; ~18.5–25.5 engineer-days remaining.

Repo caveats: 5 stashes accumulated (#63), 2 Dependabot moderate vulns flagged, repo still PRIVATE.

## ▶ 2026-05-11 morning — B-02 tactical patch

`develop` advances past `46590cd` with one commit closing B-02. Substrate gap discovered + addressed in-scope: the `turns` table was unwritten (schema present, FTS5 trigger ready, but no `INSERT` site anywhere). Patch adds `MemoryStore.appendTurn` writer and wires both sides — orchestrator `sessionHistoryLookup` closure (read) and AppDelegate `turnContent` (write piggybacked on existing memory-extraction flush path).

- **Patch site (read side):** `packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift` — adds `PriorTurn` struct, `SessionHistoryLookup` typealias with `emptySessionHistoryLookup` default (preserves pre-B-02 test setups), ctor parameter, hydration logic that prepends prior turns between system prompt and current user message in chronological order.
- **Patch site (write side):** `packages/Memory/Sources/Memory/MemoryStore.swift` `appendTurn(sessionId:role:content:source:createdAt:)` + `MemoryQueries.turnInsertSQL`. Single-row INSERT; FTS5 trigger mirrors `content` into `turns_fts` automatically.
- **AppDelegate wiring:** `App/AppDelegate.swift` constructs `sessionHistoryLookup` closure calling `recentTurnsForSession(limit: 10)` and reversing DESC → chronological; passes it to `AgentOrchestrator` init. `turnContent` closure (existing memory-extraction path) gains a side-effect: write the flushed pair via `appendTurn` before returning. Assistant row offset by +1 ms so DESC + id-tiebreaker preserves user→assistant order.
- **Regression coverage:**
  - `HistoryThreadingRegressionTests.HT-1` — three-turn integration; asserts third call's messages array is `[system, user("ok"), assistant("ack"), user("yes"), assistant("ack2"), user("why?")]`.
  - `HistoryThreadingRegressionTests.HT-2` — empty-history default produces `[system, user]` (pre-B-02 baseline preserved).
  - `HistoryThreadingRegressionTests.HT-3` — three-turn happy path emits zero `LLMProviderError.streamTruncatedFinal` events. Pins R-006 / Phase E gate behavior — the patch grows the messages array, not the system prompt, so `CacheHints.eligibleForSystemPrompt(finalSystem)` is unchanged.
  - `MemoryStoreAppendTurnTests.AT-1..4` — append round-trip, user/assistant pair chronological reconstruction, session scoping, FTS5 trigger fires. Env-gated on `JARVIS_VEC0_STUB_PATH` per existing MemoryStore-test convention; skip without vec0.dylib.
- **Honesty note:** in dormant-memory mode (no vec0/no Ollama), turn persistence is also dormant — the `appendTurn` call is guarded by `memoryStore != nil`. When D-5/D-6 land and memory comes up live, persistence activates without further code changes.

## ▶ 2026-05-07 evening — Design swarm output

## ▶ Earlier this session — Design swarm output (2026-05-07 evening)

`develop` HEAD was `b36e8eb` (handoff commit) at swarm start. Tonight's commit adds all `.planning/architecture/` artifacts and the `Tools/jarvis-diag/` skeleton (compiles green; type-signatures only).

**Locked decisions:**
- **UQ-1:** runtime gate `JARVIS_HARNESS=1` (single binary).
- **UQ-2:** B-02 tactical patch outside migration + regression test; B-04 stays in M-6.
- **UQ-3:** explicit `Voice.synthesizeTurn(turnId:text:tier:)` command (orchestrator-as-driver visible at API).
- **UQ-4:** Settings owns ALL configuration mutation; Voice has only runtime-control verbs; `bargeIn` migrates to Turn.
- **UQ-5:** parametric harness mandated — every scenario runs `.inProcessActor` AND `.jsonRoundTripWebView`.

Plus 4 orchestrator-decided defaults (UUIDs for identifiers; `~/Library/Application Support/Jarvis-Harness/` data isolation; `Settings._setConfirmationDefault(.deny)` default; bus dual-version handshake `["2.3.0", "2.4.0-rc"]` during M-0..M-7).

**Carry-forward bug status (unchanged tonight; closes during migration per UQ-2 + plan):**
- B-02 → tactical patch BEFORE M-1
- B-03 → M-5 (Vision)
- B-04, B-05 → M-6 (Voice)
- B-06 → M-7 (Turn) [DOM observability gap acknowledged; out of harness scope]
- B-07 → deferred (Plan 10-05 re-scope)
- B-08 → M-1 (Self)

---

## ▶ 2026-05-07 morning — substrate fixes (pre-pivot)

## Current Status (2026-05-07 end-of-session)

`develop` at `1b7fb81`, push pending. Tree clean (only ignorable untracked: `.claude/scheduled_tasks.lock`, `build-devoupload/`).

**This session's work — substrate fixes for the agent's tool-call pipeline:**

- `260350b`..`9a59648` — Plan 10-02b: tool catalog enumeration (B-01a) — orchestrator now sources `availableTools:` from the runtime catalog instead of hardcoded `[]`. Closes the regression that landed silently in commit `fdb56d2` (Phase 9 Plan 09-01) and silenced ALL tool calls for ~3 days.
- `a75ae0a` — Plan 10-02 SUMMARY recording AC-06 PASS / AC-05 FAIL after the live test surfaced B-01.
- `3cf0d39`..`1b7fb81` — Plan 10-02c: dispatch routing (B-01b) — `InProcessAwareToolDispatcher` composite routes in-process tool calls (memory + four self-knowledge) through `InProcessToolRegistry.dispatch`; preserves confirmation gating. Live-verified: "what mic are you using?" now returns "Sennheiser SDW 5 BS headset (USB) at 48 kHz, with AEC on" with real `tool_use`/`tool_result` round-trip.

**Phase 10 status at session-end:**

- 10-01 (4 self-knowledge tools) — shipped, AC-01..04 PASS
- 10-02 (system prompt preamble) — AC-06 PASS; AC-05 retroactively PASS via 10-02b/c live verification (SUMMARY's FAIL marker not yet flipped — deferred per handoff)
- 10-02b — shipped, B-01a closed
- 10-02c — shipped, B-01b closed; **SUMMARY missing** (only PLAN written; deferred to post-design housekeeping)
- 10-03 / 10-04 / 10-05 — DEFERRED. They build diagnostic UI on top of subsystems still dead. Re-scope against new API after design lock.

**Why the pivot to API-first design:** two days of "fix → test green → relaunch → still broken" produced 7 carry-forward bugs (B-02..B-08 — see TODO.md and the handoff). The verification gate has been "executor self-reports green tests + boundary gates," which cannot detect substrate failures. The architectural pivot dissolves this entire bug class by forcing every behavior through a tested API contract. **Stopping individual bug fixes** until the API design is locked.

## Carry-forward bugs (DO NOT fix piecemeal)

Live evidence collected during today's verification. All re-scope against the new API.

| ID | Symptom |
|----|---------|
| B-02 | Conversation continuity broken — prior turn context lost |
| B-03 | HUD camera button click does nothing |
| B-04 | Voice input dead — wake-word + STT silent |
| B-05 | TTS silent — text replies not spoken |
| B-06 | Chat panel doesn't auto-scroll as text streams |
| B-07 | Voice Log menu item missing (Plan 10-05 unrun) |
| B-08 | `get_self_state` returns correct ID but Claude paraphrases as "Opus 4.5" |

## Pre-existing carry-forwards (unchanged today)

- D-5 / D-6 — `libsqlite3.dylib` + `vec0.dylib` build-and-bundle (user environment work)
- D-7 — `ollama pull nomic-embed-text` + `qwen2.5-coder:32b`
- HUMAN-UAT — VOICE-07/09/10/12/13/14 on Release Developer ID archive
- B-7-followup — AudioLevelEmitter production wiring
- TTSInterruptTests.testI3 pre-existing 10s flake

---

## Earlier session — 2026-05-04 (preserved below for context)

`develop` at `0234eaa`, push pending. Tree clean. Track A + Track B-1..7 + Cleanup batch + Track C (vision) + Track D code-work (D-1..D-4 + D-5/D-6 skeletons) + audit-2026-05-04 P0/P1/P2/P3-18 fixes + documentation sweep closed. D-5/D-6 binaries + D-7 model pulls remain on the user (environment work the executor cannot do autonomously).

### Documentation sweep (this session, 5 commits)

- **`4e1c8a0` — docs: write top-level README.md** — replaces the stale "Pre-implementation" stub with a current overview: status table, repo layout, build/test commands, pointers to ARCHITECTURE/CONTRIBUTING.
- **`41b506d` — docs: write ARCHITECTURE.md** — marquee architecture document (~2300 words). Mermaid top-level diagram of the audio-graph fan-out + agent loop + bus, subsystem deep-dives for the 13 packages, cross-cutting concerns (concurrency, TCC, codesign, the 18 boundary gates), audit-derived anti-pattern list, where-things-live cheat sheet, honest gaps & deferred work.
- **`508cf92` — docs(packages): per-package README files** — adds README.md to each of the 13 SPM packages. Each covers purpose, key public types, deps, consumers, invariants, test stack, notable files. Memory README explicitly marks the package functionally OFF until vec0.dylib + Ollama models land.
- **`85b14ce` — docs(docstrings): add header docstrings to key public types** — AppDelegate (preamble + lifecycle + see-also), VoiceController (// MARK block converted to /// with Threading + Anti-patterns), MCPClient (registry + restart-mutex + relationships). Comment-only; verified via `swift build` (Voice, MCP) + `check-app-builds.sh`. Other types listed in the brief already had substantive docstrings — left alone per audit-grade-improvement-only.
- **`0234eaa` — docs: write CONTRIBUTING.md** — dev environment setup, build/test pointers, GSD workflow, boundary-gate discipline, conventional-commit conventions matching the existing log, test-double naming taxonomy, anti-pattern checklist, step-by-step guides for adding an MCP tool / HUD button + bus event, compaction-recovery section for AI agents.

All 18 boundary gates green; App target builds clean; Voice + MCP packages compile after docstring additions.

## What Was Done This Session

- Six-agent deep audit (voice / HUD / vision / memory / LLM / tests) → `.planning/audit-2026-05-03/SYNTHESIS.md`. Verdict: nothing worked end-to-end; every modality had ≥1 fatal break.
- **Commit `1f8e03e` — Track A** (text turn + animated rings):
  - HUD `idle` ring no longer static (`stateUniforms.ts:30`).
  - `CacheHints.eligibleForSystemPrompt` gates `extended-cache-ttl` on prompts ≥1024 tokens (likely streamTruncated cause).
  - `StreamOutcome` classifier distinguishes 200+0bytes / 200+0frames / 200+EOF / complete.
  - `AnthropicAPIKeyProvider.make` propagates `KeychainError` instead of swallowing.
  - 2 new real-WKWebView e2e tests (chat-turn round-trip both directions).
- **Commit `ee7f6d2` — Track B-1..3** (voice foundations):
  - `scripts/copy-voice-models.sh` bundles ONNX models at runtime path `Contents/Resources/Models/{openWakeWord,silero}/`. 6 shell tests.
  - `WakeWordDAG.swift:93` fixed: production now calls `feed(samples:)` not `feedTest()`. 2 unit tests.
  - `TTSEngineActor.orpheus` is now `OrpheusTTS?`; `App/Voice/VoiceOutputWiring.swift` constructs tier-1 (AVSpeechSynthesizer) without Orpheus weights. 4 unit tests including real `AVSpeechSynthesizer`.
- **Commit `e9c0a34` — Track B-4** (audio graph + STT wiring):
  - `AudioGraphOwner.setCancelInFlight` / `setReleaseORTSessions` cross-actor setters (Swift 6 mode requires).
  - New `PCMBufferBuilder` (`AudioChunk.pcm16k` → `AVAudioPCMBuffer` + `AVAudioConverter` resample). Lives outside `@available(macOS 26)` gate so unit tests run on every supported macOS. +7 tests.
  - `LiveSpeechAnalyzerBridge.feed(_:)` no longer `_ = chunk` — full SpeechAnalyzer + SpeechTranscriber wiring: builds analyzer with `bestAvailableAudioFormat`, opens `AsyncStream<AnalyzerInput>` pipe, spawns result-drain Task, finalises through end-of-input.
  - `installVoice` constructs AudioGraphOwner, spawns degradation+rebuild consumers BEFORE `open()` (so the aec=false retry path is observed), hands ring buffer to `WakeWordDAG.start(ring:)`, sets `cancelInFlight` for teardown step 1. Fail-soft on graph open failure.
  - VoiceWiringTests testW1 asserts new `audioGraphOwner` / `audioGraphDegradationTask` / `audioGraphRebuildTask` strong properties.
- **Commit `61aed20` — Track B-5** (chunk pump + e2e proof):
  - VoiceController gains a `chunkPump: @Sendable (AsyncStream<AudioChunk>.Continuation) async -> Void` init parameter (no-op default for back-compat).
  - `startSTTSession` spawns a detached `chunkPumpTask`; `endSTTSession` cancels it before closing the chunk continuation; `shutdown` cancels it. No leaked Task on session end.
  - AppDelegate's production pump reads `audioGraphOwner.ringBuffer` in 1024-sample windows (~64 ms @ 16 kHz), 10 ms sleep on starve, exits on Task cancel.
  - VoiceLoopE2ETests (+3): preset-chunks → orchestrator.submit text match (E1); empty pump → no submit + back to idle (E2); pump task exits within 100 ms of pttUp (E3).
- **Commit `bce725b` — Track B-7** (BufferBroadcaster fan-out):
  - New `BufferBroadcaster` (`packages/Voice/.../AudioGraph/BufferBroadcaster.swift`) fans the audio-graph tap output to per-subscriber `RingBuffer`s; consumers no longer race for samples on the legacy SPSC ring.
  - `AudioGraph.swift` tap callback calls `broadcaster.publish(buffer)`; the legacy `public let ringBuffer` is now a private "primary" subscription so `WakeWordDAG.start(ring:)` and the overflow watcher keep working without signature changes.
  - `AudioGraphOwner.subscribe(capacityFrames:)` actor method added — chunk pump in AppDelegate now subscribes per-session via this and unsubscribes on pump exit.
  - Publish path is wait-free in steady state: `OSAllocatedUnfairLock<[Subscription]>` snapshot copy, iterate outside lock; per-subscriber `RingBuffer.write` remains lock-free. Real-time tap-thread safe.
  - 5 new BufferBroadcasterTests (BB-1..5: single sub, multi-sub no theft, unsubscribe stops, late-join skips prior, concurrent stress). All pass.
  - Voice swift-testing 17 → 22 (+5 BB). XCTest 84 unchanged. Pre-existing `TTSInterruptTests.testI3` baseline 10s flake unchanged.
  - Anti-patterns enforced: no actor hops on tap thread, NSLock forbidden, T-06-05-03 (no PCM logging) preserved, VOICE-14 single-call-site preserved.
- **Commit `ad93dac` — BLOCKER-INT-1** (real bus gateway): replaced `NoopBusGateway` in `AppDelegate.swift` with `MCPBusGatewayAdapter` that forwards `emitToolCallStart` / `emitToolCallEnd` through `OutboundBatcher`. Tool-call cards now reach the webview bus. New `MCPBusGatewayAdapterTests` proves the start→end forward path.
- **Commit `6f6617e` — F-A2-01** (stale bus world): `WebviewBridgeOutboundTests:80` asserted retired `JarvisBusWorld` name; production switched to `.page` in `fb41c5f`. Test now asserts `WKContentWorld.page` — load-bearing again.
- **Commit `08125a4` — tests-audit cleanup** (5 tautologies): removed/replaced `XCTAssertTrue(true)` placeholders per `.planning/audit-2026-05-03/tests-audit.md` section 5. MCPRuntimeWiringTests:260 in-place assertion fix; WebviewBundleLoadTests, InputMonitoringDenialTests, PackageBoundaryTests deleted documentation-as-test funcs; ToolChoiceTests trailing tautology removed (closure compile is the gate). HudStateEnumTests rubber-stamps left as-is (a11y labels are user-facing, load-bearing).
- **Commit `5cd46c9` — F2 linter** (`scripts/check-no-leftover-stubs.sh`): grep-based gate against `Replaced in 0…`, `TODO: Plan|0X-…`, 2-line stub function bodies, and production `Noop*(` / `*Stub(` instantiations. Self-tested against synthetic fixture; clean on current `develop`. Allowlists `Dormant*` (real producer-stream pattern).
- **Commit `7a5543a` — Track C-1** (CameraCapture AVCapturePhotoCaptureDelegate): replaces the 1×1 black-JPEG hardcode with the real photoOutput delegate path. New `PhotoCaptureProxy` (NSObject) bridges the delegate callback into a CheckedThrowingContinuation; retains itself for the lifetime of the capture (AVCapturePhotoOutput holds delegates weakly), breaks the cycle on the first didFinishProcessingPhoto callback. Test seam `photoCaptureOverride` mirrors `authStatusProbe` — production tests can exercise captureFrame() end-to-end without hardware. Vision 56 → 59.
- **Commit `ea09fd4` — Track C-2** (frameStream fan-out): replaces `AsyncStream { cont.finish() }` with a real fan-out backed by `AVCaptureVideoDataOutputSampleBufferDelegate`. New `VideoSampleDelegate` fans incoming CMSampleBuffers to a UUID-keyed map of registered continuations under an `NSLock`-guarded snapshot. `frameStream(forPresence:)` now generates a UUID per subscription, hops into the actor to register against the live delegate, and tears down via `cont.onTermination`. shutdown() drains the subscription set. Vision 59 → 63.
- **Commit `4159d44` — Track C-3** (HUD camera button): closes vision-audit §4 "HUD button emitter has zero matches". New `CameraButton.tsx` posts `{ type: 'frameAttachRequested' }` via `window.jarvisBus.send`; rendered next to the chat input's Send button with matching toolbar chrome. JS path: `webview/packages/hud/src/chat/CameraButton.tsx:14`. Swift handler at `App/AppDelegate.swift:1696-1698` already routed it into `FrameAttachController.requestAttach(reason: .hudButton)`. HUD vitest 94 → 97.
- **Commit `df6a4d2` — Track C-4** (explicit T2 missing variant): replaces the silent `t2Provider: t1` AppDelegate hardcode with `MissingT2Provider` whose `stream(...)` finishes with `VisionError.t2ProviderUnavailable`. Real vllm-mlx wiring (codesigning + binary bundling + feature flag) is downstream work and out of Track-C scope; the bug being fixed here is "silent T1-as-T2 fallback hides intent" — explicit-missing makes the missing wiring debuggable instead of silent. Production callers must gate on `evaluatePostResponse(..., t2Available: false)` (already do); MissingT2Provider's stream is never actually invoked in the live flow. Vision 63 → 67.
- **Commit `eac16c9` — Track C-5** (confirmSend wired): closes vision-audit §4 "confirmSend has zero non-test callers". `handleChatSubmit` and `handleChatCancelAndSubmit` now consult `FrameAttachController.hasPendingFrame` and, when armed, pull the `ImageBlock` via `confirmSend(userText:)` and route through `submit(.withImages(...))`. Both submit handlers carry the wiring (WARNING-4 parity with the existing phrase-trigger path). Completes the Track C-3 click flow end-to-end. Vision 67 → 70.
- **Commit `19362f6` — Track C-6** (real-hardware integration test): `CameraCaptureRealHardwareTests` exercises captureFrame() and frameStream() against real AVCaptureSession output. Gated by ALL of: `JARVIS_REAL_CAMERA=1` env, `AVCaptureDevice.default(for: .video)` non-nil, `authorizationStatus == .authorized`. Test does NOT prompt for TCC — headless test runs skip cleanly. Run interactively: `JARVIS_REAL_CAMERA=1 swift test --package-path packages/Vision --filter CameraCaptureRealHardwareTests`. Asserts: jpeg byte count > 1000, SOI marker, width/height > 1 (so a regression to the 125-byte 1×1 stub trips immediately); frameStream emits a `.sampleBuffer` within 2s. Vision 70 → 72 (2 tests, both skip without env+TCC).
- **Commit `75a10be` — Track D-1** (installMemory cascade): single `return` after `MemoryStore(databaseURL:)` throw left both `memoryExtractionOrchestrator` AND `memoryExtractionCoordinator` nil for the process lifetime — extraction was a no-op even though the LLM call to Ollama is independent of SQLite. Restructured: store nil now logs a warning, sets `memorySearchAvailable=false`, but extractor + orchestrator + coordinator all construct. ApplyOp closure captures `[weak self]` and routes to debug log when `memoryStore` is nil (drain loop survives). New `MemoryInstallWiringTests` proves the cascade is closed. T-06-05-03 preserved: log only turnId hash, never subject/object content.
- **Commit `707c45b` — Track D-2** (SearchMemoryTool + ForgetFactTool registration): both tools have lived in `packages/MCP/Sources/MCP/InProcess/` since Plan 07-03 with zero production registration — agent loop had no way to call memory. New `App/MCP/InProcessMemoryAdapters.swift` bridges MCP's tool protocols to Memory's actors (`HybridSearchAdapter` wraps `HybridSearch` and translates `[FactRef]` → `[SearchMemoryHit]`; `ForgetFactStoreAdapter` wraps `MemoryStore.forgetFact`). `installMemory` builds an `InProcessToolRegistry` and registers conditionally: `forget_fact` when `memoryStore != nil`, `search_memory` when `memorySearchAvailable && embedder init succeeds`. Embedder failure degrades to "writes ok, no search" rather than failing the whole subsystem.
- **Commit `51750c1` — Track D-3** (priorFacts wiring): pre-fix `MemoryExtractionOrchestrator.process(_:)` hardcoded `priorFacts: []` — extractor was blind to existing facts, only ever ADDed, never UPDATEd. Added `PriorFactsLookup` typealias + `priorFactsLookup` ctor parameter (default `emptyPriorFactsLookup` preserves pre-D-3 behavior). Lookup throws degrade to empty list with a warning log so the drain task survives. New `MemoryStore.recentActiveFacts(limit:)` + matching `MemoryQueries.recentActiveFactsSQL` (server-side cap, active-only). AppDelegate's installMemory passes a closure returning up to 50 recent active facts. Tests: `testD3_priorFactsLookupDrivesUpdateOp` (stub provider emits UPDATE only when it sees `[99]` prior fact id in system prompt; asserts `applyOp` receives `.update(supersedes: 99, …)`); `testD3_priorFactsLookupErrorDegradesToEmpty` (lookup throws, job still applies its ADD op). Memory 86 → 88.
- **Commit `c3bd0a5` — Track D-4** (remember-Brutus end-to-end): new `RememberBrutusEndToEndTests.testExtractionWriteThenSearchFindsBrutus` proves the extraction → store → search loop holds. Real `MemoryExtractionOrchestrator` + `MemoryExtractor` + `HybridSearch`; fakes for the vec/Ollama-dependent surfaces (`FakeStore` actor conforms to both apply path and `MemoryReadStore`; `StubEmbedder` returns constant 768-dim vector; `BrutusProvider` returns one ADD op then `messageStop`). Scenario: turn 1 "My dog Brutus is a Bernese Mountain Dog." → ADD lands in store → turn 2 "What breed is Brutus?" → `search.searchFacts` returns one hit with summary `"Brutus breed Bernese Mountain Dog"`. Boundary stops at `HybridSearch.searchFacts`; MCP-side dispatch covered by `InProcessMemoryToolsTests` in the MCP package. Memory 86 → 87 (D-3 added via grouping; total Memory tests now 87).
- **Commit `6e249ee` — Track D-5/D-6** (deferred build + fetch script skeletons): `scripts/build-sqlite-with-extensions.sh` (clang flags for `SQLITE_ENABLE_LOAD_EXTENSION=1` + FTS5 + RTREE + threadsafe=2; TODO markers for SQLite version, amalgamation URL, SHA256, codesign identity) and `scripts/fetch-sqlite-vec.sh` (GitHub release tag + SHA256 + asset path; TODO markers for version + hash). Both mode 755, exit 1 with clear "TODO: fill in …" message until pins land — no deceptive successful stub.
- **Commits `57847f2` / `f9cd25d` / `2d9a25a` — audit-2026-05-04 P2 stragglers**:
  - `57847f2` (P2-14, test-seam visibility): VoiceController `_forceState` / `_testFireSpeechEnd` / `_testCurrentSttSessionId` (4 seams) flipped from `public` → `internal`; MCPClient `_testHandle` + MCPServerHandle `_testProcessIdentifier` (2 seams) flipped to `@_spi(Testing) public`. Voice tests already use `@testable import`; MCP tests gain `@testable @_spi(Testing) import JarvisMCP`; Harness's `MCPCrashRunner` opts in via `@_spi(Testing) import JarvisMCP`. Public ABI no longer leaks test entry points.
  - `f9cd25d` (P2-15, mock naming): new CLAUDE.md §"Test naming conventions" (line 127) documents Mock/Stub/Fake taxonomy (records-and-scripts / canned-data / realistic-stateful). 15 worst-mismatch stragglers renamed in older corpus: 6 `Stub*` → `Mock*` (HybridSearchTests StubEmbedder/StubStore, SessionHistoryTests StubStore, InProcessMemoryToolsTests StubHybrid/StubHistory/StubForget — all record calls); 8 `Mock*` → `Stub*` (STTBackendSwitchTests MockSpeechAnalyzerBridge/MockWhisperKitBridge, VoiceWiringTests Mock*ForW4 ×6 — all canned no-ops); 1 `Fake*` → `Mock*` (FakeJSEvaluator in two files — comment already said "Records each call for assertion"). Did NOT touch types added in today's P1+P2 fix commits per audit constraint.
  - `2d9a25a` (P3-18 / security LOW-3): `scripts/check-applescript-confirmation.sh` — defense-in-depth grep gate. For each non-comment/non-test line containing `run_applescript`, asserts the enclosing register-call body (line + up to 5 following lines, terminated at `)`) contains `requiresConfirmation: true`. Verified catches regression: temporarily flipped `App/MCP/MCPRuntimeWiring.swift:119` to `false` → gate FAILed with the file:line citation; reverted; gate PASSes on clean tree. Comment-only references in HudStateIntent.swift:19 + InProcessTool.swift:9 are filtered by `is_comment_line`.

- **Commit `c7f9ece` — Track B-6** (VAD-gated session end):
  - `VoiceController.startSTTSession` now spawns a per-session VAD interceptor task. Pump output flows through it, forwarding every chunk to STT *and* running Silero VAD per 512-sample window.
  - New private `runVADInterceptor`: tracks armed state on `.speechStart`, counts consecutive silence chunks after `.speechEnd`, and triggers `endSTTSession()` once the hangover threshold (5 chunks ≈ 160 ms) is reached. Mid-utterance speech resumption cancels the pending finalize.
  - `endSTTSession()` is now `async`; `pttUp()` awaits it. Single non-VAD caller path preserved.
  - 512-sample VAD window builder carries over the partial tail between chunks so it works against both the test pump (512-sample chunks) and the production pump (up to 1024-sample chunks).
  - Anti-patterns enforced: VAD handler does NOT block on `await analyzer.finish()` — finalize fires inside `Task { … }` to avoid deadlock on the analyzer completion path. T-06-05-03 preserved (no PCM in logs). VOICE-14 single `cancelAndSubmit` site preserved.
  - VADGatedSessionTests (+4): VAD-1 `.speechEnd` + 5×silence → submit; VAD-2 PTT regression with VAD wired; VAD-4 sustained speech → no submit; VAD-5 speech resumption within hangover cancels pending finalize.

## Active Branches

| Branch | Status |
|--------|--------|
| `develop` | At `2d9a25a`, ahead of origin (push pending). Tree clean. |

## Pending Work — moved to GitHub Issues

Live tracking has migrated to https://github.com/KofTwentyTwo/Jarvis/issues. Crosswalk for items previously listed here:

- AudioLevelEmitter production wiring — verified done; consumer still dead — [#54](https://github.com/KofTwentyTwo/Jarvis/issues/54) + [#44](https://github.com/KofTwentyTwo/Jarvis/issues/44)
- Track C (vision) — CLOSED 2026-05-04 (commits `7a5543a` through `19362f6`)
- Track D (memory code-work) — CLOSED 2026-05-04 (commits `75a10be` through `6e249ee`); environment work [#56](https://github.com/KofTwentyTwo/Jarvis/issues/56)/[#57](https://github.com/KofTwentyTwo/Jarvis/issues/57)/[#58](https://github.com/KofTwentyTwo/Jarvis/issues/58); memory database now live via `48ad8d6`
- TTSInterruptTests.testI3 flake — [#55](https://github.com/KofTwentyTwo/Jarvis/issues/55)
- streamTruncated empirical confirmation — [#62](https://github.com/KofTwentyTwo/Jarvis/issues/62)
- Migration M-0..M-7 — epics [#4](https://github.com/KofTwentyTwo/Jarvis/issues/4) through [#11](https://github.com/KofTwentyTwo/Jarvis/issues/11)
- Carry-forward bugs B-03..B-08 — [#48](https://github.com/KofTwentyTwo/Jarvis/issues/48) through [#53](https://github.com/KofTwentyTwo/Jarvis/issues/53)
- 2026-05-12 audit findings — see `docs/TODO.md` crosswalk for the full list

## Key Reference

- Audit reports: `.planning/audit-2026-05-03/{SYNTHESIS,voice,voice-audit,hud-audit,vision-audit,memory-audit,llm-audit,tests-audit}.md`
- Plan: `.planning/AUDIT-AND-FIX-PLAN.md`, findings tracker: `.planning/AUDIT-FINDINGS.md`
- Test stack at session end (post P2-14/15/P3-18): Voice 87 XCTest + 23 swift-testing (3 skipped), MCP 85 XCTest, Memory 88 XCTest (19 skipped — vec0/Ollama gating), Bus 58 XCTest, AgentCore 19 + 72 XCTest, Vision 19/72 XCTest, Shell 5+7 XCTest, webview/hud **97** vitest. **All 18 boundary gates PASS** (17 pre-existing + new check-applescript-confirmation.sh), app builds clean. Pre-existing baseline issues unrelated to this batch: `webview/packages/hud/src/hud/SegmentedRing.tsx` typecheck warnings, `TTSInterruptTests.testI3` 10s flake. Flag for follow-up; out of scope here.
- Next-session orientation: read `.planning/audit-2026-05-04/SYNTHESIS.md` first, then this file, then `git log --oneline 6e249ee..HEAD` for the audit P0-P2 fix story.
