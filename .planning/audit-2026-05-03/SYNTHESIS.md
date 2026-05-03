---
title: v0.12.0 Deep Audit — Synthesis
date: 2026-05-03
inputs:
  - hud-audit.md
  - voice.md
  - voice-audit.md
  - vision-audit.md
  - memory-audit.md
  - llm-audit.md
  - tests-audit.md
verdict: "Nothing works end-to-end. Three modalities are scaffolding-only. The fourth (text) is one cache_control header away from working."
---

# v0.12.0 Deep Audit — Synthesis

The user's framing — "50+ hours of agent work and nothing useful created" — is **correct, and arguably charitable.** Six independent auditors, each focused on one dimension (HUD, voice, vision, memory, LLM, tests), came back with grades ranging from D+ to F. Every modality the project promises has at least one fatal break between code-that-passes-tests and code-that-runs.

What's also true: most of the underlying classes are real, well-factored, and unit-tested in isolation. The catastrophe is at the **wiring layer.** Producers exist, consumers exist, the test suite verifies each in a vacuum, and **the cables are missing or going to the wrong place.**

## Scoreboard

| Modality | Grade | One-sentence verdict |
|---|---|---|
| **HUD** (rings) | D+ | A 1-line bug at `stateUniforms.ts:30` that a unit test actively defends. |
| **Voice** | F | Models never bundled, audio graph never instantiated, STT bridge body is `_ = chunk`, TTS engine is `nil`. |
| **Vision** | F | `AVCapturePhotoOutput` allocated but `capturePhoto(...)` never called. Frame stream is `AsyncStream { cont.finish() }`. No HUD camera button exists. |
| **Memory** | F | Apple's stripped libsqlite3 prevents `sqlite-vec` from loading. The "future ops plan" to bundle a custom build has zero commits. SearchMemoryTool is unregistered. |
| **LLM** | D+ | Architecture sound. Likely `streamTruncated` cause: `cacheHints: .extended1h` on a 10-token system prompt; Anthropic requires ≥1024 tokens for cache breakpoint. Diagnostic SSEDecoder swallows "200+0 bytes" and "200+truncation" as the same event. |
| **Tests** | C− | ~937 tests across 174 files. ~5% real-runtime. Two real-WKWebView tests, both added today as direct response to a shipped bug. Several `XCTAssertTrue(true)` tautologies. SpyBus + NoopBusGateway are both "valid" implementations of the same protocol — the test passes, production swallows. |

## The four systemic root causes

Across all six reports, the same four patterns explain >90% of the findings:

### 1. "Producer wired ✓, consumer wired ✓, cable missing ✗"

This is the headline pattern from the v0.12.0 milestone audit. Every report independently re-discovered it:
- **Vision**: `FrameAttachController.confirmSend(...)` has zero non-test callers. `frameAttachRequested` has zero JS-side emitters. The HUD camera button doesn't exist.
- **Voice**: `WakeWordDAG.start(ring:)` is never called in production. `AudioGraph` is never instantiated outside tests.
- **Memory**: `SearchMemoryTool` and `ForgetFactTool` exist in code but are not registered with the MCP runtime. The agent has no way to call them.
- **LLM**: until commit `048ab08` (today), the orchestrator + broadcaster + ALL six subscribers were dormant on every cold launch — `agentInstallTask` lost the race against MCPRuntime build, and `installAgent` silently short-circuited on `mcpRuntime == nil`.

The unit tests prove each end of the cable exists. Nothing tests the cable itself.

### 2. Resources documented as bundled, never actually bundled

