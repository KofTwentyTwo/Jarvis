# TODO

Live triage list. Higher up = higher priority. Move done items to a dated archive section if the file gets long.

## Demo path (one working modality)

- [x] Track A: text turn + animated rings (`1f8e03e`)
- [ ] Re-launch app, verify CacheHints fix actually unblocks streaming. Read `system.log` for the new `AnthropicProvider stream outcome:` line — it now classifies 200+0bytes / 200+frames+EOF / complete.

## Track B — voice (~1 day total; B-1..3 done)

- [x] B-1: bundle ONNX models at `Contents/Resources/Models/{openWakeWord,silero}/`
- [x] B-2: WakeWordDAG.swift:93 typo (production was calling test seam)
- [x] B-3: tier-1 TTS engine (AVSpeechSynthesizer) wired in `installVoice`
- [ ] B-4: `AudioGraphOwner` construction in `installVoice`; `AVAudioEngine.start()`; mic taps → wake-word DAG
- [ ] B-4: replace `LiveSpeechAnalyzerBridge.feed()` body (`_ = chunk`) with macOS 26 SpeechAnalyzer wiring
- [ ] B-5: voice loop e2e — feed known WAV at audio graph, assert STT result lands on orchestrator
- [ ] B-6 (stretch): TTS tier-2 Orpheus — gated on ~6GB HuggingFace weight download; currently degrades to tier-1

## Track C — vision (~1 day)

- [ ] `CameraCapture`: implement `AVCapturePhotoCaptureDelegate` conformance + actual `capturePhoto(...)` call. Currently allocated but never invoked; returns 1×1 black JPEG.
- [ ] `frameStream(forPresence:)` — replace `AsyncStream { cont.finish() }` with delegate-yielded continuation
- [ ] HUD camera button — emit `BusInbound.frameAttachRequested`. Currently doesn't exist; `frameAttachRequested` has zero JS-side emitters
- [ ] T2 sidecar (`VllmMlxSidecar`) — currently `t2Provider: t1` is hardcoded
- [ ] `FrameAttachController.confirmSend(...)` — orphaned, has zero non-test callers
- [ ] Real-hardware vision integration test (XCTSkipIf no camera)

## Track D — memory (~3 days)

- [ ] Build custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1`. Codesign nested. Bundle.
- [ ] Bundle `vec0.dylib` (currently `Resources/PLACEHOLDER.txt`)
- [ ] Remove `installMemory` early-return cascade so coordinator + extractor construct even on vec init failure
- [ ] Register `SearchMemoryTool` + `ForgetFactTool` with `mcpRuntime` (currently the agent has no way to query memory)
- [ ] Fix `MemoryExtractionOrchestrator.swift:84` — `priorFacts: []` hardcode means UPDATE/supersede never fires
- [ ] Pull local Ollama models (nomic-embed-text + qwen2.5-coder:32b)
- [ ] End-to-end "remember Brutus" regression scenario

## Cross-cutting

- [ ] **BLOCKER-INT-1** — replace `NoopBusGateway` at `AppDelegate.swift:467` so tool-call cards reach HUD
- [ ] **F-A2-01** — `WebviewBridgeOutboundTests:80` stale `JarvisBusWorld` assertion (asserts retired world name)
- [ ] **Test pyramid health** — 5 explicit `XCTAssertTrue(true)` tautologies; multiple rubber-stamp tests asserting source literal == test literal. Audit report has the list at `.planning/audit-2026-05-03/tests-audit.md`.
- [ ] Phase F1 — top-level IntegrationTests target (the structural fix; one cold-launch e2e test would catch INT-1/2/3 + F-E-RACE-1/FK-1/WIRE-1)
- [ ] Phase F2 — `scripts/check-no-leftover-stubs.sh` linter (catches "Replaced in 0X-0Y" rot)

## Knowledge graph / docs hygiene

- [ ] REQUIREMENTS.md traceability table is all `[ ]` despite ~70 of 79 being satisfied per phase SUMMARY frontmatters. Reconcile in one sweep at milestone close.
- [ ] `.planning/AUDIT-AND-FIX-PLAN.md` — Phase B3 (`/gsd-validate-phase 1..9`) still deferred
