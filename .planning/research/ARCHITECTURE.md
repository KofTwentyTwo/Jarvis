# Architecture Research — Jarvis (Native Swift + WKWebView + R3F + MCP + Voice)

**Project:** Jarvis personal macOS AI assistant (hybrid Swift/SwiftUI host + WKWebView R3F HUD)
**Mode:** Ecosystem — Architecture dimension
**Researched:** 2026-04-21
**Confidence:** HIGH on architecture tier (four rounds of whiteroom audit + 2026-current Swift concurrency / MCP lifecycle patterns both converge on the same answers). MEDIUM on a handful of voice/audio invariants where macOS 26 Tahoe behavior is new enough that contracts will only firm up at scaffold time.

---

## Top-line findings

- **The top-level shape is correct and does not need rearchitecture.** R3 decisions are 2026-standard: `AsyncChannel` for back-pressure, `actor` + `@MainActor final class` for the single-writer HUD coordinator, single `.toolUseRequested` event at the LLMProvider boundary, MCP stdio child-process lifecycle with per-server restart mutex, non-blocking confirmation sheet, canonical six-step audio-graph teardown.
- **R4's 22 HIGH + 22 MEDIUM are almost entirely wiring, not architecture.** 36 of 44 findings are mechanical schema/wiring propagation of decisions R3 already made (add TS mirror case, add to §1 script list, wire scheme into CI). 6 are ordering-contract completions at already-identified seams. **Only 2 are genuinely new architecture-tier gaps.**
- **The two real architecture-tier gaps** are (a) **R4-S2 Input Monitoring TCC envelope** for `NSEvent.addGlobalMonitorForEvents(.keyDown)` — same shape as the mic TCC gap R2-V10 closed, just reopened for hotkey; and (b) **R4-L1 tool-choice policy never landed** — zero occurrences of `tool_choice` in rev 3, meaning cap-recovery "one more call" can silently request another tool and defeat the cap.
- **Build order is dependency-driven, not phase-driven.** Two critical paths: **(A) message-bus spine** (Xcode/Hardened Runtime → WKWebView host → typed bus with BUS_PROTOCOL_VERSION handshake + callAsyncJavaScript primitive payload → R3F HUD). **(B) agent spine** (LLMProvider headless → AgentOrchestrator + MCPClient + 3 helpers → ConfirmationBroker). Voice attaches after B; observability grows alongside every step from B onward, not as a final polish phase.
- **`HudStateCoordinator` is the keystone fix.** The rev-3 decision to make it a `@MainActor final class` (not an `actor`, which Swift cannot bind to MainActor) with a precedence ladder `awaitingConfirmation > speaking > listening > thinking > idle > booting` and three `for await` subscribers (agent, voice, confirmation) is what resolves the R1 H-A3 "two writers" race cleanly and is the pattern any new state source should slot into.

---

