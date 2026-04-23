---
phase: 6
name: Voice
researched: 2026-04-22
domain: On-device voice pipeline (wake-word, VAD, STT, TTS, AVAudioEngine graph)
confidence: HIGH
authoritative_sources:
  - /Users/james.maes/Git.Local/Kof22/Jarvis/CLAUDE.md (voice stack section)
  - /Users/james.maes/Git.Local/Kof22/Jarvis/.planning/research/RESEARCH-DELTAS.md (Silero v6.2.1, Orpheus streaming, WhisperKit argmax-oss-swift)
  - /Users/james.maes/Git.Local/Kof22/Jarvis/.planning/ROADMAP.md lines 132–149 (Phase 6 success criteria)
  - /Users/james.maes/Git.Local/Kof22/Jarvis/App/Jarvis.entitlements (confirmed mic + speech-recognition-assets)
  - /Users/james.maes/Git.Local/Kof22/Jarvis/App/Info.plist (confirmed NSMicrophoneUsageDescription + NSSpeechRecognitionAssetsUsageDescription)
---

# Phase 6: Voice — Research

## Executive Summary

Phase 6 lands the full on-device voice loop: `openWakeWord (hey_jarvis)` → `Silero VAD v6.2.1` → `SpeechAnalyzer` (Tahoe) or `WhisperKit` (fallback) → agent turn → `AVSpeechSynthesizer` (tier 1) or `Orpheus` via `mlx-audio-swift` (tier 2). The pipeline runs entirely inside the Jarvis.app process on Apple Silicon with no cloud endpoints and no Python sidecar. Every stage is already fact-locked in `CLAUDE.md` and `RESEARCH-DELTAS.md`, so this research layer is mostly a **codification exercise**: translate the settled facts into a package-level design, code sketches, and pitfall/verification tests the planner can turn into plan files.

The single largest implementation risk is not algorithmic — it is **audio-graph lifecycle correctness**. `AVAudioEngine.isVoiceProcessingEnabled` must be flipped before any `connect` or `installTap` call, AEC-off must be treated as a distinct graph variant (not a runtime toggle), and the six-step canonical teardown sequence must apply uniformly across all four rebuild triggers (device change, AEC fallback, mic re-grant, sustained ring overflow). The secondary risk is Metal command-buffer serialization deadlock inside Orpheus when TTS requests overlap — `TTSEngineActor` with a serial executor is the enforced contract. A third, narrower risk is a format-drift footgun: Tahoe's post-AEC input format is 24 kHz, Sonoma's is 16 kHz; format must be probed (`inputNode.outputFormat(forBus: 0)`) and any rate conversion must happen **after** channel-coerce, not before (R4-D4).

**Primary recommendation:** Ship voice as a top-level `packages/Voice/` Swift package with five subsystems (`WakeWord/`, `VAD/`, `STT/`, `TTS/`, `AudioGraph/`) plus a `VoiceController` actor that owns the state machine (`.idle → .listening → .thinking → .speaking`). The bus (Phase 2) and orchestrator (Phase 4) already define `cancelAndSubmit` as a single atomic entry — do not add a second. Ring-buffer-based DAGs are the pattern for both wake-word (mel → embedding → classifier) and TTS stream decode; bounded `AsyncChannel` is the pattern for cross-actor events.

## User Constraints (from CLAUDE.md)

### Locked Decisions
- Wake word: **openWakeWord `hey_jarvis`** via **ONNX Runtime Swift 1.24.2+** (no sidecar).
- VAD: **Silero v6.2.1**, 512-sample / 32 ms / 16 kHz chunk contract, opset-16 `silero_vad.onnx` preferred, `silero_vad_16k_op15.onnx` fallback.
- STT primary: **Apple `SpeechAnalyzer` / `SpeechTranscriber`** on macOS 26 Tahoe.
- STT fallback: **WhisperKit via `argmaxinc/argmax-oss-swift v0.18.0`**, model `large-v3-v20240930_626MB`, behind feature flag.
- TTS tier 1: **`AVSpeechSynthesizer`** (instant, short confirmations + think-aloud).
- TTS tier 2: **Orpheus via `blaizzy/mlx-audio-swift v0.1.2`**, `LlamaTTSModel.fromPretrained("mlx-community/orpheus-3b-0.1-ft-bf16")`, `generateStream`. TTFA target **150–250 ms**. **`TTSEngineActor` with serial executor** prevents Metal deadlock.
- TTS tier 2 fallback: `TTSKit` from `argmax-oss-swift` with `play(strategy: .auto)`.
- AEC-off is a **distinct graph variant** (not a runtime toggle). HUD banner: `"AEC unavailable; degraded-mode active"`.
- TTS interrupt sequence is **atomic**: cancel producer → 10 ms cosine fade → `stop()` → completion ≤ 20 ms → emit `.ttsStopped`. Ducking releases **only on `.ttsStopped`**.
- Barge-in during `.speaking` enters the orchestrator through **one `cancelAndSubmit` hop**, not two.
- Local-only. No cloud TTS/STT. Local streaming of audio chunks is allowed and preferred.

### Claude's Discretion
- Internal package/folder structure inside `packages/Voice/`.
- Ring-buffer capacities (with logged defaults).
- Error surface (`VoiceError` enum shape).
- Fine-grain state machine names.
- Test fixture WAV sources.

