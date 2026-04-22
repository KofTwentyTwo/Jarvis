# Jarvis

## What This Is

A personal, always-on macOS AI assistant styled after the Iron Man "Jarvis" HUD. It's a native Swift/SwiftUI host app with an embedded React + React Three Fiber web layer for the HUD, driven by an in-process agent loop that calls an LLM (Claude Opus 4.7 primary, local Ollama as a first-class alternative), executes tools via MCP, and speaks/listens through an all-local voice pipeline. Personal use only — single user, single machine, no multi-tenant, no auth, no commercial distribution.

## Core Value

An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — greenfield. Ship to validate.)

### Active

<!-- Current scope. Building toward these. All are hypotheses until shipped. -->

**Ambient presence / shell**
- [ ] I can summon the HUD from anywhere with a global hotkey and dismiss it the same way
- [ ] A menu-bar item is present whenever the app is running
- [ ] The HUD window is borderless, transparent, and always-on-top when summoned
- [ ] The app launches at login (opt-in) and sits quietly in the background otherwise

**HUD rendering**
- [ ] A WKWebView hosting React + R3F renders a single particle ring that pulses through four agent states: idle / listening / thinking / speaking
- [ ] All HUD state transitions are driven by Swift-side truth via a typed JSON bus over `WKScriptMessageHandler`
- [ ] Tool calls surface as visible HUD state (ring color/pulse shift) not as a hidden internal event

**Agent loop**
- [ ] The Swift orchestrator talks to an `LLMProvider` protocol with streaming; swapping Opus ↔ local Ollama is a config toggle, not a rewrite
- [ ] `AnthropicProvider` streams Claude Opus 4.7 via Messages API with cache_control `ttl: "1h"` set explicitly, handles `content_block_start`/`input_json_delta` for tool args, and reports usage tokens
- [ ] `OllamaProvider` streams Qwen 2.5-Coder 32B (known-good tool-calling baseline) via native `/api/chat` with parity coverage
- [ ] Tool-call loop handles parallel tool calls, error results, and stream disconnection without losing turn state

**MCP tools (starter set)**
- [ ] `get_time` returns current time and is invocable by the agent
- [ ] `get_clipboard` returns current clipboard contents and is invocable by the agent
- [ ] `run_applescript` executes arbitrary AppleScript, gated behind a user confirmation prompt rendered in the HUD

**Voice loop (fully local — no cloud TTS/STT)**
- [ ] Wake-word: openWakeWord `hey_jarvis` listens continuously with Silero VAD gating
- [ ] STT primary: Apple SpeechAnalyzer (macOS 26 Tahoe, on-device)
- [ ] STT fallback: WhisperKit (`large-v3-turbo`) behind a feature flag for lower-quality scenarios
- [ ] TTS tier 1: `AVSpeechSynthesizer` for instant confirmations and think-aloud
- [ ] TTS tier 2: Orpheus via `mlx-audio-swift` (in-process, no Python sidecar), behind a feature flag, streaming audio chunks with target 150–250 ms time-to-first-audio
- [ ] End-to-end: "Hey Jarvis, what time is it?" → natural-sounding spoken answer with HUD state visible throughout

**Text input fallback**
- [ ] I can type into the HUD and get streamed tokens back, with the same tool-call and HUD-state behavior as voice

**Vision (first pass)**
- [ ] Webcam feed is available to the agent, gated behind TCC permission prompts
- [ ] Vision framework does face detection / presence, emitting events the agent can react to (e.g., "James walked back to the desk")
- [ ] Optional: single-frame capture can be attached to a turn and sent to Opus for scene understanding

**Memory (first pass)**
- [ ] SQLite database at `~/Library/Application Support/Jarvis/jarvis.db` with FTS5 and `sqlite-vec` extensions loaded
- [ ] Embeddings via `nomic-embed-text` on Ollama (768-dim, local, free)
- [ ] mem0-style `ADD / UPDATE / NOOP` extraction after each turn, executed by local Qwen 2.5-Coder 32B — no user data leaves the machine for memory
- [ ] Facts carry `valid_from` / `valid_to` so superseded facts aren't deleted
- [ ] The agent can be asked about prior turns ("what did we decide about X?") and retrieve

