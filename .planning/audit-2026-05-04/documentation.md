# Documentation Audit — 2026-05-04

## Verdict: STALE-IN-PLACES

The two top-level project navigation docs (`docs/SESSION-STATE.md`, `docs/TODO.md`) are **accurate** and load-bearing as of `412caa9`. Code-level documentation (header docstrings on `VoiceController`, `BufferBroadcaster`, `MemoryExtractionOrchestrator`, `MCPBusGatewayAdapter`, `AudioGraphOwner`, the Track-D scripts, the `check-no-leftover-stubs.sh` linter, today's V/B/E/BB/VAD test docstrings) is **also accurate** — today's Track-A/B/C/D commits added good docstrings inline as they shipped fixes. The damage is concentrated in three places:

1. **`.planning/STATE.md`** — last touched 2026-05-01, predating the entire 2026-05-03 audit and 2026-05-04 fix-up. Body still says "Phase 1 ready to execute," progress table shows every phase `0/? Not started`, current position says "Phase 09 EXECUTING" — yet the YAML frontmatter says `status: milestone_complete`. Internally contradictory; reading the body alone misleads any agent that resumes here.
2. **Root `CLAUDE.md`** — opens with "Pre-implementation. Planning complete via GSD; Phase 1 (Foundations) is next." That was true on 2026-04-22; the project is now at v0.12.0 with Phases 1–9 complete and a finished post-milestone audit cycle landed today. The architectural body of CLAUDE.md is fine; the lede and the "Build / test (to be populated once scaffolded)" stub are stale.
3. **`.planning/phases/06-voice/06-05-controller-wiring-SUMMARY.md`** — claims `NullOrchestratorAdapter` / `NullTTSAdapter` / `NullBusEmitterAdapter` are still in production (lines 36, 86, 156, 158) and "stubs prevent the end-to-end voice loop from actually running in production builds until Phase 7." Phase 9-04 replaced those Nulls four+ commits ago, and today's Track B-4..B-7 finished the audio-graph + STT bridge + chunk pump + VAD wiring. This summary now lies twice over. It needs a postscript.

The audit reports under `.planning/audit-2026-05-03/` are historical — not "wrong," just no longer the current ground truth — but `SYNTHESIS.md`'s headline verdict ("Nothing works end-to-end. Three modalities are scaffolding-only.") will mislead any future reader who reaches it without the 2026-05-04 follow-through context. A short pointer at the top of `SYNTHESIS.md` would close the loop.

---

## Findings by document

### Root `CLAUDE.md`

- ❌ **`CLAUDE.md:5–7`** — "Pre-implementation. Planning complete via GSD (Get Shit Done) workflow; Phase 1 (Foundations) is next." False. Per `.planning/STATE.md` frontmatter (`status: milestone_complete`, `progress.completed_phases: 9`) and per the `git log` showing 9 phases of execution-summary commits dating back to 2026-04-22, the project is well past Phase 1. Today's commit log alone (`52d0c94 docs(session)` … `412caa9 docs(session)`) shows active production-code repair work, not pre-implementation planning.
- ❌ **`CLAUDE.md:142–149`** — "### Build / test (to be populated once scaffolded) … _Expected future entries:_ Build Swift app … Run Swift tests …". Never populated. `swift test --package-path packages/Voice` (and the matching invocations for AgentCore/Replay/Bus/Memory/Vision/HUD vitest) are routine in `docs/SESSION-STATE.md` and the audit reports. The CLAUDE.md section is the only top-level entry point a fresh assistant has for "how do I run tests" — and it points nowhere.
- ✅ **`CLAUDE.md:30–84`** — Architecture description (Swift + WKWebView + R3F, Opus 4.7 primary / Ollama first-class, MCP via `swift-sdk v0.12.0`, voice stack with Silero v6.2.1 / openWakeWord / SpeechAnalyzer / AVSpeechSynthesizer / Orpheus, SQLite + FTS5 + sqlite-vec memory, Hardened Runtime + allow-jit, speech-recognition-assets entitlement) — every claim cross-checks against either `RESEARCH-DELTAS.md` or live code (`packages/AgentCore/Sources/AgentCore/ModelID.swift:18` pins `claude-opus-4-7`; `packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift:1–35` matches the six-step teardown description; `App/MCPBusGatewayAdapter.swift` matches the BusGateway description).
- ⚠️ **`CLAUDE.md:60–61, 105`** — TTS tier-2 "Orpheus via `mlx-audio-swift`" described as available behind feature flag. Code reality (per `App/Voice/VoiceTTSAdapter.swift:5–14` and `docs/TODO.md:21` "B-8 (stretch): TTS tier-2 Orpheus — gated on ~6GB HuggingFace weight download; currently degrades to tier-1") is that Orpheus is not currently constructed in production — engine `nil` → no-op fallback. CLAUDE.md still reads as if both tiers are wired. Not "stale" exactly — describing the design contract — but a one-line "tier-2 not yet wired in production as of 2026-05-04; tier-1 only" would prevent a future reader from assuming Orpheus is live.
- ✅ **`CLAUDE.md:127–129`** — Known prompt-injection note. Still accurate; the live `BRIEF.md` archive still carries the tag and the reader continues to need this warning.
- ✅ **`CLAUDE.md:151–215`** — Behavioral guidelines block. Time-invariant, accurate.

### `docs/SESSION-STATE.md`

- ✅ **`SESSION-STATE.md:7`** — `develop` at `6e249ee` ahead of origin. `git log --oneline -1` confirms `412caa9 docs(session)…` is now the head — note: SESSION-STATE was written before the very last "record Track D close" commit landed, so the head SHA in `Current Status` is one commit behind. Cosmetic, but a fresh resume reads "git log" first and would notice the mismatch.
- ✅ **`SESSION-STATE.md:11–62`** — Track A/B/C/D commit summaries map 1:1 to the actual `git log` output. Every cited SHA (`1f8e03e`, `ee7f6d2`, `e9c0a34`, `61aed20`, `c7f9ece`, `bce725b`, `ad93dac`, `6f6617e`, `08125a4`, `5cd46c9`, `7a5543a`, `ea09fd4`, `4159d44`, `df6a4d2`, `eac16c9`, `19362f6`, `75a10be`, `707c45b`, `51750c1`, `c3bd0a5`, `6e249ee`) matches a commit on `develop`. File:line claims spot-checked: `stateUniforms.ts:30`, `WakeWordDAG.swift:93`, `AppDelegate.swift:467` (now `MCPBusGatewayAdapter` at line 539), `WebviewBridgeOutboundTests:80` — all real anchors.
- ✅ **`SESSION-STATE.md:82`** — Test stack claim "Voice 84 XCTest + 22 swift-testing (3 skipped), … Memory 87 XCTest." Verified: `swift test --package-path packages/Memory` reports `Executed 87 tests, with 19 tests skipped and 0 failures` (skipped count differs from the "3 skipped" line that was about Voice swift-testing — the 19 are Memory-side env-gated DB tests). Voice swift-testing tail confirms `Test run with 22 tests in 6 suites passed`. The XCTest count for Voice (84) is plausible from the file list (16 XCTest test files in `packages/Voice/Tests/VoiceTests/`) but I did not count individual tests.
- ✅ **`SESSION-STATE.md:70–76`** — Pending Work list aligns with `docs/TODO.md` open items (`AudioLevelEmitter production wiring`, `streamTruncated empirical confirmation`, `pre-existing TTSInterruptTests.testI3 flake`). Same items in both files; no contradiction.

### `docs/TODO.md`

- ✅ **`TODO.md:7`** — `[x] Track A: text turn + animated rings (1f8e03e)`. SHA exists; commit body matches the claim.
- ✅ **`TODO.md:14–19`** — All Track B `[x]` items map to real commits with matching `git log` bodies. The B-7 entry describes `BufferBroadcaster.swift` — file exists at `packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift` with a header docstring that itself describes the same fan-out behavior.
- ✅ **`TODO.md:25–30`** — Track C `[x]` items all have matching commits and the cited SHAs (`7a5543a`, `ea09fd4`, `4159d44`, `df6a4d2`, `eac16c9`, `19362f6`) are real.
- ✅ **`TODO.md:34–40`** — Track D `[x]` items match the four code-work commits; `[ ]` items D-5/D-6/D-7 correctly carry the "deferred — needs user environment work" annotation. Skeletons at `scripts/build-sqlite-with-extensions.sh` and `scripts/fetch-sqlite-vec.sh` confirmed present and exit with TODO-fill messages until pinned (verified head of both scripts).
- ✅ **`TODO.md:44–48`** — Cross-cutting closeouts. `BLOCKER-INT-1` → `ad93dac` real; `F-A2-01` → `6f6617e` real; `08125a4` tautology cleanup real; F2 linter at `scripts/check-no-leftover-stubs.sh` exists and passes (`bash scripts/check-no-leftover-stubs.sh` returns `[check-no-leftover-stubs] PASS`).
- ✅ **`TODO.md:8`** — `[ ] Re-launch app, verify CacheHints fix actually unblocks streaming.` Still open per SESSION-STATE.md:76 — consistent.
- ⚠️ **`TODO.md:47`** — `[ ] Phase F1 — top-level IntegrationTests target`. Still open. SESSION-STATE.md doesn't mention F1 directly. A real-WKWebView e2e test pair shipped under `1f8e03e` (chat-turn round-trip) and an earlier handshake test under `326a27d`. Those are real e2e tests, but they live in package test targets, not a dedicated top-level IntegrationTests target. The TODO `[ ]` is correct (the target structure isn't there yet) but a reader scanning the file might think "no e2e tests landed today" — a one-line note "incremental WKWebView e2e tests landed under Track A; F1 target restructure still outstanding" would clarify.

