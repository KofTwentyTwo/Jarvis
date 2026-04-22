# Requirements: Jarvis

**Defined:** 2026-04-22
**Core Value:** An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

---

## v1 Requirements

v1 target per user scope decision: **"Everything through 'usable Jarvis'"** — Week-one skeleton + full voice loop + vision first pass + memory first pass. Screen capture, multi-panel HUD, broader tool set stay in v2.

### Ambient Shell (SHELL)

- [ ] **SHELL-01**: I can summon the HUD from anywhere with a global hotkey and dismiss it with the same key
- [ ] **SHELL-02**: Default hotkey is unset; first-launch shortcut-recorder UI binds it (Cmd+Shift+J / Option+Space collide with common apps)
- [ ] **SHELL-03**: A menu-bar item is present whenever the app is running; icon reflects current agent state (idle / listening / thinking / speaking / awaiting-confirmation)
- [ ] **SHELL-04**: The HUD window is borderless, transparent, always-on-top when summoned (NSPanel, nonactivating, .statusBar level)
- [ ] **SHELL-05**: The app launches at login when opt-in is enabled and sits in background with `LSUIElement=YES` otherwise
- [ ] **SHELL-06**: Input Monitoring TCC denial surfaces a HUD banner with System Settings deep link; local-monitor-only degraded mode falls back when global monitor is denied

### HUD Rendering (HUD)

- [ ] **HUD-01**: WKWebView hosts React 19 + R3F 9 + drei 10.7 + three r184 + Zustand 5 + Vite 8 app; renders a particle ring reactive to agent state
- [ ] **HUD-02**: Seven distinct visual states render: idle / listening / thinking / speaking / awaitingConfirmation / reconfiguring / booting
- [ ] **HUD-03**: All HUD state transitions are driven by Swift-side truth via a typed JSON bus over `WKScriptMessageHandlerWithReply`; bus uses `type` discriminator shape with hand-written `Codable`
- [ ] **HUD-04**: Outbound JSON payload passed via `callAsyncJavaScript(arguments:)` as a primitive string — never string-interpolated into `evaluateJavaScript`
- [ ] **HUD-05**: Two-way `BUS_PROTOCOL_VERSION` handshake refuses mismatched bundles at startup with a native `NSAlert`
- [ ] **HUD-06**: High-frequency events (audioLevel, tokenDelta) coalesce through an OutboundBatcher at ~30 Hz; state transitions flush immediately
- [ ] **HUD-07**: Tool-call events surface as both ring state shift AND expandable chat-panel cards with lifecycle (pending / running / awaiting-approval / completed / failed)
- [ ] **HUD-08**: `HudStateCoordinator` is `@MainActor final class`, the sole writer of HUD state, resolving via precedence: `awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`

### Agent Loop (AGENT)

- [ ] **AGENT-01**: Swift orchestrator talks to an `LLMProvider` protocol that takes `toolChoice: ToolChoice`; swapping Opus ↔ local Ollama is a config toggle
- [ ] **AGENT-02**: `AnthropicProvider` streams `claude-opus-4-7` via Messages API (URLSession + SSE); cache_control blocks carry `ttl: "1h"` explicitly AND request includes `anthropic-beta: extended-cache-ttl-2025-04-11` header
- [ ] **AGENT-03**: SSE decoder handles `content_block_start`/`input_json_delta`/`content_block_stop`; closes on `message_stop` (not `message_delta`); swallows `ping`; emits `partial_tool_use_at_disconnect` on mid-delta stream termination; routes `thinking_delta` to its own event case; treats `stop_reason: "refusal"` as first-class
- [ ] **AGENT-04**: `OllamaProvider` streams `qwen2.5-coder:32b` via native `/api/chat` NDJSON; decoder reads `tool_calls` whenever seen (never gates on `done:true`); separate `/v1/chat/completions` SSE decoder is available behind a flag
- [ ] **AGENT-05**: `ollama.base_url` is constrained at config load to `127.0.0.1` / `localhost` hosts only
- [ ] **AGENT-06**: Turn loop handles parallel tool calls, error results, and stream disconnection without losing turn state; `SubmitOutcome { ran, superseded, rejected }` is the explicit displacement primitive; `cancelAndSubmit` is the single atomic entry for voice barge-in
- [ ] **AGENT-07**: Tool-call cap-recovery call sets `tool_choice: .none` (Anthropic: `{type:"none"}`; Ollama: drop `tools` array)
- [ ] **AGENT-08**: Tool-result content capped at 8 KB with truncation marker inserted in model-facing history; full blob written to replay log
- [ ] **AGENT-09**: `stream_truncated` retries are bounded at 1 per turn; second truncation is terminal `.providerError`; retry turns get fresh `turnId` with `retry_of` + re-snapshot + reset tool-call budget
- [ ] **AGENT-10**: Bounded `AsyncChannel(capacity: N)` at every inter-subsystem seam; replay channel capacity 2048 with drop-oldest policy for `tokenDelta` only (tool-call/turnEnd/reconfiguring/confirmation events never dropped)
- [ ] **AGENT-11**: 60s timeout on confirmation `broker.response(id)` await; timed-out = synthetic deny + log