**Dev/observability (always-on)**
- [ ] Dev/debug overlay (toggle) showing: current agent state, last 5 tool calls (inputs + outputs), context token count, per-turn latency breakdown
- [ ] Every turn (user input, LLM output, tool calls, tool results) is logged to a local replay file; a simple replayer exists
- [ ] Eval harness with 15–25 hand-written scenarios, runnable on demand
- [ ] Feature flags for risky/in-development tools, toggleable without rebuild
- [ ] Structured logs with separate channels for agent / tools / UI / system

**Secrets & permissions**
- [ ] API keys live in macOS Keychain, never in plaintext, never checked in
- [ ] TCC permissions (Microphone, Camera, Input Monitoring, Automation, Accessibility as needed) are prompted incrementally with graceful denial handling
- [ ] Hardened Runtime + `com.apple.security.cs.allow-jit` entitlement in place from day one (required for WKWebView JIT in Release)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- **Multi-tenant / auth / commercial shipping** — single-user personal project, no need for login flows, tenancy, or licensing.
- **Screen capture / ScreenCaptureKit** — deferred to v2. Adds another TCC surface and significant scope; not needed to prove the end-to-end loop.
- **Multi-panel holographic HUD / ambient data tiles (weather, calendar next-up, etc.)** — v2. The single pulsing ring is enough to validate the rendering pipeline; layout complexity waits until the core loop is solid.
- **Broader MCP tool catalog (calendar, music, file system, browser control, notifications)** — v2. The three-tool starter set proves the MCP integration; more tools are additive once the loop works.
- **Cloud TTS / cloud STT / remote streaming endpoints for voice** — hard rule. Voice is local-only. "No streaming" constraint refers to cloud services only; local incremental TTS/STT is permitted and preferred.
- **Electron as a host** — rejected. Tauri is the only acceptable non-Swift fallback, and only if Swift + WKWebView proves untenable.
- **Sonnet as primary model** — superseded. Primary is Opus 4.7 per CLAUDE.md.
- **Multi-machine sync (iCloud / backend)** — deferred. Local-first until single-machine proves out.
- **Kokoro-82M TTS tier** — optional third tier, only if Orpheus proves insufficient; adds a Python sidecar we'd rather avoid.
- **Fixing all 22 HIGH + 22 MEDIUM AUDIT-R4 findings as a discrete gate** — audit loop is paused. Findings are absorbed into build phases where they apply; we do not block on a rev-4 of PLAN/IMPL.

## Context

**Pre-existing planning corpus.** This project is pre-implementation but not pre-planning. Substantial material exists and is the source of truth for architectural decisions:
- `BRIEF.md` — original vision, decisions, week-one scope (partially superseded by CLAUDE.md).
- `CLAUDE.md` — current authoritative architectural decisions (Opus 4.7 primary, Ollama first-class, Orpheus TTS, Apple SpeechAnalyzer, SQLite + sqlite-vec memory, macOS 26 Tahoe target, Hardened Runtime + allow-jit).
- `docs/PLAN-week-one.md` rev 3 and `docs/IMPL-week-one.md` rev 3 — detailed plan and implementation spec, audit-converged on architecture tier.
- `docs/AUDIT-R1.md` through `AUDIT-R4.md` — four rounds of whiteroom audit. R4 is paused at 22 HIGH + 22 MEDIUM unresolved architecture-tier findings, which GSD absorbs into build phases rather than pursuing a rev-4 of the docs.

**Host environment.** Apple Silicon Mac running macOS 26 Tahoe. `SpeechAnalyzer` / `SpeechTranscriber` are available natively. `mlx-audio-swift` runs Orpheus in-process without Python. Ollama is assumed installed locally with `qwen2.5-coder:32b` and `nomic-embed-text` pulled.

**Author profile.** Competent generalist developer (JS/TS, Python, systems thinking). Not a Swift expert — explain Swift-specific idioms (property wrappers, actors, `@MainActor`, async/await vs Combine, `ObservableObject`) when they come up.

**Build cadence.** Incremental. No 2,000-line drops; one piece at a time, reviewed, iterated.