### `.planning/PROJECT.md`

- ❌ **`PROJECT.md:13–17`** — "### Validated … (None yet — greenfield. Ship to validate.)". Multiple "Active" requirements have shipped through Phases 1–9 (`LLMProvider` protocol with both providers, MCP starter tools, OutboundBatcher, ReplayLog, MenuBar/HUD shell, Voice subsystem, Memory schema, Vision capture, etc.). Per the "Evolution" instructions in `PROJECT.md:142–151`, validated requirements are supposed to migrate from Active to Validated at phase transitions. None did. This is a load-bearing failure for any future agent doing milestone planning.
- ⚠️ **`PROJECT.md:127–139`** — Key Decisions table. Every "Outcome" cell is "— Pending". Per the Evolution rules, these should be marked validated/invalidated as phases land. All 11 decisions are at this point either locked-and-shipped or locked-and-deferred-to-v1.x. None say so.
- ✅ **`PROJECT.md:1–11`** — "What This Is" / "Core Value" sections — accurate; matches CLAUDE.md and STATE.md framing.
- ✅ **`PROJECT.md:80–93`** — Out of Scope list — still valid; no items have leaked back into scope.

### `.planning/STATE.md`

- ❌ **`STATE.md:1–13`** — Frontmatter says `milestone: v0.12.0, status: milestone_complete, completed_phases: 9, percent: 100`. Body says (lines 28–54):
  - `**Current focus:** Phase 09 — orchestrator-wiring`
  - `Phase: 09 (orchestrator-wiring) — EXECUTING`
  - `**Status:** Milestone complete`
  - `[ ] Phase 1: Foundations — **planned** … ready to execute`
  - `[ ] Phase 2: Bus` … `[ ] Phase 8: Hardening`
  
  The frontmatter and the prose contradict each other inside the same file. The "Current Position" / phase-checklist section is preserved from the 2026-04-22 init when nothing was done yet, but never updated as phases shipped. Last-updated timestamp says `2026-05-01T19:26:01.288Z` — predates audit-2026-05-03, today's audit-fix work, and three of the seven planning-summary docs in `.planning/phases/06-voice/`.
