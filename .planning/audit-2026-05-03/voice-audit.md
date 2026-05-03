# Voice Subsystem Audit — 2026-05-03

## TL;DR

**Grade: F.** **Nothing in the voice subsystem actually runs end-to-end.** Source code for the wake-word/VAD/STT/TTS engines exists and is well-factored at the unit level, but the production wiring is broken at five distinct points: (1) ONNX model files are not in any built `.app` bundle, (2) Silero VAD has no ONNX file even on disk, (3) `WakeWordDAG.start(ring:)` is never called in production so no audio is ever fed to the wake-word detector, (4) the production `LiveSpeechAnalyzerBridge.feed()` is a literal no-op stub, and (5) `TTSEngineActor` is never constructed in production — `VoiceTTSAdapter(engine: nil)` is hard-coded. The user cannot say "hey Jarvis" and get any response, spoken or otherwise. The voice loop is **mute, deaf, and ungrounded**.

---

## 1. Wake Word — broken at four layers

### 1.1 ONNX model files: NOT shipped with the app bundle

- The on-disk source-of-truth wake-word ONNX files exist at `Resources/models/openwakeword/` (1.3 MB `hey_jarvis_v0.1.onnx`, 1.3 MB `embedding_model.onnx`, 1.1 MB `melspectrogram.onnx`, plus `MANIFEST.json`). Verified by `ls Resources/models/openwakeword/`.
- `project.yml:99-115` defines the `Jarvis` target's `sources:` and the only `buildPhase: resources` is `App/Resources/webview` (line 113-115). **There is no resource phase that copies `Resources/models/**` into the app bundle.**
- `App/Resources/` contains exactly one subdirectory: `webview/`. There is no `App/Resources/models/`.
- Both built apps are empty of ONNX:
  - `build/Debug/Jarvis.app/Contents/Resources/` — completely empty (verified via `/bin/ls -la`).
  - `build/Build/Products/Release/Jarvis.app/Contents/Resources/` — contains only `Assets.car` and `Config_Config.bundle`.
- `App/AppDelegate.swift:652-655` reads from `Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Models", isDirectory: true)`. Capital-M `Models`. The repo path is lowercase-m `models`. Even if a build phase were added, the path mismatch would have to be fixed too.

**Result:** Every Release/Debug launch hits the `catch` at `AppDelegate.swift:662-665` with `WakeWordError.missingModel` and short-circuits the entire voice install. This matches the system log line in the prompt: `OpenWakeWordSession init failed (models absent?): MANIFEST.json missing`.

### 1.2 `OpenWakeWordSession` itself: real code, never reached

The implementation at `packages/Voice/Sources/Voice/WakeWord/OpenWakeWordSession.swift:33-55` is genuine — three `ORTSession` constructors, real `runMel` / `runEmbedding` / `runClassifier` ONNX inference (lines 274-368). It would work given valid model files. But it is constructed exactly once in production at `AppDelegate.swift:661`, which throws because the bundle has no models.

### 1.3 `WakeWordDAG.start(ring:)` is never called in production

Even if the models were bundled, `WakeWordDAG` requires a `RingBuffer` argument to start consuming audio:

- `packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift:67` — `public func start(ring: RingBuffer) async`.
- Cross-tree grep for `wakeWordDAG.start` or `wakeWordDAG\.` in production code: only `AppDelegate.swift:735` (passing `wakeWordDAG.wakeWordStream`, the consumer side). **The producer side `start(ring:)` is never invoked.**

### 1.4 `AudioGraph` / `AVAudioEngine` is never constructed in production