## System overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ macOS host process — Jarvis.app (LSUIElement, non-sandboxed)                 │
│                                                                              │
│ ┌─── AppDelegate (single owner of startup barrier chain — R3-S2) ─────────┐ │
│ │                                                                          │ │
│ │  MenuBar    JarvisPanel           VoiceController (actor)                │ │
│ │  NSStatus   (nonactivating,       • openWakeWord + Silero VAD            │ │
│ │  Item       borderless,           • SpeechAnalyzer (primary STT)         │ │
│ │             .statusBar level)     • WhisperKit (fallback STT)            │ │
│ │              ┌────────────┐       • AVSpeechSynthesizer (TTS tier-1)     │ │
│ │              │ WKWebView  │       • Orpheus via mlx-audio-swift (tier-2) │ │
│ │              │ (R3F HUD)  │       • AVAudioEngine (isVoiceProc=true)     │ │
│ │              └─────┬──────┘                                              │ │
│ │                    │                                                      │ │
│ │       ┌── WebviewBridge ──┐                                              │ │
│ │       │ WKScriptMsgHandler │                                              │ │
│ │       │   WithReply        │                                              │ │
│ │       │ callAsyncJavaScript│                                              │ │
│ │       │   (args: primitive)│                                              │ │
│ │       │ OutboundBatcher    │                                              │ │
│ │       │   @ ~30Hz          │                                              │ │
│ │       │ BUS_PROTOCOL_      │                                              │ │
│ │       │   VERSION handshake│                                              │ │
│ │       └───┬────────────────┘                                              │ │
│ │           ▼                                                               │ │
│ │       ┌──────────────────────────────────────────┐                       │ │
│ │       │ HudStateCoordinator (@MainActor class)   │◄── VoiceController    │ │
│ │       │ SINGLE WRITER for HudState               │◄── ConfirmationBroker │ │
│ │       │ Precedence:                              │◄── AgentOrchestrator  │ │
│ │       │   awaitingConfirmation > speaking        │     (three for-await  │ │
│ │       │   > listening > thinking > idle          │      loops; resolves  │ │
│ │       │   > booting > reconfiguring*             │      precedence;      │ │
│ │       └────────────┬─────────────────────────────┘      one bridge.send) │ │
│ │                    │                                                      │ │
│ │    Hotkey (global  │                                                      │ │
│ │    + local monitor │                                                      │ │
│ │    pair; R4-S2 TCC │                                                      │ │
│ │    envelope gap)   ▼                                                      │ │
│ │       ┌────────────────────────────────────────┐                          │ │
│ │       │ AgentOrchestrator (actor)              │                          │ │
│ │       │  • submit / cancelAndSubmit            │                          │ │
│ │       │    → SubmitOutcome {ran, superseded,   │                          │ │
│ │       │                     rejected}          │                          │ │
│ │       │  • AsyncChannel<Event> (.systemReady   │                          │ │
│ │       │    first event suspends until HUD      │                          │ │
│ │       │    coordinator pumps — startup barrier)│                          │ │
│ │       │  • LaunchSnapshot vs PerTurnSnapshot   │                          │ │
│ │       └──┬─────────────┬──────────────┬────────┘                          │ │
│ │          ▼             ▼              ▼                                   │ │
│ │    ┌────────┐    ┌──────────┐   ┌──────────────┐                          │ │
│ │    │LLMProv │    │MCPClient │   │ConfirmBroker │                          │ │
│ │    │protocol│    │ (actor,  │   │(non-blocking │                          │ │
│ │    │ •Anth  │    │ per-     │   │ sheet on     │                          │ │
│ │    │ •Olla  │    │ server   │   │ hidden       │                          │ │
│ │    │ stream │    │ restart  │   │ NSPanel;     │                          │ │
│ │    │ w/ tool│    │ mutex    │   │ 60s timeout; │                          │ │
│ │    │ Choice │    │ R3-A13)  │   │ native UI    │                          │ │
│ │    │ (R4-L1)│    │          │   │ for destruc- │                          │ │
│ │    └────┬───┘    └────┬─────┘   │ tive only)   │                          │ │
│ │         │             │         └──────────────┘                          │ │
│ │         ▼             ▼                                                   │ │
│ │       ReplayLog (actor, AsyncChannel(2048), drop-oldest tokenDelta only)  │ │
│ │       SQLite WAL + FTS5 + sqlite-vec                                      │ │
│ │                                                                           │ │
│ └───────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  Jarvis.app/Contents/Helpers/ (per-helper TCC identity, nested .app bundles) │
│     mcp-time.app     mcp-clipboard.app     mcp-applescript.app               │
│     (stdio NDJSON JSON-RPC 2.0; statically linked week-one; per-child        │
│      FD_CLOEXEC on parent long-lived FDs)                                    │
└──────────────────────────────────────────────────────────────────────────────┘
      │
      ├─► api.anthropic.com  (HTTPS; Opus 4.7; cache_control ttl=1h explicit)
      ├─► 127.0.0.1:11434    (Ollama; /api/chat native NDJSON preferred)
      └─► (no other network — voice stack is all-local)