- ❌ **`STATE.md:140`** — "Re-resumed 2026-04-29 via /gsd-resume-work — STATE.md loaded cleanly … Routing user to /clear + /gsd-execute-phase 7." Stale by ~5 days. Phase 7 done; the file's own frontmatter agrees.
- ❌ **`STATE.md:144–148`** — "Next action when work resumes: … 1. git pull. 2. Run /gsd-execute-phase 7 …" Routes a future agent to re-execute an already-done phase. A genuine fresh-resume would land on `docs/SESSION-STATE.md` instead and miss this contradiction only if they happened to skip STATE.md — but the global `~/.claude/CLAUDE.md` compaction-recovery instructions explicitly point readers to project STATE.md.
- ✅ **`STATE.md:108–116`** — "Phase 6 → Phase 8 Deferred Items (recorded 2026-04-27)" section. Still accurate work-list (Xcode 26 launch fragility, six UAT gates, Orpheus TTFA measurement). Consistent with `docs/TODO.md:21` (Orpheus tier-2 deferred) and `06-HUMAN-UAT.md`.
- ✅ **`STATE.md:118–124`** — Scaffold-time verifications list. All four still legitimately open (P1 entitlement probe, Input Monitoring HUD banner, Silero v6.2.1 contract parity, AEC post-format probe). Properly forward-pointing.

