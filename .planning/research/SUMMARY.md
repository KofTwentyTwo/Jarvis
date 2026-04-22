# Research Synthesis — Jarvis (Personal macOS AI Assistant)

**Created:** 2026-04-21
**Authority rule:** RESEARCH-DELTAS.md wins over primary four research files. D1 (`claude-opus-4-7` real), D3 (Qwen3 broken — PITFALLS correct, STACK superseded), D7 (Orpheus streaming works — downgrade from blocker), Silero v5→v6.2.1 upgrade, `speech-recognition-assets` entitlement kept as load-bearing scaffold-time check.

---

## Executive Summary

- **Stack is settled.** Swift/SwiftUI + WKWebView (React 19 + R3F 9) + Claude Opus 4.7 (streaming, URLSession + SSE) + Ollama `qwen2.5-coder:32b` + official MCP Swift SDK v0.12.0 + SQLite/FTS5/sqlite-vec + Apple SpeechAnalyzer (WhisperKit fallback) + Orpheus via mlx-audio-swift (streaming confirmed). Top-level shape survived four rounds of whiteroom audit unchanged.
- **Hard rules day one:** Hardened Runtime + `com.apple.security.cs.allow-jit`; `cache_control ttl:"1h"` plus `anthropic-beta: extended-cache-ttl-2025-04-11` header; `speech-recognition-assets` entitlement + `NSSpeechRecognitionAssetsUsageDescription` Info.plist key; launch-pinned vs per-turn config snapshot split (security keys restart-only); per-helper nested `.app` bundles under `Contents/Helpers/`, deepest-first codesign, no `--deep`; single-writer `HudStateCoordinator` (`@MainActor final class`) with precedence ladder; bounded `AsyncChannel` at every inter-subsystem seam; canonical six-step audio-graph teardown.
- **Load-bearing gotchas to instrument early:** Opus 4.7 tokenizer ~1.35x inflation → cap `tool_result` at 8 KB; Ollama emits `tool_calls` on chunk before `done:true`; Anthropic stream closes on `message_stop` not `message_delta`; `NSEvent.addGlobalMonitorForEvents(.keyDown)` silently no-ops on Input Monitoring denial; `tool_choice` must be `.none` on cap-recovery call; injection nonce must never cross to JS.
- **Phase structure follows the dependency DAG, not arbitrary numbering.** 8 phases: Foundations → Bus → HUD → Agent-core → MCP → Voice → Memory+Vision → Hardening. Observability (ReplayLog + DevOverlay + eval harness) grows alongside every step from P4 onward — NOT a P8 polish phase.
- **Open deltas resolved per RESEARCH-DELTAS.md, with three remaining scaffold-time verifications:** Opus 4.7 identifier real (user-authoritative); Qwen3 still broken (PITFALLS correct); Orpheus `generateStream` works; Silero v5→v6.2.1 upgrade; `speech-recognition-assets` entitlement unverified externally — include anyway.

---

## Stack (pinned versions, deltas-authoritative)