- **Voice models**: `project.yml:107` *excludes* `Resources/**` from the App target. `Contents/Resources/` of the built app contains zero `.onnx` files. Even if they were bundled, the runtime path is `Contents/Resources/Models` (capital M) but the disk path is `Resources/models` (lowercase). The `fetch-silero-models.sh` script has never been executed — Silero MANIFEST.json still has literal `sha256: "PLACEHOLDER..."`.
- **Memory**: `vec0.dylib` is the placeholder file `Resources/PLACEHOLDER.txt`. The plan to bundle a custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1` has zero commits, zero scripts, zero plan files. It's a phantom todo.

The project has been spending plan cycles writing code that depends on assets that nothing ever produces or copies.

### 3. Methods constructed, then never called

- **Vision**: `CameraCapture.swift:153-155` allocates `AVCapturePhotoOutput` and adds it to the session. `capturePhoto(...)` is **never called anywhere in the file**. No `AVCapturePhotoCaptureDelegate` conformance exists. The `onePixelJPEG()` stub at line 190-212 isn't a placeholder for an "almost done" implementation — it's the entire camera path.
- **Voice**: `AudioGraphOwner` is referenced in tests, never instantiated in `/App`. `AVAudioEngine.start()` and `installTap()` are never called. The mic never opens.
- **HUD**: 19 of 22 visible chrome fields are hardcoded template strings. "MCP HELPERS 3", "WAKE WORD ARMED", "TCC AUDIO ✓" — none of these are reactive. They look live, they aren't.

The architecture diagrams describe what could happen. The runtime delivers what does happen. They've drifted.

### 4. Tests defend the stub

This is the most insidious pattern, because it actively prevents the bug from being fixed:

- **HUD**: `stateUniforms.test.ts:31` literally asserts `STATE_PARAMS[idle].pulse === 0`. The visible bug — static rings in idle state — is enforced by the test. Fixing the visual would break the test.
- **Memory**: `HybridSearchTests.swift:106` asserts `XCTAssertTrue(true, "Real-DB execution lives in 07-06 regression-corpus.")`. That's a literal `true` assertion with a comment promising a follow-up that never landed.
- **Vision**: `FrameAttachControllerTests` uses `FakeCapture` returning a 10-byte hand-crafted fixture. The 1×1 JPEG stub passes every Vision test because no test asserts width > 1.
- **Voice**: 4 `AVSpeechSmokeTests` actually exercise real `AVSpeechSynthesizer`. The other ~79 tests use `Mock*` / `Scripted*` / `Null*` / `XCTSkipUnless(JARVIS_REAL_MODELS=1)`. The skipped real-model tests run nowhere in CI.
- **Tests-audit count**: 5 explicit `XCTAssertTrue(true)` tautologies. Multiple "rubber stamp" tests asserting the literal in source matches the literal in test.

Every theatrical test creates a false-positive ratchet. The repo can't migrate off these without tripping its own gates.

## What works (be specific so we don't lose this)

Several real, durable assets came out of these 50 hours. The audits agree on these:

- **Bus protocol decoder** — exhaustive switch with `_exhaustive: never` sentinel, every BusOutbound case unit-tested. Real.
- **Anthropic SSE decoder** — every documented edge case (refusal, partial tool-use, ping, message_stop vs message_delta) unit-tested via real fixtures. Real.
- **OutboundBatcher** — 30 Hz coalescing actor, real concurrency tests.
- **OrchestratorEventBroadcaster** — protection matrix for `.bus` priority verified.
- **The chat input UI shipped today** (commit `621b454`) — input → submit → Swift handler → orchestrator. Proven end-to-end via screenshot.
- **The race-condition fix today** (commit `048ab08`) — `agentInstallTask` now awaits MCPRuntime, beginSession is called. Six subscribers are alive at runtime for the first time in repo history.
- **Replay log** — schema, FK constraints, write semantics. Real, tested, FK-validated as of today.
- **MenuBar + WindowManager + WKWebView host** — borderless transparent window with hotkey toggle. Proven by today's smoke test.

These ~30 hours of work are not wasted. The remaining ~20 hours of work amount to: the wiring is missing, the resources don't ship, the production callers don't exist.

## What it would actually cost to get one working modality

Auditors converge on text-with-animated-rings as the cheapest first delivery. Estimates aggregated below.

### Track A: text turn that streams tokens — ~2 hours of focused work

1. **Drop `CacheHints: .extended1h`** when system prompt is < 1024 tokens (or until we reach that floor). Anthropic's prompt cache requires ≥1024 tokens per breakpoint; below that, the server can return 200 + immediate-EOF on the `extended-cache-ttl` beta. (~30 min, in `AnthropicProvider`.)
2. **Add HTTP-status diagnostic** to `AnthropicProvider` so future "200 + 0 bytes" doesn't silently look identical to "200 + truncated mid-stream". One log line. (~15 min.)
3. **Surface KeychainError** instead of swallowing into empty string at `AppDelegate.swift:885-887`. (~15 min.)
4. **Curl-replay the production request body** (not just headers) to confirm the Anthropic side. (~30 min.)
5. **Fix `stateUniforms.ts:30`** to give the `idle` state a real `pulse` and `rotate` value, and update the test table. The static rings disappear. (~30 min.)

After Track A, the text-modality demo works end-to-end with animated rings.

### Track B: voice turn — ~1 day

1. Add `Resources/**` to `project.yml` build phase (or a postBuildScript that copies to `Contents/Resources/Models/`). Reconcile capital-M vs lowercase-m path mismatch. (~30 min.)
2. Run `scripts/fetch-silero-models.sh` and check in the model files (or wire fetch into postBuildScript). (~30 min.)
3. Replace `LiveSpeechAnalyzerBridge.feed()` body (`_ = chunk`) with the actual SpeechAnalyzer wiring per macOS 26 docs. (~3 hr.)
4. Construct an `AudioGraphOwner` in `installVoice` and start the audio engine. Wire mic → wake-word DAG → VAD → STT. (~2 hr.)
5. Fix `WakeWordDAG.swift:93` calling `feedTest()` instead of `feed(samples:)`. One-line. (~5 min.)
6. Construct a `TTSEngineActor` in `installVoice` (Orpheus or AVSpeechSynthesizer); replace `VoiceTTSAdapter(engine: nil)`. (~2 hr.)
7. One real-runtime test: feed a known WAV file at the audio graph, assert STT yields non-empty text. (~1 hr.)

### Track C: vision turn — ~1 day

1. Add `AVCapturePhotoCaptureDelegate` conformance to `CameraCapture`; route `capturePhoto(...)` → delegate → `CapturedFrame`. (~3 hr.)
2. Replace `frameStream(forPresence:)`'s `cont.finish()` with a real continuation that yields delegate-captured frames. (~1 hr.)
3. Add a HUD camera button that emits `BusInbound.frameAttachRequested`. (~1 hr.)
4. Find or hook a real T2 provider (or accept that `t2Provider: t1` is the contract). (~varies.)
5. One real-hardware test (XCTSkipIf no camera) that asserts `captureFrame()` returns a JPEG decoding to non-1×1. (~1 hr.)

### Track D: memory — ~3 days

1. Build a custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1`. Codesign nested. Bundle. (~1 day.)
2. Bundle `vec0.dylib`. (~2 hr.)
3. Remove the `installMemory` early-return cascade so the extractor + coordinator construct even when SQLite-vec init fails (degrade gracefully but keep the rest working). (~30 min.)
4. Register `SearchMemoryTool` + `ForgetFactTool` with `mcpRuntime`. (~1 hr.)
5. Fix `MemoryExtractionOrchestrator.swift:84` — `priorFacts: []` hardcode. (~1 hr.)
6. Pull local Ollama models for embeddings + extraction. (~30 min.)
7. End-to-end regression scenario: "remember Brutus" → store → search → recall. (~half-day.)

## What I think the user should ask for next

You have three legitimate paths and one cosmetic one:

1. **"Make the text demo work"** — Track A. Two hours. You'd have working chat-with-streaming-tokens AND animated rings. This is the one I'd recommend if you want to feel like the project moved.
2. **"Tear out the dead modalities and ship a text-only v0.12.0"** — close vision/voice/memory as v0.13+ scope. Removes the lying-about-completion problem. ~half-day of cleanup.
3. **"Burn it down and pick a smaller scope"** — if you've lost faith in the agent loop, accepting the current state is sunk cost and starting fresh from the chat modality outward is rational. The bus protocol, decoder, OutboundBatcher, Anthropic decoder, MenuBar host are durably good and could be reused.
4. **"Just give me animated rings"** — 30 minutes. Cosmetic fix. Doesn't move the modalities. Worth knowing it's that cheap.

Recommended: **Track A.** The text demo at the end of two hours would be the first time anything in this project actually does what it promises. Voice / vision / memory cost real days each; text costs hours. The honesty-restoring move is to ship one working modality before doing anything else.

## Footnote on the test pyramid

The tests-audit's bottom line: `~937 tests, ~5% real-runtime, 8 boundary grep gates, 9/9 phase verifications.` All the sigils said green; the milestone said done; the app was nonfunctional. The user's "50+ hours, nothing works" is the only unbiased signal on file.

Phase F1 (top-level integration tests) is the structural fix for this bug class. Until it lands, every future milestone audit will surface the same shape of finding. Phase F2 (stub linter) and F3 (verifier extension) are also explicitly listed in `AUDIT-AND-FIX-PLAN.md`. None of them have been started.

If we do anything beyond Track A this week, **F1 is the highest-leverage**. A single end-to-end test that cold-launches the app, mounts the JS bundle in a real WKWebView, mocks the Anthropic provider with a 200+SSE-stream backend, and asserts that a chat submit produces text in the chat panel — that one test would catch BLOCKER-INT-1, INT-2, INT-3, F-E-RACE-1, F-E-FK-1, F-E-WIRE-1, AND the streamTruncated scenario. All in one shot. About a day to write.

The 50 hours have produced real engineering. The illusion of completion has been the cost.