### Deferred Ideas (OUT OF SCOPE)
- Personal fine-tuned wake-word model (VOICE-V2-01) — stock `hey_jarvis_v0.1` only.
- Long-answer spoken-summarization flow (VOICE-V2-02).
- Kokoro-82M tier-3 TTS — not in v1 unless Orpheus + TTSKit both fail.
- Cloud TTS/STT of any kind.
- Vision-driven voice activity detection (Phase 7).

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| VOICE-01 | openWakeWord `hey_jarvis` continuous listen via ORT Swift 1.24.2+, ≥4-frame hysteresis, SHA-256-vendored weights | §1 Wake-word DAG |
| VOICE-02 | Silero VAD v6.2.1 at 512/32ms/16kHz; opset-16 preferred, opset-15 fallback | §2 VAD + contract-parity probe |
| VOICE-03 | SpeechAnalyzer/SpeechTranscriber primary, entitlement load-bearing | §3 STT primary |
| VOICE-04 | WhisperKit via argmax-oss-swift v0.18.0, `large-v3-v20240930_626MB`, flagged | §4 STT fallback |
| VOICE-05 | AVSpeechSynthesizer tier 1, short confirmations + think-aloud | §5 TTS tier 1 |
| VOICE-06 | Orpheus via mlx-audio-swift, `generateStream`, TTFA 150-250ms, `TTSEngineActor` | §6 TTS tier 2 |
| VOICE-07 | End-to-end "Hey Jarvis, what time is it?" happy path, HUD states idle→listening→thinking→speaking | §11 End-to-end |
| VOICE-08 | `isVoiceProcessingEnabled=true` BEFORE connect/installTap; probe `inputNode.outputFormat(forBus: 0)` | §7 AVAudioEngine pipeline |
| VOICE-09 | AEC-off = distinct graph variant; HUD banner "AEC unavailable; degraded-mode active" | §8 AEC-off |
| VOICE-10 | Canonical 6-step teardown × 4 triggers | §9 Teardown |
| VOICE-11 | Atomic TTS interrupt sequence; duck release on `.ttsStopped` only | §10 TTS interrupt |
| VOICE-12 | Menu-bar mute-wake-word toggle; PTT remains armed | §13 Mute toggle |
| VOICE-13 | Push-to-talk hold-hotkey, bypasses wake word | §12 PTT |
| VOICE-14 | Barge-in: single `cancelAndSubmit`, re-enter `.listening` without losing turn state | §10 TTS interrupt |

## Project Constraints (from CLAUDE.md)

- Swift-idiomatic explanations where non-obvious (user is not a Swift expert).
- Build incrementally — no 2000-line drops.
- Claude Opus 4.7 is the orchestrator model; local routing uses `qwen2.5-coder:32b` (not Qwen3).
- Hardened Runtime + `com.apple.security.cs.allow-jit` required (confirmed in entitlements).
- macOS 26 Tahoe target; scaffold-time Release cold-launch probe required.
- No Python sidecar. In-process only.
- All settled architectural decisions are settled — do not re-litigate.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|--------------|----------------|-----------|
| Continuous mic capture + AEC | Swift host / `AVAudioEngine` | — | Requires TCC-gated hardware and `isVoiceProcessingEnabled`; webview can't reach `AVAudioSession`/VPIO. |
| Wake-word detection | Swift host / ORT | — | Low-latency DSP in-process; ONNX Runtime Swift bindings live in the app. |
| VAD gating | Swift host / ORT | — | Shares ORT session pool with wake-word; must run on the same audio buffers without round-tripping. |
| STT (primary) | Swift host / `SpeechAnalyzer` | — | macOS 26-only framework; native-only API. |
| STT (fallback) | Swift host / WhisperKit (MLX) | — | In-process MLX model; behind feature flag. |
| TTS tier 1 | Swift host / `AVSpeechSynthesizer` | — | OS-provided; zero setup; instant playback. |
| TTS tier 2 | Swift host / Orpheus via `mlx-audio-swift` | `TTSKit` fallback | In-process MLX; serial executor prevents Metal deadlock. |
| HUD state visualization | Frontend / R3F (Phase 3) | — | Consumes `voiceState` from bus — never a source of truth. |
| PTT hotkey | Swift host / `NSEvent` global monitor | — | Same subsystem as Phase 1 hotkey; PTT hold emits `.pttDown`/`.pttUp` into `VoiceController`. |
| Mute-wake-word toggle | Swift host / menu-bar | — | Phase 1 menu bar already exists; adds `MuteWakeWordItem`. |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| macOS 26 Tahoe | SpeechAnalyzer (VOICE-03) | ✓ (user host) | 26.x | WhisperKit (VOICE-04) |
| Apple Silicon | Orpheus via MLX (VOICE-06) | ✓ | M-series | AVSpeechSynthesizer tier 1 only |
| ONNX Runtime Swift | Wake-word + Silero (VOICE-01/02) | pending scaffold | 1.24.2+ | — (blocking) |
| `onnxruntime-swift-package-manager` | SPM dep | will resolve at scaffold | 1.24.2+ | — |
| `blaizzy/mlx-audio-swift` | Orpheus (VOICE-06) | will resolve at scaffold | 0.1.2 | TTSKit from argmax-oss-swift |
| `argmaxinc/argmax-oss-swift` | WhisperKit + TTSKit | will resolve at scaffold | 0.18.0 | — |
| Microphone TCC | All audio (VOICE-01..11) | entitlement present; runtime grant pending | — | HUD banner + re-prompt |
| `speech-recognition-assets` entitlement | SpeechAnalyzer asset download | ✓ in `Jarvis.entitlements` | — | WhisperKit path |
| `NSSpeechRecognitionAssetsUsageDescription` | First-launch asset permission prompt | ✓ in `Info.plist` | — | — |

## Package Layout

```
packages/Voice/
├── Package.swift
├── Sources/
│   └── Voice/
│       ├── VoiceController.swift          // actor, owns state machine
│       ├── VoiceState.swift               // .idle .listening .thinking .speaking + events
│       ├── VoiceError.swift
│       ├── AudioGraph/
│       │   ├── AudioGraph.swift           // AVAudioEngine wrapper
│       │   ├── AudioGraphVariant.swift    // .aecOn(format) / .aecOff(format)
│       │   ├── InputFormatProbe.swift     // outputFormat(forBus: 0) at runtime
│       │   ├── RingBuffer.swift           // lock-free SPSC ring
│       │   ├── RebuildTrigger.swift       // .deviceChange .aecFallback .micRegrant .ringOverflow
│       │   └── Teardown.swift             // canonical 6-step
│       ├── WakeWord/
│       │   ├── WakeWordDAG.swift          // mel ring → embedding ring → classifier
│       │   ├── OpenWakeWordSession.swift  // ORT wrapper, ≥4-frame hysteresis
│       │   └── ModelManifest.swift        // SHA-256-pinned weight paths
│       ├── VAD/
│       │   ├── SileroVAD.swift            // 512-sample/32ms/16kHz session
│       │   └── ContractParityProbe.swift  // scaffold-time v5↔v6 contract verification
│       ├── STT/
│       │   ├── STTProvider.swift          // protocol
│       │   ├── SpeechAnalyzerSTT.swift    // primary (macOS 26)
│       │   └── WhisperKitSTT.swift        // fallback, feature-flagged
│       ├── TTS/
│       │   ├── TTSEngineActor.swift       // serial executor, in-process
│       │   ├── AVSpeechSynth.swift        // tier 1
│       │   ├── OrpheusTTS.swift           // tier 2 (mlx-audio-swift)
│       │   ├── TTSKitFallback.swift       // tier 2 fallback
│       │   └── TTSInterrupt.swift         // atomic 5-step sequence
│       └── Control/
│           ├── PushToTalk.swift           // hotkey hold/release integration
│           └── MuteWakeWord.swift         // menu-bar toggle
└── Tests/
    └── VoiceTests/
        ├── VpioOrderingTests.swift        // unit: tap install on non-VPIO node throws
        ├── TeardownTests.swift            // canonical 6-step × 4 triggers
        ├── SileroContractTests.swift
        ├── OrpheusSerializationTests.swift // rapid-fire synth ordering
        └── BargeInTests.swift             // single cancelAndSubmit entry
```

