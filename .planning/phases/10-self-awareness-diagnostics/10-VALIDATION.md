---
phase: 10
slug: self-awareness-diagnostics
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-06
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `10-RESEARCH.md` § Validation Architecture (lines 912–966).
> Locked in: `10-CONTEXT.md` D-26..D-28 (Live Verification gate, tccutil reset protocol).

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Swift Testing (`@Test` macros) for SPM packages; XCTest for the App target |
| **Config file** | Per-package `Package.swift` declares `.testTarget`. App target uses Xcode test scheme via `scripts/check-app-builds.sh` (Xcode 26 ad-hoc-Debug bundle harness fragility means `swift test` cannot drive the App target — the script wraps `xcodebuild build -configuration Debug`). |
| **Quick run command** | `swift test --package-path packages/<Pkg> --filter <Suite>/<test>` (sub-second for new unit tests) |
| **Full suite command** | All package tests, looped: `for p in AgentCore Voice Vision Memory MCP DevOverlay Bus Config Logging Replay Harness Keychain Shell VoiceLog; do swift test --package-path packages/$p; done` plus `bash scripts/check-app-builds.sh` and the 18 boundary gates from `CLAUDE.md`. |
| **Estimated runtime** | Quick: <30 s per touched package. Full: ~6–8 min (package suites + app build + boundary gates). |

---

## Sampling Rate

- **After every task commit:** Run `swift test --package-path packages/<TouchedPkg>` for whichever SPM package the task modified (≤30 s typical). If the task touches the App target, run `bash scripts/check-app-builds.sh`.
- **After every plan wave / per plan boundary:** `bash scripts/check-app-builds.sh` PASS, all **18 boundary gates** green (the 17 pre-existing + `check-applescript-confirmation.sh`), AND the plan's `SUMMARY.md` MUST include a populated `## Live Verification` section per `10-CONTEXT.md` D-26 (relaunch command + observed log lines + AC match). Tests-green is necessary but not sufficient.
- **Before `/gsd-verify-phase 10`:** All five plan SUMMARY.md files contain Live Verification with PASS evidence for their respective ACs (D-27); all 14 SPEC ACs explicitly checked; no boundary gate red; `JARVIS_REAL_CAMERA=1` / `JARVIS_REAL_MODELS=1` interactive runs invoked where applicable.
- **Max feedback latency:** ~30 s for unit-test feedback per touched package; ~8 min for full pre-merge sweep.

---

## Per-Task Verification Map

> Plan IDs follow the locked D-02 order. Tasks within each plan will be enumerated by gsd-planner; this table maps **requirements** (not tasks) to validation lanes.

