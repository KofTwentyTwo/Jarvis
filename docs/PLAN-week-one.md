# PLAN: Jarvis Week-One Scope

> **Rev 3 (2026-04-17):** applied AUDIT-R3 **architecture-tier** HIGH + MEDIUM fixes. C-tier (code-level API exactness) deferred to the implementation-time checklist in `docs/AUDIT-R3.md`. See `docs/AUDIT-R3.md`.
> **Rev 2 (2026-04-17):** applied AUDIT-R2 HIGH + MEDIUM fixes (select LOWs). See `docs/AUDIT-R2.md`.
> **Rev 1 (2026-04-17):** applied AUDIT-R1 HIGH/MEDIUM fixes. See `docs/AUDIT-R1.md`.

## Goal

Ship an end-to-end, thin slice of the Jarvis architecture: a Swift-native macOS app hosting a WKWebView R3F HUD, driven by a Swift-side agent orchestrator that talks to either Claude Opus 4.7 or a local Ollama model, with three starter MCP tools and a full voice loop (wake word → STT → agent → TTS).

"Done" means: you can say "Hey Jarvis, what time is it?" and hear a natural-sounding answer while the HUD ring pulses through idle → listening → thinking → speaking states. Typed input through the chat panel produces the same pipeline minus wake/STT/TTS.

## Scope (in)

1. Swift app skeleton (menu-bar + transparent borderless floating window + global hotkey + WKWebView filling the window).
2. Typed JSON message bus over `WKScriptMessageHandler` (Swift ↔ JS bidirectional).
3. React + R3F HUD skeleton (one particle ring reactive to 4 agent states).
4. Agent orchestrator with `LLMProvider` protocol and two implementations: `AnthropicProvider` (Opus 4.7 streaming) and `OllamaProvider` (Qwen 2.5-Coder 32B streaming).
5. Three MCP tools: `get_time`, `get_clipboard`, `run_applescript` (the last gated behind a HUD confirmation).
6. Voice loop: openWakeWord (`hey_jarvis`), Apple SpeechAnalyzer for STT, AVSpeechSynthesizer (tier-1) + Orpheus via `mlx-audio-swift` (tier-2 behind feature flag) for TTS.
7. Text input fallback with the same streaming + tool-call pipeline.

Plus the always-on NFRs from `CLAUDE.md`: dev/debug overlay, conversation replay log, eval harness (15 scenarios), feature flags, structured logs.

## Scope (out — explicit non-goals)

- Vision (webcam, screen capture) — week-2+
- Multi-panel HUD, ambient data, holographic flair beyond the one ring — week-2+
- Long-term memory extraction pipeline — week-2+, though the SQLite store and Keychain scaffolding are in scope
- Additional MCP tools (calendar, music, file system, browser control) — week-2+
- Eval harness runner integrated into CI — week-2+; week-one is command-line only
- Sandbox entitlement (`com.apple.security.app-sandbox`) — Jarvis is a personal non-sandboxed app

## Architecture (restated for reviewers)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Swift / SwiftUI host process (menu-bar agent, LSUIElement = true)    │
│                                                                      │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │ Hotkey +   │  │ WindowCtrl   │  │ Voice Ctrl   │  │ ReplayLog  │  │
│  │ MenuBar    │  │ (NSPanel,    │  │ (WakeWord,   │  │ (SQLite    │  │
│  │            │  │  transparent)│  │  STT, TTS)   │  │  append)   │  │
│  └──────┬─────┘  └──────┬───────┘  └──────┬───────┘  └──────┬─────┘  │
│         │               │                 │                 │        │
│         └───────────────┴────────┬────────┴─────────────────┘        │
│                                  ▼                                   │
│                    ┌─────────────────────────┐                       │
│                    │   AgentOrchestrator      │                       │
│                    │   (actor, streams events)│                       │
│                    └───────┬─────────┬────────┘                       │
│              ┌─────────────┘         └────────────┐                  │
│              ▼                                    ▼                  │
│   ┌──────────────────┐                ┌────────────────────┐         │
│   │  LLMProvider     │                │  MCPClient         │         │
│   │  (protocol)      │                │  (JSON-RPC 2.0)    │         │
│   │  • Anthropic     │                │  • stdio transport │         │
│   │  • Ollama        │                │  • tool registry   │         │
│   └──────────────────┘                └────────┬───────────┘         │
│                                                │                     │
│                                                ▼                     │
│                              ┌─────────────────────────────┐         │
│                              │ Local MCP server sidecars   │         │
│                              │ (Swift binaries, stdio):    │         │
│                              │  • time.mcp                 │         │
│                              │  • clipboard.mcp            │         │
│                              │  • applescript.mcp          │         │
│                              └─────────────────────────────┘         │
│                                                                      │
│  ┌───────────────────────────────────────────────────────────────┐   │
│  │                       WKWebView                               │   │
│  │  React + R3F bundle (loaded from app bundle Resources/)       │   │
│  │  • ParticleRing (Three.js shader)                             │   │
│  │  • ChatPanel                                                  │   │
│  │  • DebugOverlay                                               │   │
│  │  • MessageBus (TS, talks to Swift via webkit.messageHandlers) │   │
│  └───────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
              ▲                                       ▲
              │                                       │
              │ HTTPS (Opus 4.7 via Messages API)     │ localhost:11434
              │                                       │ (Ollama)
              ▼                                       ▼
        api.anthropic.com                        local Ollama daemon