```

---

## Component responsibilities

| Component | Responsibility | Actor / isolation |
|-----------|----------------|-------------------|
| **AppDelegate** | Sole owner of startup barrier chain (§17.1); hotkey registration; activation-policy; panel lifecycle. `@main struct JarvisApp: App` wraps `Settings { EmptyView() }` only — SwiftUI lifecycle is insufficient under `LSUIElement=YES`. | MainActor |
| **JarvisPanel** | Borderless, transparent, always-on-top HUD window. `canBecomeKey=true, canBecomeMain=false, .nonactivatingPanel \| .borderless`, level `.statusBar`. Hidden at launch; content view hosts WKWebView directly (not via SwiftUI representable). | MainActor |
| **WKWebView + R3F HUD** | Pure rendering layer. Reacts to events from the bus; no truth lives here. Hardened Runtime `allow-jit` entitlement is load-bearing (JS JIT crashes without it in Release). | WebKit content world |
| **WebviewBridge** | Typed JSON message bus. `WKScriptMessageHandlerWithReply` inbound; `callAsyncJavaScript(arguments:)` outbound with JSON payload as primitive string (never interpolated). `OutboundBatcher` coalesces audioLevel/tokenDelta at ~30 Hz. Two-way `BUS_PROTOCOL_VERSION` handshake with refusal on mismatch. Hand-written `Codable` with `type` discriminator (synthesized Codable for enums-with-associated-values does NOT match TS shape). | MainActor |
| **HudStateCoordinator** | **Single writer** for `HudState`. Subscribes to AgentOrchestrator.events, VoiceController.events, ConfirmationBroker.events via `for await`; resolves against precedence ladder. Resolves the R1 H-A3 two-writer race. | `@MainActor final class` |
| **AgentOrchestrator** | Turn loop; tool-call dispatch; retry policy; parallel tool-call fan-out/serialize; cancellation. `SubmitOutcome { ran, superseded, rejected }` for displacement. `cancelAndSubmit` is single atomic entry for voice barge-in (two-call pattern is explicitly incorrect — R3-A3). Publishes semantic events only (never HudState). | `actor` |
| **LLMProvider** | Provider-agnostic streaming. Single `.toolUseRequested(id, name, arguments)` at the boundary collapses Anthropic's per-fragment `input_json_delta` stream and Ollama's atomic `tool_calls` array into one contract. `.toolUseAssembling` is optional UI progress behind a flag. Must take `toolChoice: ToolChoice` parameter (R4-L1 gap). | Stateless; background cooperative executor |
| **MCPClient** | JSON-RPC 2.0 over stdio NDJSON per helper. Per-server restart mutex (inner actor with in-flight `Task` slot) — concurrent `callTool` paths await the same restart, never spawn duplicates (R3-A13). On child EOF, drain continuation map with `MCPError.serverCrashed`; lazy restart on next call. | `actor` |
| **MCP helpers** | Separately codesigned Hardened-Runtime app bundles under `Contents/Helpers/`. Own `CFBundleIdentifier`, own entitlements, own LaunchServices identity → own TCC prompts. `mcp-applescript` is the sole holder of `com.apple.security.automation.apple-events` (R3-S5 removed it from main app; post-build verification asserts). Statically linked week-one (R3-S1) to avoid `@rpath` failures. Nested `.app` layout, not flat `Contents/MacOS/`. Codesign ordering inside-out, never `--deep`. | Separate processes |
| **VoiceController** | Wake → VAD → STT → agent → TTS pipeline. Owns audio-graph lifecycle with canonical six-step teardown applied uniformly to all four rebuild triggers (device change, AEC fallback, mic re-grant, sustained ring overflow). AEC-on and AEC-off are **distinct graph variants** with their own invariants, not a config knob. Publishes `VoiceEvent` stream (R4-A5: enum must be defined). | `actor` + RT audio thread bridged via `TPCircularBuffer` SPSC |
| **ConfirmationBroker** | Four legal transitions: `.timeout` (60s), `.barge`, `.approve`, `.deny`. Non-blocking sheet on hidden `NSPanel` (never modal — modals park MainActor and break barge-in cancel). Sole transition authority; hops once to `@MainActor ConfirmationPresenter`; late hops no-op. | `actor` + MainActor presenter |
| **ReplayLog** | SQLite WAL + FTS5 + sqlite-vec. Bounded `AsyncChannel(capacity: 2048)`. Drop-oldest for `tokenDelta`; `toolCall*`/`turnEnd`/`reconfiguring`/`confirmation_*` NEVER dropped. FDs opened with `O_CLOEXEC` so they don't leak to MCP children. Orphan-turn detection via `meta.crash_count` + "last event != turn_end" query. | `actor` |
| **Keychain + Config + FeatureFlags** | API keys in Keychain (`com.kingsrook.jarvis.anthropic`); `UserDefaults` for trivial prefs; `config.json` for rest. **`LaunchSnapshot`** (security-relevant: applescript.*, tool blocklist, `ollama.base_url` allowlist constrained to `127.0.0.1`/`localhost` at load, confirmation policy) requires restart. **`PerTurnSnapshot`** (non-security: provider, ttsTier, sttUseWhisperKit) snapshotted at `submit()` entry. API-key entry is native `SecureField` sheet; webview never holds the key on JS heap (R3-Sec1). | Core module |

---

## Recommended project structure

Rev-3 IMPL layout is correct. The R4 fixes are:

```
scripts/                          ** R4-B1: six scripts, not two **
├── build-webview.sh              # content-hash sentinel (pnpm-lock.sha256), NOT -nt timestamp (R3-B9)
├── codesign.sh                   # renamed from sign-and-notarize.sh; --notarize flag (R3-S15)
├── check-plist-parity.sh         # Xcode build phase, not CI-only (R3-B4)
├── verify-models.sh              # ONNX SHA-256 verification
├── verify-fixtures.sh            # voice fixture SHA-256 verification
├── check-bus-protocol-version.sh # Xcode pre-build phase; enforces TS/Swift parity (R3-B18/R4-B8)
└── prime-tcc.sh                  # Tier-B TCC priming on new dev machine (R3-B8)
```

Other layout rationale (unchanged from rev 3 but worth pinning):
- `packages/` as local SPM modules separates pure logic from AppKit; `Agent` depends on `Voice.TTSEngine` *protocol*, not impls, so `NullTTSEngine` substitutes in eval
- `mcp-servers/` at top level (peer targets of main app) for clean codesign ordering
- `webview/` outside `packages/` with pnpm + Vite toolchain, built to `dist/`, copied into `Contents/Resources/webview/`
- `config/{Shared,Debug,Release}.xcconfig` in §1 (R3-B13)

---

## Architectural patterns (core seven)

**1. Single-writer state coordinator with precedence ladder.** `HudStateCoordinator` is the only callsite for `bridge.send(.hudState)`. Every subsystem publishes *intent events*; coordinator resolves against precedence. 2026-standard because multiple event sources → visible UI state always produces races without it.

**2. Provider-agnostic event stream with single tool-call event.** Single `.toolUseRequested(id, name, arguments)` at `LLMProvider` boundary collapses Anthropic's streaming tool-use triple and Ollama's atomic `tool_calls` array. Must round-trip `ToolCall { providerId: String, localId: UUID }` both ways or Anthropic 400s on `tool_result`. R4-L1 gap: `toolChoice: ToolChoice` parameter is missing — required for cap-recovery to set `.none` (Anthropic: `tool_choice: {type:"none"}`; Ollama: drop tools array).

**3. Per-server child-process actor with restart mutex.** `MCPClient` actor holds per-helper `MCPServerHandle`; crash → drain continuations with `MCPError.serverCrashed`; concurrent `callTool` during recovery serialize through in-flight `Task` slot (R3-A13). Matches 2026 MCP spec: spawn → initialize handshake with timeout → on failure reset_server → on sustained unreachability degrade with `McpDegradedReport`. Per-helper TCC identity is a real security win.

**4. Typed JSON bus with discriminator + two-way versioned handshake.** Hand-written `Codable` emits `{"type":"hudState","state":"idle"}` shape (synthesized form does NOT match TS). Outbound via `callAsyncJavaScript(arguments: ["payload": jsonString])` — never interpolated. `BUS_PROTOCOL_VERSION` two-way handshake refuses mismatched bundles with native `NSAlert` (one-way handshakes are useless — user never sees `console.error`). OutboundBatcher @ ~30 Hz for high-frequency events; immediate flush for state transitions.

**5. Canonical graph-teardown sequence for any audio rebuild.** VoiceController exposes exactly one six-step sequence applied to all four triggers: publish `.reconfiguring` → cancel converter → cancel wake-word DAG → finalize STT with named reason → cancel TTS via V4 fade → stop engine, rebuild, re-pre-warm SpeechAnalyzer + Orpheus (re-probe format on AEC-fallback only — R4-V1). AEC-on and AEC-off are distinct graph variants.

**6. Bounded back-pressure channels at every inter-subsystem seam.** 2026-standard per SE-0406 and the `MultiProducerSingleConsumerAsyncChannel` pitch: no unbounded buffers at actor seams.

| Seam | Primitive | Capacity | Overflow policy |
|------|-----------|----------|-----------------|
| Orchestrator → ReplayLog | `AsyncChannel<ReplayEvent>` | 2048 | Drop `tokenDelta` oldest; `toolCall*`/`turnEnd`/`reconfiguring`/`confirmation_*` NEVER dropped |
| Orchestrator `.textDelta` → TTS segmenter | unbounded fan-out | — | HUD never back-pressures TTS |
| TTS segmenter → Orpheus producer | `AsyncChannel<Sentence>` | 4 | Suspend segmenter; barge-in cancels owning `withTaskGroup`; `channel.finish()` wakes segmenter (R3-V4) |
| RT audio thread → VoiceController | `TPCircularBuffer` SPSC | fixed bytes | Atomic `rawRingDrops` counter; consumer treats non-zero as discontinuity edge |
| AppDelegate startup → Orchestrator | `AsyncChannel<Event>` | unbounded | First `.systemReady` send SUSPENDS until HudStateCoordinator pumps — this IS the startup barrier primitive (R3-A5) |
| MCPClient ↔ helper child | stdio pipes | OS default | NDJSON line-based; read loop drains continuously |

**7. Launch-pinned vs per-turn config snapshots.** Security keys (`applescript.*`, `ollama.baseURLAllowlist`, `confirmationTimeoutSeconds`, destructive tool blocklist) live in `LaunchSnapshot` — restart required. Non-security (`provider`, `ttsTier`, `sttUseWhisperKit`) in `PerTurnSnapshot`, snapshotted at `submit()` entry. Keychain-stored integrity hash is theater (R3-Sec3) — replaced with honest disclaimer + real controls (launch-pin, host allowlist, hard-coded confirmation).

---

## Data flow — turn execution (voice path)

```
[User speaks "Hey Jarvis, what time is it?"]
     ▼