## 1. Wake-Word DAG (VOICE-01)

**openWakeWord** is a three-stage streaming DAG: **mel spectrogram** → **embedding** → **classifier**. All three stages ship as ONNX models. The bundled `hey_jarvis_v0.1` classifier is ~20k params; the shared mel + embedding are reused across any wake word.

Runs on 16 kHz mono `Float32`. The mel stage emits one frame every 80 ms; the classifier is triggered every 80 ms and its output is a probability in `[0,1]`. The **≥4-consecutive-frame threshold** (per CLAUDE.md) means a positive trigger requires 4 frames above threshold in a row — ~320 ms of hysteresis. This kills singleton spikes from TV/background chatter.

**Vendoring:** download `melspectrogram.onnx`, `embedding_model.onnx`, and `hey_jarvis_v0.1.onnx` at build time; write a `MANIFEST.json` with SHA-256s checked at session open. Weights live in `Resources/`; the session **fails closed** if a checksum mismatches — never auto-redownload.

**Threading:** one background `Task` per DAG, reading from the AudioGraph mic ring; ORT sessions are not thread-safe — one session per stage, owned by the task.

```swift
actor WakeWordDAG {
    private let mel: ORTSession       // mel spectrogram
    private let emb: ORTSession       // embedding
    private let cls: ORTSession       // hey_jarvis classifier
    private var consecutive: Int = 0
    private let threshold: Float = 0.5
    private let framesRequired = 4    // ≥4 consecutive frames ≈ 320 ms

    func feed(_ pcm16k: UnsafeBufferPointer<Float>) async throws -> DetectionDecision {
        let melFrame = try mel.run(pcm16k)
        let embFrame = try emb.run(melFrame)
        let prob     = try cls.run(embFrame)
        if prob >= threshold {
            consecutive += 1
            if consecutive >= framesRequired { consecutive = 0; return .fired }
        } else {
            consecutive = 0
        }
        return .none
    }
}
```

## 2. Silero VAD v6.2.1 (VOICE-02) + Contract-Parity Probe

**Contract (unchanged from v5):** 512 samples / 32 ms / 16 kHz mono `Float32`, stateful LSTM-style model. v6.2.1 preserves the chunk contract (RESEARCH-DELTAS); the scaffold-time probe **must verify empirically** by feeding a known waveform and asserting the same output shape/timing as v5.

**Two model variants, pick at runtime:**
- `silero_vad.onnx` (opset 16) — preferred. Requires ORT ≥ 1.24 built with opset-16 support.
- `silero_vad_16k_op15.onnx` (opset 15) — fallback for ORT builds without opset-16.

Probe at session open:
```swift
func loadSileroSession() throws -> ORTSession {
    do { return try ORTSession(opset16URL) }
    catch ORTError.opsetUnsupported { return try ORTSession(opset15URL) }
}
```

**Placement:** VAD sits **in parallel** with wake-word on the same 16 kHz ring — both consume, neither mutates. Post-wake, VAD's `speechStart → speechEnd` events define the STT utterance window.

**Contract-parity probe (scaffold-time only, `#if DEBUG`):** load a 5 s fixture WAV, feed both v6.2.1 and any v5 reference (or a recorded v5 baseline output), assert speech/non-speech boundaries agree within ± 32 ms. If they diverge, fail the scaffold test with a clear error.

## 3. SpeechAnalyzer Primary STT (VOICE-03)

`SpeechAnalyzer` / `SpeechTranscriber` ship in macOS 26 Tahoe and are **~55% faster than Whisper** on the same hardware (per Apple WWDC25, MacRumors 2025-06-18). On-device, free, supports streaming partial results.

**Entitlement pair (load-bearing per AUDIT-R2-S5):**
- `com.apple.developer.speech-recognition-assets` (entitlement) ✓ already in `Jarvis.entitlements`.
- `NSSpeechRecognitionAssetsUsageDescription` (Info.plist) ✓ already present.

**Scaffold-time probe (VOICE-03):** cold-launch a Release archive **with the entitlement stripped**; confirm `SFSpeechErrorCode.assetUnavailable` fires → proves the entitlement is load-bearing. If STT works without it, the claim is speculative and AUDIT-R2-S5 is refuted — log the result either way. (RESEARCH-DELTAS "KEEP AT SCAFFOLD" clause.)

```swift
final class SpeechAnalyzerSTT: STTProvider {
    func transcribe(_ stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        AsyncStream { continuation in
            let analyzer = SpeechAnalyzer(...)
            let transcriber = SpeechTranscriber(locale: .current, options: .partialResults)
            Task {
                for await chunk in stream { try? analyzer.feed(chunk.pcm) }
                try? await analyzer.finish()
            }
            Task { for await result in transcriber.results { continuation.yield(.init(result)) } }
        }
    }
}
```

## 4. WhisperKit Fallback via argmax-oss-swift (VOICE-04)

