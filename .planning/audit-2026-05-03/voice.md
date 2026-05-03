# Voice Modality — Brutally Honest Deep Audit

**Date:** 2026-05-03
**Auditor:** read-only static + bundle-artefact audit
**Verdict (TL;DR):** The voice modality on this machine is **end-to-end non-functional**. The single warning in `v0.12.0-MILESTONE-AUDIT.md` (`WARN-INT-1: TTS engine nil; voice loop is mute`) understates reality by an order of magnitude. The wake word never fires, the audio graph is never instantiated by the app, the STT bridge is a placeholder that ignores audio, and the TTS engine is `nil`. Even bundling the missing ONNX models would not produce sound — every layer below TTS is wired to a null surface or stubbed.

---

## 1. Documented scope vs reality

### 1a. CLAUDE.md (root, "Voice stack")

CLAUDE.md commits to:

- openWakeWord `hey_jarvis` via ONNX Runtime Swift, ≥4-frame hysteresis, `streaming DAG: mel ring → embedding ring → classifier`.
- Silero VAD v6.2.1 (512-sample / 32 ms / 16 kHz contract).
- STT primary: macOS 26 Tahoe `SpeechAnalyzer` / `SpeechTranscriber`.
- STT fallback: WhisperKit via `argmaxinc/argmax-oss-swift v0.18.0`, model `large-v3-v20240930_626MB`.
- TTS tier 1: `AVSpeechSynthesizer`.
- TTS tier 2: Orpheus via `mlx-audio-swift v0.1.2` / `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")`. **Streaming confirmed**, target 150–250 ms TTFA.
- TTS tier 2 fallback: TTSKit from `argmax-oss-swift`.
- Week-one scope (lines 132-154) explicitly includes "Full voice loop" — wake word + STT + TTS.

### 1b. REQUIREMENTS.md

`.planning/REQUIREMENTS.md` lines 60-73 list **VOICE-01 .. VOICE-14** as v1 requirements, and the traceability table (lines 217-230) marks every single one as **Pending**. This was not an artefact-drift bug — per the milestone audit, it correctly reflects that no VOICE requirement has been validated end-to-end on real hardware.

### 1c. ROADMAP.md / PROJECT.md

`.planning/ROADMAP.md:163-178` — Phase 6 Voice "**Goal**: The end-to-end voice loop … 'Hey Jarvis, what time is it?' → natural spoken answer — works entirely on-device with HUD state visible through idle → listening → thinking → speaking …". Phase 6 has 5 plans (06-01 audio graph, 06-02 wake-word, 06-03 vad-stt, 06-04 tts-engine, 06-05 controller-wiring) and is listed in `v0.12.0-MILESTONE-AUDIT.md` as "human_needed | 7/7".

`.planning/v0.12.0-MILESTONE-AUDIT.md:WARN-INT-1` softens this with: "TTS engine `nil`; voice loop is mute … Voice in works; voice out is silent." That is **wrong** — voice in does not work either.

### 1d. The smoke-test log line

```
installVoice: OpenWakeWordSession init failed (models absent?): ... MANIFEST.json
```

That single line is the entire story: voice never even gets past step 2 of `installVoice()`. The whole subsystem is short-circuited at boot.

---

## 2. What code exists, and what it actually does

### 2a. `packages/Voice/Sources/Voice/` (production code)

Files (all real, all compile, most carry rich docstrings):