| Req ID | Plan | Wave | Behavior | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|--------|------|------|----------|------------|-----------------|-----------|-------------------|-------------|--------|
| SELF-01 | 10-01 | 1 | `list_audio_devices` returns ≥1 input + ≥1 output, fields populated | — | Read-only CoreAudio query; no side effects; `requiresConfirmation: false` | unit | `swift test --package-path packages/MCP --filter ListAudioDevicesToolTests` | ❌ W0 | ⬜ pending |
| SELF-01 | 10-01 | 1 | Tool registers in `MCPRuntimeWiring` with `requiresConfirmation: false` | T-10-MCP-01 | Read-only tools must explicitly mark non-confirming so `check-applescript-confirmation.sh` semantics stay readable | unit | `swift test --package-path packages/MCP --filter MCPRuntimeWiringTests/registersFourSelfKnowledgeTools` | ❌ W0 (extend existing) | ⬜ pending |
| SELF-01 | 10-01 | 1 | Cross-validates with `system_profiler SPAudioDataType` on host | — | N/A | live-launch | manual: relaunch + invoke tool via DevOverlay tool-call inspector + diff vs `system_profiler SPAudioDataType` | — | ⬜ pending |
| SELF-02 | 10-01 | 1 | `get_active_audio_route` returns non-nil while voice loop active | — | Reads through live `AudioGraphOwner` actor — no shared mutable state in tool body | integration | `swift test --package-path packages/Voice --filter ActiveAudioRouteAdapterTests` (uses test seam on `AudioGraphOwner`) | ❌ W0 | ⬜ pending |
| SELF-02 | 10-01 | 1 | Result matches `AudioGraph: probed format sampleRate=X channels=Y` log line | — | N/A | live-launch | manual relaunch — observe log line, call tool, diff | — | ⬜ pending |
| SELF-03 | 10-01 | 1 | `get_self_state` returns populated struct (`app_version`, `pid`, `uptime`, `llm_model`, `voice_loop_state`) | — | No PII / no transcript content; bundle/process/runtime introspection only | unit | `swift test --package-path packages/MCP --filter GetSelfStateToolTests` | ❌ W0 | ⬜ pending |
| SELF-03 | 10-01 | 1 | Cross-checks against `Bundle.main.infoDictionary` + active `LaunchSnapshot` / `PerTurnSnapshot` | — | N/A | unit | same suite, fixture-driven | ❌ W0 | ⬜ pending |
| SELF-04 | 10-01 | 1 | `list_camera_devices` returns built-in FaceTime camera entry | — | Read-only `AVCaptureDevice.DiscoverySession`; no capture session opened | unit + live-launch | unit: `swift test --package-path packages/MCP --filter ListCameraDevicesToolTests`; live: relaunch + invoke + diff `system_profiler SPCameraDataType` | ❌ W0 | ⬜ pending |
| SELF-05 | 10-02 | 2 | After preamble change, "what mic are you using?" produces `get_active_audio_route` tool call | — | Preamble nudges introspection-tool-first; replaces hardcoded `"You are Jarvis, a personal macOS assistant."` literal at `App/AppDelegate.swift:1242` | live-launch | manual: relaunch app, ask via voice/text, observe DevOverlay last-5 tool-calls list shows `get_active_audio_route` (DEPENDS on Plan 10-03 — DevOverlay must populate) | — | ⬜ pending |
| SELF-05 | 10-02 | 2 | Asking "are you a text-only assistant?" produces denial citing voice + vision | — | N/A | live-launch | manual relaunch + log capture | — | ⬜ pending |
| SELF-06 | 10-02 | 2 | Preamble does NOT push system prompt over Anthropic 1024-tok cache-eligibility boundary unintentionally | T-10-CACHE-01 | Preamble keeps system prompt under 4096 chars (Assumption A4 in RESEARCH); `extended-cache-ttl` boundary respected | unit | `swift test --package-path packages/AgentCore --filter CacheHintsEligibilityTests/preambleDoesNotEnableCacheUnintentionally` | ❌ W0 (extend existing) | ⬜ pending |
| DIAG-02 | 10-03 | 3 | `DevSnapshotEmitter` instantiated by `installAgent`; `DevOverlayBridge.attach(channel:)` called from `toggleDevOverlay()` | T-10-DEVOVERLAY-01 | Wiring repair only — no new APIs; subscriber lifetime bound to window lifetime | integration + live-launch | unit: existing `DevSnapshotEmitterTests/applyTurnEndedFlushesAccumulator` (passes today); integration: salvage `DevOverlayBroadcasterIntegrationTests.swift` from `stash@{0}`; live: relaunch + send turn calling `get_time` + observe DevOverlay populated within 100 ms of `.turnEnded` | ✓ unit existing; ❌ integration | ⬜ pending |
| DIAG-03 | 10-04 | 4 | Audio loopback records 2 s + plays back audibly via `AudioGraphOwner.subscribe()` (Track B-7 fan-out) | T-10-AUDIO-01 | Reuses existing tap; no new ring buffer; doesn't disturb wake-word DAG | live-launch | manual: `tccutil reset Microphone com.koftwentytwo.jarvis`; relaunch; click "Audio Loopback Test"; speak; observe playback within 1 s | — | ⬜ pending |
| DIAG-04 | 10-04 | 4 | TTS Playback diagnostic speaks "Jarvis is online" within 2 s | — | Tier-1 `AVSpeechSynthesizer`; no tier-2 path | live-launch | manual: click "Speak Test Phrase" menu item; observe audible phrase + log line | — | ⬜ pending |
| DIAG-01 | 10-05 | 5 | Voice Log opens via menu item; first entry appears within 1 s of "Hey Jarvis" | — | AppKit window mirrors `DevOverlayWindow` (no new WKContentWorld); `NSWindow.frameAutosaveName` for position | live-launch | manual: `tccutil reset Microphone com.koftwentytwo.jarvis`; relaunch; open Voice Log via menu; say "Hey Jarvis, what time is it?"; observe wake-word fire + VAD speechStart + STT final + tool call + TTS synthesize entries within 10 s, all timestamped | — | ⬜ pending |
| DIAG-01 | 10-05 | 5 | Publisher caps at 2000 events with FIFO eviction on overflow (D-21) | T-10-VLOG-01 | In-memory only — never writes transcript content to OSLog (T-06-05-03) | unit | `swift test --package-path packages/VoiceLog --filter VoiceLogPublisherTests/capsAt2000WithFIFO` | ❌ W0 (salvage from stash + extend) | ⬜ pending |
| DIAG-01 | 10-05 | 5 | RMS rate-limited ≤1 Hz at publisher side (D-24) | T-10-VLOG-02 | Subscribers always receive monotonic ≤1 Hz `audioLevelRMS` events; no actor hops on tap thread | unit | `swift test --package-path packages/VoiceLog --filter VoiceLogPublisherTests/audioLevelRMSRateLimited` | ❌ W0 | ⬜ pending |
| DIAG-01 | 10-05 | 5 | No transcript text passes through `Logger` / `os.log` (T-06-05-03 invariant) | T-06-05-03 | Voice Log holds transcripts in-process only; existing grep gate enforces no-OSLog | grep gate | existing `scripts/check-no-transcript-oslog.sh` boundary gate (or grep equivalent in `CLAUDE.md` boundary list) | ✓ existing | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