### MCP Tools (MCP)

- [ ] **MCP-01**: MCP client uses official `modelcontextprotocol/swift-sdk v0.12.0`
- [ ] **MCP-02**: `get_time` returns the current time, invocable by the agent
- [ ] **MCP-03**: `get_clipboard` returns current clipboard contents; refuses pasteboards with `NSPasteboardTypeFileURL` regardless of string content
- [ ] **MCP-04**: `run_applescript` executes arbitrary AppleScript, gated behind a native-AppKit confirmation sheet on a hidden NSPanel (never a webview modal); `ToolCallStart.args` for confirmation-required tools serialize to webview as `{awaitingApproval: true}` until after approval
- [ ] **MCP-05**: Each MCP helper is a separately codesigned nested `.app` bundle under `Contents/Helpers/<Name>.app/`, with its own Info.plist + entitlements + per-helper TCC identity; only `mcp-applescript` holds `com.apple.security.automation.apple-events`
- [ ] **MCP-06**: Codesign is deepest-first; `--deep` is forbidden; "Code Sign On Copy" is disabled; post-build verification phase greps each helper's entitlements and fails the build on missing
- [ ] **MCP-07**: Per-server restart mutex: on helper EOF, MCPClient drains continuation map with `MCPError.serverCrashed` and lazy-restarts on next call; concurrent callers share one restart
- [ ] **MCP-08**: Child processes spawned via single `ChildSpawnGate` enforcing `FD_CLOEXEC` on parent long-lived FDs + minimal environment (`PATH=/usr/bin:/bin`)
- [ ] **MCP-09**: Confirmation broker has four legal transitions: `.timeout` (60s), `.barge`, `.approve`, `.deny`; modals are forbidden across all `@MainActor` presentation paths (lint-enforced); late-hop transitions no-op

### Voice Loop (VOICE)