**LLM + agent:** `claude-opus-4-7` (string ID, hand-rolled SSE) with 1h cache TTL + beta header; `qwen2.5-coder:32b` via Ollama `/api/chat` NDJSON (Qwen3 opt-in disabled per ollama#14493/#14601/#14745); `nomic-embed-text` 768-dim embeddings; **modelcontextprotocol/swift-sdk v0.12.0** (supersedes roll-your-own JSON-RPC).

**Native + audio:** Swift 6 / Xcode 16 / macOS 26 target (macOS 13+ baseline); `NSEvent.addGlobalMonitorForEvents` + local pair (drop `HotKey` SPM); `argmaxinc/argmax-oss-swift v0.18.0` WhisperKit fallback with model `large-v3-v20240930_626MB`; Apple `SpeechAnalyzer` primary (entitlement pair required); `blaizzy/mlx-audio-swift v0.1.2` + Orpheus 3B `mlx-community/orpheus-3b-0.1-ft-bf16` tier-2 TTS (streaming confirmed); argmax TTSKit in reserve; **Silero VAD v6.2.1** (`silero_vad.onnx` opset-16 preferred, `silero_vad_16k_op15.onnx` fallback); `onnxruntime-swift-package-manager 1.24.2+`; openWakeWord ONNX embedded via ORT Swift; `TPCircularBuffer` SPSC.

**Webview (greenfield = current majors):** React 19.x, R3F 9.6.0+, drei 10.7.7+, three r184, Zustand 5.0.12, Vite 8.0.9+, TypeScript 5.5+, pnpm 9.x.

**Persistence + misc:** SQLite + FTS5 + sqlite-vec v0.1.10-alpha.3 (load extension directly; `EMBEDDING_DIM = 768` pinned); `apple/swift-log 1.5.3+` (channels agent/tools/UI/system); `apple/swift-async-algorithms 1.0.0+`; `apple/swift-argument-parser 1.3.0+`; direct `Security.framework` for Keychain.

---

## Features

### Table Stakes (13)

Global hotkey (ship unset + first-launch shortcut recorder); menu-bar with state-reflecting icon; text-chat fallback with streamed tokens; tool-call cards (expandable, not just ring color); native NSPanel confirmation (never webview); wake word + push-to-talk parity; mute-wake-word toggle; barge-in cancel with 10 ms cosine fade; browsable conversation history; sub-500 ms TTFA + streaming; token/context exposure in DevOverlay; Keychain secrets + native `SecureField` entry; incremental per-capability TCC prompting.

### Differentiators (13)

R3F cinematic particle-ring HUD; fully local voice stack; in-process Orpheus (no Python sidecar); model-agnostic Opus ↔ Ollama toggle; MCP-native per-helper `.app` bundles with per-helper TCC identity; on-device presence/face awareness (signal only); ambient "it's just there" presence; in-process memory with temporal `valid_from`/`valid_to` + mem0-style ADD/UPDATE/NOOP extraction; "forget this" control (v1.x); full conversation replay with deterministic re-run through real pipeline; eval harness tied to replay (byte-equality modulo IDs); DevOverlay with per-turn latency breakdown; feature flags (security-relevant → restart-required).

### Anti-Features (10)

Cloud TTS/STT; presence-triggered auto-speak; always-speaking ambient commentary; real-time screen-content narration; cloud-synced memory across devices; automatic app-launch on inferred intent; AppleScript skip-confirmation allowlist; multi-user/multi-tenant; fully hands-free continuous conversation (session-scoped only); silent memory updates.

---

## Architecture Snapshot

`AppDelegate` owns the startup barrier chain and single-writer HUD; WKWebView is pure rendering surface driven by typed JSON bus with versioned two-way handshake; `AgentOrchestrator` actor runs the turn loop against provider-agnostic `LLMProvider` collapsing Anthropic streaming tool-use + Ollama atomic `tool_calls` into single `.toolUseRequested`; `MCPClient` actor supervises three nested-app-bundle helpers with per-server restart mutexes; `VoiceController` actor owns audio graph with canonical six-step teardown and AEC-on/off as distinct variants; `ConfirmationBroker` resolves destructive-tool gates via non-blocking native sheet on hidden NSPanel (modals park MainActor and break barge-in); `ReplayLog` actor persists every turn to SQLite WAL with bounded `AsyncChannel(2048)` drop-oldest `tokenDelta` only.

**Core seven patterns** (see `ARCHITECTURE.md` for detail):
1. Single-writer state coordinator with precedence ladder (`awaitingConfirmation > speaking > listening > thinking > idle > booting > reconfiguring`).
2. Provider-agnostic event stream with single `.toolUseRequested` event + mandatory `toolChoice` parameter.
3. Per-server child-process actor with restart mutex.
4. Typed JSON bus with `type` discriminator + `BUS_PROTOCOL_VERSION` two-way handshake + `callAsyncJavaScript(arguments:)` (never string-interpolated).
5. Canonical six-step audio-graph teardown uniform across all four rebuild triggers.
6. Bounded `AsyncChannel(capacity: N)` at every inter-subsystem seam; drop-policy per channel.
7. `LaunchSnapshot` (security-sensitive: applescript.*, ollama.base_url, blocklist, confirmation policy — restart required) vs `PerTurnSnapshot` (provider, tts.tier, stt flags — applies next `submit()`).

---

## Top 10 Pitfalls to Build Around

1. **WKWebView `allow-jit`** [P1] — entitlement day one; Release-archive CI smoke; do NOT also widen `allow-unsigned-executable-memory`.
2. **Opus 4.7 cache TTL + beta header** [P4] — pass `ttl:"1h"` on every cache block AND header `anthropic-beta: extended-cache-ttl-2025-04-11`; unit-test serialized request.
3. **Opus 4.7 tokenizer ~1.35x inflation** [P4/P8] — cap `tool_result` at 8 KB with truncation marker; DevOverlay surfaces per-turn tokens.
4. **SSE parser edges** [P4] — skip empty `input_json_delta`; treat `message_stop` as canonical close (not `message_delta`); swallow `ping`; handle `stop_reason: "refusal"` first-class; route `thinking_delta` to own case; on disconnect emit `partial_tool_use_at_disconnect`.
5. **Ollama `tool_calls` timing** [P4] — decode whenever seen, never gate on `done:true`; separate decoders for `/api/chat` NDJSON vs `/v1/chat/completions` SSE.
6. **Helper codesign ordering** [P1/P5] — nested `.app` bundles; deepest-first; no `--deep`; no "Code Sign On Copy"; post-build entitlement-grep phase.
7. **Prompt injection** [P4/P5/P8] — per-turn nonce wrap (never leaves Swift); pre-strip tag-like substrings; native confirmation only; `sanitize → headTruncate → wrapUntrusted` ordering before packing `LLMMessage`; refuse `NSPasteboardTypeFileURL`; args masked pre-approval for `requiresConfirmation` tools; 20+ injection corpus.
8. **MCP crash + FD leakage** [P5] — drain continuation map with `MCPError.serverCrashed` on EOF; lazy restart; per-server restart mutex; single `ChildSpawnGate` enforcing `FD_CLOEXEC` + minimal env.
9. **AEC ordering + route changes** [P6] — `setVoiceProcessingEnabled(true)` before any connect/installTap; canonical 6-step rebuild uniform across four triggers; AEC-off is a real variant with HUD banner; TTS interrupt = cancel → 10 ms cosine fade → stop → await → `.ttsStopped`; ducking lowered only on `.ttsStopped`.
10. **Schema drift** [P2] — R4's dominant failure mode. Hand-written `Codable` with explicit `type` discriminator; `check-bus-protocol-version.sh` Xcode pre-build phase; round-trip per enum case; exhaustive switches (no `default`); SQL CHECK derived from enum.

**Peers to these ten:** Input Monitoring TCC envelope (P1, R4-S2 new); `tool_choice: .none` on cap-recovery (P4, R4-L1 never landed); `stream_truncated` retry budget of 1 per turn (P4); sqlite-vec dimension mismatch silently returns garbage (P7).

Full list in `PITFALLS.md`.

---

## Phase Structure (dependency-DAG-derived, 8 phases)

| # | Phase | Depends on | Delivers | NFR growth |
|---|-------|------------|----------|------------|
| P1 | **Foundations** | — | Xcode project; `allow-jit` + `speech-recognition-assets` entitlement pair; menu-bar + NSPanel + WKWebView shell; `NSEvent` hotkey with Input Monitoring envelope; `Contents/Helpers/` layout + codesign script skeleton; `config.json` launch vs per-turn split; Keychain; scripts (build-webview, codesign, check-plist-parity, verify-models, verify-fixtures, check-bus-protocol-version, prime-tcc). | Structured logs channels declared |
| P2 | **Bus** | P1 | Typed JSON bus; hand-written `Codable` with `type` discriminator; `callAsyncJavaScript(arguments:)` primitive; `BUS_PROTOCOL_VERSION` two-way handshake refusing mismatch; `OutboundBatcher @ ~30 Hz`; Xcode pre-build parity script; round-trip per enum case. | Parity tests |
| P3 | **HUD** | P2 | React 19 + R3F 9 skeleton; particle ring with seven states; `HudStateCoordinator` precedence ladder + three `for await` subscriber shims. | — |
| P4 | **Agent core** | P1 (not P2/P3) | `LLMProvider` with `toolChoice:`; `AnthropicProvider` SSE decoder; `OllamaProvider` NDJSON + `/v1` SSE fallback; `AgentOrchestrator` (`submit`/`cancelAndSubmit`/`SubmitOutcome`; per-turn nonce; snapshot split); 8 KB tool-result cap; retry budget 1; bounded `AsyncChannel` at every seam. | **ReplayLog + DevOverlay + eval harness start here** |
| P5 | **MCP** | P4 | Official MCP Swift SDK v0.12.0; three nested helper `.app` bundles; per-helper entitlements (only `mcp-applescript` has `automation.apple-events`); per-server restart mutex; `ChildSpawnGate`; deepest-first codesign; `ConfirmationBroker` non-blocking sheet (60 s, four transitions); sanitize ordering; args masked pre-approval. | Replay captures tool calls |
| P6 | **Voice** | P4 | Audio graph with correct `isVoiceProcessingEnabled` ordering; openWakeWord streaming DAG; **Silero VAD v6.2.1**; SpeechAnalyzer + WhisperKit flagged; AVSpeech tier-1 + Orpheus tier-2 flagged (format probe, TTFA 150-250 ms, `withTaskGroup` producer-segmenter, capacity-4 channel); canonical 6-step teardown; AEC-off variant; TTS interrupt; entitlement verification; Metal single-thread via `TTSEngineActor`. | — |
| P7 | **Memory + Vision** | P4 | SQLite WAL + FTS5 + sqlite-vec (`sqlite3_enable_load_extension`; 768-dim pinned); mem0-style ADD/UPDATE/NOOP via local `qwen2.5-coder:32b`; temporal validity; AVFoundation webcam + Vision face/presence (signal-only, never trigger); optional single-frame attach. | — |
| P8 | **Hardening** | Everything | 20+ injection corpus; SSE fixture corpus; Ollama NDJSON fixtures + live eval; tool-cap eval (zero `toolUseRequested` on recovery); wake-hysteresis corpus; MCP crash-recovery; device-change audio rebuild; `replay-roundtrip` oracle; "looks done but isn't" checklist. | Eval matrix gates shipping |

**Research flags (scaffold-time verification load-bearing):** P1 entitlement + Input Monitoring TCC; P6 SpeechAnalyzer + AEC post-format + Orpheus TTFA + Silero v6.2.1 contract; P7 sqlite-vec scaling + mem0 prompt templates.

**Phases unlikely to need more research:** P2 bus, P3 HUD state machine, P4 LLM streaming (fixture-testable), P5 MCP lifecycle.

---

## Open Questions for User / Scaffold-Time Verification

1. `speech-recognition-assets` entitlement on macOS 26 — externally unverified; include day one + cold-launch Release smoke at P6.
2. Default global hotkey — recommend ship unset + first-launch shortcut-recorder (Cmd+Shift+J collides Chrome/Slack/VSCode; Option+Space collides Alfred/Raycast).
3. Silero v5→v6.2.1 drop-in — contract preserved but unverified; ORT 1.24.2 opset-16 support determines `silero_vad.onnx` vs `silero_vad_16k_op15.onnx`.
4. Orpheus empirical TTFA — feasibility confirmed (D7); 150-250 ms needs measurement; TTSKit in reserve.
5. Ambient corner mode v1 or v1.x — recommend v1.x (Core Value leverage argues this is the cheap next pull).
6. "Memory updated" affordance v1 surface — minimum DevOverlay row v1; toast v1.x.
7. Mute-wake-word toggle + push-to-talk — promote to PROJECT.md Active at requirements step.

---

## Confidence

**HIGH:** Stack pins, features/anti-features, architecture top-level + 7 patterns, load-bearing pitfalls.
**MEDIUM:** macOS 26 Tahoe SpeechAnalyzer entitlement + AEC post-format specifics; Orpheus empirical TTFA; Metal serialization pitfall (single-source).
**Overall:** HIGH with three bounded verification checkpoints at scaffold.

---

## Gaps to Address at Requirements-Definition (next step)

- **Promote to Active:** mute-wake-word toggle, push-to-talk variant, minimum memory-updated affordance, menu-bar icon state reflection, tool-call cards in chat panel.
- **Resolve:** ambient corner mode timing (v1 vs v1.x), default hotkey behavior, long-answer spoken-summarization flow.