**Sampling continuity check:** No 3 consecutive tasks lack automated verification — every plan has at least one unit/integration test alongside its live-launch step.

---

## Wave 0 Requirements

Wave 0 work scaffolds the test files BEFORE the first executable plan begins, so Plan 10-01 has tests to make green rather than starting from nothing. Per CONTEXT.md D-04, every plan ends with a live-launch entry in its SUMMARY.md regardless of unit-test coverage.

- [ ] `packages/MCP/Tests/MCPTests/ListAudioDevicesToolTests.swift` — stub asserts the four self-knowledge tools register
- [ ] `packages/MCP/Tests/MCPTests/GetActiveAudioRouteToolTests.swift` — stub for SELF-02 (uses `AudioGraphOwner` test seam)
- [ ] `packages/MCP/Tests/MCPTests/GetSelfStateToolTests.swift` — stub for SELF-03
- [ ] `packages/MCP/Tests/MCPTests/ListCameraDevicesToolTests.swift` — stub for SELF-04
- [ ] Extend `packages/MCP/Tests/MCPTests/MCPRuntimeWiringTests.swift` with `registersFourSelfKnowledgeTools` (asserts each registered with `requiresConfirmation: false`)
- [ ] Extend `packages/AgentCore/Tests/AgentCoreTests/CacheHintsEligibilityTests.swift` with `preambleDoesNotEnableCacheUnintentionally`
- [ ] `packages/VoiceLog/Package.swift` + Sources/VoiceLog/* (selectively salvage from `stash@{0}` per D-25; verify each file matches D-22/D-23/D-24)
- [ ] `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogPublisherTests.swift` — `capsAt2000WithFIFO` + `audioLevelRMSRateLimited` (extend stashed file or rewrite if it conflicts with D-22)
- [ ] `packages/VoiceLog/Tests/VoiceLogTests/VoiceLogViewModelTests.swift` — selectively salvage from stash
- [ ] Salvage `packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBroadcasterIntegrationTests.swift` from stash (Plan 10-03 input)
- [ ] Bake the canonical Live-Launch Verification template (RESEARCH.md § "Live-Launch Verification Format (D-26 template)") into each plan's SUMMARY.md scaffold

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Wake-word fires on real "Hey Jarvis" utterance | SPEC AC-07 (DIAG-01) | Requires real mic + real human voice; ONNX wake-word DAG cannot be reproduced in CI without a controlled audio fixture, and TCC-grant flow is OS-level | (1) `tccutil reset Microphone com.koftwentytwo.jarvis`; (2) relaunch Release-signed Developer ID archive; (3) click Allow on mic prompt; (4) say "Hey Jarvis, what time is it?"; (5) observe Voice Log entry `wakeWordFired` within 1 s, `vadSpeechStart`, ≥1 `sttPartial`, `sttFinal` containing "what time is it", orchestrator `submit`, `get_time` tool call, orchestrator turn-end, `ttsSynthesizeStart`, `ttsSynthesizeComplete` — all within 10 s, all timestamped |
| TTS playback audible at expected route | SPEC AC-10 (DIAG-04) | Requires real speaker output; AVSpeechSynthesizer-output cannot be intercepted without distorting the production code path | (1) Click "Diagnostics → Speak Test Phrase" menu item; (2) hear "Jarvis is online" within 2 s of click; (3) record observed audible-yes/no in SUMMARY.md |
| Audio loopback round-trip | SPEC AC-09 (DIAG-03) | Requires real mic + speaker round-trip | (1) `tccutil reset Microphone com.koftwentytwo.jarvis`; (2) relaunch; (3) click "Diagnostics → Audio Loopback Test"; (4) speak audibly during the 2 s capture window; (5) hear the recorded audio play back within 1 s of the capture window ending |
| DevOverlay populates within 100 ms of `.turnEnded` | SPEC AC-08 (DIAG-02) | Wall-clock observation against a real LLM round-trip | (1) Relaunch; (2) open DevOverlay; (3) send a text turn that calls `get_time`; (4) within 100 ms of seeing turn-end in logs, screenshot DevOverlay showing populated Provider/Model/Input/Output/Cache/Latency/last-5-tool-calls |
| "What mic are you using?" routes to `get_active_audio_route` | SPEC AC-05 (SELF-05) | End-to-end LLM behavior; cannot be reliably tested in unit tests because the model's tool-call decision is non-deterministic | (1) Relaunch with new preamble; (2) ask "what mic are you using?" via voice or text; (3) observe DevOverlay last-5 tool-calls shows `get_active_audio_route`; (4) observe response names the device |
| "Are you a text-only assistant?" produces denial | SPEC AC-06 (SELF-05) | End-to-end LLM behavior | (1) Ask the question; (2) observe response cites voice + vision capabilities |
| `list_audio_devices` matches `system_profiler` | SPEC AC-01 | Hardware-truth comparison | (1) `system_profiler SPAudioDataType` (CLI); (2) Invoke tool via DevOverlay tool-call inspector or chat turn; (3) diff sets — every device in the tool result has a corresponding `system_profiler` entry |
| `list_camera_devices` matches `system_profiler` | SPEC AC-04 | Hardware-truth comparison | (1) `system_profiler SPCameraDataType`; (2) Invoke tool; (3) diff |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies (Live-launch ACs are explicit Manual-Only entries above)
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30 s per task / < 8 min per plan boundary
- [ ] `nyquist_compliant: true` set in frontmatter (after planner enumerates per-task assignments)

**Approval:** pending
