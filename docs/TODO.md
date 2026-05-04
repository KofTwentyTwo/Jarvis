# TODO

Live triage list. Higher up = higher priority. Move done items to a dated archive section if the file gets long.

## Demo path (one working modality)

- [x] Track A: text turn + animated rings (`1f8e03e`)
- [ ] Re-launch app, verify CacheHints fix actually unblocks streaming. Read `system.log` for the new `AnthropicProvider stream outcome:` line — it now classifies 200+0bytes / 200+frames+EOF / complete.

## Track B — voice (B-1..7 done)

- [x] B-1: bundle ONNX models at `Contents/Resources/Models/{openWakeWord,silero}/`
- [x] B-2: WakeWordDAG.swift:93 typo (production was calling test seam)
- [x] B-3: tier-1 TTS engine (AVSpeechSynthesizer) wired in `installVoice`
- [x] B-4: `AudioGraphOwner` construction in `installVoice`; `AVAudioEngine.start()`; mic taps → wake-word DAG (`e9c0a34`)
- [x] B-4: replace `LiveSpeechAnalyzerBridge.feed()` body (`_ = chunk`) with macOS 26 SpeechAnalyzer wiring (`e9c0a34`)
- [x] B-5: VoiceController chunkPump + voice-loop e2e proof (`61aed20`). 3 new tests prove the chain: preset chunks → STT → orchestrator.submit. AppDelegate wires the production pump reading from `audioGraphOwner.ringBuffer`.
- [x] B-6: VAD-gated session end (`c7f9ece`). Per-session VAD interceptor in `VoiceController.startSTTSession` — slices pump output into 512-sample windows, runs Silero VAD, triggers `endSTTSession()` on `.speechEnd` + 5-chunk hangover. 4 new tests (VAD-1/2/4/5).
- [x] B-7: BufferBroadcaster fan-out for multi-consumer audio ring (`bce725b`). New `BufferBroadcaster` at the AudioGraph tap; chunk pump now subscribes per-session via `AudioGraphOwner.subscribe()`; legacy `ringBuffer` still works for WakeWordDAG. 5 new BufferBroadcasterTests (BB-1..5 incl. concurrent stress).
- [ ] B-7-followup: AudioLevelEmitter production wiring. The emitter is constructed only in tests today — when wired in AppDelegate it MUST call `audioGraphOwner.subscribe()`, not reuse `audioGraphOwner.ringBuffer`.
- [ ] B-8 (stretch): TTS tier-2 Orpheus — gated on ~6GB HuggingFace weight download; currently degrades to tier-1.

## Track C — vision (closed 2026-05-04)

- [x] C-1: `CameraCapture` `AVCapturePhotoCaptureDelegate` conformance + real `capturePhoto(...)` call (`7a5543a`)
- [x] C-2: `frameStream(forPresence:)` delegate-yielded continuation via `VideoSampleDelegate` fan-out (`ea09fd4`)
- [x] C-3: HUD camera button emits `BusInbound.frameAttachRequested` (`4159d44`)
- [x] C-4: explicit `MissingT2Provider` replaces silent `t2Provider: t1` fallback (`df6a4d2`)
- [x] C-5: `FrameAttachController.confirmSend(...)` wired into `handleChatSubmit` / `handleChatCancelAndSubmit` (`eac16c9`)
- [x] C-6: real-hardware vision integration test, gated by `JARVIS_REAL_CAMERA=1` + TCC authorized (`19362f6`)

## Track D — memory (~3 days)

- [ ] Build custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1`. Codesign nested. Bundle.
- [ ] Bundle `vec0.dylib` (currently `Resources/PLACEHOLDER.txt`)
- [ ] Remove `installMemory` early-return cascade so coordinator + extractor construct even on vec init failure
- [ ] Register `SearchMemoryTool` + `ForgetFactTool` with `mcpRuntime` (currently the agent has no way to query memory)
- [ ] Fix `MemoryExtractionOrchestrator.swift:84` — `priorFacts: []` hardcode means UPDATE/supersede never fires
- [ ] Pull local Ollama models (nomic-embed-text + qwen2.5-coder:32b)
- [ ] End-to-end "remember Brutus" regression scenario

## Cross-cutting

- [x] **BLOCKER-INT-1** — replace `NoopBusGateway` at `AppDelegate.swift:467` so tool-call cards reach HUD (`ad93dac`)
- [x] **F-A2-01** — `WebviewBridgeOutboundTests:80` stale `JarvisBusWorld` assertion fixed; now asserts `WKContentWorld.page` (`6f6617e`)
- [x] **Test pyramid health** — 5 `XCTAssertTrue(true)` tautologies removed/fixed per `.planning/audit-2026-05-03/tests-audit.md` (`08125a4`). HudStateEnumTests rubber-stamps left as-is (a11y labels are load-bearing).
- [ ] Phase F1 — top-level IntegrationTests target (the structural fix; one cold-launch e2e test would catch INT-1/2/3 + F-E-RACE-1/FK-1/WIRE-1)
- [x] Phase F2 — `scripts/check-no-leftover-stubs.sh` linter (catches "Replaced in 0X-0Y" rot) (`5cd46c9`)

## Knowledge graph / docs hygiene

- [ ] REQUIREMENTS.md traceability table is all `[ ]` despite ~70 of 79 being satisfied per phase SUMMARY frontmatters. Reconcile in one sweep at milestone close.
- [ ] `.planning/AUDIT-AND-FIX-PLAN.md` — Phase B3 (`/gsd-validate-phase 1..9`) still deferred