RT audio thread → TPCircularBuffer (raw + 16 kHz resampled rings)
     ▼
VoiceController: openWakeWord DAG (mel → embedding → "hey_jarvis")
                 crossed threshold → VoiceEvent.wakeDetected
     ▼
Silero VAD (32ms stride) detects speech start
SpeechAnalyzer streams transcription
     ▼
VAD detects speech end → finalize transcript
     ▼
VoiceController.cancelAndSubmit(userInput, source: .wake)   [R3-A3 atomic entry]
     ▼
AgentOrchestrator:
  snapshot PerTurnSnapshot
  freshTurnId = UUID()
  freshTurnNonce = UUID()  [R3-Sec2; never leaves Swift]
  publish(.turnStarted)  →  HudStateCoordinator, ReplayLog
     ▼
LLMProvider.stream(systemPrompt, history, userMessage, tools, toolChoice: .auto)
  AsyncThrowingStream<LLMEvent>:
    .assistantMessageStart
    .textDelta ──► orchestrator ──► .tokenDelta ──► webview batcher
                                              └──► TTS segmenter ──► AsyncChannel(4)
                                                                ──► Orpheus ──► AVAudioEngine
    .toolUseRequested(id, name, args)
    .stopReason(.toolUse)
     ▼
ToolCallDispatcher:
  publish(.toolCallStart) → HUD / ReplayLog
  MCPClient.callTool("get_time") → mcp-time.app via stdio NDJSON
  sanitize(result.content)             [R4-Sec3: before packing into LLMMessage]
  rawForPreview = sanitized string     [R4-Sec2: preview from unwrapped content]
  wrapped = wrapUntrusted(content, nonce: freshTurnNonce)
  publish(.toolCallEnd(preview: previewSlice(rawForPreview)))
  history.append(tool result)
     ▼
