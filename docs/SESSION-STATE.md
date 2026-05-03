# Session State

**Last Updated:** 2026-05-03

## Current Status

`develop` at `ee7f6d2`, pushed. Tree clean. Track A (text demo + animated rings) closed end-to-end with TDD coverage. Track B-1..3 (voice models bundled, WakeWordDAG typo fix, tier-1 TTS engine wired) closed. Track B-4 + B-5 are the next session's pickup point.

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

## Active Branches

| Branch | Status |
|--------|--------|
| `develop` | At `ee7f6d2`, pushed to origin. Tree clean. |

## Pending Work

- [ ] **Track B-4** — `AudioGraphOwner` construction in `installVoice`; `AVAudioEngine.start()`; mic taps → wake-word DAG. Replace `LiveSpeechAnalyzerBridge.feed()` body (`_ = chunk`) with macOS 26 SpeechAnalyzer wiring.
- [ ] **Track B-5** — voice loop e2e test: feed a known WAV at the audio graph, assert STT result lands on the orchestrator.
- [ ] **Track C** — vision: `AVCapturePhotoOutput` delegate flow (currently allocated but never called); HUD camera button (doesn't exist); `frameStream` returns immediately-finished `AsyncStream`. ~1 day.
- [ ] **Track D** — memory: bundle custom libsqlite3 with `SQLITE_ENABLE_LOAD_EXTENSION=1`, ship `vec0.dylib`, register `SearchMemoryTool` + `ForgetFactTool` with MCP runtime, fix `priorFacts: []` hardcode. ~3 days.
- [ ] BLOCKER-INT-1 — replace `NoopBusGateway` so tool-call cards reach HUD.
- [ ] F-A2-01 — `WebviewBridgeOutboundTests:80` stale `JarvisBusWorld` assertion.
- [ ] streamTruncated empirical confirmation — re-launch app and verify cache_control fix actually completes a turn.

## Key Reference

- Audit reports: `.planning/audit-2026-05-03/{SYNTHESIS,voice,voice-audit,hud-audit,vision-audit,memory-audit,llm-audit,tests-audit}.md`
- Plan: `.planning/AUDIT-AND-FIX-PLAN.md`, findings tracker: `.planning/AUDIT-FINDINGS.md`
- Test stack at session end: AgentCore 215/215, Voice +6 (DAG + TTS), Replay 33/33, Bus 57/58 (1 pre-existing F-A2-01), webview/hud 94/94, all 15 boundary gates PASS, app builds clean.
- Next-session orientation: read `.planning/audit-2026-05-03/SYNTHESIS.md` first, then this file, then `git log --oneline ee7f6d2`'s commit body for B-1..3 carry-forward.
