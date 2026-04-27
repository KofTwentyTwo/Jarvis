---
phase: "06-voice"
plan: "06-03"
subsystem: "voice/vad-stt"
tags: ["silero-vad", "speech-analyzer", "whisperkit", "argmax-oss-swift", "feature-flag", "tdd"]
dependency_graph:
  requires: ["06-01-audio-graph"]
  provides: ["SileroVAD", "VADDecision", "ContractParityProbe", "VADError", "STTProvider", "AudioChunk", "PartialTranscript", "SpeechAnalyzerSTT", "WhisperKitSTT", "STTBackendSelector", "STTError", "STTWarningLogger"]
  affects: ["06-04-tts-engine", "06-05-controller-wiring"]
tech_stack:
  added: ["WhisperKit (argmax-oss-swift v0.18.0)", "Apple SpeechAnalyzer / SpeechTranscriber (macOS 26 Tahoe)"]
  patterns: ["Swift 6 actor isolation", "TDD RED/GREEN", "protocol-based test seams (VADInferenceEngine, SpeechAnalyzerBridge, WhisperKitBridge, STTWarningLogger)", "lazy-async-bridge for sync factory"]
key_files:
  created:
    - "packages/Voice/Sources/Voice/VAD/SileroVAD.swift"
    - "packages/Voice/Sources/Voice/VAD/ContractParityProbe.swift"
    - "packages/Voice/Sources/Voice/VAD/VADError.swift"
    - "packages/Voice/Sources/Voice/STT/STTProvider.swift"
    - "packages/Voice/Sources/Voice/STT/SpeechAnalyzerSTT.swift"
    - "packages/Voice/Sources/Voice/STT/WhisperKitSTT.swift"
    - "packages/Voice/Sources/Voice/STT/STTBackendSelector.swift"
    - "packages/Voice/Sources/Voice/STT/STTError.swift"
    - "packages/Voice/Tests/VoiceTests/SileroContractTests.swift"
    - "packages/Voice/Tests/VoiceTests/STTBackendSwitchTests.swift"
    - "packages/Voice/Tests/VoiceTests/AVSpeechSmokeTests.swift"
    - "Resources/models/silero/MANIFEST.json"
    - "Resources/models/silero/.gitkeep"
    - "scripts/fetch-silero-models.sh"
    - "scripts/probe-speech-assets.sh"
  modified:
    - "packages/Voice/Package.swift"
    - ".gitignore"
decisions:
  - "VADDecision is a 4-case enum (`.speech`, `.silence`, `.speechStart`, `.speechEnd`) — boundary transitions emit once, steady-state emits the active label every chunk"
  - "VADInferenceEngine protocol bridges SileroVAD to ORT — production uses ORTVADEngine, tests inject MockVADEngine via TestableVADOpset seam (no real ONNX models in unit tests)"
  - "STTProvider is a class-bound, Sendable protocol with `transcribe(stream:) -> AsyncStream<PartialTranscript>` + `finalize() async throws -> String` — both backends conform"
  - "STTBackendSelector.make(backend:warningLogger:) is SYNCHRONOUS by design — WhisperKit's async `init` is wrapped via LazyWhisperKitBridge so the selector never blocks"
  - "Empty-string backend ('') is treated as `speech_analyzer` in addition to the `speech_analyzer` literal, so PerTurnSnapshot consumers don't need to default-fill"
  - "WhisperKit modelName is `large-v3-v20240930_626MB` (Argmax-versioned MLX variant). The W2 test grep-asserts this string and acts as an anti-pattern guard against the HF Whisper `large-v3-turbo` variant"
  - "SpeechAnalyzerSTT uses `LiveSpeechAnalyzerBridge @available(macOS 26)` with `UnavailableSpeechAnalyzerBridge` fallback that throws `STTError.backendUnavailable` on older macOS — keeps the module compilable on host SDKs older than Tahoe"
  - "SFSpeechErrorCode.assetUnavailable is mapped to `STTError.assetMissing` so callers can distinguish 'entitlement/asset missing' from 'inference failed'"
  - "probe-speech-assets.sh exits 0 (pass), 1 (infrastructure error), 2 (inconclusive) — not a hard failure when AUDIT-R2-S5 can't be confirmed; documented in script header"