| File | Role | Production status |
|------|------|-------------------|
| `AudioGraph/AudioGraph.swift` | AVAudioEngine + VPIO + tap → ring buffer | **Fully implemented but never instantiated by `App`** (see §5). |
| `AudioGraph/AudioGraphOwner.swift` | Six-step rebuild lifecycle owner | **Never referenced from `/App` (zero hits)**. |
| `AudioGraph/RingBuffer.swift` | Lock-free SPSC ring | Real impl. Never written to in production. |
| `WakeWord/OpenWakeWordSession.swift` | 3-stage ORT pipeline + scripted test seam | Real ORT path AND scripted path. Never reaches ORT path because models aren't bundled. |
| `WakeWord/WakeWordDAG.swift` | Detached feed loop reading the ring | Implemented. **`start(ring:)` is never called from `/App` and the loop calls the test-only `feedTest()` which always feeds an empty array** (line 93). |
| `WakeWord/ModelManifest.swift` | SHA-256 verify of openWakeWord ONNX | Real impl. Throws `WakeWordError.modelHashMismatch` / `.missingModel` correctly. |
| `VAD/SileroVAD.swift` | ONNX Runtime VAD with op16/op15 fallback + LSTM state | Real impl. Never reached because Silero ONNX files were never downloaded. |
| `VAD/ContractParityProbe.swift` | Scaffold-time chunk-contract check | Exists. |
| `STT/SpeechAnalyzerSTT.swift` | Apple Speech framework adapter | **`LiveSpeechAnalyzerBridge.feed()` body is `_ = chunk`, `start()` is empty, `finalText()` returns `""`** (lines 169-192). The class is a placeholder per the comment "Wired fully in Plan 06-05. Placeholder here." That wiring never landed. |
| `STT/WhisperKitSTT.swift` | Lazy WhisperKit fallback | Implemented end-to-end with `LazyWhisperKitBridge`. Loads model on first transcribe. Never reached because the upstream STT is `speech_analyzer` and the audio chunk stream is empty (see §5). |
| `STT/STTBackendSelector.swift` | String-keyed factory | Real, called once with `"speech_analyzer"` from `App/AppDelegate.swift:737`. |
| `TTS/AVSpeechSynth.swift` | Tier-1 synthesizer wrapper | Real, complete. Stored synth + delegate + rapid-fire guard. **Constructed nowhere in `/App`.** |
| `TTS/OrpheusTTS.swift` | Tier-2 actor wrapping `LlamaTTSModel.generateStream` | Real impl, including reentrancy + cancellation. **Constructed nowhere in `/App`.** |
| `TTS/TTSKitFallback.swift` | TTSKit fallback wrapper | Exists. **Constructed nowhere in `/App`.** |
| `TTS/TTSEngineActor.swift` | Tier router, serial executor | Real. Public `init(orpheus:tier1:fallback:)` is the **only** init. **Zero non-test call sites in the entire repo** (verified: `grep -r 'TTSEngineActor('`). |
| `Control/PushToTalk.swift` | PTT key wrapper | Real. Constructed in `installVoice()` at line 752, but at that point voice has already returned because models are missing. |
| `Control/MuteWakeWord.swift` | Menu-bar mute toggle | Real. Same gating as PTT. |
| `Control/AudioLevelEmitter.swift` | RMS at ~30 Hz to bus | Real. Not started — its `start()` requires a ring being written to. |
| `VoiceController.swift` | Top-level state machine | Real, orchestrates 7 dependencies. Constructed in `installVoice()`, but two upstream returns (`OpenWakeWordSession init` failure and the missing AudioGraphOwner wiring) mean the state machine runs against an empty wake-word stream and an empty STT chunk stream forever. |

### 2b. `App/Voice/` (App-side adapters)

| File | Lines | Behavior |
|------|-------|----------|
| `VoiceOrchestratorAdapter.swift` | (real) | Real adapter — forwards `submit` / `cancelAndSubmit` to `AgentOrchestrator`, drains `events` AsyncStream and translates to `VoiceOrchestratorEvent`. |
| `VoiceTTSAdapter.swift` | 68 | Wraps an **optional** `TTSEngineActor`. **Production always passes `engine: nil`** (`AppDelegate.swift:715`). When `engine == nil`, every `synthesize(_:)` call is `guard let engine else { return }` — a no-op (line 45). Banner text confirms this: "TTSEngineActor construction is gated on Orpheus MLX weights + AVSpeech availability and lands in a follow-on plan". The follow-on plan never happened. |
| `VoiceBusEmitterAdapter.swift` | (real) | Real adapter pushing audio-level RMS into `OutboundBatcher`. Its only data source (`AudioLevelEmitter` reading the ring) never starts. |
| `VoiceBusEmitterAdapter.swift` / `RejectReasonCopy.swift` | minor | OK. |

There is also `App/Voice/VoiceTTSAdapter.swift` line 6: "Phase 9 / Plan 4 / D-09: replaces `NullTTSAdapter`." The replacement adapter exists; it just gracefully no-ops because the engine it would wrap is never built. The boundary gate `scripts/check-no-null-voice-adapters.sh` PASSES — but the gate only tests for *type* presence; it cannot detect that the production code passes `nil` to the real adapter.