**The consolidation (RESEARCH-DELTAS):** the standalone `argmaxinc/WhisperKit` repo was folded into `argmaxinc/argmax-oss-swift v0.18.0` (monorepo with WhisperKit + TTSKit + SpeakerKit). Package import is:

```swift
.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0")
```

Target product: `WhisperKit`. Model string: `large-v3-v20240930_626MB` (Argmax-versioned MLX variant — **not** `large-v3-turbo`, which is the HF Whisper name and is not the right download path). The 626 MB weight downloads on first run into `~/Library/Application Support/Jarvis/models/whisperkit/`.

**Feature flag:** `features.stt.backend = "speech_analyzer" | "whisperkit"` in config.json (Phase 1). Toggle without rebuild; no mid-session swap.

```swift
final class WhisperKitSTT: STTProvider {
    private let kit: WhisperKit
    init() async throws {
        self.kit = try await WhisperKit(model: "large-v3-v20240930_626MB")
    }
    func transcribe(_ stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript> {
        // chunked streaming inference; emit partial every ~500 ms
    }
}
```

## 5. AVSpeechSynthesizer Tier 1 (VOICE-05)

OS-provided TTS. Zero setup, near-zero latency, quality mediocre. Use for:
- **Think-aloud** while tier 2 warms or while the agent is producing tokens.
- **Sub-1-sentence confirmations** ("OK", "Done", "One moment").

**Gotcha:** `AVSpeechSynthesizer` holds strong references and leaks if the delegate is deallocated mid-utterance; keep the synthesizer a property, not a local. It also blocks its own utterance queue — for overlap we must `stopSpeaking(at: .immediate)` before a new utterance.

```swift
final class AVSpeechSynth {
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String, voice: AVSpeechSynthesisVoice = .init(language: "en-US")!) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text); u.voice = voice
        synth.speak(u)
    }
}
```

## 6. Orpheus Tier 2 via mlx-audio-swift (VOICE-06)

Orpheus is a 3 B LLaMA-based TTS that emits Snac codec tokens, decoded to PCM. `blaizzy/mlx-audio-swift v0.1.2` runs it in-process on Apple Silicon via MLX — **no Python sidecar** (the legacy `mlx-audio` Python package needed `pip`).

**Streaming confirmed (RESEARCH-DELTAS D7):** `generateStream` yields events including `.token`, `.audio(Chunk)`, `.info`. Target empirical TTFA **150–250 ms**, verified at scaffold.

**Metal-buffer serialization deadlock:** rapid-fire calls to `generate`/`generateStream` on Orpheus race the Metal command buffer and can deadlock inside MLX kernel dispatch. **`TTSEngineActor` with a serial executor** is the enforced mitigation — synthesis is FIFO-serialized; concurrent calls queue.

```swift
actor TTSEngineActor {
    static let shared = TTSEngineActor()
    private let model: LlamaTTSModel
    private var currentTask: Task<Void, Error>?

    init() {
        self.model = try! LlamaTTSModel.fromPretrained(
            "mlx-community/orpheus-3b-0.1-ft-bf16")
    }

    func synthesize(_ text: String,
                    voice: String = "tara",
                    into sink: AudioSink) async throws {
        currentTask?.cancel()                    // serialize: only one live synth
        let task = Task {
            for try await evt in model.generateStream(text, voice: voice) {
                try Task.checkCancellation()
                switch evt {
                case .audio(let chunk): await sink.enqueue(chunk)
                case .info, .token: break
                }
            }
        }
        currentTask = task
        try await task.value
    }

    func cancel() async {
        currentTask?.cancel(); currentTask = nil
    }
}
```

**Voice selection:** Orpheus supports `tara`, `leah`, `jess`, `leo`, `dan`, `mia`, `zac`, `zoe`. Ship `tara` as default, config-override per Phase 1.

**Fallback:** if scaffold TTFA > 250 ms or streaming misbehaves, `TTSKit` from `argmax-oss-swift` supports `play(strategy: .auto)` and is more mature but different voice character. Feature flag: `features.tts.tier2 = "orpheus" | "ttskit"`.

## 7. AVAudioEngine Pipeline + `isVoiceProcessingEnabled` Ordering (VOICE-08)

**The rule:** `AVAudioEngine.isVoiceProcessingEnabled = true` **must be set before any `connect` or `installTap`** on the input node. Flipping it afterward either silently no-ops (Tahoe) or crashes (Sonoma). A unit test enforces this.

**Post-AEC format probe (R4-D4):** the input format returned by VPIO is **not** the hardware format — it's the post-processed format. On **Tahoe it is 24 kHz Float32 mono**; on **Sonoma it was 16 kHz**. **Probe via `inputNode.outputFormat(forBus: 0)` at graph-open time — never assume.** If the format is 24 kHz, rate-convert to 16 kHz (via `AVAudioConverter`) for Silero/openWakeWord consumption. **Coerce channels before rate convert** (R4-D4) — rate-converting a 2-ch buffer into a 1-ch target produces interleaved/garbage samples in `AVAudioConverter` on Tahoe.

```swift
func buildGraph(aec: Bool) throws -> AudioGraph {
    let engine = AVAudioEngine()
    // (1) FLIP VPIO FIRST — BEFORE any connect/installTap
    if aec { try engine.inputNode.setVoiceProcessingEnabled(true) }
    // (2) PROBE format after VPIO flip — never before, never assume
    let inFmt = engine.inputNode.outputFormat(forBus: 0)
    assert(inFmt.channelCount >= 1)
    // (3) Channel-coerce then rate-convert to 16 kHz Float32 mono for consumers
    let targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 16_000, channels: 1, interleaved: false)!
    let mixer = AVAudioMixerNode()
    engine.attach(mixer)
    engine.connect(engine.inputNode, to: mixer, format: inFmt)
    // (4) Install tap LAST
    mixer.installTap(onBus: 0, bufferSize: 1024, format: targetFmt) { buffer, _ in
        ringBuffer.write(buffer)
    }
    try engine.start()
    return AudioGraph(engine: engine, format: targetFmt, variant: aec ? .aecOn : .aecOff)
}
```