- `grep -rn "AudioGraph(\|AudioGraphOwner(\|LiveGraphBuilder()\|AVAudioEngine()" --include='*.swift'`: zero hits in `App/` or production source. All hits are in `packages/Voice/Tests/**` and `packages/Harness/Sources/Harness/Runners/AudioGraphRebuildRunner.swift:123`.
- `installVoice()` (`AppDelegate.swift:643-764`) constructs `OpenWakeWordSession`, `SileroVAD`, `WakeWordDAG`, `VoiceController`, `PushToTalk`, `MuteWakeWord`, then calls `vc.start()`. **It never instantiates `AudioGraph` or `AudioGraphOwner`.** No mic input ever opens.
- `VoiceController.start()` at `packages/Voice/Sources/Voice/VoiceController.swift:97-102` only spawns `wakeWordTask` and `orchestratorTask` consumers of pre-existing streams. It has no `AVAudioEngine` reference.

### 1.5 Demonstrable detection: NO

There is no test in the suite where a real `hey_jarvis` utterance (or any audio recording) is fed into a real `OpenWakeWordSession` backed by real ORT and asserts `.fired`. Even `WakeWordHysteresisTests` at `packages/Voice/Tests/VoiceTests/WakeWordHysteresisTests.swift:115,149,197,251` uses the test-only `init(scriptedClassifier:)` — it bypasses ORT entirely. The only test that touches real ORT is `WakeWordHysteresisTests.swift:99` which asserts that loading `OpenWakeWordSession` with an empty tmp dir **throws** — i.e. it only verifies the failure path.

---

## 2. VAD (Silero) — no ONNX file on disk at all

### 2.1 Models: ABSENT

- `Resources/models/silero/` contains only `MANIFEST.json` (803 bytes, with `sha256: "PLACEHOLDER_run_scripts_fetch-silero-models.sh_to_populate"` — line 7 of the file) and a `.gitkeep`. **No `.onnx` file has ever been downloaded.**
- `scripts/fetch-silero-models.sh:30,34-35` exists to fetch them but has not been run (the SHA placeholder confirms this).

### 2.2 Even if downloaded, never bundled and never reached

Same problem as openWakeWord: `project.yml` does not list `Resources/models/silero` in any resource phase, so the file would be unreachable from `Bundle.main` at runtime even if fetched.

### 2.3 `SileroVAD` source: real

`packages/Voice/Sources/Voice/VAD/SileroVAD.swift:54-` defines `ORTVADEngine` with real `ORTSession`, real LSTM hidden state plumbing (`h`, `c` of shape `[2,1,64]`), real opset-16-then-15 fallback. It is functional given a real ONNX file.

### 2.4 Tests: 100% mocked

`SileroContractTests.swift` instantiates `MockVADEngine()` for every test (lines 18, 26, 39, 57, 83, 105, 111, 162). The one real-runtime path at line 150 explicitly `throw XCTSkip("Silero ONNX models not present in Resources/models/silero/; run scripts/fetch-silero-models.sh")`. Of 9 tests, **0 use real ORT and 9 use `MockVADEngine`**. There is zero evidence Silero v6.2.1 ever processed a single 512-sample frame on this machine.

---

## 3. STT — primary is a NO-OP STUB; fallback is real but feature-flagged off

### 3.1 SpeechAnalyzer (primary, macOS 26 Tahoe): STUB

- `packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift:148-193` is the production `LiveSpeechAnalyzerBridge`.
  - `start()` (line 169-171): empty body. Comment: `Setup happens on first feed(); placeholder for 06-05 to wire live APIs.`
  - `feed(_ chunk:)` (line 173-177): body is `_ = chunk`. Comment: `Wired fully in Plan 06-05. Placeholder here.`
  - `finish()` (line 179-181): only finishes the partials continuation. Never calls a real `SpeechAnalyzer`.
  - `partialResults()` returns an empty stream that yields nothing.
  - `finalText()` returns the empty string `collectedText` (never written to).
- The class file imports `Foundation` and uses no `Speech` framework symbol. The "06-05 wiring" was never landed despite the plan claim.
- **Result:** every voice turn in production hits `SpeechAnalyzerSTT`, which silently consumes audio chunks and returns the empty string. No transcription. Ever.