---

## 3. Model files — bundled? expected? where do they come from?

### 3a. Source-tree model directories

```
Resources/models/openwakeword/
  .gitkeep
  embedding_model.onnx      (1.3 MB — present, fetched 2026-04-30)
  hey_jarvis_v0.1.onnx      (1.3 MB — present)
  melspectrogram.onnx       (1.1 MB — present)
  MANIFEST.json             (real SHA-256 hashes — populated)
Resources/models/silero/
  .gitkeep
  MANIFEST.json             (PLACEHOLDER hashes — script never run)
  (no .onnx files at all)
```

`Resources/models/silero/MANIFEST.json` literally contains:

```
"sha256": "PLACEHOLDER_run_scripts_fetch-silero-models.sh_to_populate"
```

Translation: **`scripts/fetch-silero-models.sh` has never been run on this machine.** Only `fetch-openwakeword-models.sh` was.

### 3b. Where the app expects to find them

`App/AppDelegate.swift:652-656`:

```swift
let bundleModels = Bundle.main.bundleURL
    .appendingPathComponent("Contents/Resources/Models", isDirectory: true)
let openWakeWordModelDir = bundleModels.appendingPathComponent("openWakeWord", isDirectory: true)
let sileroModelDir = bundleModels.appendingPathComponent("silero", isDirectory: true)
```

The app expects `Jarvis.app/Contents/Resources/Models/openWakeWord/` and `.../silero/`. (Note the case mismatch: source dir is `openwakeword`, code looks for `openWakeWord` — a separate bug if anything ever copied it.)

### 3c. The build never copies them

`project.yml` lines 100-107 — the App target's only resource path is `App/Resources/webview` (the HUD bundle). The repo-root `Resources/` tree is **explicitly excluded** by the `excludes: [..., "Resources/**"]` clause on the `App` source path (line 107). There is no `copyFiles` phase, no postBuildScript, no `xcassets` reference, no path inclusion anywhere in `project.yml` that targets `Resources/models/`.

`scripts/codesign.sh` is a signing walker — it does not copy data.
`scripts/build-webview.sh` builds the HUD JS only.
None of the prebuild / postbuild scripts mention models.

### 3d. The empirical evidence in the built bundle

```
$ ls build/Build/Products/Debug/Jarvis.app/Contents/Resources/
AppIcon.icns    Config_Config.bundle  swift-crypto_Crypto.bundle
Assets.car      Memory_Memory.bundle  swift-transformers_Hub.bundle
Bus_Bus.bundle  mlx-swift_Cmlx.bundle webview
```

No `Models/` directory. No `openWakeWord/`. No `silero/`. No `.onnx` files anywhere in the bundle (`find … -name '*.onnx'` returns empty).

### 3e. Conclusion on models

**The "missing MANIFEST.json" log line is misleadingly worded — the file is missing because the entire `Models/` subtree is missing because nothing in the build copies it.** Adding a build phase that runs `cp -R Resources/models/ "${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Resources/Models/"` would address openWakeWord. Silero would still fail because the .onnx files were never downloaded; `fetch-silero-models.sh` has never executed and the MANIFEST.json contains placeholder hashes (so `ModelManifest.verify` would throw `modelHashMismatch` even if files existed).

---

## 4. TTS production wiring — single end-to-end check

### 4a. The chain

`AgentOrchestrator` → `OrchestratorEventBroadcaster.events` (`.voice` subscription) → `VoiceOrchestratorEvent.turnEnded(text:)` → `VoiceController.handleOrchestratorEvent` → `tts.synthesize(text)`.

`tts` is `VoiceTTSAdapter` from `AppDelegate.swift:715`:

```swift
let ttsAdapter = VoiceTTSAdapter(engine: nil)
```

`VoiceTTSAdapter.synthesize` (`App/Voice/VoiceTTSAdapter.swift:44-46`):

```swift
func synthesize(_ text: String) async {
    guard let engine else { return }   // dormant — no engine wired yet
```

So `tts.synthesize` is **always** a no-op. There is no production path through `TTSEngineActor`, `OrpheusTTS`, `AVSpeechSynth`, or `TTSKitFallback`. Verified by `grep -r 'TTSEngineActor(' --include='*.swift' | grep -v Tests | grep -v .build`: returns zero rows.