**Unit test (enforces ordering):**
```swift
func testTapOnNonVpioNodeThrows() {
    let engine = AVAudioEngine()
    // VPIO NOT enabled — should throw
    XCTAssertThrowsError(
        try AudioGraphGuard.installTap(on: engine.inputNode, engine: engine)
    ) { XCTAssertEqual($0 as? AudioGraphError, .vpioNotEnabled) }
}
```

## 8. AEC-Off as Distinct Graph Variant (VOICE-09)

**AEC-off is not a runtime toggle — it is a separate graph build.** Trying to flip `isVoiceProcessingEnabled` at runtime on a running engine is unreliable (crashes on some builds, silent failure on others). The correct path: on AEC-on-failure (hardware or OS refuses VPIO), **tear down the full graph and rebuild with `aec: false`**.

Observable failure modes that trigger AEC-off:
- `setVoiceProcessingEnabled(true)` throws.
- First ~2 s of post-VPIO capture are silent or NaN (AEC warmup failure).
- External USB audio interface not playing well with VPIO.

**HUD banner (VOICE-09):** on transition to AEC-off variant, the `VoiceController` emits a `voiceDegradedMode` event; Phase 3 HUD renders the banner **"AEC unavailable; degraded-mode active"**. Banner persists until graph is rebuilt with AEC-on (e.g., next device change to a VPIO-friendly device).

```swift
enum AudioGraphVariant { case aecOn(AVAudioFormat), aecOff(AVAudioFormat) }

func openGraph() async -> AudioGraph {
    do { return try buildGraph(aec: true) }
    catch {
        logger.warning("AEC unavailable: \(error); rebuilding without VPIO")
        await voiceController.emit(.degradedMode(reason: .aecUnavailable))
        return try! buildGraph(aec: false)   // MUST succeed; panic if not
    }
}
```

## 9. Canonical Six-Step Teardown × Four Triggers (VOICE-10)

One teardown sequence, four triggers. The sequence:

1. **Cancel in-flight** — wake-word DAG, VAD session, STT session, TTS producer (via `TTSEngineActor.cancel()`). Await each cancel with a 50 ms timeout.
2. **Stop engine** — `engine.stop()`. If stop blocks > 200 ms, force-deinit the engine.
3. **Remove taps** — `mixer.removeTap(onBus: 0)`; detach all attached nodes.
4. **Release ring buffers** — clear producer/consumer cursors; zero the backing storage (debug builds also poison with `NaN` to catch use-after-free).
5. **Release ORT sessions** — `nil` out wake-word + Silero sessions; ORT holds Metal/CPU arenas that must be freed before rebuild.
6. **Emit `.reconfiguring`** — the HUD transitions to the reconfiguring state (Phase 3 HUD already supports this precedence); the voice controller blocks new submissions until rebuild completes.

Then rebuild with the new variant/format and emit `.idle`.

**Four triggers — all funnel through the same teardown:**

| Trigger | Detector | Typical latency |
|---------|----------|------------------|
| **Device change** | `AVAudioEngine` configuration-change notification (`AVAudioEngine.configurationChangeNotification`) | < 100 ms after user action |
| **AEC fallback** | VPIO init failure OR 2 s of NaN post-VPIO warmup | ~2 s from graph open |
| **Mic re-grant** | TCC state transition from denied → authorized (observe via `AVCaptureDevice.authorizationStatus` polling or `AVAuthorizationStatus` KVO) | Whenever user flips it |
| **Sustained ring overflow** | > 500 ms of consumer lag on mic ring; backpressure metric | Continuous monitoring |

```swift
actor AudioGraphOwner {
    private var graph: AudioGraph?

    func rebuild(trigger: RebuildTrigger) async {
        await voiceController.emit(.reconfiguring(reason: trigger))
        if let g = graph {
            await cancelInFlight()                 // (1)
            g.engine.stop()                        // (2)
            g.removeAllTaps()                      // (3)
            g.releaseRings()                       // (4)
            g.releaseORTSessions()                 // (5)
        }
        graph = await openGraph()                  // rebuild
        await voiceController.emit(.idle)          // exits reconfiguring
    }
}
```

## 10. TTS Interrupt + Barge-In (VOICE-11, VOICE-14)

**TTS interrupt sequence (atomic, 5 steps):**
1. Cancel Orpheus producer: `TTSEngineActor.shared.cancel()`.
2. **10 ms cosine fade-out** on the audio sink (prevents click/pop — absolutely required for UX).
3. `AVAudioPlayerNode.stop()` on the playback node.
4. Await completion handler with **≤ 20 ms** timeout.
5. Emit `.ttsStopped` on the voice event bus.

**Ducking release rule:** ducking is lowered **only on `.ttsStopped`** — never on `TTSEvent.finished` alone. Why: `finished` fires when the synth producer is done, but audio may still be draining the sink buffer for 100–200 ms. Releasing duck on `finished` clips the tail.

```swift
func interruptTTS() async {
    await TTSEngineActor.shared.cancel()            // (1)
    await audioSink.cosineFadeOut(duration: .milliseconds(10))  // (2)
    playerNode.stop()                               // (3)
    await waitForCompletion(timeout: .milliseconds(20))         // (4)
    await eventBus.emit(.ttsStopped)                // (5) → ducking releases here
}
```

**Barge-in during `.speaking` (VOICE-14):** when the wake-word DAG fires while the voice state is `.speaking`:

```swift
func onWakeWordFired() async {
    switch state {
    case .speaking:
        // SINGLE cancelAndSubmit — not two actor hops
        await orchestrator.cancelAndSubmit(source: .voice, trigger: .bargeIn)
    case .idle, .listening:
        await transition(to: .listening)
    case .thinking:
        // dedupe — already in a turn
        break
    }
}
```

`cancelAndSubmit` (Phase 4 primitive) internally runs the TTS interrupt sequence, cancels the current turn's streaming, and submits the new voice turn — all in one hop. A unit test asserts exactly one `cancelAndSubmit` call per barge-in event. Two hops (say, `stopTTS()` then later `startListening()`) would race against a tail token from the cancelled turn.

## 11. End-to-End "What Time Is It?" Happy Path (VOICE-07)

Full sequence (observable without DevOverlay):