### 3.2 WhisperKit fallback: real, but unreachable

- `packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift:54-56,140-152` does call `WhisperKit(model: "large-v3-v20240930_626MB")` and a real `k.transcribe(audioArray:)`. This is genuine.
- `AppDelegate.swift:737` hard-codes `STTBackendSelector.make(backend: "speech_analyzer")`. There is no production code path that selects `whisper_kit`. The feature flag exists in `STTBackendSelector` (verified via `STTBackendSwitchTests.swift:163,171,180,191`) but the flag is never set anywhere in production.

### 3.3 Tests

- `STTBackendSwitchTests.swift`: 8 tests, **all mocked** via `MockSpeechAnalyzerBridge` (line 205) and `MockWhisperKitBridge` (line 239). None hit the real `LiveSpeechAnalyzerBridge` (which is a stub anyway) or real `WhisperKit`.
- No test has ever transcribed real audio in this codebase. There is no `XCTSkipUnless(JARVIS_REAL_MODELS)` path that does so for STT.

### 3.4 Single proof of any STT working: NONE

---

## 4. TTS — engine `nil` everywhere in production

### 4.1 Confirmed `nil`

- `App/AppDelegate.swift:715` — `let ttsAdapter = VoiceTTSAdapter(engine: nil)`. Comment: `TTSEngineActor construction is deferred (no production engine wiring yet); pass nil so VoiceTTSAdapter no-ops gracefully.`
- `App/Voice/VoiceTTSAdapter.swift:44-46` — `func synthesize(_ text: String) async { guard let engine else { return }  // dormant`
- `grep -rn "TTSEngineActor(" --include='*.swift'` returns hits ONLY in test files (`OrpheusSerializationTests.swift:126`, `TTSInterruptTests.swift:24,32,78`). **Zero production constructors.**

### 4.2 Source code: real, untested in production

- `OrpheusTTS.swift:51-58` — production init really does `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")`. Genuine. Never called.
- `AVSpeechSynth.swift:22+` — wraps `AVSpeechSynthesizer` with stored synthesizer + delegate per Pitfall §5. Genuine. Never called from production.
- `TTSEngineActor.swift:24-65` — orchestrates both tiers behind a serial executor. Genuine. Never called from production.

### 4.3 Tests

- `AVSpeechSmokeTests.swift`: 4 tests, **REAL** — instantiates `AVSpeechSynth()` and calls `speak(...)` against the actual macOS speech synthesizer (verified by no Mock in file). This is the *only* corner of the voice subsystem where a real production component runs against real OS APIs in the test suite.
- `OrpheusSerializationTests.swift`: 3 tests, **MOCKED** via `ScriptedSpeechModel` (line 23, 64, 93, 110) — emits scripted `.token` events to bypass MLX/Metal entirely. Zero real Orpheus inference.
- `OrpheusTTFATests.swift`: 2 tests, **gated behind `JARVIS_REAL_MODELS=1`** env var (lines 26, 77) which is not set in CI/normal runs. Effectively skipped.
- `TTSInterruptTests.swift`: 5 tests, all use `ScriptedSpeechModel` / `NullSpeechModel`. **MOCKED.**

### 4.4 End-to-end TTS audio out: NEVER

In production: zero engine. In tests: only `AVSpeechSmokeTests` exercises a real speech path, and even that only verifies `speak()` returns within 2 s — it doesn't assert audible output. Orpheus has never run on this machine in any committed test path that anyone executes.

---

## 5. Audio Pipeline — never opens