- [ ] **VOICE-01**: openWakeWord `hey_jarvis` listens continuously, streaming DAG via ONNX Runtime Swift 1.24.2+ with a ≥4-consecutive-frame threshold (~320ms hysteresis); model weights vendored with SHA-256 verification
- [ ] **VOICE-02**: Silero VAD **v6.2.1** gates wake-word + STT at 512-sample/32ms chunks at 16 kHz; ORT opset-16 `silero_vad.onnx` preferred with `silero_vad_16k_op15.onnx` fallback
- [ ] **VOICE-03**: STT primary: Apple `SpeechAnalyzer` / `SpeechTranscriber` on macOS 26 Tahoe (on-device); scaffold-time Release cold-launch probe verifies `speech-recognition-assets` entitlement is load-bearing
- [ ] **VOICE-04**: STT fallback: WhisperKit via `argmaxinc/argmax-oss-swift v0.18.0`, model `large-v3-v20240930_626MB`, behind a feature flag
- [ ] **VOICE-05**: TTS tier 1: `AVSpeechSynthesizer` for instant confirmations and think-aloud (<1-sentence utterances)
- [ ] **VOICE-06**: TTS tier 2: Orpheus via `blaizzy/mlx-audio-swift v0.1.2` (`LlamaTTSModel` + `generateStream`), in-process on Apple Silicon, no Python sidecar; behind a feature flag; empirical TTFA target 150–250 ms verified at scaffold; `TTSEngineActor` with serial executor prevents Metal-buffer serialization deadlock
- [ ] **VOICE-07**: End-to-end: "Hey Jarvis, what time is it?" produces a natural-sounding spoken answer with HUD state visible through idle → listening → thinking → speaking
- [ ] **VOICE-08**: `AVAudioEngine.isVoiceProcessingEnabled = true` is called BEFORE any `connect` / `installTap`; post-AEC format is probed via `inputNode.outputFormat(forBus: 0)` not assumed (24 kHz Tahoe / 16 kHz Sonoma)
- [ ] **VOICE-09**: AEC-off is a real distinct graph variant (not a config toggle); its unavailability surfaces a HUD banner "AEC unavailable; degraded-mode active"
- [ ] **VOICE-10**: Canonical six-step audio-graph teardown sequence applies uniformly to all four rebuild triggers (device change, AEC fallback, mic re-grant, sustained ring overflow)
- [ ] **VOICE-11**: TTS interrupt: cancel Orpheus producer → 10ms cosine fade-out → `stop()` → await completion handler (≤20ms) → emit `.ttsStopped`; ducking is lowered only on `.ttsStopped`, never on `TTSEvent.finished` alone
- [ ] **VOICE-12**: Mute-wake-word toggle is accessible from the menu bar; when muted, the wake-word DAG is paused but push-to-talk remains active
- [ ] **VOICE-13**: Push-to-talk variant: hold-to-talk hotkey pathway activates STT without wake word (privacy / reliability fallback for wake-word false-negatives)
- [ ] **VOICE-14**: Barge-in: voice wake during active `.speaking` cancels TTS atomically and re-enters `.listening`; `cancelAndSubmit` is the single entry point, not two separate actor hops

### Text Input (TEXT)

- [ ] **TEXT-01**: I can type into the HUD chat panel and get streamed tokens back with identical tool-call/HUD-state behavior to voice
- [ ] **TEXT-02**: Chat panel renders streaming text with token-by-token updates and tool-call cards inline
- [ ] **TEXT-03**: Conversation history is browsable within the session; persisted turns are queryable via memory (MEM-*)

### Vision (VISION)

- [ ] **VISION-01**: Webcam feed is available to the agent, gated behind Camera TCC permission; first-use prompt surfaces with graceful-denial fallback
- [ ] **VISION-02**: Vision framework emits face-detection / presence events (e.g., "James walked back to the desk") as **signals** the agent can react to — never as triggers that initiate speech or turns
- [ ] **VISION-03**: Presence-triggered auto-speak is explicitly forbidden (anti-feature); agent may reference presence only within a user-initiated turn
- [ ] **VISION-04**: Optional: single webcam frame can be attached to a turn and sent to Opus 4.7 for scene understanding when the user asks

### Memory (MEM)

- [ ] **MEM-01**: SQLite database at `~/Library/Application Support/Jarvis/jarvis.db` with WAL mode, FTS5 built-in, and `sqlite-vec v0.1.10-alpha.3` loaded via `sqlite3_enable_load_extension` + `sqlite3_load_extension`
- [ ] **MEM-02**: `EMBEDDING_DIM = 768` is a shared constant across extraction + schema (mismatch returns garbage silently)
- [ ] **MEM-03**: Embeddings via `nomic-embed-text` on Ollama (local, free, 768-dim)
- [ ] **MEM-04**: mem0-style `ADD / UPDATE / NOOP` extraction runs after each turn, executed by local `qwen2.5-coder:32b` via Ollama; NO user data leaves the machine for memory
- [ ] **MEM-05**: Facts carry `valid_from` / `valid_to` timestamps (Zep/Graphiti-style) so superseded facts aren't deleted; history is preserved
- [ ] **MEM-06**: Memory extraction runs as a background turn (separate orchestrator instance with `.memoryExtraction` TurnSource) with a bounded job queue; does not block `turnEnd`
- [ ] **MEM-07**: The agent can retrieve prior turns on request ("what did we decide about X?") via FTS5 + vector search
- [ ] **MEM-08**: DevOverlay surfaces a minimum "memory updated" affordance — row per ADD/UPDATE showing fact + extraction trigger — so silent memory mutations are visible

