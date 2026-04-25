---
phase: 06-voice
plan: 03
type: execute
wave: 2
depends_on: [06-01]
files_modified:
  - packages/Voice/Sources/Voice/VAD/SileroVAD.swift
  - packages/Voice/Sources/Voice/VAD/ContractParityProbe.swift
  - packages/Voice/Sources/Voice/VAD/VADError.swift
  - packages/Voice/Sources/Voice/STT/STTProvider.swift
  - packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift
  - packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift
  - packages/Voice/Sources/Voice/STT/STTBackendSelector.swift
  - packages/Voice/Sources/Voice/STT/STTError.swift
  - packages/Voice/Tests/VoiceTests/SileroContractTests.swift
  - packages/Voice/Tests/VoiceTests/STTBackendSwitchTests.swift
  - packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift  # placeholder created here, populated in Plan 06-04
  - Resources/models/silero/MANIFEST.json
  - Resources/models/silero/.gitkeep
  - scripts/fetch-silero-models.sh
  - scripts/probe-speech-assets.sh
autonomous: true
requirements: [VOICE-02, VOICE-03, VOICE-04]
tags: [voice, silero-vad, speech-analyzer, whisperkit, argmax-oss-swift, contract-parity, feature-flag]
assumptions:
  - Plan 06-01 has shipped: Voice package + `RingBuffer` + ORT dependency are available.
  - `argmaxinc/argmax-oss-swift v0.18.0` is the consolidated monorepo for `WhisperKit`; the package product `WhisperKit` is what we import (RESEARCH-DELTAS).
  - Apple `SpeechAnalyzer` / `SpeechTranscriber` are first-party macOS 26 Tahoe APIs that require the `com.apple.developer.speech-recognition-assets` entitlement (already wired in Phase 1) and `NSSpeechRecognitionAssetsUsageDescription` (already in Info.plist).
  - The Silero v6.2.1 ONNX models (`silero_vad.onnx` opset-16 + `silero_vad_16k_op15.onnx` opset-15 fallback) are vendored in `Resources/models/silero/` with SHA-256 manifest, downloaded via `scripts/fetch-silero-models.sh`. Like the openWakeWord weights, the .onnx files are gitignored — only `MANIFEST.json` + the .gitkeep land in git.
  - The 512-sample / 32 ms / 16 kHz chunk contract is preserved between Silero v5 and v6.2.1 (RESEARCH-DELTAS Assumption A1) — verified at scaffold-time by `SileroContractTests` running a synthetic waveform parity check.
  - The STT backend selector reads `features.stt.backend` from Phase 1's `PerTurnSnapshot`; valid values are `"speech_analyzer"` (default) and `"whisperkit"`. Mid-session swap is NOT supported — backend pins at `submit()` snapshot time per Phase 1 SEC-05 contract.
  - Anti-pattern callouts: DO NOT mid-session-swap STT backend (PerTurnSnapshot pinning per SEC-05). DO NOT use `large-v3-turbo` model name — that's HF Whisper, not Argmax (RESEARCH §4). DO NOT auto-prompt for `speech-recognition-assets` entitlement at runtime — the entitlement load-bearing probe is run-once at scaffold via `probe-speech-assets.sh`. DO NOT block on `await analyzer.finish()` synchronously — wrap in a finalize Task so VAD `.speechEnd` doesn't deadlock.