metrics:
  duration: "~90 minutes"
  completed: "2026-04-27"
  tasks_completed: 3
  files_created: 14
  files_modified: 2
  tests_added: 18
---

# Phase 06 Plan 03: VAD + STT Summary

Silero VAD v6.2.1 + dual-backend STT (Apple SpeechAnalyzer primary on Tahoe, WhisperKit fallback via argmax-oss-swift v0.18.0) with feature-flagged backend selection, plus the scaffold-time entitlement probe for the load-bearing speech-recognition-assets capability.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | SileroVAD + ContractParityProbe + VADError (VOICE-02) | `a694e6b` | SileroVAD.swift, ContractParityProbe.swift, VADError.swift, fetch-silero-models.sh |
| 2 | STT protocol + SpeechAnalyzer / WhisperKit / Selector (VOICE-03/04) | `b332214` | STTProvider.swift, SpeechAnalyzerSTT.swift, WhisperKitSTT.swift, STTBackendSelector.swift, STTError.swift, probe-speech-assets.sh |
| 3 | AVSpeechSmokeTests stub for Plan 06-04 | (folded into `b332214`) | AVSpeechSmokeTests.swift (1 placeholder test) |

Additional commits: `a2b9650` (RED S1-S6 SileroContractTests + MockVADEngine), `3e76e05` (RED S1/S2 SpeechAnalyzer + W1/W2 WhisperKit + B1-B4 selector + AVSpeechSmokeTests stub), `c4aa6cc` (W2 grep-gate doc-comment cleanup).

## Tests

18 tests total, all passing post-merge (S5 skips when ONNX models absent — expected).

| Test | Scenario | Result |
|------|----------|--------|
| S1 | 511/513 sample chunks throw `VADError.invalidChunkSize` | pass |
| S2 | LSTM state preserved across calls (silence → speechStart → speech) | pass |
| S3 | Full transition: silence/speech/silence emits the right enum sequence | pass |
| S4 | Opset-16 throws → opset-15 fallback succeeds via `MockVADEngine.failOpset16` seam | pass |
| S5 | `ContractParityProbe` synthetic-waveform gate vs ±32 ms tolerance | skip (no models) |
| S6 | `reset()` clears wasSpeech so next speech emits `.speechStart` | pass |
| SpeechAnalyzer S1 | Stubbed analyzer yields partials | pass |
| SpeechAnalyzer S2 | `SFSpeechErrorCode.assetUnavailable` → `STTError.assetMissing` mapping | pass |
| WhisperKit W1 | Stubbed bridge yields fixed final transcript | pass |
| WhisperKit W2 | `modelName` is the Argmax-versioned variant (anti-pattern guard) | pass |
| Selector B1 | `"speech_analyzer"` returns `SpeechAnalyzerSTT` | pass |
| Selector B2 | `"whisperkit"` returns `WhisperKitSTT` | pass |
| Selector B3 | Unknown value falls back to `SpeechAnalyzerSTT` and emits warning | pass |
| Selector B4 | Empty string `""` falls back silently (no warning) | pass |
| AVSpeechSmokeTests stub | Trivial passing test placeholder for Plan 06-04 | pass |

## Anti-pattern callouts re-stated

- DO NOT mid-session-swap STT backend — `PerTurnSnapshot` pinning per SEC-05 is enforced by the `make(backend:)` factory being called once per turn; the selector itself does not store state.
- DO NOT use `large-v3-turbo` model name — that's HF Whisper, not Argmax. Test W2 enforces the correct `large-v3-v20240930_626MB` Argmax MLX variant as a grep-gate.
- DO NOT auto-prompt for the `speech-recognition-assets` entitlement at runtime — the load-bearing probe is a one-shot scaffold-time tool (`probe-speech-assets.sh`).
- DO NOT block on `await analyzer.finish()` synchronously — `finalize()` is `async throws` and the caller is responsible for not deadlocking against VAD's `.speechEnd`.

## Deviations from Plan