| Step | Component | HUD state |
|------|-----------|-----------|
| User says "Hey Jarvis" | WakeWordDAG fires after ≥4 frames (~320 ms hysteresis) | `.idle → .listening` |
| Silero VAD detects speech start | VAD emits `.speechStart` | `.listening` (ring pulses) |
| User says "what time is it" | SpeechAnalyzer streams partial transcripts | `.listening` (ring rotates) |
| Silero VAD detects `.speechEnd` | STT finalizes transcript | `.listening → .thinking` |
| Orchestrator invokes agent turn | AnthropicProvider streams | `.thinking` |
| Model tool-calls `get_time` | MCP client invokes `mcp-time` | `.thinking` |
| Model produces final text ("It's 2:47 PM") | Token stream arrives | `.thinking → .speaking` |
| `TTSEngineActor` streams Orpheus audio | Player node drains chunks | `.speaking` (ring glows) |
| Playback completes, sink drains, `.ttsStopped` | Ducking releases | `.speaking → .idle` |

**Scaffold acceptance test:** record the phrase, play into the system via a loopback device, assert a natural-sounding spoken answer plays within a time budget (TBD; soft < 3 s end-to-end wall clock).

## 12. Push-to-Talk Hold-Hotkey (VOICE-13)

PTT bypasses wake-word detection entirely. While a dedicated PTT hotkey is held:
- Wake-word DAG is **paused** (save cycles).
- VAD + STT session is **started immediately** on key-down.
- On key-up, STT is finalized (not on VAD `.speechEnd`).
- `.ttsStopped` still runs if a prior TTS was active (barge-in behavior).

Hotkey infra reuses Phase 1 `NSEvent.addGlobalMonitorForEvents` (not Carbon, not `HotKey` SPM — per CLAUDE.md). Default binding: unset, user-bound in Phase 1 shortcut recorder.

```swift
func onPTTDown() async {
    await wakeWord.pause()
    await voiceController.transition(to: .listening(source: .ptt))
}
func onPTTUp() async {
    await stt.finalize()
    await wakeWord.resume()
}
```

**Interaction with mute-wake-word:** PTT works regardless of mute state (VOICE-12) — muting wake word must not disable PTT.

## 13. Menu-Bar Mute-Wake-Word Toggle (VOICE-12)

Reuses Phase 1 menu-bar infra. Adds a toggleable `"Mute wake word"` item. State persisted in `UserDefaults` (`features.voice.wakeWordMuted = true|false`).

**Semantics:**
- Mute: `WakeWordDAG.pause()` — DAG stops consuming the ring (ring continues running for VAD/STT; audio pipeline untouched).
- PTT hotkey **remains fully armed** (VOICE-12 explicit contract).
- HUD reflects mute state via a subtle icon change in the menu-bar item — not a full HUD mode.

```swift
@MainActor final class MuteWakeWordMenuItem {
    func toggle() async {
        let now = !defaults.bool(forKey: "features.voice.wakeWordMuted")
        defaults.set(now, forKey: "features.voice.wakeWordMuted")
        if now { await voiceController.muteWakeWord() }
        else   { await voiceController.unmuteWakeWord() }
    }
}
```

## Common Pitfalls

### Pitfall 1: Metal Command-Buffer Serialization Deadlock in Orpheus
**What goes wrong:** Two overlapping `generateStream` calls inside the same MLX model instance produce a Metal command-buffer cycle; everything deadlocks until process kill.
**Why it happens:** `mlx-audio-swift` does not itself serialize access to the underlying `LlamaTTSModel`; MLX kernel submissions from two threads race on the shared Metal queue.
**How to avoid:** `TTSEngineActor` with Swift's serial executor (default for actors). One synthesis in flight at a time; concurrent callers queue.
**Warning signs:** profiler shows Metal kernel stuck; `generateStream` never yields `.audio(...)` on the second call.

### Pitfall 2: Tahoe 24 kHz vs Sonoma 16 kHz Post-AEC Format
**What goes wrong:** Code written against Sonoma hardcodes 16 kHz input, feeds Tahoe's 24 kHz buffers into Silero, gets garbage.
**Why it happens:** Tahoe's VPIO upgraded to 24 kHz post-AEC; existing codebases assume 16 kHz.
**How to avoid:** Always probe `inputNode.outputFormat(forBus: 0)` after `setVoiceProcessingEnabled(true)`. Rate-convert to 16 kHz for downstream consumers.
**Warning signs:** Silero VAD emits high false-positive rate; wake-word never fires.

### Pitfall 3: Coerce Channels BEFORE Rate-Convert (R4-D4)
**What goes wrong:** `AVAudioConverter` sample-rate-converting a 2-channel buffer into a 1-channel target produces interleaved/garbage samples on Tahoe.
**Why it happens:** Converter's internal dispatch order assumes monotonic channel counts; mismatched input/output channel counts through rate-conversion is ambiguous.
**How to avoid:** Two-stage conversion — first coerce to mono (mixer node), then rate-convert mono-to-mono.
**Warning signs:** Audio sounds like a chipmunk with an echo.

### Pitfall 4: Ring Buffer Overflow from TTS Output Stall
**What goes wrong:** Mic ring fills because consumer (wake-word or Silero) stalled waiting on a Metal queue, mic buffer overruns, drops samples silently.
**Why it happens:** Lock-free SPSC ring with no backpressure signalling; stalled consumer ≠ throttled producer.
**How to avoid:** Monitor ring depth; if sustained > 500 ms lag, fire `.ringOverflow` teardown trigger (§9). Don't silently drop — rebuild the graph.
**Warning signs:** Wake word works for 30 seconds then stops; random transcription gaps.

### Pitfall 5: Mic Re-grant Mid-Session
**What goes wrong:** User denies mic at first prompt, later re-grants in System Settings. App doesn't notice because it cached `.denied` at startup.
**Why it happens:** Not polling `AVCaptureDevice.authorizationStatus` after the initial denial.
**How to avoid:** Subscribe to `AVCaptureDevice` authorization transitions; on denied → authorized, fire teardown + rebuild.
**Warning signs:** "Everything looks right but no audio comes in" after the user says they fixed permissions.