```

### Thread / actor model

- **MainActor** — all WKWebView / AppKit interaction, menu-bar UI, native confirmation UI.
- **`AgentOrchestrator` actor** — owns the turn loop, serializes tool-call dispatch, publishes *semantic* events (`.systemReady`, `.turnStarted`, `.assistantMessageStart`, `.textDelta`, `.toolUseAssembling`, `.toolCallStart`, `.toolCallEnd`, `.assistantMessageEnd`, `.retryStarted`, `.usage`, `.turnEnd`) via a single output stream. Does NOT decide `HudState` directly. `.assistantMessageEnd` is emitted before every tool-call boundary and before `.turnEnd` so the webview can close out chat bubbles cleanly (R2 A11). `.systemReady` is emitted exactly once after the startup barrier chain completes (R3-A11).
- **`HudStateCoordinator` — `@MainActor final class`** (R2 A1). **Single writer** for `HudState`. Inbound event streams are consumed via `Task { @MainActor in for await … }`. Precedence `awaitingConfirmation > speaking > listening > thinking > idle > booting` (R3-A12: `.booting` is the pre-systemReady prefix state so the HUD never shows a misleading `.idle` before the agent can actually accept input). Resolves the two-writer race (AUDIT-R1 H-A3, R2 A5).
- **LLMProvider** — stateless async functions returning `AsyncThrowingStream<LLMEvent, Error>`. Runs on a background cooperative-executor; never blocks. Cancellation propagated via structured concurrency; no separate `CancellationToken` parameter (AUDIT-R1 M-A1).
- **MCPClient actor with per-server restart mutex** — one child-process sidecar per MCP server, stdio **NDJSON** JSON-RPC 2.0. On child EOF, every outstanding continuation resumes with `MCPError.serverCrashed` and subsequent `callTool()` invocations serialize through a per-server in-flight `Task` slot so concurrent crash-recovery paths don't spawn duplicate children (R3-A13). See IMPL §7.
- **VoiceController** — audio graph runs on Core Audio's real-time thread; control plane is an actor bridging RT→main via **`TPCircularBuffer`** SPSC ring buffers (AUDIT-R1 H-V6). AEC via `AVAudioEngine.inputNode.isVoiceProcessingEnabled = true` (macOS has no AVAudioSession). AEC-off is a **distinct graph variant** with its own invariants, not a configuration knob — see IMPL §8 and R3-V2. Audio-graph rebuild follows a **canonical six-step teardown** applied uniformly to every rebuild trigger (device change, AEC fallback, mic re-grant, producer overflow); see IMPL §8 and R3-V1.
- **TTS back-pressure seam — lifetime-bound** — orchestrator publishes `.textDelta` unconditionally to a fire-and-forget broadcast. A TTS-side sentence segmenter pushes completed sentences into a **bounded `AsyncChannel(capacity: 4)` from `swift-async-algorithms`** (R2 A3). Segmenter + Orpheus producer lifetimes are bound under a single `withTaskGroup` owned by the TTS subsystem; barge-in cancels the group, and producer cancellation calls `channel.finish()` which wakes any segmenter parked in `send` (R3-V4).
- **WebviewBridge** — `WKScriptMessageHandlerWithReply` on MainActor; outbound calls use `WKWebView.callAsyncJavaScript(arguments:)` — never string-interpolated JSON (AUDIT-R1 H-Sec2). High-frequency events (`audioLevel`, `tokenDelta`) coalesced through a MainActor `OutboundBatcher` at ~30 Hz; state transitions ship immediately (R2 S7). Four webview hardening contracts are pinned in IMPL §4/§9: webview preferences posture (no file-URL / universal-access / JS-open-windows), CSP requirement, native-only API-key entry, and a project-wide React lint rule banning raw-HTML props on elements (R3-Sec1).
- **`ConfirmationBroker` actor with non-blocking presentation** — 60-second timeout per confirmation. Presentation is a sheet on a hidden dedicated `NSPanel`, never a modal nested event loop — blocking modals would park the MainActor and prevent `bargeCancel()` from running (R3-S3). Four legal transitions: `.timeout`, `.barge`, `.approve`, `.deny`. Any transition closes the sheet from a Task hop onto MainActor. Destructive confirmations are native UI (not webview), per AUDIT-R1 H-Sec3.
- **`ReplayLog` actor with bounded back-pressure** — owns SQLite handle; ingestion is a bounded `AsyncChannel(capacity: 2048)` between orchestrator events and the writer. Overflow policy: drop `tokenDelta` oldest-first, emit a `replay_overflow { dropped, first_ts, last_ts }` marker; `toolCall*` and `turnEnd` are **never dropped** (R3-A9). WAL mode, single-writer.
- **Turn-in-progress guard — explicit displacement outcome** — `AgentOrchestrator.submit(...)` returns `enum SubmitOutcome { ran, superseded, rejected }` (R3-A1). Single-slot pending-submission with replace-or-reject semantics (R2 A6). Displaced callers observe `.superseded` without needing separate continuations. Invariant: two consecutive `submit()` while a turn is active yield exactly one `.ran` and one `.superseded`.
- **Voice barge-in uses a single atomic orchestrator entry** — `AgentOrchestrator.cancelAndSubmit(userInput:source:) -> SubmitOutcome` (R3-A3). Single actor hop; eliminates the actor-hop gap where a queued text submit could preempt between `cancel()` and `submit()`. The two-call pattern is explicitly **incorrect**.
- **Config bifurcated into security vs non-security snapshots** (R3-A2): `launchSnapshot` for security-relevant keys (`applescript.*`, tool blocklist, `ollama.base_url` host allowlist, confirmation policy) — read once at launch, restart required to change; `perTurnSnapshot` for non-security keys (`provider`, `ttsTier`, `sttUseWhisperKit`) — snapshotted at `submit()` entry and reused for the whole turn. Attempting to place a security key in `perTurnSnapshot` fails a unit test. IMPL §6 and §17.5 agree on the taxonomy.
- **Startup readiness primitive — named explicitly** (R3-A5): the orchestrator's output is an `AsyncChannel` (swift-async-algorithms) whose producer yields `.systemReady` first; the startup barrier `send` does not return until the `HudStateCoordinator` has begun its `for await` loop. Documented in IMPL §6 and §17.1. Rev-2's "hold the producer" prose is replaced by a named primitive.
- **`TurnSource` lands `.eval` and `.replay` cases** (R3-A10): threaded through `DevMetrics` and the `events.turn_source` SQLite column. Eval runner submits with `source: .eval`; replay runner with `source: .replay`.

## Sequencing (order of build)

Each step has a visible deliverable and a smoke test.

| # | Step | Deliverable | Smoke test |
|---|------|-------------|------------|
| 1 | Xcode project + SPM deps + Hardened Runtime entitlement | App launches, menu-bar icon visible, hotkey toggles empty window | `xcodebuild build && open Jarvis.app` |
| 2 | WKWebView hosted + static HTML placeholder loaded from `Resources/webview/` | Window shows "hello from webview" text | Manual visual check |
| 3 | `WebviewBridge` + typed JSON message bus (`SwiftToJS` + `JSToSwift` enums) | JS can `window.jarvis.send({type:"ping"})`, Swift logs it and replies | XCUITest + JS console log |
| 4 | Vite + React + R3F skeleton; `ParticleRing` reactive to a `HudState` enum piped over the bus | Swift button cycles through 4 states, ring animates | Visual |
| 5 | `LLMProvider` protocol + `AnthropicProvider` (streaming + tool_use parsing) + `OllamaProvider` (`/v1/chat/completions` SSE) | CLI-style Swift unit tests hit both backends with a canned prompt and print tokens | `xcodebuild test -only-testing:...ProvidersTests` |
| 6 | `AgentOrchestrator` actor + `MCPClient` + three MCP servers (separate Swift executable targets) | "What time is it?" text input goes through the loop, tokens stream to webview, ring turns "thinking" during the API call | Visual + replay log |
| 7 | `AppleScriptConfirmation` flow — webview shows a modal on `run_applescript` call, user confirms or denies, result flows back | Prompt with "say hello via AppleScript" triggers confirmation UI | Visual + log |
| 8 | `VoiceController` — openWakeWord sidecar + SpeechAnalyzer + AVSpeechSynthesizer + audio session routing | "Hey Jarvis, what time is it?" triggers full loop | Mic test + speaker test |
| 9 | Orpheus TTS behind feature flag via `mlx-audio-swift` | Tier-2 TTS replaces tier-1 when flag on; measure first-audio latency | Stopwatch + subjective |
| 10 | `DevOverlay` + `ReplayLog` (SQLite append) + eval harness (15 canned scenarios, text-only) | Overlay shows last 5 tool calls + token count; replay file replays through same pipeline | `jarvis eval run` prints pass/fail |

### Dependencies between steps

- 5 depends on 1 (app exists). 5 does NOT depend on 2–4 (providers are headless).
- 6 depends on 5 (needs providers). Parallelizable with 3–4.
- 7 depends on 6.
- 8 can start after 1; blocked only on having audio plumbing. Merging into the loop requires 6.
- 9 depends on 8.
- 10 depends on 6 (needs orchestrator events) and should be built *alongside* every other step once the bus exists; listed last for clarity, not for sequencing.

Strict critical path: `1 → 2 → 3 → 5 → 6 → 7 → 8 → 9`. Steps 4 and 10 are parallelizable against 5+.

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Hardened Runtime + JIT entitlement misconfiguration → webview crash in Release only | Med | High | Pin `com.apple.security.cs.allow-jit = true` in entitlements plist in step 1; run a Release build on day one to confirm |
| Opus 4.7 tool-call streaming parser bugs (`input_json_delta` accumulation) | Med | High | Unit-test the SSE parser against recorded Anthropic response fixtures before wiring to orchestrator |
| Ollama Qwen 2.5-Coder tool-call format drift between minor versions | Low | Med | Pin Ollama model tag in config; include the model version in eval harness output |
| openWakeWord false-accept rate on `hey_jarvis` pretrained model | Med | Med | Start with default threshold; expose threshold as config; plan to fine-tune post-week-one |
| SpeechAnalyzer latency / accuracy on noisy input | Low | Med | Feature-flag fallback to WhisperKit `large-v3-turbo` from day one |
| Orpheus via `mlx-audio-swift` package maturity (newer package, possible bugs) | Med | Low | Behind feature flag; AVSpeechSynthesizer is default and always works |
| AppleScript TCC denial on first `run_applescript` call → confusing failure | High | Med | Detect `errAEEventNotPermitted` and surface a specific UI with guidance; pre-check via `AEDeterminePermissionToAutomateTarget` when possible |
| MCP stdio sidecar startup latency adding to first-tool-call time | Low | Low | Pre-launch on app start; health-check via a ping RPC |
| TTS preemption — user interrupts mid-utterance with a new wake word | High | Med | `VoiceController` must handle a cancel-and-ducking path; design the state machine with interruption as a first-class transition, not a bolt-on |
| Anthropic cache_control TTL regression eats budget silently | Low | Med | Explicit `"ttl": "1h"` on every cache_control block; assert in unit tests |
| Token counting drift (Opus 4.7 tokenizer ~35% inflation vs Opus 3.x) | Low | Med | Read `usage.input_tokens` from the API response, don't trust local estimates; surface in DevOverlay |
| Agent loop never terminates (model keeps calling tools) | Med | High | Hard cap on tool calls per turn (default 10); on cap, inject a synthesized tool_result telling the model to stop calling tools and respond (AUDIT-R1 L-A2 bumped likelihood) |
| Tool result poisons history (e.g., 1 MB clipboard) | Med | High | Cap tool_result content at 8 KB with truncation marker; full result goes to replay log only (AUDIT-R1 H-L6) |
| Indirect prompt injection via clipboard → AppleScript | High | Critical | Native modal shows full AppleScript verbatim; blocklist of `do shell script` triggers double-confirm; tool results wrapped in `<UNTRUSTED_CONTENT>` sentinel (AUDIT-R1 H-Sec1) |
| Webview DOM injection via Swift→JS string interpolation | Med | Critical | Use `callAsyncJavaScript(arguments:)`; never interpolate JSON into source (AUDIT-R1 H-Sec2) |
| MLX Metal JIT crashes in Release with Hardened Runtime | Med | High | When Orpheus tier-2 enabled, widen entitlements: `allow-unsigned-executable-memory=true`; document trade-off (AUDIT-R1 H-S4) |
| LLM token stream outpaces TTS synthesis, unbounded queue growth | Med | Med | Bound token-to-TTS queue at 4 sentences; orchestrator pauses publishing to TTS (not HUD) when full (AUDIT-R1 H-A4) |
| AppleScript TCC silent failure on first automation of a new target | High | Med | `AEDeterminePermissionToAutomateTarget` preflight in `mcp-applescript`; structured `permissionDenied` error with target bundle id (AUDIT-R1 H-S2) |
| MCP server crash leaves orchestrator awaiting | Med | High | On child EOF, drain continuation map with `.serverCrashed`; lazy restart on next tool call (AUDIT-R1 H-A5) |
| Confirmation UI can be forged by compromised webview JS | Low | Critical | Native `NSAlert` (not webview) for destructive confirmations; webview display is advisory only (AUDIT-R1 H-Sec3) |
| MLX Metal execution under Hardened Runtime | Low | Med | `allow-jit = true` is sufficient; MLX ships precompiled `.metallib`, any runtime compilation runs out-of-process in `MTLCompiler.framework`. **Do NOT widen to `allow-unsigned-executable-memory`** — R2 S4 overturns the R1 H-S4 decision as a hardening regression with no evidence of need. If MLX/Orpheus actually crashes on W^X in Release, capture the exact failing symbol and add the narrowest entitlement; `allow-unsigned-executable-memory` is almost certainly not it |
| `AVAudioEngine.isVoiceProcessingEnabled` AEC gotchas on macOS | Med | High | R2 S1: AEC must be enabled **before** any `connect`/`installTap`; input-node format is coerced by the driver (16 kHz mono on Sonoma, 24 kHz on Tahoe), so the R1 "install at 48 kHz and resample" path is wrong in the AEC-on case. Trust `inputNode.outputFormat` after enabling. Subscribe to `AVAudioEngineConfigurationChangeNotification` and rebuild graph on device change. Fall back to AEC-off with higher duck aggressiveness on enable failure. Include the +30 ms AEC latency in the wake-word budget. Document split-device (BT out + USB in) as a known AEC-degraded mode |
| TTS interrupt click/pop + stale-sample self-trigger | Med | Med | R2 V4: interrupt sequence is (1) cancel Orpheus producer, (2) schedule 10 ms cosine fade-out buffer at current playhead, (3) `stop()`, (4) await `AVAudioPlayerNodeCompletionHandler` or 20 ms, (5) publish `.ttsStopped`. `HudStateCoordinator` transitions `speaking → listening` only on `.ttsStopped`; AEC stays on through the transition |
| Hot-reloaded `config.json` flips a security-relevant flag | Med | Critical | R2 Sec6: whitelist hot-reloadable flags; confirmation policy / provider URL / tool gating / blocklist changes require app restart with a "restart to apply" banner. Constrain `ollama.base_url` to `http(s)://127.0.0.1` or `http://localhost` at load time; any other host refused unless a separate install-time file flag is set. Config hash in Keychain; mismatch warns and reverts. `run_applescript` confirmation is hard-coded, never flag-gated |
| Carbon `HotKey` triggers Input Monitoring TCC prompt with process-wide scope | Med | High | R2 Sec7: prefer `NSEvent.addGlobalMonitorForEvents` for plain-modifier hotkeys. If Carbon HotKey is required, register a single hotkey only in week-one; log every registration with stack trace. Long-term: route destructive-capability MCPs through an XPC service signed with a different identity |
| Tool-arg assembly UX gap (800–2500 ms silent `.thinking` window) | Med | Low | R2 L5: decoder emits internal `.toolUseAssembling(id, name, partialBytes)` on each Anthropic `input_json_delta` and once on Ollama tool-call detection. Orchestrator republishes behind `ui.showToolAssembling` flag; HUD drives a progress animation off it. Preserves semantic single-emit for tool execution |
| Concurrent MCP crash-restart paths spawn duplicate children | Low | High | R3-A13: per-server restart mutex inside `MCPClient` — an inner actor with an in-flight restart `Task` slot; concurrent `callTool` callers await the same restart. Documented in IMPL §7 |
| Blocking confirmation modal collides with voice barge-in | Med | High | R3-S3: `ConfirmationBroker` uses a non-blocking sheet on a dedicated hidden `NSPanel`, never a nested modal event loop. Four legal transitions (`timeout`/`barge`/`approve`/`deny`) each close the sheet from a Task hop onto MainActor. Blocking-modal patterns banned in `ConfirmationPresenter` |
| Main app retains `automation.apple-events` after helper restructure → webview XSS bypasses `mcp-applescript` | Med | Critical | R3-S5: entitlement **removed** from `Jarvis.entitlements`; retained only on `mcp-applescript.entitlements`. Verification asserts the main app's signed entitlements do not contain the key |
| Audio-graph rebuild leaves dangling converter / wake-word / STT / TTS state | Med | High | R3-V1: canonical six-step teardown uniformly applied to every rebuild trigger (device change, AEC fallback, mic re-grant, producer overflow). `.reconfiguring` HUD state holds last visible state while rebuild runs. See IMPL §8 "Graph rebuild sequence" |
| AEC-off fallback uses a different graph shape; silent failures if invariants aren't pinned | Med | Med | R3-V2: AEC-off spec'd as an explicit graph variant — resampler unconditionally present (hardware-native format ≠ 16 kHz), pre-warm re-run required, user-visible "AEC unavailable; degraded-mode active" warning. Same variant is the shape used by fixture-mode eval |
| Orpheus playback format unknown at graph-wiring time → mismatch or forced rebuild on first use | Med | Med | R3-V3: boot-probe at startup with tier-2 enabled — synthesize one short fixed utterance, inspect buffer format, persist to `config.json` under `voice.orpheus.output_format`. Step-9 graph wiring gates on presence of probed format |
| Webview security regresses as HUD gains features | Med | Critical | R3-Sec1: four design-contract controls land in IMPL §4/§9 — webview preferences posture, CSP requirement, native-only API-key entry, and a React lint rule banning raw-HTML props on elements. Exact values are C-tier; the requirement and the ban are A-tier and enforced by a linter rule in CI |
| `<UNTRUSTED_CONTENT>` nonce leakage to webview defeats the framing | Low | High | R3-Sec2: nonce never appears on any `SwiftToJS` payload — previews shipped to the webview are built from unwrapped content. Unit test asserts the nonce doesn't appear in webview-bound payloads across a fixture turn with tool-result quoting |
| Config-integrity theater — Keychain hash forgeable by same-user processes | Low | Med | R3-Sec3: drop the hash; replace with honest disclaimer. The real controls are the launch-snapshot whitelist, `ollama.base_url` host constraint, and hard-coded `run_applescript` confirmation. Banner text updated to match reality |
| MCP-child stderr echoes attacker-supplied bytes into logs / replay | Med | Med | R3-Sec4: `Core/Logging/Sanitize.swift` is a required pipeline stage for every byte stream crossing an MCP boundary (UTF-8 validation, C0-control strip, bidi/zero-width strip, line-length cap, non-printable escaping). Applied at both system-log write and `ReplayLog` ingestion |
| `mcp-clipboard` leaks file paths when Finder items are copied | Med | High | R3-Sec5: refusal policy triggers on `NSPasteboardTypeFileURL` presence, not only on empty-string. Returns `"Clipboard contains N file paths; hidden for privacy."` Tier-B eval scenario covers Finder-copy |
| Skip-allowlist reintroduces the regex-bypass R2 Sec2 condemned | Med | Critical | R3-Sec6: **no skip-allowlist for week-one.** Every `run_applescript` invocation requires the confirmation checkbox. OSA-level AST matching revisited post-week-one |
| SHA-256 digest over source bytes ≠ compiled bytes (smart-quote normalization, identifier recomposition) | Low | Med | R3-Sec7: digest is computed over **compiled** script bytes. Compilation failure → refuse without a digest |
| Heuristic keyword injection banner is security theater | Low | Low | R3-Sec10: drop the banner heuristic for week-one — checkbox wording is unambiguous regardless of provenance. Post-week-one: make the second-model check non-optional (local Ollama call evaluates proposed script + originating tool result; unsure/no → higher-tier confirmation) |
| Replay-feed content bypasses nonce-wrapping when re-entering a model context | Med | High | R3-Sec11: single-entry helper `replayToModel(row) -> LLMMessage` in `ReplayLog`; eval runner, memory extractor, and replay runner must use it. Re-wraps with the **current** turn's nonce before model feed. Print-only viewers see raw content |