### 4b. The unit-test landscape doesn't reflect this gap

- `AVSpeechSmokeTests.swift` constructs `AVSpeechSynth()` directly and exercises real AVFoundation in-test. So **AVSpeech itself works** — the gap is purely wiring.
- `OrpheusTTFATests.swift` is gated behind `XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1")` (line 26-29). It **does not run by default** — the only place where Orpheus performance is exercised is opt-in.
- `OrpheusSerializationTests.swift` and `TTSInterruptTests.swift` exercise `OrpheusTTS` and the cancellation chain via `SpeechGenerationModelProtocol` mocks, not real weights.

### 4c. Verdict on TTS

CLAUDE.md says AVSpeech tier-1 + Orpheus tier-2 are week-one scope. Today: **neither is reachable from a production code path**. The adapter exists, the engine type exists, the protocols exist; the line that constructs the engine and hands it to the adapter does not.

---

## 5. Wake word + VAD + STT pipeline — does the audio actually flow?

Trace, end-to-end, starting from microphone:

1. **AVAudioEngine / VPIO** — `AudioGraph.init` and `AudioGraphOwner.init` exist in `packages/Voice/Sources/Voice/AudioGraph/`. Each enables `voiceProcessing`, probes input format, installs a tap, writes to a `RingBuffer`.
2. **`AudioGraphOwner`** is the only thing that can drive that tap and own the ring. **Search results:** `grep -rn "AudioGraphOwner" /Users/james.maes/Git.Local/Kof22/Jarvis/App --include='*.swift'` returns **zero hits**. The App layer never instantiates it.
3. Therefore `AVAudioEngine.start()` is never called, `inputNode.installTap(...)` is never called, the RingBuffer is never written.
4. **`WakeWordDAG.start(ring:)`** requires a `RingBuffer` argument. `AppDelegate.installVoice()` line 678 only constructs the DAG via `WakeWordDAG(session: wakeWordSession)` and never calls `.start(ring:)`. So even if a ring existed, the DAG's feed task never spawns.
5. **The DAG calls the wrong API.** `WakeWordDAG.swift:93`: `if let decision = try? await self.session.feedTest()`. `feedTest()` is the **internal scripted-classifier test seam** (`OpenWakeWordSession.swift:119-121`). In production, `scriptedClassifier == nil`, so `feedTest()` invokes `runHysteresis(pcmSamples: [])` → `runORT(pcmSamples: [])` → `runMel(pcm: [])` with a `[1, 0]` ORT input — which would throw, and the outer `try?` swallows it. Even *if* the ring were wired and the loop ran, every iteration would silently consume an empty buffer and never call the real ONNX models. **`feed(samples:)` is the production API and `WakeWordDAG` does not call it.** This appears to be a write-time error or a half-finished migration; either way, no test catches it because the unit tests only exercise scripted seams.
6. **VoiceController STT chunk stream.** `VoiceController.startSTTSession` (line 300-325) creates a fresh `(chunkStream, cont)` pair and stores `cont` on `sttChunkCont`. The provider is then asked to `transcribe(stream: chunkStream)`. **Nothing in the entire codebase ever calls `sttChunkCont?.yield(...)` or wires it to an audio source.** Search: `grep -rn "sttChunkCont" packages App --include='*.swift'` — every hit is to nil-out / finish() / declare. No producer.
7. **`SpeechAnalyzerSTT.LiveSpeechAnalyzerBridge`** has placeholder bodies:
   - `start()` empty (line 169-171)
   - `feed(_ chunk:)` body is `_ = chunk` (line 173-177)
   - `partialResults()` returns an empty stream
   - `finalText()` returns `""`
   The comment is candid: "Wired fully in Plan 06-05. Placeholder here." Plan 06-05 did not wire it.
8. **`finalize()`** therefore returns `""`. `VoiceController.handleSTTFinalized(text: "")` hits the `if text.isEmpty { await doTransition(to: .idle); return }` branch — silently dropping the turn.

So even in the impossible counterfactual where Silero ONNX files were downloaded and the `Models/` directory were bundled and the case mismatch were fixed and the AudioGraph were wired and `WakeWordDAG.start(ring:)` were called and `feedTest` were swapped for `feed(samples:)`, the STT step at the end would still receive zero audio chunks and return an empty string. The voice loop has at least **five independent bugs that each individually break it**, four of them severe enough to require not just code changes but architectural connection (instantiating AudioGraphOwner, wiring its ring to WakeWordDAG, wiring its tap to VoiceController.sttChunkCont, completing LiveSpeechAnalyzerBridge).