### `.planning/ROADMAP.md`

- ❌ **`ROADMAP.md:17–25, 243–254`** — Phase header list (`- [ ] Phase 1: Foundations …` × 9) and Progress table at the bottom (`Foundations 0/? Not started`, etc.) both show every phase un-started. Per STATE.md frontmatter and per the per-plan checkboxes deeper in the file (e.g. `ROADMAP.md:52–56` show all five Phase 1 plans `[x]` complete), this is wrong. The phase-header summary line was never updated to match the per-plan reality.
- ✅ **`ROADMAP.md:52–56, 75–79, 99–103, 128–133, 151–161, 181–190, 224–238, 297–310`** — Per-plan checkbox tables (Phase 1 through Phase 9) — accurate. Phase 1, 2, and most plans through 9 are correctly marked `[x]`. Phase 3 plans show `[ ]` but the rest of the doc says HUD shipped — see Phase 3 cross-doc inconsistency below.
- ✅ **`ROADMAP.md:289–321`** — Phase 9 Orchestrator Wiring section. Plans 09-01..04 all `[x]`; success-criteria narrative matches what the code does today.

### `.planning/research/RESEARCH-DELTAS.md`

- ✅ **D1 (`claude-opus-4-7` model identifier)** — Code reality at `packages/AgentCore/Sources/AgentCore/ModelID.swift:18` (`public static let opus47 = ModelID(rawValue: "claude-opus-4-7")`) matches; AnthropicProvider header docstring at line 8 cites the same delta. Authoritative claim still aligned with code.
- ✅ **D3 (Qwen3 tool-calling broken in Ollama)** — Cannot reverify upstream issue tracker without internet, but the project's behavior is consistent: `ROADMAP.md:118` and CLAUDE.md:51 both pin `qwen2.5-coder:32b` as the local baseline; no Qwen3 opt-in path exists in code.
- ✅ **D7 (Orpheus streaming confirmed via mlx-audio-swift)** — Consistent with code (`App/Voice/VoiceTTSAdapter.swift:8–13` documents the engine-optional pattern; the streaming claim is preserved as the design contract).
- ✅ **Silero v6.2.1 upgrade** — Consistent with `packages/Voice/Sources/Voice/VAD/SileroVAD.swift` (not re-read here, but the "Silero contract parity" scaffold-time verification at `STATE.md:122` is open work, not a contradiction).

### `.planning/phases/06-voice/06-05-controller-wiring-SUMMARY.md`