LLMProvider.stream again with updated history
  .textDelta → HUD + TTS
  .stopReason(.endTurn)
     ▼
publish(.assistantMessageEnd, .turnEnd(terminator: .endTurn))
TTS drains → VoiceEvent.ttsStopped → HUD (speaking → idle)
Ducking lowered ONLY on .ttsStopped (R4-V5), never on .playbackDrained alone
```

---

## Startup barrier chain (dependency DAG, NOT step numbers — R4-S1)

```
applicationDidFinishLaunching
  ├─► Core services ready        (Logging, Config.LaunchSnapshot, FeatureFlags,
  │                               Keychain probe, ReplayLog actor init)
  ├─► Persistence ready          ← Core services
  │                              (SQLite open WAL, FTS5 + sqlite-vec load,
  │                               orphan-turn detection, crash_count++)
  ├─► HUD coordinator pumping    ← Core services
  │                              (subscribed to agent/voice/confirm events,
  │                               state = .booting)
  ├─► Panel + webview ready      ← HUD coordinator pumping
  │                              (JarvisPanel hidden, WKWebView content loaded,
  │                               BUS_PROTOCOL_VERSION handshake succeeded)
  ├─► MCPClient ready            ← Core services
  │                              (helpers spawned, initialize handshake within
  │                               3s aggregate, tool registry assembled)
  ├─► Orchestrator ready         ← MCPClient + HUD coordinator + Panel+webview
  │                              (sends .systemReady on events channel — first
  │                               send SUSPENDS until HUD coordinator pumps;
  │                               this IS the readiness primitive)
  ├─► Voice ready (optional)     ← Orchestrator + Microphone TCC granted
  │                              (AEC-on or AEC-off variant, pre-warm, probe)
  ├─► Hotkey registered          ← Panel+webview + Orchestrator + Input Monitoring
  │                              TCC granted (R4-S2 GAP — no denial-detection,
  │                              no HUD banner, no degraded-mode fallback)
  └─► activation-policy = .accessory; ready