---

## 6. Test coverage authenticity

Sample tests reviewed:

### 6a. `WakeWordHysteresisTests.swift`
H1–H6 test the hysteresis state machine via the `internal init(scriptedClassifier:)` test seam (`OpenWakeWordSession.swift:66`). The test **bypasses ORT entirely**. H6 alone touches `ModelManifest.verify` against an in-temp-dir manifest. The classifier path is never exercised against the real `hey_jarvis_v0.1.onnx`. Verdict: useful unit coverage of the counter logic; **zero coverage of the model path**.

### 6b. `OrpheusTTFATests.swift`
T1 probe is gated `XCTSkipUnless(JARVIS_REAL_MODELS == "1")`. T2 (TTSKit) is similarly gated. These tests **do not run in the standard `swift test` invocation**. They are scaffold-time human probes only.

### 6c. `AVSpeechSmokeTests.swift`
A1–A4 use real `AVSpeechSynthesizer` and real `AVAudioEngine`. These are the only tests in the suite that exercise real OS audio APIs end-to-end. They prove **the AVFoundation primitives work** — they do not prove the production path uses them.

### 6d. `VoiceControllerTests.swift`
V1–V4 use full mocks (`MockOrchestrator`, `MockTTS`, `MockBusEmitter`, `MockVADEngine`, `SpeechAnalyzerSTT(analyzerBridge:)` with a mock bridge). The tests verify the state machine. They cannot fail when the production wiring is broken because the mocks fabricate every signal.

### 6e. `App/Tests/AppTests/VoiceWiringTests.swift`
Looking at line 108-141: it constructs a `VoiceController` directly inside the test with a synthetic `AsyncStream<WakeWordEvent>`. It does not assert that AppDelegate's `installVoice` produces a controller that can fire on a real wake event. There is no integration test that cold-launches the app and verifies that wake → STT → submit → TTS round-trips.

### 6f. Verdict on test authenticity

The unit suite is large and well-written **at the contract level** of each individual class. It is silent on three categories of failure that all currently apply:

1. Construction-site errors (`engine: nil`, missing `start(ring:)` call, missing `AudioGraphOwner`).
2. Missing resources (no model copy phase, no Silero download).
3. Stub bodies in `LiveSpeechAnalyzerBridge`.

The boundary grep gates (`scripts/check-no-null-voice-adapters.sh` etc.) cannot detect any of this because, as `v0.12.0-MILESTONE-AUDIT.md` puts it: "boundary gates correctly enforce isolation but don't catch absence-of-implementation."

The deferred F1 #2 integration test (`packages/Bus/Tests/BusTests/RealWKWebViewIntegrationTests.swift` cousin for voice) does not exist. The smoke-test loop is manual.

---

## 7. Smallest credible plan to land "wake word fires → STT transcribes → orchestrator submits → TTS speaks"

Ranked, with file:line anchors. Each is a non-skippable predecessor for the one below.

**(1) Get `AVSpeechSynthesizer` to actually speak the orchestrator's reply.** This is the smallest, most independent fix. Construct a `TTSEngineActor` in `AppDelegate.installVoice` that wraps real `AVSpeechSynth()` (and optionally an `OrpheusTTS()` async init guarded by feature flag), then pass it into `VoiceTTSAdapter(engine: ...)` instead of `nil`. The text-input path already works (per `AUDIT-FINDINGS.md` Phase E fixes), so completing this loop alone makes the bot speak responses to *typed* input. **Effort:** ~40 LOC in `AppDelegate.installVoice` + a new `App/Voice/TTSEngineFactory.swift`; no architectural changes. **Anchor:** `App/AppDelegate.swift:715`.

**(2) Bundle the openWakeWord ONNX files into the .app.** Add a `copyFiles` phase or `postBuildScript` to `project.yml` that copies `Resources/models/openwakeword/*` into `Jarvis.app/Contents/Resources/Models/openWakeWord/`. Fix the case mismatch in `App/AppDelegate.swift:655` (`openWakeWord` vs source dir `openwakeword`). **Effort:** ~10 LOC in `project.yml`. **Anchor:** `project.yml:99-115`, `App/AppDelegate.swift:652-656`.