- The mic input requires `AVAudioEngine.start()` which requires a constructed `AudioGraph` or `AudioGraphOwner`. As established in §1.4, neither is constructed in production.
- `AudioGraph.swift:132-135` shows the production constructor. It is reachable from the `LiveGraphBuilder` test seam. But `installVoice()` never calls `AudioGraph(...)` or `AudioGraphOwner(...)`.
- `VoiceController` has no audio-engine ownership. It only consumes `wakeWordStream: AsyncStream<WakeWordEvent>` (line 34). The producer is `WakeWordDAG.start(ring:)` which is never called.
- **No PCM samples ever flow through the wake-word, VAD, or STT pipeline at runtime.** The mic light never even turns on (would require Microphone TCC prompt followed by `AVAudioEngine.start()` — neither happens).

`AECFallbackTests` and `TeardownTests` and `VpioOrderingTests` do construct `AudioGraphOwner` and `AudioGraph` in tests via `RecordingGraphBuilder` stubs, so the wiring code is exercised in isolation — but with stub builders that never touch real CoreAudio.

---

## 6. Test Classification

| Test file | Tests | REAL | MOCK | DEAD/SKIPPED | Notes |
|---|---:|---:|---:|---:|---|
| `WakeWordHysteresisTests.swift` | 9 | 0 | 8 | 1 | All `init(scriptedClassifier:)`; test 9 just asserts ORT init throws on empty dir |
| `ModelManifestTests.swift` | 4 | 0 | 0 | 4 | Pure manifest parsing — DEAD relative to runtime detection |
| `SileroContractTests.swift` | 9 | 0 | 8 | 1 | All `MockVADEngine`; line 150 XCTSkips real-ORT path |
| `STTBackendSwitchTests.swift` | 8 | 0 | 8 | 0 | All mocked bridges |
| `AVSpeechSmokeTests.swift` | 4 | 4 | 0 | 0 | The only honest tests in the subsystem |
| `OrpheusSerializationTests.swift` | 3 | 0 | 3 | 0 | `ScriptedSpeechModel` |
| `OrpheusTTFATests.swift` | 2 | 0 | 0 | 2 | Both `XCTSkipUnless(JARVIS_REAL_MODELS=1)` |
| `TTSInterruptTests.swift` | 5 | 0 | 5 | 0 | `ScriptedSpeechModel` / `NullSpeechModel` |
| `BargeInTests.swift` | 4 | 0 | 4 | 0 | Mock TTS / mock orchestrator |
| `MuteWakeWordTests.swift` | 3 | 0 | 3 | 0 | Mock controller |
| `PTTTests.swift` | 6 | 0 | 6 | 0 | Mock controller |
| `VoiceControllerTests.swift` | 4 | 0 | 4 | 0 | `MockSTTForController`, `MockBannerForController`, `MockVADEngine` |
| `AECFallbackTests.swift` | ~8 | 0 | ~8 | 0 | `RecordingGraphBuilder` stub |
| `AECFallbackBannerTests.swift` | 3 | 0 | 3 | 0 | Mock banner |
| `TeardownTests.swift` | ~5 | 0 | ~5 | 0 | Stub graph builders |
| `RingBufferTests.swift` | ~8 | 8 | 0 | 0 | Pure data-structure tests (legitimately REAL) |
| `VpioOrderingTests.swift` | ~3 | 0 | 3 | 0 | `RecordingGraphBuilder` |
| `InputFormatProbeTests.swift` | ~3 | 0–3 | 0 | 0 | Touches `AVAudioEngine().inputNode` (line 59) — partially real format probe |

**Aggregate (excluding pure data-structure RingBuffer & InputFormatProbe):**
- ≈ 83 voice tests
- **REAL against production audio/STT/TTS/wake-word runtime:** 4 (the `AVSpeechSmokeTests`)
- **MOCK / scripted seam:** ≈ 75
- **DEAD / SKIPPED:** ≈ 4 (ModelManifest parsing + Orpheus TTFA gated)
- **Real-runtime ratio: ≈ 5%** — and 100% of those 5% live in `AVSpeechSmokeTests`, which only proves `AVSpeechSynthesizer` returns within 2 s.