```

---

## Build order

**Critical path A (message bus spine):**
1. Xcode project + SPM deps + Hardened Runtime entitlement (`allow-jit`)
2. WKWebView hosting a static HTML placeholder
3. WebviewBridge: typed Schemas.swift, hand-written Codable, BUS_PROTOCOL_VERSION handshake, callAsyncJavaScript primitive form, OutboundBatcher
4. React + R3F skeleton, ParticleRing reactive to HudState (parallelizable with 5)

**Critical path B (agent loop spine):**
5. LLMProvider + AnthropicProvider (SSE decoder with per-index block-type table, `input_json_delta` accumulator, stream-truncation cleanup, retry policy, `cache_control ttl=1h`, **`toolChoice` parameter** — R4-L1) + OllamaProvider (`/api/chat` native NDJSON with correct `tool_calls` framing, `/v1` fallback)
6. AgentOrchestrator + MCPClient + 3 helpers (nested app bundles, proper codesign ordering, per-server restart mutex, FD_CLOEXEC)
7. ConfirmationBroker + AppleScript confirmation flow

**Parallel track (after step 3):**
- HudStateCoordinator + precedence ladder + VoiceEvent enum definition (even before VoiceController implemented — publish from a shim to validate resolver)

**Sequential after B (voice loop):**
8. VoiceController — openWakeWord ONNX + Silero VAD + SpeechAnalyzer + AVSpeechSynthesizer. AEC-on variant first. Six-step teardown uniform. **With Input Monitoring TCC envelope handling — R4-S2.**
9. Orpheus via mlx-audio-swift behind feature flag. Format probe at startup; `withTaskGroup` for segmenter + producer; barge-in cancels group.

**Orthogonal (grows alongside every step from 6 onward):**
10. ReplayLog + DevOverlay + eval harness. Not a "phase 10 cleanup" — absent observability debt compounds fast.

**Dependency summary:**
- 3 blocks everything (no bus → no HUD, no DevOverlay, no confirmation UI)
- 6 blocks 7, 8, 9, 10 (no orchestrator → no events)
- 5 blocks 6 but not 3 or 4 (LLMProviders are headless, parallelizable with webview skeleton)
- 8 can begin after 1 (audio plumbing standalone with mock agent); merging into loop requires 6
- 10 grows from step 6 onward

---

## AUDIT-R4 triage

**Genuinely new architecture gaps (must close before voice step is trustworthy):**

1. **R4-S2 · Input Monitoring TCC envelope missing.** `NSEvent.addGlobalMonitorForEvents(.keyDown)` silently no-ops on denial. Fix: probe via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` or first-fire watchdog; HUD "grant Input Monitoring" banner with System-Settings deep link; local-monitor-only degraded mode on denial; add to §17.2 ready-signals table.

2. **R4-L1 · Tool-choice policy never landed.** Zero occurrences of `tool_choice` in PLAN/IMPL rev 3. Fix: `LLMProvider.stream(...)` takes `toolChoice: ToolChoice`; cap-recovery call sets `.none` (Anthropic: `tool_choice: {type:"none"}`; Ollama: drop tools array entirely). Eval asserts zero `.toolUseRequested` on recovery call.