- ❌ **`06-05-controller-wiring-SUMMARY.md:36`** — Decisions list says "AppDelegate voice wiring uses Null adapters for orchestrator/TTS/bus (Phase 7 stubs) — VoiceController starts but TTS/orchestrator are no-ops until Phase 7." False as of `Phase 9 Plan 4 / D-09` (commits before today). `App/Voice/VoiceOrchestratorAdapter.swift:11` literally says "Phase 9 / Plan 4 / D-09: replaces `NullOrchestratorAdapter`." Same for `VoiceTTSAdapter.swift:6` and `VoiceBusEmitterAdapter.swift:9`.
- ❌ **`06-05-controller-wiring-SUMMARY.md:86`** — "Phase 7 stubs: `NullOrchestratorAdapter`, `NullTTSAdapter`, `NullBusEmitterAdapter`." Also stale — those types no longer exist in `App/` (`grep -rn "NullOrchestratorAdapter\|NullTTSAdapter\|NullBusEmitterAdapter" App packages` finds zero hits).
- ❌ **`06-05-controller-wiring-SUMMARY.md:131–133, 156–158`** — Architectural Decisions and Known Stubs sections both still describe the Null adapters as alive. Especially the closing line "These stubs prevent the end-to-end voice loop from actually running in production builds until Phase 7" is now actively misleading: today's Track B-4 wired `AudioGraphOwner` and `LiveSpeechAnalyzerBridge`'s real `feed()` body, B-5 added the chunk pump, B-6 added VAD-gated session end, B-7 added `BufferBroadcaster` fan-out. The voice loop is now wired end-to-end save for Orpheus tier-2 (B-8) and the human-UAT empirical probes deferred to Phase 8 (per `STATE.md:108–116`).
- ✅ **`06-05-controller-wiring-SUMMARY.md:1–47`** — Frontmatter and "What Was Built" sections are accurate descriptions of the 06-05 deliverables themselves.
- ✅ Rest of Phase-6 SUMMARY docs (`06-01-audio-graph-SUMMARY.md`, `06-02-wake-word-SUMMARY.md`, `06-03-vad-stt-SUMMARY.md`, `06-04-tts-engine-SUMMARY.md`) — not individually reviewed; they predate 06-05 and the 2026-05-03 audit verdict is that these layers' code was real and unit-tested. They're likely time-capsule-accurate but should also pick up a postscript pointing to the Track B-1..7 audit-fix commits if any agent uses them as resume material.

### Code-level documentation

