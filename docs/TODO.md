# TODO

Live triage list. Higher up = higher priority. Move done items to a dated archive section if the file gets long.

## ▶ TOP — Architectural pivot to API-first (2026-05-07)

**Authoritative handoff:** `.planning/architecture/HANDOFF-2026-05-07.md`. Read it before any work in the next session.

- [ ] **Next session:** dispatch the 6-agent design swarm per the handoff. Goal: `JARVIS-API-DESIGN.md` v1.0 + test contract + migration plan, implementation-ready by 2026-05-07T23:59 local.
- [ ] After v1.0 lock: cross-AI peer review (GPT-5 Pro / Gemini 2.5 Pro / fresh Opus instance) — likely tomorrow.
- [ ] After cross-AI review: begin migration per `JARVIS-API-MIGRATION-PLAN.md`. Each migration step gates on the harness staying green.

**Until the API is locked, DO NOT fix individual bugs piecemeal** — they re-scope against the new contract.

## Carry-forward bugs (re-scope against new API)

Live evidence collected during 2026-05-07 user testing. All re-scope against the new API contract — do NOT fix piecemeal in the next session.

- [ ] B-02 — Conversation continuity broken (prior turn context lost across turns)
- [ ] B-03 — HUD camera button click does nothing
- [ ] B-04 — Voice input dead (wake-word + STT silent)
- [ ] B-05 — TTS silent (text replies not spoken)
- [ ] B-06 — Chat panel doesn't auto-scroll
- [ ] B-07 — Voice Log menu item missing (Plan 10-05 deferred)
- [ ] B-08 — `get_self_state` correct ID but Claude paraphrases as "Opus 4.5" — minor

## Substrate fixes shipped 2026-05-07

- [x] B-01a (Plan 10-02b): tool catalog enumeration — `availableTools:` no longer hardcoded `[]` (`e0c0310`)
- [x] B-01b (Plan 10-02c): dispatch routing — `InProcessAwareToolDispatcher` composite routes in-process tools (`1b7fb81`)
- [x] Live-verified at HEAD `1b7fb81`: real device names + real `tool_use`/`tool_result` round-trips for `get_active_audio_route` / `get_time` / `get_self_state`

## Phase 10 status at handoff

- [x] 10-01: 4 self-knowledge MCP tools — AC-01..04 PASS
- [~] 10-02: system prompt preamble — AC-06 PASS; AC-05 retroactively PASS via 10-02b/c live verification (SUMMARY flip pending)
- [x] 10-02b: B-01a substrate fix
- [~] 10-02c: B-01b substrate fix shipped; SUMMARY missing
- [ ] 10-03 / 10-04 / 10-05: DEFERRED — re-scope against new API after design lock

## Loose ends (housekeeping; not blockers for swarm)

- [ ] Flip Plan 10-02 AC-05 from FAIL → PASS in `10-02-SUMMARY.md` (live evidence: HEAD `1b7fb81`)
- [ ] Author `10-02c-SUMMARY.md` (only PLAN exists)
- [ ] `stash@{0}` triage — Voice Log / camera / DevOverlay scaffolding from 2026-05-06; defer until Plan 10-05 re-scoped

---

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

## Track D — memory (code-work closed 2026-05-04)

- [ ] D-5 (deferred — needs user environment work): build custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1`. Skeleton at `scripts/build-sqlite-with-extensions.sh`; pin SQLite version + SHA256 + codesign identity, then run.
- [ ] D-6 (deferred — needs user environment work): bundle `vec0.dylib`. Skeleton at `scripts/fetch-sqlite-vec.sh`; pin sqlite-vec tag + SHA256, then run.
- [x] D-1: Remove `installMemory` early-return cascade so coordinator + extractor construct even on vec init failure (`75a10be`)
- [x] D-2: Register `SearchMemoryTool` + `ForgetFactTool` with `mcpRuntime` (`707c45b`)
- [x] D-3: Fix `MemoryExtractionOrchestrator` `priorFacts: []` hardcode — UPDATE/supersede now fires (`51750c1`)
- [ ] D-7 (deferred — needs user environment work): pull local Ollama models — `ollama pull nomic-embed-text` + `ollama pull qwen2.5-coder:32b`.
- [x] D-4: End-to-end "remember Brutus" regression scenario with fakes (`c3bd0a5`)

## Cross-cutting

- [x] **BLOCKER-INT-1** — replace `NoopBusGateway` at `AppDelegate.swift:467` so tool-call cards reach HUD (`ad93dac`)
- [x] **F-A2-01** — `WebviewBridgeOutboundTests:80` stale `JarvisBusWorld` assertion fixed; now asserts `WKContentWorld.page` (`6f6617e`)
- [x] **Test pyramid health** — 5 `XCTAssertTrue(true)` tautologies removed/fixed per `.planning/audit-2026-05-03/tests-audit.md` (`08125a4`). HudStateEnumTests rubber-stamps left as-is (a11y labels are load-bearing).
- [ ] Phase F1 — top-level IntegrationTests target (the structural fix; one cold-launch e2e test would catch INT-1/2/3 + F-E-RACE-1/FK-1/WIRE-1)
- [x] Phase F2 — `scripts/check-no-leftover-stubs.sh` linter (catches "Replaced in 0X-0Y" rot) (`5cd46c9`)

## Audit-2026-05-04 P0-P2 closure (2026-05-04 afternoon)

- [x] P0 sweep (small fixes + 3 doc rewrites) (`14cff7b`, `6ce94a7`, `7a72ee6`, `26f5ae3`)
- [x] P1+P2 fixes — Voice correctness + cross-cutting cleanup (`f19657a`, `81357ca`, `e606c63`, `e8bbbcf`, `11cb659`, `a4f7666`, `263705d`)
- [x] P2-14 — test seam visibility cleanup (Voice 4 seams `public`→`internal`, MCP 2 seams `public`→`@_spi(Testing) public`) (`57847f2`)
- [x] P2-15 — Mock/Fake/Stub naming convention documented in CLAUDE.md §"Test naming conventions" + 15 worst-mismatch stragglers renamed (`f9cd25d`)
- [x] P3-18 / security LOW-3 — `scripts/check-applescript-confirmation.sh` defense-in-depth grep gate (verified catches regression) (`2d9a25a`)

## Knowledge graph / docs hygiene

- [ ] REQUIREMENTS.md traceability table is all `[ ]` despite ~70 of 79 being satisfied per phase SUMMARY frontmatters. Reconcile in one sweep at milestone close.
- [ ] `.planning/AUDIT-AND-FIX-PLAN.md` — Phase B3 (`/gsd-validate-phase 1..9`) still deferred