## Open questions

Round 1 audit resolved most of these. Round 2 resolved #2 and #3. Remaining genuine unknowns:

1. **Orpheus output sample rate/format.** `mlx-audio-swift` Orpheus may emit Float32 at 24kHz or 48kHz (or int16 at 24 kHz) depending on model variant. Verify at scaffold; document observed. Audio player node must be configured to match. **Blocks step 9 in sequencing until resolved** (R2 V12 deferred-LOW promoted here).
2. **pnpm vs npm.** *Resolved (R2 B3):* pnpm. Pinned via mise/asdf with explicit shim activation at the top of `build-webview.sh` — Xcode Run Scripts execute under `/bin/sh -c` with a stripped env that never sources `~/.zshrc`/`~/.zprofile`, so `.tool-versions` alone does not work. The activation step is documented in IMPL §9/§14.
3. **Hotkey default.** *Resolved (R2 S8):* ship hotkey **unset** by default (Cmd+Shift+J collides with Chrome/Slack/VS Code; whichever has focus wins). Prompt on first launch with a shortcut-recorder UI ("Press your preferred shortcut for Jarvis").

### Resolved by AUDIT-R1

- **MCP transport** → stdio child processes with **NDJSON** framing; child binaries codesigned independently. R2 S2/S3 supersede the rev-1 "flat `Contents/MacOS/`" layout: each MCP is a nested `Contents/Helpers/mcp-<name>.app/` bundle with its own `Info.plist`/entitlements/LaunchServices identity (→ per-helper TCC identity), resolved explicitly (see IMPL §3, §7).
- **React state** → Zustand 4.5+.
- **Webview build** → Vite 5.3+, bundle at `Resources/webview/`, dev loads `http://localhost:5173` behind `NSAllowsLocalNetworking` in Debug-only Info.plist.
- **openWakeWord** → embedded via `onnxruntime-swift-package-manager` (correct SPM name). Streaming DAG with rolling mel (76-frame) and embedding (16-frame) buffers.
- **Audio routing** → AEC via `AVAudioEngine.inputNode.isVoiceProcessingEnabled = true`; threshold ducking as belt-and-suspenders; mic stays open so "stop" still works.

