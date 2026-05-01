# Roadmap: Jarvis

**Created:** 2026-04-22
**Granularity:** standard
**Core Value:** An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

**v1 definition:** "Usable Jarvis" — week-one skeleton + full voice loop + vision first pass + memory first pass. ScreenCaptureKit, multi-panel HUD, broader tool catalog stay in v2.

**Phase structure derivation:** Dependency-DAG from `research/SUMMARY.md`, converged through four audit rounds. Critical paths are (A) P1 → P2 → P3 (bus spine) and (B) P1 → P4 → P5 (agent spine), joining at P6. P3 and P5 can run in parallel after their inputs clear. P7 depends on P4. P8 depends on everything.

**Coverage:** 78 / 78 v1 requirements mapped.

---

## Phases

- [ ] **Phase 1: Foundations** — Xcode project, entitlements pair, shell scaffolding, codesign skeleton, Keychain, scripts
- [ ] **Phase 2: Bus** — Typed JSON message bus with versioned handshake and schema-drift prevention
- [ ] **Phase 3: HUD** — React 19 + R3F 9 particle ring with seven states driven by `HudStateCoordinator`
- [ ] **Phase 4: Agent Core** — `LLMProvider` protocol, SSE/NDJSON decoders, `AgentOrchestrator`, ReplayLog + DevOverlay start landing here
- [ ] **Phase 5: MCP** — Official MCP Swift SDK, three helper `.app` bundles, confirmation broker, sanitize pipeline
- [ ] **Phase 6: Voice** — Wake word + VAD + STT + TTS with canonical audio-graph teardown and barge-in
- [ ] **Phase 7: Memory + Vision** — SQLite + FTS5 + sqlite-vec, mem0-style extraction, webcam + Vision presence (signal-only)
- [ ] **Phase 8: Hardening** — Injection corpus, fixture corpora, replay-roundtrip oracle, eval matrix gates shipping
- [ ] **Phase 9: Orchestrator Wiring** — Instantiate `AgentOrchestrator` in `AppDelegate`; close INT-07-01..04 cross-phase dispatch deferrals (memory extraction, vision dispatch, presence-aware prompt, frame-attach) plus the `NullOrchestratorAdapter` voice dead-end

---

## Phase Details

### Phase 1: Foundations

**Goal**: A cold-launched Release build of the bare Jarvis shell runs on a fresh Apple Silicon Mac without JIT crash, with all entitlements, TCC prompting plumbing, codesign layout, and configuration substrate in place.

**Depends on**: Nothing (greenfield)

**Requirements** (17): SHELL-01, SHELL-02, SHELL-03, SHELL-04, SHELL-05, SHELL-06, AGENT-05, MCP-05, MCP-06, OBS-05, OBS-06, SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-08

**Success Criteria** (what must be TRUE):
  1. A Release-signed archive cold-launches on a fresh Apple Silicon Mac with Hardened Runtime + `com.apple.security.cs.allow-jit` + `com.apple.developer.speech-recognition-assets` + `NSSpeechRecognitionAssetsUsageDescription` all present; entitlement-grep post-build phase fails the build if any is missing.
  2. Scaffold-time verification: removing `com.apple.developer.speech-recognition-assets` from a Release archive and cold-launching causes `SFSpeechErrorCode.assetUnavailable` to fire in STT init — confirming the entitlement is load-bearing (per RESEARCH-DELTAS SpeechAnalyzer section).
  3. The user can bind a global hotkey via a first-launch shortcut-recorder UI; Input Monitoring TCC denial surfaces a HUD banner with a System Settings deep link and falls back to local-monitor-only degraded mode (R4-S2). Silent no-op on denial is not acceptable.
  4. Menu-bar item is always present; borderless transparent always-on-top NSPanel summons/dismisses via the bound hotkey; `LSUIElement=YES` keeps the app out of the Dock; launch-at-login opt-in works on reboot.
  5. `Contents/Helpers/` directory layout is in place with codesign skeleton that is **deepest-first**, forbids `--deep`, disables "Code Sign On Copy", and has a post-build entitlement-grep phase (MCP-06) — even before any real MCP helpers exist.
  6. Anthropic API key round-trips through macOS Keychain via a native SwiftUI `SecureField` entry path; key is never written to disk in plaintext and never in the webview JS heap; `ollama.base_url` is constrained at config load to `127.0.0.1`/`localhost` only (AGENT-05).
  7. `LaunchSnapshot` vs `PerTurnSnapshot` config split exists (SEC-05); security-sensitive keys (`applescript.*`, tool blocklist, `ollama.base_url` host, confirmation policy) are launch-pinned and require restart to change; non-security keys apply at next `submit()`. Feature flags (OBS-05) live in one of the two snapshots, not both.
  8. Structured logs via `apple/swift-log 1.5.3+` are wired with four separate channels (agent / tools / UI / system) and a single `redact()` function covering API keys, `Authorization: Bearer`, `AKIA*`, `ghp_*` patterns (OBS-06).