- ✅ **`packages/Voice/Sources/Voice/VoiceController.swift:6–24`** — Header comment lists subsystems consumed (WakeWordDAG, SileroVAD+STT, VoiceTTSInterface→TTSEngineActor, VoiceOrchestratorInterface→AgentOrchestrator adapter, VoiceBannerInterface→HUDBannerCoordinator, BusOutboundEmitter→OutboundBatcher) plus invariants (VOICE-14 single cancelAndSubmit, T-06-05-03 no transcript log, T-06-05-02 native AppKit banner, T-06-05-04 200ms barge-in debounce, VOICE-12 PTT-when-muted). All five invariants have matching tests in the package. Accurate.
- ✅ **`packages/Voice/Sources/Voice/AudioGraph/BufferBroadcaster.swift:1–37`** — Long header docstring describes the SPSC-ring sample-stealing problem, the per-subscriber-ring fix, the threading rules (`OSAllocatedUnfairLock` snapshot copy, real-time tap-thread safety, infrequent subscribe/unsubscribe), and the `@unchecked Sendable` justification. Matches today's BB-1..5 test suite. Accurate.
- ✅ **`packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift:5–35`** — Six-step teardown DRY description, VOICE-09 AEC variant emit, VOICE-10 four-trigger uniformity, plus reserved slots for Plan 06-02 (cancelInFlight) and Plan 06-04 (releaseORTSessions). Consistent with today's Track B-4 commit body and the `setCancelInFlight` / `setReleaseORTSessions` cross-actor setters at lines 144–157.
- ✅ **`packages/Memory/Sources/Memory/MemoryExtractionOrchestrator.swift:6–60`** — Header describes the bounded-channel + serial-drain model, the `ApplyOp` test seam, and the new (D-3) `PriorFactsLookup` + `emptyPriorFactsLookup` default. Header explicitly walks through why the `priorFacts: []` hardcode was the bug and what the lookup closure now does. Excellent inline doc — written today as part of D-3 and survives the change correctly.
- ✅ **`App/MCPBusGatewayAdapter.swift:1–30`** — Cites `BLOCKER-INT-1` directly, describes the wire mapping (`emitToolCallStart` → `BusOutbound.toolCallStart` etc.), the `String → UUID` deterministic SHA256 derivation, and the dispatcher-protocol drift it bridges. Accurate.
- ✅ **`App/MCP/InProcessMemoryAdapters.swift:1–30`** — Cites Track-D D-2, explains why these adapters live in `App/` rather than `packages/MCP/` (Memory↔MCP boundary). Accurate.
- ⚠️ **`packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift:146`** — Comment says "Plan 06-05 wires this from `@MainActor` install code." True at the time; today's Track B-4 (`AudioGraphOwner.setCancelInFlight` / `setReleaseORTSessions` cross-actor setters) commit added the actual wiring. The "Plan 06-05" comment is now ambiguous — Plan 06-05 wrote the property; Track B-4 wrote the setter. Not wrong, just one revision behind.
- ⚠️ **`App/AppDelegate.swift:8`** — `import Voice           // Plan 06-05: VoiceController + PTT + MuteWakeWord`. Still accurate but Phase 9 / Plan 4 / D-09 + Track B-4..7 added a lot more import-Voice code (broadcaster subscribe, chunk pump, VAD interceptor wiring). The comment is shorthand, not stale per se. No action needed.
- ✅ **`scripts/check-no-leftover-stubs.sh:1–46`** — Header documents the four flagged patterns precisely (literal `Replaced in 0`, `TODO: Plan|0X-`, 2-line stub bodies, `Noop*`/`*Stub` instantiations) plus the `Dormant*` allowlist rationale. Linter passes against current `develop`. Accurate and load-bearing.
- ✅ **`scripts/build-sqlite-with-extensions.sh:1–22`** and **`scripts/fetch-sqlite-vec.sh:1–18`** — Both correctly tagged "THIS IS A SKELETON" with explicit TODO markers and exit-1-with-message until pinned. Header explains intent (extension loading, vec0 codesigning + bundling) and where the output lands (`./build/sqlite/libsqlite3.dylib`, `App/Resources/vec0.dylib`). Accurate.

### Test docstrings