### Pitfall 6: Ducking Released Before Audio Drains
**What goes wrong:** System sounds blast in the tail of TTS because duck released at `TTSEvent.finished` instead of `.ttsStopped`.
**Why it happens:** Producer done ≠ sink empty. 100–200 ms of buffered audio still plays after `finished`.
**How to avoid:** Emit `.ttsStopped` only from the player-node completion handler; release duck only on that event.
**Warning signs:** Clipped TTS tails, Slack notification chime audible during "speaking" end.

### Pitfall 7: `isVoiceProcessingEnabled` Set After `connect`
**What goes wrong:** Setting VPIO after connecting nodes silently no-ops on Tahoe, crashes on Sonoma.
**Why it happens:** VPIO must be set at node-init time; the engine snapshots it on first connect.
**How to avoid:** Unit test: attempt to install tap on a node whose VPIO flag is off → throws `AudioGraphError.vpioNotEnabled`.
**Warning signs:** AEC appears disabled in Release but enabled in dev.

### Pitfall 8: Two-Hop Barge-In
**What goes wrong:** Separate calls `stopTTS()` and later `startListening()` race; a trailing token from the cancelled turn arrives after listening has started, contaminating the new turn.
**Why it happens:** No atomic boundary between cancel + submit.
**How to avoid:** Single `cancelAndSubmit` orchestrator entry (Phase 4 primitive). Unit test asserts count==1 per barge-in.
**Warning signs:** The user says "Jarvis stop—" and the old answer finishes before the new one starts.

## Code Examples (canonical)

### State machine
```swift
enum VoiceState: Equatable {
    case idle
    case listening(source: ListeningSource)    // .wakeWord, .ptt
    case thinking
    case speaking
    case reconfiguring(reason: RebuildTrigger)
}

enum VoiceEvent {
    case wakeWordFired
    case pttDown, pttUp
    case sttPartial(String), sttFinal(String)
    case ttsStarted, ttsStopped
    case degradedMode(reason: DegradationReason)
    case rebuild(trigger: RebuildTrigger)
}
```