**1. [Rule 3 — flagged] Package.swift WAS modified (plan said it was closed by 06-01).**
- Root cause: 06-01's `Package.swift` declared the WhisperKit (`argmax-oss-swift`) and ORT package-level deps but did NOT wire them as Voice target deps. Without target wiring, `import WhisperKit` and `import OnnxRuntimeBindings` don't compile.
- Fix: Added `.product(name: "WhisperKit", package: "argmax-oss-swift")` and `.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")` to Voice target deps. macOS platform also bumped to `.v14` (ORT 1.24.2 requirement).
- Worktree merge: parallel 06-02 plan applied a similar fix (ORT only); the orchestrator resolved the resulting conflict by union (both ORT and WhisperKit products land on Voice target deps). See merge commit `71e229d`.
- Recommendation for future planning: 06-01 should have wired ORT, argmax-oss-swift, and (in 06-04) mlx-audio-swift as target deps proactively. The "Package.swift closed" guarantee must mean *closed for further dep additions*, not *imports must compile from declared package deps*.

**2. [Rule 1] WhisperKit's async init is incompatible with the synchronous `STTBackendSelector.make` factory.**
- `WhisperKit(model:)` is `async throws`; the selector is synchronous so callers can use it from any context.
- Fix: `LazyWhisperKitBridge` defers `WhisperKit(model:)` until first `transcribe()` call. The selector returns a fully constructed `WhisperKitSTT` immediately; model loading is deferred to first use.
- This trade is explicit: first-turn STT latency includes model load (~few hundred ms on Apple Silicon); subsequent turns hit the loaded model.

**3. [Rule 1] SpeechAnalyzer is `@available(macOS 26)`-only.**
- The Voice package builds against macOS 14+ (ORT requirement). On macOS 14/15 hosts, `SpeechAnalyzer` symbols don't exist.
- Fix: `SpeechAnalyzerBridge` protocol with two implementations:
  - `LiveSpeechAnalyzerBridge` — `@available(macOS 26)`, real impl
  - `UnavailableSpeechAnalyzerBridge` — fallback that throws `STTError.backendUnavailable`
  - `SpeechAnalyzerSTT.init` picks the right bridge at runtime via `if #available(macOS 26.0, *)`.
- Future-proofs the package against running on a Sonoma/Sequoia host where SpeechAnalyzer simply isn't present.

## Known Stubs

- `AVSpeechSmokeTests.swift` is a 1-test placeholder created in this plan; Plan 06-04 (TTS) populates it with real AVSpeechSynthesizer smoke tests. The placeholder exists so 06-04's `files_modified` doesn't need to claim file creation when it's actually file modification.
- `Resources/models/silero/MANIFEST.json` ships with placeholder SHA-256 values. The `scripts/fetch-silero-models.sh` script downloads the v6.2.1 ONNX models and updates the manifest with real hashes. Until then, S5 (`ContractParityProbe`) skips at runtime — this is expected and documented.

## Threat Flags

None.

## TDD Gate Compliance

- RED gates: `a2b9650` (S1-S6 + MockVADEngine), `3e76e05` (S1/S2 SpeechAnalyzer + W1/W2 WhisperKit + B1-B4 selector)
- GREEN gates: `a694e6b` (SileroVAD + ContractParityProbe + VADError), `b332214` (STT protocol + backends + selector + probe-speech-assets.sh)
- REFACTOR gate: `c4aa6cc` (W2 grep-gate doc-comment cleanup)

## SUMMARY recovery note

This SUMMARY was written by the orchestrator after the executor agent hit a tool-permission denial during its final SUMMARY-write step. The recovery was orchestrator-side: the wave-2 merge sequence resolved a `Package.swift` conflict between the parallel 06-02 and 06-03 branches by union (both target deps land), then the orchestrator wrote both SUMMARYs into develop's working tree. All 5 commits from the executor branch (`a2b9650` → `c4aa6cc`) merged into develop via merge commit `71e229d`. Post-merge `swift test --package-path packages/Voice` reports 31 XCTest + 17 Swift Testing cases all green (with 1 expected skip).

## Self-Check: PASSED