- ✅ **`packages/Voice/Tests/VoiceTests/VoiceControllerTests.swift:5–9`** — V1–V4 docstring matches actual test bodies (V1 wake-word→listening, V2 VAD speechEnd→thinking+orchestrator.submit, etc.).
- ✅ **`packages/Voice/Tests/VoiceTests/BargeInTests.swift:3–11`** — B1..B4 docstring matches test bodies (single cancelAndSubmit, HUD-listening within 150ms, empty-string sentinel, 200ms debounce).
- ✅ **`packages/Voice/Tests/VoiceTests/VoiceLoopE2ETests.swift:5–28`** — E1..E3 docstring is unusually thorough: lists what's exercised (chunk pump → STT → orchestrator.submit, leak-free Task on session end, transcript propagation via `STTProvider.finalize`) and what's NOT exercised (real `AudioGraphOwner` + macOS 26 SpeechAnalyzer — HUMAN-UAT territory). Matches today's Track B-5 commit body.
- ✅ **`packages/Voice/Tests/VoiceTests/VADGatedSessionTests.swift:3–28`** — VAD-1..5 docstring describes the per-session interceptor, 512-sample window slicing, hangover-threshold finalize, anti-deadlock note (don't `await analyzer.finish()` synchronously, T-06-05-03 no-PCM-log discipline). Matches today's Track B-6 commit body.
- ✅ **`packages/Voice/Tests/VoiceTests/BufferBroadcasterTests.swift:5–14`** — BB-1..5 docstring describes the multi-consumer sample-stealing motivation. Matches B-7 commit and the `BufferBroadcaster.swift` header.

### Script headers

- ✅ All `scripts/check-*.sh` headers I sampled (`check-no-leftover-stubs.sh`, `check-bus-protocol-version.sh`, `check-no-evaluate-javascript.sh`) describe what they enforce. The new D-5/D-6 skeletons are clearly marked as skeletons.

### Audit reports (`.planning/audit-2026-05-03/*.md`)

- ⚠️ **`SYNTHESIS.md:12`** — `verdict: "Nothing works end-to-end. Three modalities are scaffolding-only."` Was true on 2026-05-03; misleading now. The body itself stays useful as historical context (and as the spec for what Track A/B/C/D delivered against), but anyone reading it 6 months from now will think the project is broken when it largely isn't.
- ⚠️ **`voice-audit.md:5`** — TL;DR "Nothing in the voice subsystem actually runs end-to-end. … five distinct points: (1) ONNX models … (2) Silero VAD … (3) `WakeWordDAG.start(ring:)` … (4) `LiveSpeechAnalyzerBridge.feed()` no-op stub … (5) `TTSEngineActor` never constructed." All five are now fixed (B-1 bundled models; B-2 fixed `WakeWordDAG.swift:93`; B-3 wired tier-1 TTS; B-4 wired `AudioGraphOwner` + real `LiveSpeechAnalyzerBridge.feed()` body; B-5..7 chunk pump + VAD + broadcaster). Historical document; does not need editing, but a short pointer at the top would help.
- ⚠️ **`memory-audit.md:93`** — "Fix the `priorFacts: []` hardcode in `MemoryExtractionOrchestrator.swift:84`" — fixed today as Track D-3.
- ⚠️ Same shape for `vision-audit.md`, `hud-audit.md`, `llm-audit.md`, `tests-audit.md` — every blocker called out in the audit reports has a corresponding `[x]` line in `docs/TODO.md`. No need to update the audit reports themselves; just point readers forward.

---

## Cross-document contradictions

1. **STATE.md vs ROADMAP.md vs frontmatter consensus.** STATE.md frontmatter says `status: milestone_complete, completed_phases: 9`. ROADMAP.md progress table (lines 247–254) says every phase `0/? Not started`. ROADMAP.md per-plan checkboxes (lines 52–56, 75–79, etc.) say `[x] complete` for ~39/43 plans. Three different stories in three places about the same project state.

2. **CLAUDE.md "Pre-implementation" vs everything else.** Root CLAUDE.md:5 says pre-implementation; STATE.md frontmatter, every audit report, every commit message, and every Phase-N-SUMMARY says we're well past it.

3. **PROJECT.md "Validated: None" vs shipped requirements.** PROJECT.md:17 says "(None yet — greenfield. Ship to validate.)". REQUIREMENTS.md (per `docs/TODO.md:52`) is "all `[ ]` despite ~70 of 79 being satisfied." Both documents are stale on the requirements ledger; the Validated section is the higher-value to update.

4. **06-05-SUMMARY.md "Null adapters" vs Phase 9-04 production adapters.** SUMMARY says Nulls are alive; `App/Voice/Voice{Orchestrator,TTS,BusEmitter}Adapter.swift` headers explicitly claim "replaces NullXAdapter."

5. **Audit-2026-05-03 "Nothing works" vs Audit-2026-05-04 "tracks A/B/C/D landed."** Not a true contradiction — the 2026-05-03 verdict was the snapshot before today's work. But the SYNTHESIS.md is the highest-traffic doc and lacks any forward pointer.

---

## Stale phase summary docs

| File | Stale claim | Suggested fix |
|------|-------------|---------------|
| `.planning/phases/06-voice/06-05-controller-wiring-SUMMARY.md` | Lines 36, 86, 131–133, 156–158: claims `Null{Orchestrator,TTS,BusEmitter}Adapter` are alive and "stubs prevent the end-to-end voice loop from running in production builds until Phase 7" | Postscript: "Updated 2026-05-04 — Null adapters replaced by production adapters in Phase 9-04 (`App/Voice/Voice*Adapter.swift`); audio-graph + STT bridge + chunk pump + VAD wiring landed under Track B-4..B-7 (`e9c0a34`..`bce725b`). Voice loop wired end-to-end save for Orpheus tier-2 (B-8) and the empirical UAT probes deferred to Phase 8." |
| `.planning/phases/06-voice/06-{01,02,03,04}-*-SUMMARY.md` | Not individually reviewed; likely time-capsule-accurate but pre-date the 2026-05-03 audit and 2026-05-04 fixes | If/when the user touches them: short postscript pointing to the Track B-1..7 commits |
| `.planning/audit-2026-05-03/SYNTHESIS.md` | Headline verdict line 12 implies project is dead | Top-of-file pointer: "Postscript 2026-05-04 — Tracks A/B/C/D landed in commits 1f8e03e..412caa9; see `docs/SESSION-STATE.md` for the current state. The verdict below is the 2026-05-03 snapshot, preserved as historical context." |

---

## Recommended doc updates (prioritized)

1. **Rewrite `.planning/STATE.md`** to match its own frontmatter — the body's "Current Position", "Phase 1 ready to execute", per-phase checkbox table, and "Next action when work resumes" sections are the most actively misleading docs in the tree. A future agent reading this file will route the user to re-execute already-shipped work. **Highest leverage.** ~30 min.

2. **Fix `CLAUDE.md:5–7` lede + `:142–149` Build/test stub.** Lede should reflect "v0.12.0 milestone complete; post-milestone audit-fix cycle landed 2026-05-04 (Tracks A/B/C/D); see `docs/SESSION-STATE.md` for current state." Build/test should list the three real `swift test --package-path packages/<X>` commands plus the boundary-gate scripts and `pnpm test --filter hud`. ~15 min.

3. **Add postscript to `.planning/phases/06-voice/06-05-controller-wiring-SUMMARY.md`** clarifying that Null adapters were replaced in Phase 9-04 and audio/STT/VAD wiring landed under Track B. ~5 min.

4. **Add a top-of-file pointer to `.planning/audit-2026-05-03/SYNTHESIS.md`** noting that Tracks A/B/C/D have since landed and pointing readers to `docs/SESSION-STATE.md`. Same for the six per-modality audit reports if desired (lighter-weight). ~5 min.

5. **Update `.planning/PROJECT.md:13–17` Validated section** to migrate the requirements that have shipped (LLMProvider w/ Anthropic+Ollama, MCP starter tools, OutboundBatcher, ReplayLog, MenuBar+HUD shell, Voice subsystem code-side, Memory schema + extraction code-side, Vision capture+attach). Also flip the Key Decisions outcome cells from "— Pending" to "— Locked + shipped." ~30 min — or roll into the `REQUIREMENTS.md` traceability sweep TODO.md:52 calls for.

6. **Update `.planning/ROADMAP.md:17–25` Phase header list and `:243–254` Progress table** to match the per-plan checkboxes deeper in the file. ~10 min.

7. **(Optional) Clarify CLAUDE.md voice-stack section** with a one-liner that tier-2 Orpheus is currently degraded to tier-1 in production pending B-8 weight download. Not strictly stale (it describes the design), but a future agent might assume Orpheus is wired. ~2 min.

Items 1, 2, and 3 are the highest priority — they're the docs a fresh `~/.claude/CLAUDE.md` compaction-recovery sequence reads first and they all currently misrepresent project state. Items 4–6 are valuable hygiene; item 7 is cosmetic.