**(3) Run `scripts/fetch-silero-models.sh`** to populate the two Silero ONNX files and the MANIFEST.json hashes. Then bundle them in step (2). **Effort:** one shell command + the same copy phase. **Anchor:** `Resources/models/silero/MANIFEST.json` (PLACEHOLDER hashes today).

**(4) Instantiate `AudioGraphOwner` and connect the ring.** This is the largest gap. `installVoice` needs to:
   - Construct an `AudioGraphOwner` with a `graphBuilder` that produces an `AudioGraph(aec: true, ...)`.
   - Open the graph (`await audioGraphOwner.openInitial()`).
   - Pass `audioGraphOwner.ring` to `WakeWordDAG.start(ring:)`.
   - Pipe the ring's downsampled-to-16-kHz output into `VoiceController.sttChunkCont` (currently nil-only).
   - Wire `audioGraphOwner.cancelInFlight` to `wakeWordDAG.cancel`.
   - Wire `audioGraphOwner.degradationStream` to `voiceController.handleAEC{Unavailable,Restored}`.
   **Effort:** ~80 LOC in `AppDelegate.installVoice`; matches the contract that `packages/Voice` already documents but never had a caller for. **Anchor:** `App/AppDelegate.swift:643-764`.

**(5) Fix the wrong-API call in `WakeWordDAG`.** Change `feedTest()` to `feed(samples:)` at `WakeWordDAG.swift:93`. **Effort:** one line. **Risk:** medium — verify that `feed(samples:)` is callable from an actor-detached `Task` without Swift 6 concurrency complaints.

**(6) Replace `LiveSpeechAnalyzerBridge` placeholder bodies** with real `SpeechAnalyzer` / `SpeechTranscriber` calls (macOS 26 Tahoe). The class skeleton already documents the contract. **Effort:** ~120 LOC in `packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:149-193`. Also requires the `com.apple.developer.speech-recognition-assets` entitlement and `NSSpeechRecognitionAssetsUsageDescription` Info.plist key, both already documented as load-bearing in CLAUDE.md but should be re-verified in the entitlements files.

**(7) Add a real integration test** that spawns the audio graph against a synthetic `AVAudioFile` source, asserts that wake-word fires within N seconds, and that STT returns the expected string. This is the only thing that will keep regressions like (1)-(6) from rotting again. **Effort:** ~150 LOC in a new `packages/Voice/Tests/VoiceTests/EndToEndAudioFileTests.swift`. The harness can sidestep TCC by feeding a file rather than the live mic.

Steps (1)-(3) alone unlock **typed input → spoken output**, which is a meaningful demoable milestone and validates 70% of the voice infrastructure that already exists. Steps (4)-(7) are required for the full "Hey Jarvis" loop.

---

## Honest summary

**Today, the voice modality on this machine does literally nothing.** The wake word never fires because the openWakeWord ONNX files are not bundled in the .app (they exist in `Resources/models/openwakeword/` but `project.yml` excludes the entire `Resources/` tree from the App target's sources, and no other build phase copies them). Silero VAD models have never been downloaded — the manifest still contains `PLACEHOLDER_run_scripts_fetch-silero-models.sh_to_populate`. Even with all models bundled, `AudioGraphOwner` is never instantiated by `App/AppDelegate.swift` (zero references in `/App`), so `AVAudioEngine.start()` is never called and the ring buffer is never written; `WakeWordDAG.start(ring:)` is therefore never called; `WakeWordDAG.swift:93` calls the test-only `feedTest()` which feeds an empty array regardless; `LiveSpeechAnalyzerBridge.feed()` body is `_ = chunk` (a documented placeholder labelled "Wired fully in Plan 06-05" — Plan 06-05 wired the controller but never wired this bridge); and `VoiceTTSAdapter` is constructed with `engine: nil`, making every `synthesize` call a guarded early return. Five independent breakages, each individually fatal. The 49-file `packages/Voice/Sources/Voice/` tree contains real, well-tested implementations of every piece — none of them are connected to each other in the production app. The single warning recorded in the milestone audit (WARN-INT-1) understates the scope by a factor of five.