## Success criteria

Week-one is "done" when all of the following are demonstrable in a single recording:

1. Cold-launch the app; menu-bar icon appears; global hotkey summons an empty HUD.
2. Type "what time is it?" in the chat panel; tokens stream; ring pulses through thinking → speaking; answer is correct.
3. Flip provider to Ollama via config toggle; repeat (2); different model, same surface.
4. Say "Hey Jarvis, read my clipboard"; wake word triggers; STT transcribes; `get_clipboard` tool runs; response is spoken via AVSpeechSynthesizer; ring animates through all four states.
5. Toggle the Orpheus feature flag; repeat (4); voice quality visibly improves; first-audio latency stays under 400 ms.
6. Ask for an AppleScript action ("set volume to 50%"); HUD confirmation prompt appears; approve; action runs; Jarvis confirms verbally.
7. Open the DevOverlay; last 5 tool calls and token counts are accurate.
8. `jarvis eval run` passes ≥13 of 15 canned scenarios.
9. Kill the app, relaunch, open a replay file; replay reproduces a prior session's messages and tool calls.

Failing any one of these is a week-one regression.

## Decision log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-17 | Opus 4.7 + Ollama Qwen 2.5-Coder 32B as the two baseline providers | User decision; Qwen 2.5 is the last known-good local tool-calling model in Ollama |
| 2026-04-17 | Local-only voice stack, no cloud TTS/STT | User constraint (privacy) |
| 2026-04-17 | Local incremental streaming TTS allowed | User clarification (2026-04-17): constraint was "no cloud," not "no streaming" |
| 2026-04-17 | R3F HUD from day one (not a post-week-one upgrade) | User decision — the HUD is part of the "prove the architecture" goal, not a polish phase |
| 2026-04-17 | Full voice loop in week-one (not a week-two expansion) | User decision — accepts ~2x effort |
| 2026-04-17 | openWakeWord `hey_jarvis` as the wake word model | User decision |
| 2026-04-17 | Orpheus via `mlx-audio-swift` as tier-2 TTS (no Python sidecar) | Swift package makes Orpheus in-process on Apple Silicon |
| 2026-04-17 | MCP servers as stdio child processes, not in-process | Matches reference implementation; permission isolation; accepts startup latency |
| 2026-04-17 (R1) | `HudStateCoordinator` actor is single writer for HUD state | Eliminates orchestrator/voice race (AUDIT-R1 H-A3) |
| 2026-04-17 (R1) | `AppleScript` confirmation uses native `NSAlert`, not webview modal | Webview is not a trust boundary for destructive tools (AUDIT-R1 H-Sec1/3) |
| 2026-04-17 (R1) | `LLMEvent.toolUseRequested(id, name, args)` replaces three-event tool streaming | Ollama has no `input_json_delta` equivalent; single event normalizes providers (AUDIT-R1 H-A1) |
| 2026-04-17 (R1) | Tool result content capped at 8 KB with truncation marker | Prevents clipboard-sized responses from poisoning history (AUDIT-R1 H-L6) |
| 2026-04-17 (R1) | ONNX Runtime via `onnxruntime-swift-package-manager`, not `onnxruntime-objc` | Correct SPM package name (AUDIT-R1 H-V1) |
| 2026-04-17 (R1) | Drop `Jarvis.xcworkspace`, use `.xcodeproj` + local SPM packages | No CocoaPods, no second Xcode project; workspace is overhead (AUDIT-R1 H-B2) |
| 2026-04-17 (R1) | `allow-unsigned-executable-memory = true` when Orpheus flag on | Required for MLX Metal JIT on Apple Silicon; accept widened entitlement (AUDIT-R1 H-S4) |
| 2026-04-17 (R2) | **Overturns R1 H-S4**: remove `allow-unsigned-executable-memory` from entitlements | R2 S4: MLX ships precompiled `.metallib`; any runtime compilation runs out-of-process in `MTLCompiler.framework`. `allow-jit` alone is sufficient. The R1 widening was speculation and a hardening regression. If MLX actually crashes on W^X in Release, capture the specific failing symbol and add the narrowest entitlement |
| 2026-04-17 (R2) | Add `com.apple.developer.speech-recognition-assets = true` entitlement + `NSSpeechRecognitionAssetsUsageDescription` Info.plist key | R2 S5: SpeechAnalyzer on macOS 26 Tahoe downloads transcriber assets via `AssetInventory` on first use; without the pair the request silently fails with `SFSpeechErrorCode.assetUnavailable` and STT never works in Release. Entitlement requires App ID capability enabled in the Developer portal |
| 2026-04-17 (R2) | `HudStateCoordinator` is `@MainActor final class`, not `actor (MainActor-bound)` | R2 A1: Swift has no type that is simultaneously `actor` and `@MainActor`-bound. Rev-1 wording was contradictory. Every WKWebView call hops to MainActor anyway; `@MainActor` class is the correct spelling |
| 2026-04-17 (R2) | HUD state precedence is `awaitingConfirmation > speaking > listening > thinking > idle` | R2 A5: with the mic hot during confirmation, showing `.listening` while a destructive-AppleScript dialog is up is actively deceptive. `awaitingConfirmation` must visibly dominate |
| 2026-04-17 (R2) | TTS back-pressure uses a bounded `AsyncChannel(capacity: 4)` from `swift-async-algorithms`, not "orchestrator pauses publishing" | R2 A3: `AsyncStream` has no per-subscriber back-pressure. Bounded channel is the only clean way to pressure the segmenter without stalling HUD text |
| 2026-04-17 (R2) | API-key entry is a native SwiftUI `SecureField` sheet, not a webview field | R2 Sec3: the webview is the highest-value XSS target left in the system; any future raw-HTML React prop or markdown-with-HTML feature plus an `addEventListener('input', …)` steals the key. Webview never has the key in scope |
| 2026-04-17 (R2) | AppleScript second-confirmation is the **default**; blocklist flags for escalation but is never a safety guarantee | R2 Sec2: substring blocklists are trivially bypassed (case/whitespace, string concat, `run script`, `load script`, homoglyphs). Narrow allowlist is the only path that skips second-confirmation |
| 2026-04-17 (R2) | `<UNTRUSTED_CONTENT>` framing uses a per-call random nonce | R2 Sec1: rev-1's plain sentinel is forgeable by the untrusted content itself. Nonce tag form is `<UNTRUSTED_CONTENT id="<UUID>">…</UNTRUSTED_CONTENT id="<UUID>">`; pre-strip matching opening-tag substrings before wrapping |
| 2026-04-17 (R2) | Security-relevant config flags require app restart (whitelist hot-reload) | R2 Sec6: `config.json` has no integrity check; any user-scope process can flip `applescript.skipConfirmation` or `ollama.base_url` and wait for hot reload. `ollama.base_url` constrained to `127.0.0.1`/`localhost`; `run_applescript` confirmation never flag-gated |
| 2026-04-17 (R2) | Ship hotkey unset by default; prompt on first launch with a shortcut recorder | R2 S8: resolves Open Question 3. `Cmd+Shift+J` collides with Chrome/Slack/VS Code; focus-app wins |
| 2026-04-17 (R2) | MCP bundle layout: nested `Contents/Helpers/mcp-<name>.app/` per server | R2 S2: flat `Contents/MacOS/` + Copy-Files re-sign breaks the outer bundle's codesign seal; nested app bundles give per-helper TCC identity (matters for `mcp-applescript`). `codesign --deep` forbidden; sign helpers deepest-first, main app last |
| 2026-04-17 (R2) | Typed message bus uses hand-written `Codable` with `type` discriminator key | R2 S6: Swift's synthesized `Codable` for enums with associated values does not emit the `{"type": "…", …}` shape the TS mirror expects — the two sides would not interop on day one |
| 2026-04-17 (R2) | Turn lifecycle matrix added to IMPL §6; new §17 Lifecycle added | R2 A2 / A8: rev-1 had no contract for startup order, shutdown, crash recovery, interrupted turns. Every transition needs a named stopReason, MCP dispatch handling, HUD transition, and replay log record |
| 2026-04-17 (R2) | `ToolCall { providerId: String, localId: UUID }` round-trips both IDs | R2 A4: Anthropic's `toolu_…` id is opaque String, Ollama synthesizes UUID; orchestrator must round-trip the provider id on `tool_result` or Anthropic rejects the next turn. Rev-1's `id: UUID` erased that |
| 2026-04-17 (R3) | `AgentOrchestrator.submit(...) -> SubmitOutcome { ran, superseded, rejected }` replaces the single-`CheckedContinuation` pattern | R3-A1: a single continuation can't simultaneously express "resume displaced caller" and "park newcomer"; an explicit outcome enum closes the contract and makes the two-consecutive-submit invariant testable |
| 2026-04-17 (R3) | Config bifurcated into `launchSnapshot` (security) vs `perTurnSnapshot` (non-security); `provider` belongs in `perTurnSnapshot` | R3-A2: §6 and §17.5 had contradictory homes for `provider`. The bifurcation pins the contract and makes accidental placement a compile/unit-test failure |
| 2026-04-17 (R3) | Voice barge-in uses a single `cancelAndSubmit` entry; the two-call pattern is incorrect | R3-A3: separate `cancel()` + `submit()` leaves an actor-hop gap that allows text input to preempt |
| 2026-04-17 (R3) | `TurnTerminator.crashRecovered` added; synthesized crash-recovery rows have `monotonic_ns: NULL` with wall-clock ordering semantics | R3-A4: §17.4 cited a terminator not in the enum; CHECK constraint / viewer switch would have failed. Closes contract drift |
| 2026-04-17 (R3) | Startup readiness uses `AsyncChannel` from swift-async-algorithms with a `.systemReady` first-event gate; orchestrator output stream is the named primitive | R3-A5: "hold the producer" was unimplementable against `AsyncStream.Continuation`. Named primitive closes the design |
| 2026-04-17 (R3) | Helpers link **statically** for week-one (Recommendation: adopt option (a)) | R3-S1: avoids `@rpath/...` load failures during dev iteration with nested helper bundles; the ~20 MB/helper binary tax is acceptable against the dynamic-framework option's same-Team-ID + `LD_RUNPATH_SEARCH_PATHS` complexity. Revisit post-week-one if binary size becomes a pain point |
| 2026-04-17 (R3) | Startup barrier chain lives in `AppDelegate.applicationDidFinishLaunching`; the `@main struct JarvisApp: App` wraps a `Settings { EmptyView() }` scene only | R3-S2: SwiftUI `App` lifecycle events can't satisfy the §17 barrier chain under `LSUIElement=YES`. Webview is created by the delegate inside a hidden `NSPanel`'s content view, not via a SwiftUI representable |
| 2026-04-17 (R3) | `ConfirmationBroker` presentation is a non-blocking sheet on a dedicated hidden `NSPanel`; blocking-modal patterns banned | R3-S3: a nested modal event loop parks MainActor and blocks `bargeCancel()`. Sheet model makes `timeout`/`barge`/`approve`/`deny` first-class async transitions |
| 2026-04-17 (R3) | Global hotkey is a **pair of monitors** (global + local) registered in step 9; only plain-modifier + alphanumeric keys supported week-one | R3-S4: a global-only monitor misses frontmost-HUD events; a local-only monitor misses everything else. Function/media/Fn keys require Accessibility and are deferred |
| 2026-04-17 (R3) | Main app entitlements do NOT include `com.apple.security.automation.apple-events`; the entitlement lives only on `mcp-applescript.entitlements` | R3-S5: retaining it on the main app defeats the R2 S2 isolation — a webview-XSS in the main process could send Apple Events bypassing the confirmation broker |
| 2026-04-17 (R3) | Audio-graph rebuild is a canonical six-step teardown applied uniformly to every trigger | R3-V1: a debounce around `ConfigurationChangeNotification` doesn't prevent dangling converter / wake-word DAG / STT session / TTS producer state. Single sequence documented in IMPL §8 |
| 2026-04-17 (R3) | AEC-off is a distinct graph variant, not a configuration knob | R3-V2: post-AEC-off format is hardware-native (48/44.1 kHz stereo), not 16/24 kHz. Resampler is unconditionally present; pre-warm is re-run; HUD surfaces "AEC unavailable; degraded-mode active" |
| 2026-04-17 (R3) | Orpheus output format is probed at startup and persisted to `config.json`; step-9 graph wiring gates on presence | R3-V3: player node needs a concrete `AVAudioFormat` at connection time. Probe once, store, reuse — eliminates on-first-use rebuild |
| 2026-04-17 (R3) | TTS segmenter + Orpheus producer live under a single `withTaskGroup`; barge-in cancels the group, producer cancel calls `channel.finish()` to wake the segmenter | R3-V4: a segmenter parked in a bounded-channel `send` doesn't wake from producer cancellation alone. Group-owned lifetime closes the deadlock |
| 2026-04-17 (R3) | Pre-warm is re-run on every rebuild trigger (boot, mic-grant, device change, AEC fallback, Orpheus tier toggle) | R3-V5: a single boot-time pre-warm doesn't cover invalidation paths |
| 2026-04-17 (R3) | Wake-word during `awaitingConfirmation` routes to `ConfirmationBroker.bargeCancel()` (synthetic deny + close + accept new submit) | R3-V6: wake-during-confirmation was unspecified; routing it through the broker prevents lost barge-ins and avoids double-submission |
| 2026-04-17 (R3) | Webview hardening contracts: preferences posture + CSP + native-only key entry + React lint rule banning raw-HTML props | R3-Sec1: R2 Sec3 closed in the decision log but only partially landed in IMPL. These four controls are A-tier; exact values are C-tier |
| 2026-04-17 (R3) | Turn nonce is generated at every `submit()` entry; never appears on any `SwiftToJS` payload; previews built from **unwrapped** content | R3-Sec2: rotation locus wasn't pinned; "per-session" caching was reachable under rev-2 prose |
| 2026-04-17 (R3) | Config integrity hash dropped in favor of an honest disclaimer; real controls are launch-snapshot whitelist, `ollama.base_url` host constraint, and hard-coded `run_applescript` confirmation | R3-Sec3: same-user Keychain hash is forgeable. Banner text must match reality |
| 2026-04-17 (R3) | `Core/Logging/Sanitize.swift` is a required pipeline stage for every byte stream crossing an MCP boundary | R3-Sec4: `redact()` alone only masks API keys; attacker-supplied bytes from `NSAppleScript.errorInfo` need UTF-8 validation, C0-control strip, bidi/zero-width strip, line-length cap, non-printable escaping at both system-log and replay ingestion |
| 2026-04-17 (R3) | `mcp-clipboard` refuses any pasteboard whose type set contains `NSPasteboardTypeFileURL`, returning `"Clipboard contains N file paths; hidden for privacy."` | R3-Sec5: Finder selections return POSIX paths as `NSPasteboardTypeString`, so the non-empty-string refusal never trips. File URLs leak verbatim to the cloud provider otherwise |
| 2026-04-17 (R3) | No `run_applescript` skip-allowlist for week-one; every invocation requires the confirmation checkbox | R3-Sec6: "narrow skip-allowlist" invites a regex; a regex re-enables the Sec2 bypass (`& (do shell script "…")`). OSA-level AST matching revisited post-week-one |
| 2026-04-17 (R3) | AppleScript confirmation digest is computed over **compiled** bytes, not source bytes; compilation failure refuses without a digest | R3-Sec7: smart-quote normalization / identifier recomposition during compile means source-digest doesn't match runtime — user sees a hash that doesn't correspond to what ran |
| 2026-04-17 (R3) | Heuristic injection-keyword banner dropped week-one; second-model check (local Ollama) becomes non-optional post-week-one | R3-Sec10: heuristic check is security theater by design, and the checkbox wording is unambiguous regardless of provenance |
| 2026-04-17 (R3) | `replayToModel(row) -> LLMMessage` is the single entry for every path that re-feeds replayed content to a model (eval runner, memory extractor, replay runner) | R3-Sec11: re-wrapping with the **current** turn's nonce on re-feed prevents the nonce-binding from going stale across runs |
| 2026-04-17 (R3) | `TurnSource.eval` and `TurnSource.replay` land now; threaded through `DevMetrics` and `events.turn_source` column | R3-A10: deferred from R2 L13; needed by B12 replay-roundtrip oracle |
| 2026-04-17 (R3) | `AgentOrchestrator.Event.systemReady` added; emitted once after the startup barrier chain completes | R3-A11: `.systemReady` was referenced in §17 but not defined. Closes contract drift |
| 2026-04-17 (R3) | `HudState.booting` added; precedence becomes `awaitingConfirmation > speaking > listening > thinking > idle > booting` | R3-A12: without `.booting`, the HUD defaults to `.idle` at launch — an assertion the agent can accept input, which isn't true until `.systemReady` |
| 2026-04-17 (R3) | `MCPClient` uses a per-server restart mutex (inner actor with an in-flight `Task` slot) | R3-A13: concurrent `callTool` paths during crash recovery would otherwise spawn duplicate child processes |
| 2026-04-17 (R3) | `ReplayLog` ingestion uses a bounded `AsyncChannel(capacity: 2048)`; overflow drops `tokenDelta` oldest-first, `toolCall*`/`turnEnd` never dropped; overflow marker event emitted | R3-A9: rev-2 had no back-pressure contract on the replay path |
| 2026-04-17 (R3) | `ConfirmRequest` collapses `confirmId` and `toolCallId` into a single `toolCallId` field | R3-A6: the bus schema shipped two UUIDs for one logical operation; intent was one |
| 2026-04-17 (R3) | Lifecycle-matrix "confirmation timed out" is a synthetic event, not a turn termination; the subsequent close is the termination | R3-A7: rev-2 matrix mislabeled the synthetic event as the terminator |
| 2026-04-17 (R3) | `meta.crash_count` column on `sessions` is the concrete store for orphan-turn detection; §12 spells out the SQL for "last event is not turn_end" | R3-A8: orphan detection was prose, not schema |
| 2026-04-17 (R3) | Each `mcp-*` is an Xcode **Application** target (`LSUIElement=YES`, no storyboard/window), not a command-line tool | R3-B1: Application bundle type is required for the nested `.app` layout and for LaunchServices-scoped TCC identity |
| 2026-04-17 (R3) | Info.plist parity check is an Xcode build phase on the main app; the allowlist of permitted Debug/Release deltas is a checked-in file with one key per line and a reason comment | R3-B4: deferring to CI lets drift ship locally |
| 2026-04-17 (R3) | `MCPIntegrationTests` is an Xcode test target in the main project (scheme pre-action sets `MCP_BINARIES_DIR`); explicit dependencies on helper app targets | R3-B5: an SPM test can't see Xcode-built helpers |
| 2026-04-17 (R3) | `scripts/prime-tcc.sh` is the Tier-B priming protocol; enumerates Tier-B targets and triggers each prompt once | R3-B8: Tier-B scenarios were promised without a priming mechanism |
| 2026-04-17 (R3) | `replay-roundtrip` eval oracle defined: `MockLLMProvider` replays the recorded `LLMEvent` sequence; assertions pin `user_input → turn_end` byte-equality modulo IDs/ts, tool-call sequence, no new errors | R3-B12: tests the replay machinery, not the live model — and closes the "does replay actually work" gap |