**Plans:** 5 plans

Plans:
- [x] 01-01-scaffold-PLAN.md — Xcode project + four SPM package manifests + entitlements pair + Info.plist + Contents/Helpers directory skeleton (Wave 1)
- [x] 01-02-keychain-config-logging-PLAN.md — Keychain SystemKeychainStore + Config LaunchSnapshot/PerTurnSnapshot split (AGENT-05, SEC-05, SEC-08, OBS-05) + Logging four-channel multiplex + Redact 5 patterns (OBS-06) (Wave 2)
- [x] 01-03-app-shell-ui-PLAN.md — MenuBarIconController + JarvisHUDPanel + HUDBannerCoordinator + BrandColors + AppDelegate entitlement hard-block (Wave 2, parallel with 01-02)
- [x] 01-04-shell-wizard-wiring-PLAN.md — Shell package (HotkeyBinder, InputMonitoringProbe, LaunchAtLoginController, ShortcutRecorder) + first-launch Wizard + full AppDelegate wiring (Wave 3)
- [x] 01-05-codesign-entitlement-probe-PLAN.md — Build-time codesign + verify-entitlements pre/post-codesign + pbxproj linter + JarvisEntitlementProbeTests one-shot probe (MCP-05, MCP-06, SEC-03) (Wave 4)

### Phase 2: Bus

**Goal**: Swift and the WKWebView speak a versioned, strictly-typed JSON protocol with zero silent schema drift. This phase is where the R4 dominant failure mode ("schema drift across the Swift/JS boundary") is architecturally foreclosed.

**Depends on**: Phase 1

**Requirements** (5): HUD-03, HUD-04, HUD-05, HUD-06, SEC-09

**Success Criteria** (what must be TRUE):
  1. Outbound payloads from Swift reach JS via `callAsyncJavaScript(arguments:)` as primitive string arguments; no `evaluateJavaScript` string interpolation exists in the codebase (lint-enforced). String-interpolation attempts break the build (HUD-04).
  2. Two-way `BUS_PROTOCOL_VERSION` handshake runs at webview load: a version mismatch between the Swift-compiled constant and the JS-bundled constant is refused with a native `NSAlert` and the webview is not loaded (HUD-05). The mismatch path is tested, not just the happy path.
  3. `scripts/check-bus-protocol-version.sh` runs as an Xcode **pre-build** phase that reads the Swift constant and the TS constant, fails the build on mismatch, and runs a round-trip test per enum case against TS fixtures (SEC-09 / R4-A4/A5 schema drift). Messages use a `type` discriminator with hand-written `Codable` conformances and exhaustive switches (no `default` branches).
  4. High-frequency events (`audioLevel`, `tokenDelta`) coalesce through an `OutboundBatcher` at ~30 Hz; state-transition events flush immediately and bypass the batcher (HUD-06). Coalescing is verified by unit test, not just visual inspection.
  5. Inbound messages use `WKScriptMessageHandlerWithReply` (HUD-03), not the legacy handler; replies carry either `Result.success(payload)` or `.failure(error)` — no silent swallowed exceptions.

**Plans:** 4 plans

Plans:
- [x] 02-01-swift-bus-package-PLAN.md — Swift packages/Bus with hand-written Codable enums, WebviewBridge (WKScriptMessageHandlerWithReply + MainActor.assumeIsolated), Handshake state machine, 14 JSON fixtures (HUD-03, HUD-05, SEC-09) (Wave 1)
- [x] 02-02-ts-bus-package-PLAN.md — TypeScript webview/packages/bus with decodeOutbound + never-sentinel exhaustiveness, window.jarvisBus glue, 14 fixtures byte-identical to Swift, pnpm workspace root (HUD-03, HUD-05, SEC-09) (Wave 1, parallel with 02-01)
- [x] 02-03-outbound-batcher-wiring-PLAN.md — OutboundBatcher actor (~30Hz coalescer), callAsyncJavaScript real wiring, WKUserScript document-start Injection.js, AppDelegate installBus() (HUD-03, HUD-04, HUD-05, HUD-06) (Wave 2)
- [x] 02-04-build-parity-lint-PLAN.md — Build-time safety nets: check-bus-protocol-version.sh + check-no-evaluate-javascript.sh + check-bus-harness-parity.sh + preBuildScripts wiring (HUD-04, SEC-09) (Wave 2, parallel with 02-03)

### Phase 3: HUD

**Goal**: The user sees a cinematic R3F particle ring that visually and unambiguously reflects every agent state, driven only by Swift-side truth, with tool-call lifecycle surfaced as expandable chat-panel cards — never hidden behind a ring-color change alone.

**Depends on**: Phase 2

**Requirements** (6): HUD-01, HUD-02, HUD-07, HUD-08, TEXT-02