**Architecture-tier completions of already-identified seams (R3 called them out, didn't fully pin):**

| R4 finding | Seam | Pin required |
|------------|------|--------------|
| R4-A4 | `ReplayEvent` type undefined | Exhaustive case list + (producer, SQL event_type, payload) mapping |
| R4-A5 | `VoiceEvent` enum undefined | Define enum + name primitive (`AsyncChannel<VoiceEvent>`) |
| R4-A6 | Startup readiness primitive double-spec | Pick one: `AsyncChannel.send` suspend OR separate `CheckedContinuation`. Remove the other |
| R4-A7 | Pre-`.systemReady` audio graph has producer without consumer | Either start wake-word DAG at graph-init (discarding detections), or defer engine.start to post-ready |
| R4-A8 | Retry-continuation turn identity | Recommend "fresh turnId with `retry_of`, re-snapshot, reset tool-call budget" |
| R4-A9 | `.reconfiguring` triple-role | Split into `VoiceEvent.reconfiguringStarted/Ended`; coordinator policy: hold state on start, re-emit pre-reconfigure on end |
| R4-A10 | Barge-in replay-row ordering | Short-circuit: `.voiceBargeIn` closes immediately, no synthetic tool_result |
| R4-V2 | Wake-during-confirmation not reciprocated in §8 | Add subsection: wake-word DAG stays live during `.awaitingConfirmation`; VoiceController is routing authority; post-barge uses `cancelAndSubmit`, not `submit` |
| R4-L5 | Confirmation-during-stream contract missing for Ollama multi-tool-call | Pin: "while broker.response awaited, provider stream not drained; events buffered, re-processed on approve, discarded on deny/timeout" |
| R4-L6 | `replayToModel` provider-id reconstruction under-specified | Replay payload schema `{localId, providerId, name, args}`; `replayToModel` reads paired `tool_call_start` |
| R4-L7 | `.replay` / `.eval` MCP dispatch + TTS suppression unspecified | `.replay` routes through `ReplayMCPAdapter`; `.replay` and `.eval` suppress TTS subscription; only `.user`/`.wake` dispatch and speak |
| R4-Sec3 | Sanitize missing before tool_result packs into `LLMMessage` | Add `Sanitize.forModel(result.content)` before `headTruncate` in turn-loop |
| R4-Sec5 | `ToolCallStart.args` ships to webview before confirmation approval | Promote from C-tier: args serialized as `{"awaitingApproval": true}` for `requiresConfirmation` tools |

**Pure wiring / mechanical propagation (don't block architecture on these):**

- R4-A1, A2, A3, L2, L3: schema-enum additions (HudState `.booting`/`.awaitingConfirmation`/`.reconfiguring`; TurnTerminator rename `.modelStop` → `.endTurn` + add missing cases; TS mirror catch-up; SQL CHECK constraint for `turn_source`)
- R4-B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12: script and CI wiring
- R4-S1: strip numeric cross-references from prose
- R4-V1, V3, V4, V5: pre-warm matrix, persistence recovery, sustained-overflow threshold
- R4-Sec1, Sec2, Sec4: prose regression fixes (strike dead Keychain-hash row; name `rawForPreview` variable; broaden `runModal` lint scope beyond `ConfirmationPresenter`)

---

## Open decision points for the user

1. **openWakeWord embedded vs sidecar.** PLAN resolves this as *embedded* via ONNX Runtime SPM — right call (sidecar adds Python process, another spawn path, another TCC surface). Confirm at scaffold.
2. **Retry-continuation turn identity (R4-A8).** Recommend "fresh turnId with `retry_of` + re-snapshot + reset tool-call budget" — each retry is a distinct DevMetrics row, budget doesn't carry over, snapshot reflects current config.
3. **`.reconfiguring` publish vs coordinator-held (R4-A9).** Recommend publish as HUD state with held-last-state policy — users should see visible reconfigure indication, not frozen last state.
4. **Memory extraction lifecycle (post-week-one, not week-one).** Sync-after-turn (blocks turnEnd; deterministic) vs background (fire-and-forget; eventual consistency). 2026-standard for mem0-style: background with bounded job queue.

---

## Anti-patterns (domain-specific — build phase review checkpoints)

1. **Two writers for HudState** — every subsystem publishes intent events; coordinator has sole `.hudState` callsite
2. **String-interpolated JSON in `evaluateJavaScript`** — U+2028/`</script>` XSS foothold; use `callAsyncJavaScript(arguments:)`
3. **Blocking modal for destructive confirmation** — parks MainActor, breaks barge-in; non-blocking sheet on hidden NSPanel instead. **Lint ban should be module-wide across `@MainActor` presentation paths, not scoped to `ConfirmationPresenter` only (R4-Sec4)**
4. **Single `CheckedContinuation<Bool, Never>` for turn-slot displacement** — use `enum SubmitOutcome`
5. **Flat `Contents/MacOS/` for codesigned helpers** — breaks outer bundle codesign seal; nested `Contents/Helpers/mcp-<name>.app/` with own entitlements; `--deep` forbidden
6. **Keychain-stored config-integrity hash** — theater; real controls are LaunchSnapshot whitelist + host allowlist + hard-coded confirmation
7. **Assuming "no streaming" means "no incremental audio"** — it means no cloud; local incremental TTS allowed and preferred (150–250 ms time-to-first-audio via Orpheus chunked codec output through AVAudioEngine)
8. **Per-provider tool-call streaming events upstream** — single `.toolUseRequested` at provider boundary; decoders handle provider-specific assembly

---

## Integration points summary

**External services:** Anthropic Messages API (HTTPS + SSE, Opus 4.7, cache_control ttl=1h explicit), Ollama daemon at `127.0.0.1:11434` (constrained by allowlist), macOS Keychain, macOS TCC (incremental prompts), AVAudioEngine/Core Audio, SQLite + FTS5 + sqlite-vec, openWakeWord ONNX, Orpheus via mlx-audio-swift (no Python), WhisperKit.

**Critical 2026-current gotchas (verified HIGH confidence):**
- Opus 4.7 tokenizer ~35% inflated; cache TTL silently regressed to 5 min default
- Ollama 0.5+ emits `tool_calls` on chunk *preceding* `done: true` terminator (decoder must decode on non-empty tool_calls, not gate on done)
- Qwen 3/3.5/Gemma 4 tool-calling broken in Ollama; `qwen2.5-coder:32b` is baseline (see STACK D3 for 2026-04 re-evaluation)
- AVAudioEngine `isVoiceProcessingEnabled` must be enabled before any `connect`/`installTap` (inputNode lazy)
- Post-AEC format is driver-coerced (16 kHz Sonoma, 24 kHz Tahoe); read `inputNode.outputFormat` after enabling
- macOS 26 Tahoe SpeechAnalyzer needs `com.apple.developer.speech-recognition-assets` entitlement OR silent `assetUnavailable` failure
- Hardened Runtime `allow-jit` is required for WKWebView JIT; MLX ships precompiled `.metallib` so `allow-jit` alone suffices — do NOT widen to `allow-unsigned-executable-memory` (R2-S4 overturned R1-H-S4)
- Input Monitoring TCC (R4-S2 gap) silently no-ops `NSEvent.addGlobalMonitorForEvents(.keyDown)` on denial
- `SecureBytes` Keychain wrapper is partial mitigation only — `URLSession` copies the key into CFNetwork/SSL/URLSessionTask buffers that wrapper cannot reach

---

## Scaling considerations

Jarvis is single-user, personal. Scaling concerns are about *deepening* (more tools, more context, more modalities), not *widening*. Practical bottleneck order:

1. **Tool-schema cache discipline first** — lexicographic ordering; don't conditionally register feature-flagged tools
2. **Background turns as separate orchestrator instances** — memory extraction on a second orchestrator with `.memoryExtraction` TurnSource, shared MCPClient
3. **Lazy helper spawn** — fine at 3 helpers pre-launched; past ~8 stretches cold-launch

Do not optimize pre-week-one.

---

## Confidence assessment

| Area | Level | Reason |
|------|-------|--------|
| Top-level component boundaries | HIGH | Four rounds of audit converged; 2026-current Swift + MCP patterns confirm |
| Concurrency primitives (`AsyncChannel`, `actor`, `withTaskGroup`) | HIGH | SE-0406 back-pressured streams, swift-async-algorithms docs, MPSC pitch all align |
| MCP child process lifecycle | HIGH | Matches 2026 MCP spec (spawn → initialize → reset_server → degraded-report); per-server restart mutex is the correct shape |
| LLMProvider event shape | HIGH | Single `.toolUseRequested` at boundary is 2026-standard (Anthropic SDK, OpenAI-compat, Ollama native all have different streaming shapes; collapsing is the right abstraction) |
| Audio graph / AEC variant split | MEDIUM | macOS 26 Tahoe behavior for SpeechAnalyzer + AVAudioEngine under Hardened Runtime is new enough that some invariants will only firm at scaffold; the six-step teardown is right in shape but specific timings are empirical |
| Orpheus / mlx-audio-swift integration | MEDIUM | Swift package is newer (0.3.x); format probe + warmup + in-process execution path has limited real-world deployment |
| R4 triage (36 wiring / 6 contract completion / 2 new gap) | HIGH | Audit cross-reference is self-consistent; the "36 mechanical" claim is verifiable by inspection of each finding |

---

## Roadmap implications (for downstream consumer)

**Phase structure should follow dependency DAG, not numeric step counting.** Two critical paths (bus + agent) with one parallel track (HUD coordination) and one orthogonal track (observability). Voice and Orpheus attach sequentially after agent. The two architecture-tier gaps (R4-S2, R4-L1) must land in their respective phases (voice-ready-gate phase and LLMProvider phase) or downstream work is built on sand.

**Phases that need deeper research flags:**
- Voice phase (step 8): macOS 26 Tahoe SpeechAnalyzer + AEC behavior + Input Monitoring TCC envelope (R4-S2) are all newer-than-training; re-verify at scaffold
- Orpheus phase (step 9): `mlx-audio-swift` 0.3.x behavior; format probe at startup; graph rebuild on toggle
- Memory phase (post-week-one): sqlite-vec performance at scale, mem0-style ADD/UPDATE/NOOP prompting, temporal validity fields

**Phases unlikely to need further research:**
- Message bus / WebKit hardening (audit-converged, 2026-standard patterns confirmed)
- MCP lifecycle (matches 2026 spec cleanly)
- LLMProvider streaming (Anthropic + Ollama shapes well-documented; fixture-testable)
- ConfirmationBroker non-blocking pattern (R3-S3 is the right answer)

---

## Sources

- [swift-async-algorithms AsyncChannel guide](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Channel.md)
- [Swift Evolution SE-0406 async-stream-backpressure](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0406-async-stream-backpressure.md)
- [swift-async-algorithms MultiProducerSingleConsumerAsyncChannel pitch (Swift Forums)](https://forums.swift.org/t/pitch-multiproducersingleconsumerasyncchannel/78932)
- [MCP Lifecycle — Model Context Protocol specification (2025-03-26)](https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle)
- [MCP server development guide — cyanheads/model-context-protocol-resources](https://github.com/cyanheads/model-context-protocol-resources/blob/main/guides/mcp-server-development-guide.md)
- [apple/swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