**Opus 4.7 footguns to track.** Tokenizer produces ~35% more tokens than Opus 3.x; cache TTL silently regressed to 5 min (pass `ttl: "1h"` explicitly); tool-use SSE parser must handle `content_block_start` with `input_json_delta` for tool args.

**Ollama tool-calling.** `qwen2.5-coder:32b` is the known-good baseline as of April 2026. Qwen 3/3.5 and Gemma 4 tool-calling are broken in Ollama; Llama 4 with `llama4_pythonic` parser is worth testing but not yet trusted.

**Security posture.** Single-user personal. Threat model is "nothing weird from the LLM, nothing weird from tool outputs, nothing weird from MCP children." Untrusted content framing, AppleScript dangerous-pattern blocklist, and tool-result truncation markers must be structural (nonces, policy enforcement at dispatch) rather than string-matching per AUDIT-R2 themes.

## Constraints

- **Tech stack (locked)**: Swift/SwiftUI host, WKWebView + React + React Three Fiber for HUD, MCP for tool system, SQLite for persistence, macOS Keychain for secrets. Do not relitigate without strong specific reason.
- **Platform**: Apple Silicon only; macOS 26 Tahoe or later required for SpeechAnalyzer. No Intel Mac support.
- **LLM primary**: Claude Opus 4.7 (`claude-opus-4-7`), streaming. Model-agnostic `LLMProvider` protocol from day one with Ollama as first-class alternate.
- **Local-only voice**: No cloud TTS/STT. No remote streaming endpoints for audio. User data (including memory extraction) stays on the machine.
- **Hardened Runtime on Apple Silicon**: `com.apple.security.cs.allow-jit` entitlement required from day one — WKWebView JavaScriptCore JIT crashes in Release builds without it.
- **Incremental delivery**: reviewed piece-by-piece; no large-batch code drops.
- **Observability non-negotiable**: dev overlay, replay log, eval harness, feature flags, structured logs built in from the start, not added later.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Swift + WKWebView over Electron/Tauri | Need Apple on-device ML (SpeechAnalyzer, Vision, Core ML), menu bar, global hotkeys, always-on mic; browsers are sandboxed out of these. Tauri is acceptable fallback only. | — Pending |
| React + R3F for HUD, not SwiftUI | R3F/WebGL ecosystem for particle/shader-heavy cinematic HUD work; SwiftUI can't match iteration speed or capability for the Iron Man aesthetic. | — Pending |
| Opus 4.7 as primary LLM; Ollama as first-class alternate | Reasoning-heavy workload fits Opus; Ollama with Qwen 2.5-Coder 32B covers offline/private/cheap/local paths from day one, not bolted on later. | — Pending |
| MCP for tools, each capability is its own server | Modular, permission-gated, reusable; industry-standard protocol; decouples tool implementation from orchestrator. | — Pending |
| Local-only voice stack | Privacy posture + latency + user constraint. openWakeWord + SpeechAnalyzer + AVSpeechSynthesizer/Orpheus covers the pipeline without cloud. | — Pending |
| SQLite + FTS5 + sqlite-vec for memory | One file, one extension dependency, keyword + vector search in the same store; scales from zero to "lots" without swapping stores. | — Pending |
| mem0-style ADD/UPDATE/NOOP extraction via local Qwen | Prevents runaway memory bloat; keeps extraction on-device; temporal validity lets facts be superseded without loss of history. | — Pending |
| Hardened Runtime + allow-jit entitlement from day one | WKWebView JS JIT crashes in Release builds without it — learn it the easy way, not at ship time. | — Pending |
| Audit loop paused at R4 | R4 did not converge (22+22 findings); most findings are mechanical wiring work; GSD absorbs them into build phases rather than pursuing rev-4. | — Pending |
| v1 scope = "usable Jarvis" (week-one + voice + vision + first-pass memory) | Week-one alone is too thin to validate the full architecture; screen capture, multi-panel HUD, and broader tool set stay in v2 to keep v1 shippable. | — Pending |
| Core Value framed as ambient presence | Beats agent-loop primacy and voice-first framings — the experience is "it's always there", not "it's a chatbot with voice." | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-21 after initialization*