must_haves:
  truths:
    - "A `SileroVAD` actor exposes a `feed(_ pcm16k:)` API consuming exactly 512 samples per call (32 ms at 16 kHz), maintaining stateful LSTM hidden vectors across calls; output is `.speech | .silence` per chunk."
    - "`ContractParityProbe.run(modelDir:)` is a scaffold-time probe that feeds a known synthetic waveform (sine sweep + silence + sine + silence) and asserts `.speechStart` / `.speechEnd` boundaries fall within ±32 ms of the expected timestamps; mismatch raises a clear scaffold-time error."
    - "An `STTProvider` protocol is implemented by both `SpeechAnalyzerSTT` (primary, Tahoe-only) and `WhisperKitSTT` (fallback, behind feature flag); both produce an `AsyncStream<PartialTranscript>` and a final-transcript callback."
    - "`STTBackendSelector.make(snapshot:)` reads `features.stt.backend` from `PerTurnSnapshot` and returns the matching `STTProvider`; an unknown value falls back to `speech_analyzer` AND logs a warning to `JarvisLogChannel.agent`."
    - "WhisperKit is initialized with model string `large-v3-v20240930_626MB` (Argmax-versioned MLX variant) — NOT `large-v3-turbo` (which is HF Whisper, not Argmax)."
    - "The `probe-speech-assets.sh` script is a one-shot scaffold-time tool that COLD-LAUNCHES a Release archive with the entitlement stripped; the expected outcome is `SFSpeechErrorCode.assetUnavailable` — confirming the entitlement is load-bearing per AUDIT-R2-S5."
  artifacts:
    - path: "packages/Voice/Sources/Voice/VAD/SileroVAD.swift"
      provides: "Actor wrapping `ORTSession` for `silero_vad.onnx`; exposes `feed(_:) -> VADDecision`; opset-16 preferred with opset-15 fallback."
      min_lines: 100
    - path: "packages/Voice/Sources/Voice/VAD/ContractParityProbe.swift"
      provides: "Static probe `run(modelDir:) async throws` for scaffold-time v6.2.1 chunk-contract verification."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/STT/STTProvider.swift"
      provides: "Protocol with `transcribe(_ stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript>` + `finalTranscript() async throws -> String`."
      min_lines: 30
    - path: "packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift"
      provides: "Primary Tahoe-only STTProvider built on `SpeechAnalyzer` + `SpeechTranscriber`."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift"
      provides: "Fallback STTProvider using `WhisperKit` from argmax-oss-swift v0.18.0; model `large-v3-v20240930_626MB`; flagged."
      min_lines: 80
    - path: "packages/Voice/Sources/Voice/STT/STTBackendSelector.swift"
      provides: "Selector reading `features.stt.backend`; returns `STTProvider` instance; logs warning on unknown value."
    - path: "scripts/probe-speech-assets.sh"
      provides: "Scaffold-time entitlement probe; cold-launches Release archive with entitlement stripped; verifies SFSpeechErrorCode.assetUnavailable fires."
      contains: "SFSpeechErrorCode"
    - path: "Resources/models/silero/MANIFEST.json"
      provides: "Pinned SHA-256s for opset-16 + opset-15 Silero VAD ONNX files."
  key_links:
    - from: "packages/Voice/Sources/Voice/VAD/SileroVAD.swift"
      to: "ORTSession (opset-16, opset-15 fallback)"
      via: "two-step session-load with catch-fallback"
      pattern: "opset16URL|opset15URL"
    - from: "packages/Voice/Sources/Voice/STT/STTBackendSelector.swift"
      to: "Config.PerTurnSnapshot.features.stt.backend"
      via: "snapshot read at submit() time"
      pattern: "features\\.stt\\.backend"
    - from: "packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift"
      to: "WhisperKit(model: \"large-v3-v20240930_626MB\")"
      via: "argmax-oss-swift v0.18.0 monorepo product"
      pattern: "large-v3-v20240930_626MB"
---

<objective>
Land VAD + STT with a clean feature-flagged backend swap. Three locked invariants:

1. **VOICE-02 — Silero VAD v6.2.1 chunk contract.** 512-sample / 32 ms / 16 kHz. Opset-16 `silero_vad.onnx` is preferred; on ORT lacking opset-16 support, the actor catches the unsupported-opset error and re-loads `silero_vad_16k_op15.onnx`. A scaffold-time `ContractParityProbe` feeds a synthetic waveform and asserts speech-boundary detection within ±32 ms (proves v6.2.1 preserves v5's chunk contract per RESEARCH-DELTAS Assumption A1).
2. **VOICE-03 — SpeechAnalyzer primary STT.** Uses Tahoe's `SpeechAnalyzer` + `SpeechTranscriber` for streaming partial transcripts. The `com.apple.developer.speech-recognition-assets` entitlement is load-bearing — verified by `scripts/probe-speech-assets.sh` at scaffold-time (cold-launch Release archive minus entitlement → expect `SFSpeechErrorCode.assetUnavailable`).
3. **VOICE-04 — WhisperKit fallback (argmax-oss-swift v0.18.0).** Behind feature flag `features.stt.backend = "whisperkit"`. Model string is `large-v3-v20240930_626MB` (Argmax-versioned MLX variant per RESEARCH §4) — NOT `large-v3-turbo`. The selector reads `PerTurnSnapshot` (pinned at `submit()` per SEC-05) so backend never swaps mid-turn.

This plan runs in parallel with 06-02 in Wave 2. Both consume Plan 06-01's `RingBuffer` read-only and write to disjoint subdirectories (`VAD/*` + `STT/*` here vs `WakeWord/*` in 06-02). Neither modifies `Package.swift` (closed by 06-01).

Output: a working `SileroVAD` + two `STTProvider` implementations + selector + scaffold-time probes (`probe-speech-assets.sh`, `ContractParityProbe`). The `AVSpeechSmokeTests` file is created here as a stub placeholder so Plan 06-04's TTS tier-1 lands without modifying this plan's `files_modified`.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/06-voice/06-RESEARCH.md
@.planning/phases/06-voice/06-01-SUMMARY.md
@.planning/research/RESEARCH-DELTAS.md
@CLAUDE.md
@App/Jarvis.entitlements
@App/Info.plist
@packages/Voice/Package.swift
@packages/Voice/Sources/Voice/AudioGraph/RingBuffer.swift
@packages/Config/Sources/Config/PerTurnSnapshot.swift

<interfaces>
<!--
  Contracts the executor needs verbatim.
-->

From `argmax-oss-swift` v0.18.0 (target product: `WhisperKit`):

```swift
import WhisperKit

public final class WhisperKit {
    public init(model: String) async throws  // model is Argmax-versioned, e.g. "large-v3-v20240930_626MB"
    public func transcribe(audioPath: String) async throws -> [TranscriptionResult]
    public func transcribe(audioArray: [Float]) async throws -> [TranscriptionResult]
}
```

Note: the v0.18 API surface for streaming is `transcribeStream` or chunked-array calls — the executor should consult Context7 (`mcp__context7__resolve-library-id` for `argmaxinc/argmax-oss-swift`) for the exact streaming surface at implementation time. If streaming isn't directly supported, chunk-and-reconcile by feeding ~500 ms windows.

From `Speech` framework (macOS 26 Tahoe):

```swift
@available(macOS 26.0, *)
public final class SpeechAnalyzer {
    public init(...)
    public func add(modules: [any SpeechAnalysisModule]) async throws
    public func feed(_ buffer: AVAudioPCMBuffer) async throws
    public func finish() async throws
}

@available(macOS 26.0, *)
public final class SpeechTranscriber: SpeechAnalysisModule {
    public init(locale: Locale, options: TranscriberOptions)
    public var results: AsyncStream<SpeechTranscriptionResult> { get }
}
```

Note: SpeechAnalyzer is NEW in Tahoe; the executor should consult Apple's Speech framework docs for exact init signatures. The interface above captures the consume-feed-finish lifecycle.

From Plan 06-01 (already shipped, do NOT modify):

```swift
public final class RingBuffer { public func readMono16k(into: ...) -> Int }
```

From Phase 1 (already shipped, do NOT modify):

```swift
public struct PerTurnSnapshot {
    public let features: Features
    public struct Features {
        public let stt: STTFeatures
        public struct STTFeatures {
            public let backend: String  // "speech_analyzer" | "whisperkit"
        }
    }
}
```

Note: if `features.stt.backend` does not exist in the Phase 1 PerTurnSnapshot yet, this plan adds it. Verify via `grep -n 'features\\.stt' packages/Config/Sources/Config/PerTurnSnapshot.swift` at the start of Task 1; if missing, the executor adds it in a leading sub-task with a tracking note (this is a Rule 3 deviation if Phase 1 didn't reserve the slot).

New surface introduced by this plan:

```swift
public enum VADDecision: Sendable, Equatable {
    case speech
    case silence
    case speechStart       // emitted on transition silence → speech
    case speechEnd         // emitted on transition speech → silence
}

public actor SileroVAD {
    public init(modelDir: URL) async throws
    public func feed(_ pcm16k: UnsafeBufferPointer<Float>) throws -> VADDecision
    public func reset() async    // reset hidden state (between utterances)
}

public enum ContractParityProbe {
    public static func run(modelDir: URL) async throws  // scaffold-time only
}

public protocol STTProvider: Sendable {
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<PartialTranscript>
    func finalize() async throws -> String
}

public struct AudioChunk: Sendable { public let pcm16k: [Float] }
public struct PartialTranscript: Sendable, Equatable { public let text: String; public let isFinal: Bool }

public enum STTBackendSelector {
    public static func make(snapshot: PerTurnSnapshot) -> any STTProvider
}

public enum STTError: Error, Sendable {
    case backendUnavailable(String)
    case assetMissing
    case finalizationFailed(underlying: Error)
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Silero VAD v6.2.1 + opset-16/15 fallback + ContractParityProbe</name>
  <files>packages/Voice/Sources/Voice/VAD/SileroVAD.swift, packages/Voice/Sources/Voice/VAD/ContractParityProbe.swift, packages/Voice/Sources/Voice/VAD/VADError.swift, packages/Voice/Tests/VoiceTests/SileroContractTests.swift, Resources/models/silero/MANIFEST.json, Resources/models/silero/.gitkeep, scripts/fetch-silero-models.sh</files>
  <behavior>
    - SileroContractTests S1 (chunk size enforcement): `feed` with a 511-sample buffer throws `VADError.invalidChunkSize`; with 513 samples also throws; with exactly 512 samples succeeds.
    - SileroContractTests S2 (state preserved across calls): feed 4 silence chunks → VAD output is `.silence`; feed 1 speech chunk → output is `.speechStart`; feed another speech chunk → `.speech` (not `.speechStart` again — state held).
    - SileroContractTests S3 (transitions): 3 silence → 3 speech → 3 silence sequence yields exactly: silence, silence, silence, speechStart, speech, speech, speechEnd, silence, silence.
    - SileroContractTests S4 (opset fallback): when opset-16 ORTSession init fails (injected error), the actor falls back to opset-15 and continues working. A test seam exposes which opset was loaded.
    - SileroContractTests S5 (parity probe — scaffold gate, marked `#if DEBUG`): generates a 5-second synthetic waveform (1 s silence + 1 s 440 Hz sine + 1 s silence + 1 s 880 Hz sine + 1 s silence), feeds in 512-sample chunks via the production VAD, asserts speech boundaries land at expected timestamps within ±32 ms tolerance.
    - SileroContractTests S6 (reset): after a speech-then-silence run, calling `reset()` clears hidden state — feeding speech again produces `.speechStart` not `.speech`.
  </behavior>
  <action>
Create `Resources/models/silero/MANIFEST.json` with placeholder SHA-256s for both ONNX files; create `scripts/fetch-silero-models.sh` mirroring `fetch-openwakeword-models.sh` from Plan 06-02 (download from `snakers4/silero-vad` v6.2.1 release; compute hashes; write manifest). Like wake-word, the .onnx files are gitignored.

Create `VADError.swift` with cases `.invalidChunkSize(got:expected:)`, `.modelLoadFailed(underlying:)`, `.opsetUnsupported`, `.runFailed`.

Implement `SileroVAD` as an actor:
1. Init: try opset-16 first → catch `ORTError.opsetUnsupported` (or its real ORT-Swift equivalent — the executor uses Context7 `mcp__context7__resolve-library-id` for `microsoft/onnxruntime-swift-package-manager` to find the actual error case at implementation time) → fall back to opset-15. Track which loaded for `loadedOpset` test seam.
2. Maintain hidden state: Silero VAD requires the previous timestep's hidden + cell state as input. Store as `[Float]` buffers (typically `[2, 1, 64]` for v6.2.1 — verify exact shape at impl time).
3. `feed(_ pcm16k:)`: validate exactly 512 samples; build ORTValue inputs (`input` + `state`); run session; parse output prob + new state; track `wasSpeech: Bool` to emit `.speechStart` / `.speechEnd` transitions vs steady `.speech` / `.silence`.
4. `reset()`: zero out hidden state buffers; reset `wasSpeech = false`.

Threshold for speech vs silence: 0.5 by default (Silero recommended). Make configurable via init parameter for tuning.

Implement `ContractParityProbe.run(modelDir:)`:
1. Generate the synthetic waveform programmatically (`Foundation.AVFoundation` not needed — pure Float arrays).
2. Feed in 512-sample chunks through a fresh `SileroVAD`.
3. Record timestamps of `.speechStart` / `.speechEnd`.
4. Compare against expected boundaries (1 s, 2 s, 3 s, 4 s seconds in the synthetic).
5. Throw `VADError.runFailed` with a descriptive message if any boundary is more than 32 ms off.

Verify: S1..S6 pass. The probe runs in `#if DEBUG` and is invoked from a `SileroContractTests.testParityProbeAtScaffold()` so its result is captured in CI; it's also runnable manually via `swift test --filter SileroContractTests.testParityProbeAtScaffold` on the user's Apple Silicon Mac.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.SileroContractTests &amp;&amp; bash -n scripts/fetch-silero-models.sh</automated>
  </verify>
  <done>SileroContractTests (6 cases — S1..S6) pass. The opset-fallback path is exercised by a test that injects an opset-16 init failure. The parity probe runs against a synthetic waveform and asserts ±32 ms boundaries.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: STTProvider protocol + SpeechAnalyzer primary + WhisperKit fallback + scaffold-time entitlement probe</name>
  <files>packages/Voice/Sources/Voice/STT/STTProvider.swift, packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift, packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift, packages/Voice/Sources/Voice/STT/STTError.swift, scripts/probe-speech-assets.sh</files>
  <behavior>
    - SpeechAnalyzerSTT S1: with a stubbed `SpeechAnalyzer` (test seam: `internal init(analyzerFactory:)`) returning two partial transcripts ("hello", "hello world"), the provider yields exactly two `PartialTranscript` events on the stream and `finalize()` returns `"hello world"`.
    - SpeechAnalyzerSTT S2: when `analyzer.feed` throws `NSError(domain: "SFSpeechErrorDomain", code: SFSpeechErrorCode.assetUnavailable.rawValue, ...)`, the provider rethrows as `STTError.assetMissing`. Test asserts the conversion path.
    - WhisperKitSTT W1: with a stubbed `WhisperKit` (test seam) returning a fixed transcript, the provider yields one final `PartialTranscript` with `isFinal: true` and `finalize()` returns the same text.
    - WhisperKitSTT W2: model string MUST be `"large-v3-v20240930_626MB"` — a unit test greps the source for the literal string and asserts a single match (no `large-v3-turbo` references in production code).
  </behavior>
  <action>
Create `STTError.swift` per `<interfaces>`.

Create `STTProvider.swift` protocol surface verbatim from `<interfaces>` (Sendable, two methods).

Implement `SpeechAnalyzerSTT.swift`:
- `@available(macOS 26.0, *)` on the type.
- Public `init()` constructs the live `SpeechAnalyzer` + `SpeechTranscriber(locale: .current, options: .partialResults)`.
- Internal `init(analyzerFactory: ...)` test seam.
- `transcribe(stream:)` spawns a Task that loops `for await chunk in stream { try? await analyzer.feed(chunk.pcm) }` then calls `try? await analyzer.finish()` on stream exhaustion.
- A separate Task drains `transcriber.results` and yields into the public `AsyncStream<PartialTranscript>`.
- `finalize()`: awaits the final result and returns the concatenated text.
- Maps `SFSpeechErrorCode.assetUnavailable` to `STTError.assetMissing` so the orchestrator can surface a human-readable banner.

Implement `WhisperKitSTT.swift`:
- `import WhisperKit`.
- Public `init() async throws { self.kit = try await WhisperKit(model: "large-v3-v20240930_626MB") }` — the model string is the WHOLE point per RESEARCH §4. Internal seam: `init(kitFactory:)`.
- `transcribe(stream:)` accumulates audio chunks, calls `kit.transcribe(audioArray:)` on natural pauses (heuristic: every ~500 ms of speech buffered), yields `PartialTranscript`s.
- `finalize()` flushes the buffer and returns the concatenated final text.
- The exact streaming API surface depends on argmax-oss-swift v0.18.0 — the executor MUST consult Context7 (`mcp__context7__resolve-library-id` for `argmaxinc/argmax-oss-swift`, then `mcp__context7__get-library-docs` with `topic: "WhisperKit streaming"`) at implementation time. If streaming is not directly supported, fall back to chunk-and-reconcile.

Create `scripts/probe-speech-assets.sh`:
```bash
#!/usr/bin/env bash
# Scaffold-time probe: cold-launches a Release archive with the
# speech-recognition-assets entitlement stripped to verify the entitlement
# is load-bearing per AUDIT-R2-S5.
#
# Usage: scripts/probe-speech-assets.sh path/to/Jarvis.app
#
# Expected outcome: SFSpeechErrorCode.assetUnavailable fires in stderr.
# If STT works without the entitlement, AUDIT-R2-S5 is REFUTED — flag the
# result either way (this is the "KEEP AT SCAFFOLD" clause from RESEARCH-DELTAS).
set -euo pipefail
APP="${1:?provide path to Jarvis.app}"
TMP=$(mktemp -d)
cp -R "$APP" "$TMP/"
TARGET="$TMP/$(basename "$APP")"
# Strip the entitlement
codesign -d --entitlements :- "$TARGET" 2>/dev/null > "$TMP/entitlements.plist"
plutil -remove com.apple.developer.speech-recognition-assets "$TMP/entitlements.plist" || true
codesign --force --sign - --entitlements "$TMP/entitlements.plist" "$TARGET"
# Cold-launch and capture STDERR for SFSpeechErrorCode.assetUnavailable
RESULT_LOG="$TMP/launch.log"
"$TARGET/Contents/MacOS/Jarvis" --probe-stt 2>&1 | tee "$RESULT_LOG" &
LAUNCH_PID=$!
sleep 3
kill -TERM "$LAUNCH_PID" 2>/dev/null || true
if grep -q "SFSpeechErrorCode" "$RESULT_LOG"; then
  echo "PROBE PASS: entitlement is load-bearing (assetUnavailable observed)"
  exit 0
else
  echo "PROBE INCONCLUSIVE: SFSpeechError not observed; STT may not be entitlement-dependent"
  exit 2  # not a hard fail — RESEARCH-DELTAS allows refutation
fi
```

The `--probe-stt` flag in the binary is added by Plan 06-05 (it instantiates an STT provider and writes errors to stderr). For this plan, the script is committed and made executable; the `--probe-stt` flag wiring lives in 06-05.

Verify: tests pass; script is `bash -n` clean.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.STTBackendSwitchTests &amp;&amp; bash -n scripts/probe-speech-assets.sh</automated>
  </verify>
  <done>SpeechAnalyzer (2 cases) + WhisperKit (2 cases) tests pass. Model string `large-v3-v20240930_626MB` appears exactly once in `WhisperKitSTT.swift` (grep gate). `probe-speech-assets.sh` is bash-syntax-clean and chmod +x.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: STTBackendSelector + features.stt.backend wiring + AVSpeechSmokeTests stub</name>
  <files>packages/Voice/Sources/Voice/STT/STTBackendSelector.swift, packages/Voice/Tests/VoiceTests/STTBackendSwitchTests.swift, packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift, packages/Config/Sources/Config/PerTurnSnapshot.swift</files>
  <behavior>
    - STTBackendSwitchTests B1: snapshot with `features.stt.backend = "speech_analyzer"` → `make()` returns a `SpeechAnalyzerSTT` (verify via type check).
    - STTBackendSwitchTests B2: snapshot with `features.stt.backend = "whisperkit"` → `make()` returns a `WhisperKitSTT`.
    - STTBackendSwitchTests B3: snapshot with `features.stt.backend = "garbage"` → `make()` returns `SpeechAnalyzerSTT` (default fallback) AND emits a warning log line containing the unknown value. Use a test logger handler to capture.
    - STTBackendSwitchTests B4: snapshot with no `features` set at all → `make()` returns `SpeechAnalyzerSTT` (default).
  </behavior>
  <action>
First, verify the Phase 1 `PerTurnSnapshot` schema:
```bash
grep -nE 'features|stt\\.backend' packages/Config/Sources/Config/PerTurnSnapshot.swift
```

If `features.stt.backend` is not present, ADD it (this is a Rule 3 deviation — document inline that Phase 1 didn't reserve the slot, with a one-line rationale that voice was deferred from the foundations phase). The change is purely additive — adding a new optional field with default `"speech_analyzer"` doesn't break existing config files.

Implement `STTBackendSelector`:
```swift
public enum STTBackendSelector {
    public static func make(snapshot: PerTurnSnapshot) -> any STTProvider {
        let backend = snapshot.features.stt.backend
        switch backend {
        case "speech_analyzer": return SpeechAnalyzerSTT()
        case "whisperkit":
            // async-init wrapper: WhisperKit(model:) is async throws
            // wrap in a synchronous selector by using a lazy actor
            return LazyWhisperKitSTT()
        default:
            Logger(label: JarvisLogChannel.agent.rawValue)
                .warning("Unknown STT backend '\\(backend)'; falling back to speech_analyzer")
            return SpeechAnalyzerSTT()
        }
    }
}
```

`LazyWhisperKitSTT` is a small wrapper that defers the async `WhisperKit(model:)` init until first `transcribe(stream:)` call — keeps the selector synchronous. Pattern is documented inline.

Create `AVSpeechSmokeTests.swift` as a placeholder file (empty `XCTestCase` subclass with one stub test marked `XCTFail("Plan 06-04 implements")`) so Plan 06-04's TTS tier-1 work has a test file to populate without modifying this plan's `files_modified`. Plan 06-04 will replace the stub with real tests.

Verify: B1..B4 pass.
  </action>
  <verify>
    <automated>swift test --package-path packages/Voice --filter VoiceTests.STTBackendSwitchTests</automated>
  </verify>
  <done>STTBackendSwitchTests (4 cases — B1..B4) pass. `features.stt.backend` field is wired in `PerTurnSnapshot.swift` (with deviation note if Phase 1 didn't reserve it). `AVSpeechSmokeTests.swift` placeholder file exists. `LazyWhisperKitSTT` lazy-init wrapper documented inline.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Mic frames → Silero ORT inference | Same boundary as wake-word — VPIO-sanitized audio in, decision out. |
| Silero output (speech/silence) → STT activation | Internal app boundary; Plan 06-05 routes VAD events to STT start/finalize. |
| User speech → SpeechAnalyzer / WhisperKit | First-party Apple APIs (SpeechAnalyzer) or in-process MLX (WhisperKit); no network. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-06-03-01 | Tampering | Swapped Silero ONNX weight | mitigate | SHA-256 manifest verification at session init (mirrors Plan 06-02 wake-word pattern). |
| T-06-03-02 | Information Disclosure | STT transcripts leak via cloud | mitigate | Architecturally impossible: SpeechAnalyzer is on-device, WhisperKit is in-process MLX. No network code path exists. Verified by REQUIREMENTS Out of Scope ("Cloud STT" rejected). |
| T-06-03-03 | Tampering | WhisperKit model string mutated to a HF Whisper variant | mitigate | Grep gate: `grep -nE 'large-v3-turbo|large-v3-v20240930' packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift` — exactly 1 match for `large-v3-v20240930_626MB`, 0 matches for `large-v3-turbo`. |
| T-06-03-04 | Denial of Service | Adversarial audio causes Silero to flap speech↔silence | accept | Plan 06-05's VoiceController uses a hangover threshold (e.g. 200 ms of silence before `.speechEnd` fires) to filter flap. v1 doesn't implement adversarial-input rate-limiting. |
| T-06-03-05 | Repudiation | STT transcripts are user-confidential and not redacted in logs | mitigate | Plan 06-05 forwards transcripts ONLY to ReplayLog (encrypted at rest by macOS FileVault) and never to `JarvisLogChannel` (system logs go to syslog where they're harder to delete). Plan 06-05 owns this discipline. |
| T-06-03-06 | Spoofing | Mid-session backend swap injects different STT model | mitigate | `PerTurnSnapshot` is pinned at `submit()` per SEC-05; backend cannot change mid-turn. Selector reads only at submit-snapshot time. |
| T-06-03-07 | Information Disclosure | speech-recognition-assets entitlement allows asset download — payload could be a vector | accept | Apple's first-party asset endpoint, code-signed; same trust boundary as the OS itself. v1 personal-use threat model accepts this. |
</threat_model>

<verification>
- `swift test --package-path packages/Voice` — all VoiceTests green (Plan 06-01's 14 + this plan's ~12 = ~26 net).
- `swift build --package-path packages/Voice` — clean.
- Grep gates:
  - `grep -nE 'large-v3-v20240930_626MB' packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift | grep -v '^[[:space:]]*//' | wc -l` — exactly 1.
  - `grep -nE 'large-v3-turbo' packages/Voice/Sources/Voice/` — 0 matches (anti-pattern guard).
  - `grep -nE 'opset16URL|opset_16|opset16' packages/Voice/Sources/Voice/VAD/SileroVAD.swift` — at least 1 (preferred path anchor).
  - `grep -nE '512' packages/Voice/Sources/Voice/VAD/SileroVAD.swift | grep -v '^[[:space:]]*//' | wc -l` — at least 1 (chunk-size constant anchor).
- `bash -n scripts/probe-speech-assets.sh` — exit 0.
- `bash -n scripts/fetch-silero-models.sh` — exit 0.
- `Package.swift` is unchanged from Plan 06-01 (Wave-2 disjoint-file contract holds).
- `Resources/models/silero/MANIFEST.json` exists with placeholder structure.
</verification>

<success_criteria>
- VOICE-02 closed at the unit-test level: chunk-size enforcement, state preservation, transition emission (speechStart/End), opset-16/15 fallback, reset semantics, scaffold-time parity probe.
- VOICE-03 closed at the unit-test level: SpeechAnalyzer provider with stubbed analyzer; entitlement-load-bearing probe script committed.
- VOICE-04 closed at the unit-test level: WhisperKit provider with correct model string `large-v3-v20240930_626MB`; selector swaps backend via PerTurnSnapshot flag.
- The `STTBackendSelector` is the SINGLE call site that reads `features.stt.backend` — Plan 06-05's `VoiceController` uses the selector, never the snapshot directly.
- Wave-2 file disjoint-ness with Plan 06-02 confirmed: this plan touches `VAD/*` + `STT/*`; 06-02 touches `WakeWord/*`. No `Package.swift` touch.
</success_criteria>

<output>
After completion, create `.planning/phases/06-voice/06-03-SUMMARY.md` documenting:
- The opset-16/15 fallback strategy and the test seam exposing `loadedOpset`.
- The contract-parity probe waveform shape and ±32 ms tolerance.
- The `large-v3-v20240930_626MB` model-string anchor (with grep gate result).
- The `LazyWhisperKitSTT` lazy-init pattern that keeps `STTBackendSelector.make` synchronous.
- The `probe-speech-assets.sh` workflow (and the `--probe-stt` flag deferred to Plan 06-05).
- The `features.stt.backend` PerTurnSnapshot deviation note (if Phase 1 didn't reserve it).
- Test count: ~12 (S1..S6 + B1..B4 + STT 4 cases).
</output>