**Success Criteria** (what must be TRUE):
  1. WKWebView hosts React 19 + R3F 9 + drei 10.7 + three r184 + Zustand 5 + Vite 8; a single particle ring renders and is reactive to all seven agent states: idle, listening, thinking, speaking, awaitingConfirmation, reconfiguring, booting (HUD-01/02).
  2. `HudStateCoordinator` is `@MainActor final class` and is the **only** writer of HUD state in the entire codebase (HUD-08). State resolution follows the precedence ladder: `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`. Tests cover each precedence pair, not just the happy path.
  3. State transitions from every subsystem (orchestrator, voice controller, MCP client, confirmation broker) reach the HUD coordinator via three `for await` subscriber shims; no subsystem writes HUD state directly.
  4. Tool calls surface simultaneously as (a) ring-state shift AND (b) expandable chat-panel cards with the full lifecycle: pending → running → awaiting-approval → completed/failed (HUD-07). Hidden internal events that never reach the HUD are a test failure.
  5. Streaming tokens render into the chat panel token-by-token with tool-call cards inlined in chronological order (TEXT-02); a synthetic test stream produces byte-identical rendered output to a pre-recorded fixture.

**Plans:** 5 plans

Plans:
- [ ] 03-01-hud-state-coordinator-PLAN.md — Swift HudStateCoordinator @MainActor + precedence resolver + 3 for-await subscribers + single-writer lint (HUD-08) (Wave 1)
- [ ] 03-02-webview-r3f-scaffold-PLAN.md — webview/packages/hud with React 19.2+R3F 9.6+drei 10.7.6+three r184+Zustand 5+Vite 8; useJarvisStore + bus dispatcher (HUD-01) (Wave 1, parallel with 03-01)
- [ ] 03-03-particle-ring-shader-PLAN.md — RingMesh.tsx + GLSL shaders + 7-state uniforms + Reduce Motion fallbacks (HUD-02) (Wave 2)
- [ ] 03-04-chat-panel-streaming-PLAN.md — Chat panel components + tool-call lifecycle cards + streaming token rendering + 20-msg replay fixture (HUD-07, TEXT-02) (Wave 2, parallel with 03-03)
- [ ] 03-05-bundle-integration-PLAN.md — build-webview.sh + AppDelegate wiring + index.html load + single-writer lint activation + end-to-end smoke (HUD-01, HUD-08) (Wave 3)

**UI hint**: yes

### Phase 4: Agent Core

**Goal**: A provider-agnostic streaming agent loop runs turns end-to-end against either Claude Opus 4.7 (cloud) or Qwen 2.5-Coder 32B (local Ollama) via a single `LLMProvider` protocol, with correct SSE/NDJSON handling, per-turn injection defense, bounded channels everywhere, and observability (ReplayLog + DevOverlay + structured logs) landing as the orchestrator lands — not deferred.

**Depends on**: Phase 1 (NOT Phase 2/3 — agent core can run headless via text fixtures)

**Requirements** (14): AGENT-01, AGENT-02, AGENT-03, AGENT-04, AGENT-06, AGENT-07, AGENT-08, AGENT-09, AGENT-10, TEXT-01, OBS-01, OBS-02, OBS-07, SEC-06