### Dev / Observability (OBS)

- [ ] **OBS-01**: Dev/debug overlay toggle shows current agent state, last 5 tool calls (inputs + outputs), context token count, per-turn latency breakdown, cache creation vs read tokens
- [ ] **OBS-02**: Every turn (user input, LLM output, tool calls, tool results, HUD events) is logged to a local SQLite replay file with nothing-masked bytes (modulo `row_id, session_id, turn_id, tool_use_id, message_id, ts, monotonic_ns, turn_nonce`)
- [ ] **OBS-03**: A replay viewer can re-run a past session through the real pipeline deterministically; byte-match oracle flags drift
- [ ] **OBS-04**: Eval harness runs 15–25 hand-written scenarios on demand; pinned to `qwen2.5-coder:32b` for local model eval
- [ ] **OBS-05**: Feature flags toggle risky/in-development tools without rebuild; security-sensitive flags require app restart (launch-snapshot pin)
- [ ] **OBS-06**: Structured logs via `apple/swift-log 1.5.3+` with separate channels for agent / tools / UI / system; one `redact()` function covers API keys, `Authorization: Bearer`, `AKIA*`, `ghp_*` patterns
- [ ] **OBS-07**: Orphan-turn detection runs at startup via `meta.crash_count` + "last event ≠ turn_end" query; crashed turns get a recovery marker

### Security & Permissions (SEC)