### VoiceController (abridged)
```swift
actor VoiceController {
    private(set) var state: VoiceState = .idle
    private let wakeWord: WakeWordDAG
    private let vad: SileroVAD
    private let stt: STTProvider
    private let tts: TTSEngineActor
    private let graphOwner: AudioGraphOwner
    private let orchestrator: AgentOrchestrator   // Phase 4

    func handle(_ e: VoiceEvent) async {
        switch (state, e) {
        case (.idle, .wakeWordFired):
            await transition(.listening(source: .wakeWord))
        case (.speaking, .wakeWordFired):
            await orchestrator.cancelAndSubmit(source: .voice, trigger: .bargeIn)
        case (.listening, .sttFinal(let text)):
            await transition(.thinking)
            await orchestrator.submit(text)
        case (_, .rebuild(let t)):
            await graphOwner.rebuild(trigger: t)
        default: break
        }
    }
}
```

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Swift) |
| Config file | `packages/Voice/Tests/` — follows SPM convention |
| Quick run command | `swift test --package-path packages/Voice --filter VoiceTests.<name>` |
| Full suite command | `swift test --package-path packages/Voice` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| VOICE-01 | Wake word ≥4-frame hysteresis fires | unit | `swift test --filter WakeWordHysteresisTests` | ❌ Wave 0 |
| VOICE-01 | SHA-256 weight verification | unit | `swift test --filter ModelManifestTests` | ❌ Wave 0 |
| VOICE-02 | Silero v6.2.1 contract parity (512/32ms/16kHz) | scaffold probe | `swift test --filter SileroContractTests` | ❌ Wave 0 |
| VOICE-03 | SpeechAnalyzer entitlement load-bearing | Release cold-launch | manual + `./scripts/probe-speech-assets.sh` | ❌ Wave 0 |
| VOICE-04 | WhisperKit fallback flag switches cleanly | integration | `swift test --filter STTBackendSwitchTests` | ❌ Wave 0 |
| VOICE-05 | AVSpeech plays short confirmation | integration | `swift test --filter AVSpeechSmokeTests` | ❌ Wave 0 |
| VOICE-06 | Orpheus TTFA in 150–250 ms | scaffold perf probe | `swift test --filter OrpheusTTFATests` | ❌ Wave 0 |
| VOICE-06 | Rapid-fire Orpheus serialized | unit | `swift test --filter OrpheusSerializationTests` | ❌ Wave 0 |
| VOICE-07 | End-to-end "what time is it" | e2e (manual + scripted) | manual UAT in `06-HUMAN-UAT.md` | ❌ Wave 0 |
| VOICE-08 | VPIO ordering enforced (tap-on-non-VPIO throws) | unit | `swift test --filter VpioOrderingTests` | ❌ Wave 0 |
| VOICE-08 | Input format probed (not hardcoded) | unit | `swift test --filter InputFormatProbeTests` | ❌ Wave 0 |
| VOICE-09 | AEC-off rebuilds graph; HUD banner emitted | integration | `swift test --filter AECFallbackTests` | ❌ Wave 0 |
| VOICE-10 | 6-step teardown × 4 triggers | unit × 4 | `swift test --filter TeardownTests` | ❌ Wave 0 |
| VOICE-11 | Duck releases only on `.ttsStopped` | unit | `swift test --filter TTSInterruptTests` | ❌ Wave 0 |
| VOICE-12 | Mute wake word; PTT still armed | integration | `swift test --filter MuteWakeWordTests` | ❌ Wave 0 |
| VOICE-13 | PTT bypasses wake word | integration | `swift test --filter PTTTests` | ❌ Wave 0 |
| VOICE-14 | Barge-in = exactly one `cancelAndSubmit` call | unit | `swift test --filter BargeInTests` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --package-path packages/Voice --filter <relevant-suite>`
- **Per wave merge:** `swift test --package-path packages/Voice`
- **Phase gate:** full `swift test` green + manual UAT in `06-HUMAN-UAT.md` passed before `/gsd-verify-phase 6`

### Wave 0 Gaps
- [ ] `packages/Voice/Package.swift` — SPM manifest with ORT, argmax-oss-swift, mlx-audio-swift deps
- [ ] `packages/Voice/Tests/VoiceTests/` test infrastructure + `conftest`-equivalent fixtures (WAV files)
- [ ] `Resources/models/openwakeword/MANIFEST.json` + SHA-256 pinning
- [ ] `Resources/models/silero/silero_vad.onnx` + `_op15.onnx` + MANIFEST entry
- [ ] `scripts/probe-speech-assets.sh` — Release cold-launch entitlement probe
- [ ] Loopback device setup doc for end-to-end e2e

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Cloud STT (AWS Transcribe, Deepgram) | On-device `SpeechAnalyzer` (Tahoe) | 2025-06 (WWDC25) | No data leaves device; ~55% faster than Whisper. |
| Python sidecar for Orpheus TTS | In-process `mlx-audio-swift` | 2025–2026 | No `pip`/Python runtime; no second TCC surface. |
| WhisperKit standalone repo | `argmaxinc/argmax-oss-swift` monorepo | late 2025 | Single package import for Whisper + TTS + Speaker. |
| Silero VAD v5 (`silero_vad_v5.onnx`) | Silero v6.2.1 (opset 16 or 15) | 2025-08 → 2026-02 | ORT is optional as of v6.2.1; better perf. Contract preserved but verify at scaffold. |
| Carbon `RegisterEventHotKey` / `HotKey` SPM | `NSEvent.addGlobalMonitorForEvents` | Phase 1 decision | Fewer TCC surfaces; no full-process key-read risk. |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Silero v6.2.1 preserves v5's 512-sample/32ms/16kHz chunk contract | §2 | [VERIFIED: RESEARCH-DELTAS] but empirical parity probe runs at scaffold — if it fails, fall back to v5 and file issue. |
| A2 | `com.apple.developer.speech-recognition-assets` is load-bearing on Release cold-launch | §3 | [ASSUMED: AUDIT-R2-S5, unverified by Apple docs] — scaffold probe confirms or refutes. If unused, remove but keep Info.plist key. |
| A3 | Orpheus TTFA hits 150–250 ms on user's Apple Silicon | §6 | [ASSUMED] scaffold-time empirical measurement. If TTFA > 250 ms, swap to TTSKit fallback. |
| A4 | Tahoe post-VPIO format is 24 kHz Float32 mono | §7 | [CITED: R4-D4 + field reports] verified by runtime probe — never hardcoded. |
| A5 | Rapid-fire Orpheus synth without serial executor deadlocks | §6 | [VERIFIED: CLAUDE.md authoritative fact] unit test exercises the deadlock pattern. |
| A6 | `mlx-audio-swift v0.1.2` `generateStream` supports Orpheus event streaming | §6 | [VERIFIED: RESEARCH-DELTAS D7] feasibility confirmed; scaffold verifies format. |
| A7 | `AVAudioEngine.configurationChangeNotification` fires reliably on USB device change | §9 | [CITED: AVFoundation docs] well-documented; fallback: poll every 2 s if notification unreliable. |
| A8 | `TTSEvent.finished` fires before sink-drain completes (by 100–200 ms) | §10 pitfall 6 | [ASSUMED: empirical AVAudioPlayerNode behavior] ducking release already gated on `.ttsStopped` defensively. |

## Open Questions

1. **Orpheus voice for Jarvis persona.** `tara`, `leah`, `jess`, `leo`, `dan`, `mia`, `zac`, `zoe` are available. Default suggested: `tara` (per blaizzy docs). User preference?
   - Recommendation: ship `tara` as default, expose as config.
2. **Cosine fade-out exact curve.** 10 ms is the duration; the fade shape should be a quarter-cosine `cos(πx/2)` for smooth tail. Confirm no click across sample rates.
3. **Ring-overflow threshold.** 500 ms is a reasonable starting point but not empirically grounded.
   - Recommendation: make it configurable, measure in scaffold.
4. **PTT default keybinding.** CLAUDE.md says plain-modifier keys preferred with `NSEvent.addGlobalMonitorForEvents`. Unbound at first launch per Phase 1 shortcut recorder — same pattern here?
5. **Mute-wake-word persistence across reboots.** `UserDefaults` seems right, but confirm with user that mute state is persistent (not session-scoped).

## Sources

### Primary (HIGH confidence)
- `CLAUDE.md` (voice stack section) — authoritative project facts.
- `.planning/research/RESEARCH-DELTAS.md` — Silero v6.2.1, Orpheus streaming, WhisperKit monorepo consolidation, SpeechAnalyzer entitlement.
- `.planning/ROADMAP.md` Phase 6 success criteria.
- `App/Jarvis.entitlements` — confirmed `com.apple.developer.speech-recognition-assets` + audio-input + JIT.
- `App/Info.plist` — confirmed `NSMicrophoneUsageDescription` + `NSSpeechRecognitionAssetsUsageDescription` + `NSAppleEventsUsageDescription`.
- `.planning/REQUIREMENTS.md` VOICE-01..VOICE-14.

### Secondary (MEDIUM confidence)
- Apple Developer docs — `AVAudioEngine`, `AVSpeechSynthesizer`, `SpeechAnalyzer`.
- `snakers4/silero-vad` GitHub release notes for v6.0 → v6.2.1.
- `Blaizzy/mlx-audio-swift` README and Swift Package Index listing.
- `argmaxinc/argmax-oss-swift` monorepo README.
- MacRumors 2025-06-18 — SpeechAnalyzer faster-than-Whisper coverage.
- `dscripka/openWakeWord` README.

### Tertiary (LOW confidence)
- Live Ollama GitHub issues (not material to Phase 6 but cited upstream in RESEARCH-DELTAS).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries pre-pinned in CLAUDE.md with version + delta corrections.
- Architecture: HIGH — five-subsystem layout is a natural carve-out of the audio pipeline; VoiceController actor parallels Phase 4's orchestrator.
- Pitfalls: HIGH — all major pitfalls sourced from CLAUDE.md + RESEARCH-DELTAS + audit rounds; Metal deadlock, 24/16kHz drift, ordering bug, ring overflow, mic re-grant, duck release timing all covered.
- Scaffold-time probes: MEDIUM — contract-parity, TTFA, entitlement load-bearing are empirical; will pass or fail at scaffold.

**Research date:** 2026-04-22
**Valid until:** 2026-05-22 (30 days — stack is stable; Silero/MLX/Argmax ship monthly so re-check at scaffold if execution slips).