This validates the user's gut: the test suite was built for unit-level correctness of well-isolated seams, not for "does the voice loop work on this machine."

---

## 7. End-to-End: can the user say "hey Jarvis, what time is it"?

**No.** Every layer is broken. Required wires to land before "hey Jarvis" → spoken response works, in dependency order:

1. **Add a resource build phase to `project.yml`** that copies `Resources/models/openwakeword/**` and `Resources/models/silero/**` into `Contents/Resources/Models/` of the built `.app`. (Or rename the on-disk dir to match the capital-M `Models` path the AppDelegate reads.)
2. **Run `scripts/fetch-silero-models.sh`** to populate `silero_vad.onnx` + opset-15 fallback, and update the placeholder SHA in `Resources/models/silero/MANIFEST.json` so `ModelManifest.verify` doesn't fail closed.
3. **Construct `AudioGraph` / `AudioGraphOwner` in `installVoice()`** with a `LiveGraphBuilder()`. Currently absent. Without this, mic never opens.
4. **Wire `wakeWordDAG.start(ring: <ring from AudioGraphOwner>)`** so PCM frames actually flow into the mel→embedding→classifier pipeline. Currently the DAG is constructed but never started.
5. **Confirm Microphone TCC entitlement is requested.** `Info.plist` `NSMicrophoneUsageDescription` should be present and the wizard should walk the user through approval. (Not audited here; follow-up.)
6. **Confirm `com.apple.developer.speech-recognition-assets` entitlement + `NSSpeechRecognitionAssetsUsageDescription`** per CLAUDE.md macOS 26 Tahoe rule. Missing either silently fails on Release.
7. **Replace `LiveSpeechAnalyzerBridge` stub with the real `SpeechAnalyzer` + `SpeechTranscriber` wiring.** Currently `start()`/`feed()`/`finish()` are empty placeholders — the API surface needs to actually be called. This is the single biggest implementation gap in the subsystem.
8. **Construct a real `TTSEngineActor`** with at minimum an `AVSpeechSynth()` tier-1 (Orpheus tier-2 can be deferred). Pass it to `VoiceTTSAdapter(engine: realActor)` instead of `nil`.
9. **Fix BLOCKER-INT-1 / INT-2** from `v0.12.0-MILESTONE-AUDIT.md` — voice STT result needs to reach the orchestrator AND the orchestrator's tokens need to flow back into the bus broadcaster's `.bus` subscriber. Even if voice-in worked, the agent loop wouldn't return spoken output without both wires.

Until #1–#8 land, voice is a lavishly-tested skeleton with no organs. The ~50 hours did produce real, well-factored unit code — `OpenWakeWordSession`, `SileroVAD`, `OrpheusTTS`, `TTSEngineActor`, `AVSpeechSynth`, `WakeWordDAG`, `AudioGraph` — but none of it is plugged into the app.

## 8. Honest assessment

The user's "nothing works end-to-end" claim is correct and understated. Voice-in is broken at four independent layers (no models bundled, no Silero file at all, no audio graph constructed, no DAG started). Voice-out is broken at one but total layer (engine `nil`). STT primary is a literal `_ = chunk` stub. The test suite has hidden all of this because every meaningful boundary was replaced with a mock or scripted seam, and the only test that XCTSkips on missing real models (`SileroContractTests` line 150) emits a helpful message that nobody has acted on.

This is the integration-test-gap pathology that the milestone audit flagged. The voice subsystem is an even more severe instance of the same failure mode than HUD/bus/orchestrator: more code, more sophistication, more elaborate test ceremony — and a less working artifact at runtime than would have been produced by one afternoon of actually starting `AVAudioEngine` and printing `print("got audio: \(buffer.frameLength)")` on the tap.

The code is salvageable. The wiring is not deep work — it's roughly a day of plumbing. But the claim "voice phase passed" in `06-VERIFICATION.md` and the audit's "VOICE-11 human_needed" framing materially misrepresent the state.