- [ ] **SEC-01**: Anthropic API key lives in macOS Keychain (`com.kingsrook.jarvis.anthropic`); never plaintext; never in the webview JS heap; entered via native SwiftUI `SecureField`
- [ ] **SEC-02**: Hardened Runtime is enabled from day one with `com.apple.security.cs.allow-jit`; `allow-unsigned-executable-memory` is NOT widened (MLX doesn't need it)
- [ ] **SEC-03**: `com.apple.developer.speech-recognition-assets` entitlement + `NSSpeechRecognitionAssetsUsageDescription` Info.plist key in `Jarvis.entitlements` from day one; scaffold-time Release cold-launch verifies entitlement is load-bearing
- [ ] **SEC-04**: TCC permissions prompt incrementally (Microphone, Camera, Input Monitoring, Automation per-target, Accessibility as needed) with graceful denial handling per surface
- [ ] **SEC-05**: Config split: `LaunchSnapshot` carries security-sensitive keys (`applescript.*`, tool blocklist, `ollama.base_url` host, confirmation policy) — restart required; `PerTurnSnapshot` carries non-security keys (provider, tts.tier, stt flags) — applies at next `submit()`
- [ ] **SEC-06**: Prompt-injection defense: per-turn random `turnNonce` wraps untrusted content (`<UNTRUSTED_CONTENT id="<nonce>">...</UNTRUSTED_CONTENT id="<nonce>">`); nonce never crosses to webview; tag-like substrings are pre-stripped from tool-result content before wrapping
- [ ] **SEC-07**: Tool-result sanitize pipeline runs on every MCP-boundary byte stream: UTF-8 valid, strip C0 controls (except `\t`), strip bidi/zero-width, cap line length; called BEFORE packing into `LLMMessage` history
- [ ] **SEC-08**: No AppleScript skip-allowlist exists (regex-based bypass is explicitly forbidden week-one)
- [ ] **SEC-09**: Schema parity: `scripts/check-bus-protocol-version.sh` runs as Xcode pre-build phase; Swift + TS `BUS_PROTOCOL_VERSION` constants must match; round-trip test per enum case against TS fixture

---

## v2 Requirements (deferred)

### Vision & HUD

- **VISION-V2-01**: ScreenCaptureKit screen-capture tool ("what's on my screen?")
- **HUD-V2-01**: Multi-panel holographic HUD layout beyond the single particle ring
- **HUD-V2-02**: Ambient data tiles (time, weather, calendar next-up) reactive to agent activity
- **HUD-V2-03**: Ambient corner mode (minimized persistent ring) for the "it's always there" ambient-presence feel

### Tool Catalog

- **MCP-V2-01**: Calendar tool (read/write via EventKit)
- **MCP-V2-02**: Music tool (Spotify + Apple Music control)
- **MCP-V2-03**: File system tool (read/write under sandboxed root)
- **MCP-V2-04**: Browser control tool (WKWebView via Safari or Arc)
- **MCP-V2-05**: Notifications tool (post/respond to macOS notifications)

### Memory & Voice

- **MEM-V2-01**: "Forget this" explicit user control with affordance in UI
- **MEM-V2-02**: Memory-updated toast notification (non-DevOverlay user-facing surface)
- **VOICE-V2-01**: Personal fine-tuned wake-word model (lower false-accept rate vs stock `hey_jarvis_v0.1`)
- **VOICE-V2-02**: Long-answer spoken-summarization flow ("read aloud the summary, not the full 400-word answer")

### Reliability

- **OBS-V2-01**: Screen Recording TCC reprompt graceful handling (Tahoe monthly cadence)
- **OBS-V2-02**: Automated daily eval run with regression alerts

---

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-tenant / auth / login flows | Single-user personal project |
| Commercial distribution / App Store | Personal use only |
| Electron as host | Rejected — sandbox + binary size + no Apple ML access. Tauri is the only acceptable non-Swift fallback, and only if WKWebView proves untenable |
| Sonnet as primary LLM | Superseded by Opus 4.7 per CLAUDE.md |
| Cloud TTS (ElevenLabs, OpenAI TTS, PlayHT) | User constraint: voice is local-only, privacy-first |
| Cloud STT (OpenAI Whisper API, Deepgram, AssemblyAI) | Same privacy constraint |
| Remote streaming endpoints for audio | "No streaming" means no cloud; local incremental TTS is permitted and preferred |
| Multi-machine sync via iCloud / backend | Local-first until single-machine proves out |
| Kokoro-82M TTS tier | Optional tier-3 only if Orpheus proves insufficient (adds Python sidecar) |
| Presence-triggered auto-speak | Privacy-eroding anti-feature per hobbyist Jarvis failure catalog (Echo/Cortana/Siri incidents) |
| Always-speaking ambient commentary | Notification fatigue; trust-sink |
| Real-time screen-content narration | Same reason + ScreenCaptureKit TCC surface not yet scoped |
| AppleScript skip-confirmation allowlist | Regex-bypass risk; every AppleScript is privileged in v1 |
| Fully hands-free continuous conversation | Session-scoped only; "always listening" inherits voice-assistant trust-erosion failure mode |
| Silent memory updates | Trust-sink; DevOverlay row is the minimum v1 surface |
| Fixing all 22 HIGH + 22 MEDIUM AUDIT-R4 findings as a discrete gate | Audit loop is paused; findings absorbed into build phases where they apply |
| Xcode workspace; CocoaPods | `.xcodeproj` + local SPM packages (R1 H-B2) |
| HotKey SPM (Carbon-based) for plain-modifier keys | `NSEvent.addGlobalMonitorForEvents` + local monitor pair is the current best-practice (R3-S4) |

---

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SHELL-01 | P1 Foundations | Pending |
| SHELL-02 | P1 Foundations | Pending |
| SHELL-03 | P1 Foundations | Pending |
| SHELL-04 | P1 Foundations | Pending |
| SHELL-05 | P1 Foundations | Pending |
| SHELL-06 | P1 Foundations | Pending |
| HUD-01 | P3 HUD | Pending |
| HUD-02 | P3 HUD | Pending |
| HUD-03 | P2 Bus | Pending |
| HUD-04 | P2 Bus | Pending |
| HUD-05 | P2 Bus | Pending |
| HUD-06 | P2 Bus | Pending |
| HUD-07 | P3 HUD | Pending |
| HUD-08 | P3 HUD | Pending |
| AGENT-01 | P4 Agent Core | Pending |
| AGENT-02 | P4 Agent Core | Pending |
| AGENT-03 | P4 Agent Core | Pending |
| AGENT-04 | P4 Agent Core | Pending |
| AGENT-05 | P1 Foundations | Pending |
| AGENT-06 | P4 Agent Core | Pending |
| AGENT-07 | P4 Agent Core | Pending |
| AGENT-08 | P4 Agent Core | Pending |
| AGENT-09 | P4 Agent Core | Pending |
| AGENT-10 | P4 Agent Core | Pending |
| AGENT-11 | P5 MCP | Pending |
| MCP-01 | P5 MCP | Pending |
| MCP-02 | P5 MCP | Pending |
| MCP-03 | P5 MCP | Pending |
| MCP-04 | P5 MCP | Pending |
| MCP-05 | P1 Foundations | Pending |
| MCP-06 | P1 Foundations | Pending |
| MCP-07 | P5 MCP | Pending |
| MCP-08 | P5 MCP | Pending |
| MCP-09 | P5 MCP | Pending |
| VOICE-01 | P6 Voice | Pending |
| VOICE-02 | P6 Voice | Pending |
| VOICE-03 | P6 Voice | Pending |
| VOICE-04 | P6 Voice | Pending |
| VOICE-05 | P6 Voice | Pending |
| VOICE-06 | P6 Voice | Pending |
| VOICE-07 | P6 Voice | Pending |
| VOICE-08 | P6 Voice | Pending |
| VOICE-09 | P6 Voice | Pending |
| VOICE-10 | P6 Voice | Pending |
| VOICE-11 | P6 Voice | Pending |
| VOICE-12 | P6 Voice | Pending |
| VOICE-13 | P6 Voice | Pending |
| VOICE-14 | P6 Voice | Pending |
| TEXT-01 | P4 Agent Core | Pending |
| TEXT-02 | P3 HUD | Pending |
| TEXT-03 | P7 Memory + Vision | Pending |
| VISION-01 | P7 Memory + Vision | Pending |
| VISION-02 | P7 Memory + Vision | Pending |
| VISION-03 | P7 Memory + Vision | Pending |
| VISION-04 | P7 Memory + Vision | Pending |
| MEM-01 | P7 Memory + Vision | Pending |
| MEM-02 | P7 Memory + Vision | Pending |
| MEM-03 | P7 Memory + Vision | Pending |
| MEM-04 | P7 Memory + Vision | Pending |
| MEM-05 | P7 Memory + Vision | Pending |
| MEM-06 | P7 Memory + Vision | Pending |
| MEM-07 | P7 Memory + Vision | Pending |
| MEM-08 | P7 Memory + Vision | Pending |
| OBS-01 | P4 Agent Core | Pending |
| OBS-02 | P4 Agent Core | Pending |
| OBS-03 | P8 Hardening | Pending |
| OBS-04 | P8 Hardening | Pending |
| OBS-05 | P1 Foundations | Pending |
| OBS-06 | P1 Foundations | Pending |
| OBS-07 | P4 Agent Core | Pending |
| SEC-01 | P1 Foundations | Pending |
| SEC-02 | P1 Foundations | Pending |
| SEC-03 | P1 Foundations | Pending |
| SEC-04 | P1 Foundations | Pending |
| SEC-05 | P1 Foundations | Pending |
| SEC-06 | P4 Agent Core | Pending |
| SEC-07 | P5 MCP | Pending |
| SEC-08 | P1 Foundations | Pending |
| SEC-09 | P2 Bus | Pending |

**Coverage:**
- v1 requirements: 78 total
- Mapped to phases: 78
- Unmapped: 0

**Phase distribution:**
- P1 Foundations: 17 requirements (SHELL-01..06, AGENT-05, MCP-05, MCP-06, OBS-05, OBS-06, SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-08)
- P2 Bus: 5 requirements (HUD-03, HUD-04, HUD-05, HUD-06, SEC-09)
- P3 HUD: 6 requirements (HUD-01, HUD-02, HUD-07, HUD-08, TEXT-02) *(5 listed; TEXT-02 brings total to 6)*
- P4 Agent Core: 14 requirements (AGENT-01..04, AGENT-06..10, TEXT-01, OBS-01, OBS-02, OBS-07, SEC-06)
- P5 MCP: 10 requirements (AGENT-11, MCP-01..04, MCP-07..09, SEC-07)
- P6 Voice: 14 requirements (VOICE-01..14)
- P7 Memory + Vision: 13 requirements (TEXT-03, VISION-01..04, MEM-01..08)
- P8 Hardening: 2 requirements (OBS-03, OBS-04)

---

*Requirements defined: 2026-04-22*
*Traceability updated with phase names: 2026-04-22 at ROADMAP completion.*