**Success Criteria** (what must be TRUE):
  1. `LLMProvider` protocol accepts a **mandatory** `toolChoice: ToolChoice` parameter; the cap-recovery turn (budget exceeded) correctly passes `.none` which serializes to Anthropic `{type:"none"}` and to Ollama drop-`tools`-array (AGENT-07 / R4-L1). A test asserts zero `.toolUseRequested` events on the recovery turn; this test was explicitly missing pre-R4.
  2. `AnthropicProvider` streams `claude-opus-4-7` via URLSession + hand-rolled SSE. Every request carries `anthropic-beta: extended-cache-ttl-2025-04-11` header AND every `cache_control` block explicitly sets `ttl: "1h"` (AGENT-02). SSE decoder handles: empty `input_json_delta` skipped, `message_stop` as canonical close (not `message_delta`), `ping` swallowed, `stop_reason: "refusal"` first-class, `thinking_delta` routed to its own event case, and mid-delta disconnect emits `partial_tool_use_at_disconnect` (AGENT-03). A pre-recorded SSE fixture corpus byte-replays through the decoder and produces the expected `LLMEvent` stream.
  3. `OllamaProvider` streams `qwen2.5-coder:32b` via `/api/chat` NDJSON; decoder emits `.toolUseRequested` whenever `tool_calls` is seen on a chunk — **never** gates on `done: true` (AGENT-04). A separate `/v1/chat/completions` SSE decoder is implemented behind a feature flag. Qwen3/3.5 are NOT exposed as opt-in baselines (RESEARCH-DELTAS D3).
  4. `AgentOrchestrator` actor implements `submit`, `cancelAndSubmit`, and `SubmitOutcome { ran, superseded, rejected }` as the sole displacement primitive (AGENT-06). Parallel tool calls, error results, and mid-stream disconnection never lose turn state. `stream_truncated` retries are bounded at 1/turn; second truncation is terminal `.providerError`; retry turns get a fresh `turnId` with `retry_of` + re-snapshot + reset tool-call budget (AGENT-09).
  5. Per-turn random `turnNonce` wraps untrusted content with paired open/close tags; the nonce is generated in Swift and **never crosses to the webview**; tag-like substrings in tool results are pre-stripped before wrapping (SEC-06). An injection-attempt corpus entry is in place even in P4; full 20+ corpus lives in P8.
  6. Tool-result content capped at 8 KB with a truncation marker inserted in model-facing history; the full blob writes to the replay log (AGENT-08). The cap defends against Opus 4.7's ~1.35x tokenizer inflation.
  7. Bounded `AsyncChannel(capacity: N)` exists at **every** inter-subsystem seam (AGENT-10). Replay channel capacity is 2048 with drop-oldest policy for `tokenDelta` **only** — `toolCall`, `turnEnd`, `reconfiguring`, and `confirmation` events are never dropped. A load test exercises the drop policy.
  8. The user can type into the HUD chat panel and receive streamed tokens back with identical tool-call/HUD-state behavior to voice (TEXT-01); end-to-end round-trip works headless via a text fixture.
  9. Observability lands with the orchestrator, not after: DevOverlay toggle shows current state, last 5 tool calls (inputs + outputs), context token count, per-turn latency breakdown, cache creation vs read tokens (OBS-01). Every turn writes to a local SQLite replay file with nothing-masked bytes modulo row_id/session_id/turn_id/tool_use_id/message_id/ts/monotonic_ns/turn_nonce (OBS-02). Orphan-turn detection runs at startup via `meta.crash_count` + "last event ≠ turn_end" query and flags crashed turns with a recovery marker (OBS-07).

**Plans:** 5 plans

Plans:
- [ ] 04-01-llm-provider-anthropic-PLAN.md — LLMProvider protocol + LLMEvent + BoundedAsyncChannel + AnthropicProvider URLSession+SSE decoder with 1h cache TTL header (Wave 1; AGENT-01, AGENT-02, AGENT-03, AGENT-07, AGENT-10)
- [ ] 04-02-ollama-provider-PLAN.md — OllamaProvider /api/chat NDJSON (tool_calls-on-sight) + /v1/chat/completions SSE behind flag + drop-tools-array on .none (Wave 2; AGENT-04, AGENT-07)
- [ ] 04-03-replay-log-PLAN.md — packages/Replay with hand-rolled SQLite WAL schema + ReplayLog batched writes + OrphanDetector + TokenDeltaDropOldestChannel (Wave 2, parallel with 04-02; OBS-02, OBS-07, AGENT-10)
- [ ] 04-04-orchestrator-PLAN.md — AgentOrchestrator actor with submit/cancelAndSubmit + stream_truncated retry + cap-recovery + SEC-06 turnNonce injection defense (Wave 3; AGENT-06, AGENT-07, AGENT-08, AGENT-09, SEC-06)
- [ ] 04-05-devoverlay-text-e2e-PLAN.md — DevOverlay SwiftUI surface + DevSnapshotEmitter + TEXT-01 headless end-to-end + AGENT-10 channel-topology load test (Wave 4; OBS-01, AGENT-10, TEXT-01)

### Phase 5: MCP

**Goal**: The three starter tools (`get_time`, `get_clipboard`, `run_applescript`) execute through the official MCP Swift SDK with correct helper codesigning, per-helper TCC identity, confirmation gating that never uses a webview modal, and a sanitize pipeline that defends the inbound boundary before tool results reach model-facing history.

**Depends on**: Phase 4

**Requirements** (10): AGENT-11, MCP-01, MCP-02, MCP-03, MCP-04, MCP-07, MCP-08, MCP-09, SEC-07

**Success Criteria** (what must be TRUE):
  1. MCP client uses `modelcontextprotocol/swift-sdk v0.12.0` (MCP-01). Three helpers (`mcp-time`, `mcp-clipboard`, `mcp-applescript`) ship as separately codesigned nested `.app` bundles under `Contents/Helpers/<Name>.app/`, each with its own Info.plist + entitlements + per-helper TCC identity. **Only `mcp-applescript` holds `com.apple.security.automation.apple-events`** (MCP-05 wired in P1, verified here via post-build grep that fails the build on drift).
  2. `get_time` returns current time; `get_clipboard` returns clipboard content AND refuses pasteboards containing `NSPasteboardTypeFileURL` regardless of string content (MCP-03); `run_applescript` executes arbitrary AppleScript only after the user approves a **native-AppKit confirmation sheet on a hidden NSPanel** — never a webview modal (MCP-04). Lint rule forbids modal presentation on any `@MainActor` presentation path.
  3. `ConfirmationBroker` implements exactly four legal transitions — `.timeout` (60s), `.barge`, `.approve`, `.deny` — with late-hop transitions no-op (MCP-09). A 60s timeout on `broker.response(id)` await synthesizes a deny + logs (AGENT-11). `ToolCallStart.args` for `requiresConfirmation` tools serialize to the webview as `{awaitingApproval: true}` until after approval; raw args never leak pre-approval.
  4. Per-server restart mutex protects against helper EOF: on crash, `MCPClient` drains the continuation map with `MCPError.serverCrashed` and lazy-restarts on next call; concurrent callers share one restart (MCP-07). A crash-injection test verifies no FD leaks across 100 restart cycles.
  5. Child processes spawn through a single `ChildSpawnGate` that enforces `FD_CLOEXEC` on parent long-lived FDs plus a minimal environment (`PATH=/usr/bin:/bin` only) (MCP-08). No helper inherits the parent's env by default.
  6. Tool-result sanitize pipeline runs on every MCP-boundary byte stream in a fixed order: **sanitize → headTruncate → wrapUntrusted**, called BEFORE packing into `LLMMessage` history (SEC-07). Sanitize enforces UTF-8 validity, strips C0 controls (except `\t`), strips bidi/zero-width characters, and caps line length. Replay captures both pre- and post-sanitize bytes.

**Plans** (5 plans across 5 waves):

| Plan | Wave | Depends on | REQ-IDs | Autonomous |
|------|------|------------|---------|------------|
| `05-01-mcp-client-stdio-transport` | 1 | [] | MCP-01, MCP-07, MCP-08 | yes |
| `05-02-helpers-time-clipboard` | 2 | [05-01] | MCP-02, MCP-03 | yes |
| `05-03-helper-applescript` | 3 | [05-01] | MCP-04 (helper portion) | no (App ID capability gate) |
| `05-04-sanitize-pipeline-tool-dispatcher` | 4 | [05-01, 05-02, 05-03] | SEC-07 | yes |
| `05-05-confirmation-broker-presenter-wiring` | 5 | [05-01, 05-02, 05-03, 05-04] | MCP-04, MCP-09, AGENT-11 | yes |

Waves are sequential (W1 → W2 → W3 → W4 → W5) because the helper bundle plans (05-02, 05-03) both modify `project.yml`, so they cannot run in parallel. Plan 05-05 also closes ME-04 (Phase 4's deferred orch→replay 2048-cap live wiring) by instantiating the BoundedAsyncChannel in production AppDelegate.

### Phase 6: Voice

**Goal**: The end-to-end voice loop — "Hey Jarvis, what time is it?" → natural spoken answer — works entirely on-device with HUD state visible through idle → listening → thinking → speaking, including barge-in, push-to-talk, mute-wake-word, and the canonical audio-graph teardown that handles device changes, AEC fallback, mic re-grant, and sustained ring overflow uniformly.

**Depends on**: Phase 4

**Requirements** (14): VOICE-01, VOICE-02, VOICE-03, VOICE-04, VOICE-05, VOICE-06, VOICE-07, VOICE-08, VOICE-09, VOICE-10, VOICE-11, VOICE-12, VOICE-13, VOICE-14

**Success Criteria** (what must be TRUE):
  1. Wake-word pipeline: openWakeWord `hey_jarvis` via ONNX Runtime Swift 1.24.2+ with a ≥4-consecutive-frame threshold (~320ms hysteresis); model weights vendored with SHA-256 verification (VOICE-01). Silero VAD **v6.2.1** gates the pipeline at 512-sample/32ms chunks at 16 kHz; ORT opset-16 `silero_vad.onnx` is preferred with `silero_vad_16k_op15.onnx` as fallback (VOICE-02). Scaffold-time contract-parity probe confirms Silero v6.2.1 preserves the 512-sample/32ms/16kHz chunk contract from v5 (RESEARCH-DELTAS).
  2. STT primary is Apple `SpeechAnalyzer` / `SpeechTranscriber` on macOS 26 Tahoe (VOICE-03); WhisperKit via `argmaxinc/argmax-oss-swift v0.18.0` with model `large-v3-v20240930_626MB` is the flagged fallback (VOICE-04). Feature flag determines which path runs without a rebuild.
  3. TTS tier 1 is `AVSpeechSynthesizer` for instant sub-1-sentence confirmations and think-aloud (VOICE-05). TTS tier 2 is Orpheus via `blaizzy/mlx-audio-swift v0.1.2` with `LlamaTTSModel` + `generateStream`, in-process on Apple Silicon, no Python sidecar, behind a feature flag (VOICE-06). Scaffold-time empirical TTFA measurement lands in the 150–250 ms target range on the user's Apple Silicon Mac. `TTSEngineActor` with a serial executor prevents Metal-buffer serialization deadlock.
  4. `AVAudioEngine.isVoiceProcessingEnabled = true` is called **before any `connect` or `installTap`** — ordering is enforced by a unit test that throws if a tap installs on a node whose VPIO flag is off (VOICE-08). Post-AEC format is **probed** via `inputNode.outputFormat(forBus: 0)` — never assumed — to handle Tahoe's 24 kHz vs Sonoma's 16 kHz (VOICE-08 / R4-D4 coerce-before-rate-convert).
  5. AEC-off is a **real distinct audio-graph variant** (not a runtime config toggle); its unavailability surfaces a HUD banner "AEC unavailable; degraded-mode active" (VOICE-09). The canonical six-step teardown sequence applies uniformly across all four rebuild triggers: device change, AEC fallback, mic re-grant, sustained ring overflow (VOICE-10).
  6. TTS interrupt sequence runs atomically: cancel Orpheus producer → 10ms cosine fade-out → `stop()` → await completion handler (≤20ms) → emit `.ttsStopped`; ducking is lowered only on `.ttsStopped`, **never on `TTSEvent.finished` alone** (VOICE-11). Barge-in during `.speaking` routes through the single `cancelAndSubmit` orchestrator entry — not two separate actor hops — and re-enters `.listening` without losing turn state (VOICE-14).
  7. End-to-end "Hey Jarvis, what time is it?" produces a natural-sounding spoken answer with HUD state transitioning through idle → listening → thinking → speaking, observable without the DevOverlay (VOICE-07). Push-to-talk hold-hotkey variant (VOICE-13) and menu-bar mute-wake-word toggle (VOICE-12) both work independently: muting wake word pauses the DAG but leaves push-to-talk armed.

**Plans** (5 plans across 4 waves):

| Plan | Wave | Depends on | REQ-IDs | Autonomous |
|------|------|------------|---------|------------|
| `06-01-audio-graph` | 1 | [] | VOICE-08, VOICE-09, VOICE-10 | yes |
| `06-02-wake-word` | 2 | [06-01] | VOICE-01 | yes |
| `06-03-vad-stt` | 2 | [06-01] | VOICE-02, VOICE-03, VOICE-04 | yes |
| `06-04-tts-engine` | 3 | [06-01] | VOICE-05, VOICE-06, VOICE-11 | yes |
| `06-05-controller-wiring` | 4 | [06-01, 06-02, 06-03, 06-04] | VOICE-07, VOICE-09, VOICE-12, VOICE-13, VOICE-14 | no (HUMAN-UAT — scaffold-time empirical probes for Orpheus TTFA, Silero contract-parity, speech-recognition-assets entitlement) |

Wave 2 (06-02 + 06-03) can run in parallel — disjoint scope (`WakeWord/*` vs `VAD/*`+`STT/*`); both consume `RingBuffer` read-only; 06-01 pins all upstream deps in Package.swift so neither wave-2 plan modifies it.

**Plans**: TBD

### Phase 7: Memory + Vision

**Goal**: Conversational history persists locally, memory is extracted into durable facts with temporal validity, the agent can retrieve prior decisions, and webcam presence emits signals the agent may reference — but never triggers a turn. No user data leaves the machine for memory or vision.

**Depends on**: Phase 4

**Requirements** (10): TEXT-03, VISION-01, VISION-02, VISION-03, VISION-04, MEM-01, MEM-02, MEM-03, MEM-04, MEM-05, MEM-06, MEM-07, MEM-08

**Success Criteria** (what must be TRUE):
  1. SQLite database at `~/Library/Application Support/Jarvis/jarvis.db` runs in WAL mode with FTS5 built-in and `sqlite-vec v0.1.10-alpha.3` loaded directly via `sqlite3_enable_load_extension` + `sqlite3_load_extension` (MEM-01). `EMBEDDING_DIM = 768` is a **single shared constant** across the extraction path and the schema (MEM-02); a mismatch would silently return garbage, so a test asserts both code paths import the same symbol.
  2. Embeddings generate via `nomic-embed-text` on Ollama (MEM-03); mem0-style `ADD / UPDATE / NOOP` extraction runs after each turn, executed by local `qwen2.5-coder:32b` via Ollama. **Zero user data ever leaves the machine for memory extraction** — asserted by a network-sandbox test (MEM-04).
  3. Facts carry `valid_from` / `valid_to` timestamps (MEM-05); superseded facts are **never deleted** — history is preserved. Memory extraction runs as a background turn (`.memoryExtraction` TurnSource) on a separate orchestrator instance with a bounded job queue, and does **not** block `turnEnd` (MEM-06).
  4. The agent retrieves prior turns on request via FTS5 + vector search ("what did we decide about X?") (MEM-07). Browsable within-session conversation history renders in the chat panel; persisted turns are queryable via memory (TEXT-03). DevOverlay surfaces a "memory updated" row per ADD/UPDATE showing the fact + the extraction trigger — silent mutations are visually prevented (MEM-08).
  5. Webcam feed is available to the agent behind Camera TCC with first-use graceful-denial fallback (VISION-01); Vision framework emits face-detection / presence events as **signals only** — they are never triggers that initiate speech or turns (VISION-02). Presence-triggered auto-speak is architecturally forbidden — no code path exists to emit TTS from a presence event (VISION-03); the agent may reference presence only within a user-initiated turn.
  6. Optional single webcam frame attaches to a turn and flows to Opus 4.7 for scene understanding when the user asks (VISION-04); the attachment is user-initiated, never background-initiated.

**Plans**: TBD

### Phase 8: Hardening

**Goal**: Before v1 ships (is used daily), shipping gates are pass/fail: the injection corpus holds, replay-roundtrip produces byte-equal output modulo IDs, the eval matrix meets its bar, and every "looks done but isn't" checklist item has been exercised. This is where observability started in P4 graduates into a shipping gate.

**Depends on**: Phase 1, 2, 3, 4, 5, 6, 7

**Requirements** (2): OBS-03, OBS-04

**Success Criteria** (what must be TRUE):
  1. A replay viewer re-runs a past recorded session through the **real pipeline** deterministically; a byte-match oracle compares actual output bytes to recorded output bytes (modulo the documented ID/timestamp exclusion list from OBS-02) and flags any drift (OBS-03). Two drift categories exist: expected (model sampling nondeterminism with temperature>0) and unexpected (schema, ordering, truncation bugs); only the second fails the gate.
  2. Eval harness runs 15–25 hand-written scenarios on demand, pinned to `qwen2.5-coder:32b` for local-model eval (OBS-04). The eval matrix covers: (a) 20+ prompt-injection corpus attempts, all blocked; (b) SSE fixture corpus byte-replays cleanly through the Anthropic decoder; (c) Ollama NDJSON fixtures + a live eval against a running `qwen2.5-coder:32b`; (d) tool-cap recovery produces **zero** `.toolUseRequested` on the recovery turn (R4-L1 regression guard); (e) wake-hysteresis corpus (false-accept / false-reject rates under recorded conditions); (f) MCP crash-recovery across 100 injected helper crashes with no FD leaks; (g) device-change audio-graph rebuild across all four triggers; (h) the "looks done but isn't" checklist from SUMMARY.md passes.

**Plans** (4 plans across 3 waves):

| Plan | Wave | Depends on | REQ-IDs | Autonomous |
|------|------|------------|---------|------------|
| `08-01-replay-oracle` | 1 | [] | OBS-03 | yes |
| `08-02-corpora-curation-and-runners` | 2 | [08-01] | OBS-04 (pillars a, b, c-fixture, e) | yes |
| `08-03-live-and-integration-runners` | 2 | [08-01] | OBS-04 (pillars c-live, d, f, g) | yes |
| `08-04-checklist-runner-and-shipping-gate` | 3 | [08-01, 08-02, 08-03] | OBS-04 (pillar h + integration) | yes |

Plans:
- [x] 08-01-replay-oracle-PLAN.md — packages/Harness SPM + ReplayRunner + DriftClassifier + ExclusionList + ReplayMCPAdapter + MockLLMProvider + jarvis-eval CLI shell + TurnSource Strategy B (.replay/.evaluation cases) (Wave 1)
- [x] 08-02-corpora-curation-and-runners-PLAN.md — Injection corpus (20+ items per D-22/D-23/D-24) + SSE/NDJSON fixture corpora + capture-anthropic-sse.sh + wake-hysteresis corpus + 4 runners + 4 jarvis-eval subcommands (Wave 2, parallel with 08-03)
- [x] 08-03-live-and-integration-runners-PLAN.md — FDLeakDetector + MCPCrashRunner (D-19) + AudioGraphRebuildRunner (D-14) + ToolCapRecoveryRunner (D-21 dual assertion) + LiveOllamaRunner (D-06) + 3 subcommands; inherits P6 deferred debt (Xcode 26 launch fragility resolution + AVAudioEngine probe) per D-12/D-13 (Wave 2, parallel with 08-02)
- [x] 08-04-checklist-runner-and-shipping-gate-PLAN.md — ChecklistRunner with 7 mechanization types (D-16/D-17) + retroactive sweep authoring P1-P8 checklist.yaml manifests folding 18 scripts/check-*.sh as type:script (D-15) + scripts/shipping-gate.sh + scripts/promote-replay-session.sh (D-09) + pre-commit hook for D-07 + R4-L7 replay-suppression integration test (Wave 3)

Wave 2 (08-02 + 08-03) runs in parallel — disjoint files_modified (corpus paths under packages/Harness/Corpora/ vs runner+integration paths under packages/Harness/Sources/Harness/Runners/ + scripts/).

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundations | 0/? | Not started | - |
| 2. Bus | 0/? | Not started | - |
| 3. HUD | 0/? | Not started | - |
| 4. Agent Core | 0/? | Not started | - |
| 5. MCP | 0/? | Not started | - |
| 6. Voice | 0/? | Not started | - |
| 7. Memory + Vision | 0/? | Not started | - |
| 8. Hardening | 0/? | Not started | - |

---

## Coverage

**v1 requirements:** 78 total
**Mapped:** 78 / 78
**Unmapped:** 0

**Distribution:**
- P1 Foundations: 17
- P2 Bus: 5
- P3 HUD: 6 (includes TEXT-02 for chat-panel rendering)
- P4 Agent Core: 14
- P5 MCP: 10 (includes AGENT-11 confirmation timeout; SEC-07 sanitize runs at MCP boundary)
- P6 Voice: 14
- P7 Memory + Vision: 13 (10 MEM + VISION + TEXT-03; phase-distribution table updates from 10 to 13)
- P8 Hardening: 2 (OBS-03 replay oracle + OBS-04 eval harness — shipping gates)

Note: REQUIREMENTS.md traceability header previously reported "10 / 2" for P7/P8; the detailed mapping in that file resolves to 13 + 2. This roadmap uses the detailed mapping as source of truth.

---

## Execution Notes

- **Critical path:** P1 → P4 (agent spine) and P1 → P2 → P3 (bus spine) can progress in parallel. P5 and P6 both depend on P4. P7 depends on P4. P8 is the final integration gate.
- **Parallelization enabled** (`config.json`): P2/P3 can overlap with P4; P5 and P6 can overlap once P4 lands; P7 can start in parallel with P5/P6.
- **YOLO mode**: skip discuss-mode, auto-advance remains OFF (user reviews at phase boundaries).
- **Observability is not a P8 polish phase.** ReplayLog + DevOverlay + structured logs land in P4. The P8 harness is the shipping gate, not the introduction of observability.
- **Audit debt absorption:** AUDIT-R4's 22 HIGH + 22 MEDIUM findings are absorbed into the phases where they apply (see per-phase success criteria referencing R4-* identifiers: R4-S2 in P1, R4-L1 in P4/P8, R4-A4/A5 in P2, R4-D4 in P6). No dedicated "audit fix" phase exists.
- **Scaffold-time verifications** (must succeed before phase completion, not deferred):
  - P1: `speech-recognition-assets` entitlement load-bearing probe
  - P6: Silero v6.2.1 contract parity with v5; Orpheus empirical TTFA 150–250 ms; AEC post-format coercion on macOS 26

### Phase 9: Orchestrator Wiring

**Goal:** Instantiate `AgentOrchestrator` in production `AppDelegate`, replacing every Null/placeholder adapter with real wiring so memory extraction, vision dispatch, presence-aware system prompts, and frame-attach all run end-to-end. Closes INT-07-01..04 from `.planning/v0.12.0-MILESTONE-AUDIT.md` and the `NullOrchestratorAdapter` / `NullTTSAdapter` / `NullBusEmitterAdapter` placeholders left over from Phase 6.

**Requirements**: ME-01..05, VIS-01..07, AGENT-09 (live-dispatch verification of types implemented in earlier phases)

**Depends on:** Phase 4 (orchestrator + LLM providers), Phase 5 (MCP tool dispatcher chain), Phase 6 (voice subsystem entry points), Phase 7 (memory coordinator + vision router + frame-attach controller). Phase 8 not on the critical path — the harness ran against unit-tested types regardless of production wiring.

**Plans:** 0 plans

Plans:
- [ ] TBD (run /gsd-plan-phase 9 to break down)

**Success criteria (preview, refined during /gsd-plan-phase 9):**
1. AppDelegate constructs and holds an `AgentOrchestrator`; tool dispatcher chain from Phase 5 is the orchestrator's `toolDispatcher`.
2. `agentOrchestratorEvents()` returns the live channel; `MemoryExtractionCoordinator.start(...)` runs in production (closes INT-07-01).
3. `VisionRouter` is reachable from a turn — either as a `ToolDispatcher` decorator or via an explicit post-response evaluation hook (closes INT-07-02; architecture decided in /gsd-discuss-phase 9).
4. `ContextBuilder.installPresence` actually mutates per-turn system prompt per D-10; presence bus events show up in the live model prompt (closes INT-07-03).
5. `FrameAttachController` instantiated; constructor signature drift (07-06 SUMMARY surprise) reconciled (closes INT-07-04).
6. Voice's `NullOrchestratorAdapter` replaced with a real adapter forwarding to `orchestrator.submit(_:)` / `cancelAndSubmit(_:)`; HUD/banner surface `SubmitOutcome.rejected` reasons.
7. Text-input path also routes through the orchestrator (closes the symmetric Phase 6 dead-end).
8. App build green, full SPM test suite green, full Harness suite green.

---

*Roadmap defined: 2026-04-22*
