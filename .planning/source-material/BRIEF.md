# Project Brief: Personal "Jarvis" AI Assistant for macOS

## Context for you, the LLM

I'm starting a new coding project and bringing you in fresh. This document contains everything you need to know — the vision, the architectural decisions already made, the rationale behind them, the tech stack, and what I want to build first. Read it in full before suggesting anything. Ask me clarifying questions if anything is ambiguous, but don't relitigate decisions that are already settled unless you have a strong, specific reason.

---

## The vision

I want to build a personal, fully LLM-powered AI assistant for macOS, modeled after the Jarvis UI from Iron Man. It's for my personal use. The defining qualities:

- **100% LLM-powered agent loop.** Not a chatbot with a few scripted features. The LLM is the brain — it decides what to do, calls tools, observes results, and responds.
- **Impressive, cinematic graphics.** Iron Man HUD vibe — glowing particle rings, holographic panels, reactive animations that respond to what the agent is doing. Always-visible, ambient, beautiful.
- **OS-level integration.** Read calendar, control music, open apps, execute shell/AppleScript, watch clipboard, access files, trigger workflows. Not sandboxed.
- **Two-way voice.** Wake word detection, continuous listening when I want it, natural TTS output. Low latency.
- **Video / vision.** It can see me through the webcam. Recognize when I walk into frame, read my expression, optionally see what's on my screen.
- **Chat fallback.** Text input always available.
- **Always-on, ambient presence.** Menu bar, global hotkeys, background operation, summonable from anywhere.

This is a personal project — no need to plan for multi-tenant, auth, or commercial distribution. But I want it built well: clean architecture, testable, with proper observability so I can debug weird agent behavior.

---

## Architectural decisions (already settled)

### Native macOS app with an embedded web UI

**Stack: Swift / SwiftUI app hosting a `WKWebView` for the visual layer.**

The Swift side owns:
- Window management (borderless, transparent, always-on-top when summoned)
- Menu bar item, global hotkeys, launch-at-login
- OS integration (AVFoundation, ScreenCaptureKit, CoreAudio, Vision framework, Core ML, AppleScript bridge, file system, notifications)
- The agent orchestrator — calling the LLM API, managing tool calls, streaming tokens
- Persistent storage (config, memory, logs)

The WebView owns:
- The Iron Man-style HUD — rendered in **React + React Three Fiber (R3F)** for 3D particle effects, glowing rings, holographic panels
- All visual state and animations
- Chat input/output display

**Communication between them:** JSON messages over `WKScriptMessageHandler` (Swift ↔ JS bidirectional bus). The webview is effectively a rendering layer; Swift is the brain.

### Why not pure browser / web app?

- Browsers are sandboxed — no calendar, no Spotify control, no clipboard watching, no shell, no background wake-word.
- Continuous camera/mic access without permission-prompt hell isn't viable in a browser.
- Apple's on-device ML (SFSpeechRecognizer, AVSpeechSynthesizer, Vision, Core ML) is only available natively and gives us free performance and privacy.
- Menu bar presence, global hotkeys, and always-on behavior require a native app.

### Why not pure native (SwiftUI for the HUD)?

- SwiftUI can do a lot, but for Iron Man-tier particle systems, shaders, and flashy 3D compositing, WebGL / Three.js / R3F is where the ecosystem and iteration speed are.
- Web UI is easier to iterate on visually, and I can hot-reload it during development.

### Alternatives considered and rejected

- **Electron / Tauri only:** Tauri is acceptable but has weaker access to Apple's on-device ML frameworks than native Swift. Electron is fine but heavier. If there's a strong reason to switch later, Tauri is the fallback — but start with Swift + WKWebView.

---

## LLM / agent architecture

- **Primary model:** Claude (Sonnet for the agent loop, streaming). API-based.
- **Agent loop lives in Swift.** The Swift orchestrator calls the Claude API, handles tool calls, streams tokens to the webview for display.
- **Tool system:** Use **MCP (Model Context Protocol)** for the tool/permission system. Each capability (calendar, music, shell, clipboard, vision, etc.) is an MCP server that the agent can invoke. This keeps tools modular and permission-gated.
- **Local-vs-cloud router:** Eventually we'll want to route some tasks (e.g., simple transcription, wake word, quick classification) to local models (Kokoro/Piper for TTS, Whisper for STT, small Core ML models) and reserve Claude for reasoning. Design the orchestrator with this in mind from day one — even if everything goes to Claude at first, the abstraction should exist.
- **Memory architecture:** Persistent memory stored locally — a JSON file in `~/Library/Application Support/Jarvis/` for structured data, `UserDefaults` for simple prefs. Consider SQLite or a vector store when memory gets larger. If I ever want to sync across my laptop and desktop, iCloud or a backend — but that's a later decision.

---

## Week-one scope (build this first)

Ship this end-to-end before adding anything else. The point is to prove the architecture works and have something usable.

1. **Swift app skeleton** — menu bar item, borderless transparent floating window, WKWebView filling it, global hotkey to summon/dismiss.
2. **Message bus** — JSON over `WKScriptMessageHandler`, bidirectional, with a clean typed API on both sides.
3. **React + R3F skeleton in the webview** — a single pulsing particle ring that reacts to agent state (idle / listening / thinking / speaking).
4. **Agent orchestrator in Swift** — calls Claude Sonnet via streaming API, handles the tool-call loop.
5. **Three starter tools (via MCP):**
   - `get_time` — returns current time
   - `get_clipboard` — returns current clipboard contents
   - `run_applescript` — executes arbitrary AppleScript (gated behind confirmation for now)
6. **Text input in the UI** — user types, tokens stream back, tool calls are visualized as HUD state changes (ring color/pulse rate).

That's a usable Jarvis-shaped thing. Voice, vision, and the full HUD come in subsequent weeks.

---

## Post-week-one roadmap (rough order)

1. **Voice in** — wake word detection (Porcupine or a small local model), SFSpeechRecognizer for STT.
2. **Voice out** — AVSpeechSynthesizer first, swap to local Kokoro/Piper for better quality later.
3. **Vision** — webcam feed, Vision framework for face detection / presence, optionally stream frames to Claude for scene understanding.
4. **Screen capture** — ScreenCaptureKit, let Jarvis see what's on my screen when I ask.
5. **More MCP tools** — calendar, music, file system, browser control, notifications.
6. **Memory & personalization** — persistent facts about me, my preferences, recent conversations.
7. **Full HUD** — multi-panel holographic layout, ambient data (time, weather, calendar next-up), reactive to agent activity.

---

## Non-functional requirements / dev ergonomics

Please build these in from the start — they pay for themselves many times over.

- **Dev panel / debug overlay** — toggle-able, shows current agent state, last 5 tool calls (inputs + outputs), current context token count, latency breakdown per turn.
- **Full conversation replay** — log every turn (user input, LLM output, tool calls, tool results) to a local file. Simple viewer to replay past sessions.
- **Eval harness** — 15–25 hand-written scenarios ("ask about calendar," "turn on lights," "summarize screen"). Run after significant changes. Doesn't need to be fancy.
- **Feature flags** — toggle features on/off without rebuilding. Especially for risky tools during development.
- **Clean logging** — structured logs, easy to grep, separate channels for agent / tools / UI / system.

---

## Config and storage conventions

- App support dir: `~/Library/Application Support/Jarvis/`
- Simple prefs: `UserDefaults`
- Structured data (memory, logs, tool configs): JSON files in app support dir, migrate to SQLite when size warrants
- Secrets (API keys): macOS Keychain, never plaintext

---

## What I want from you right now

Start by:

1. **Confirming you've read and understood everything above.** Flag any architectural decision you think is wrong, with specific reasoning. I'm open to being convinced, but the default is we proceed with what's written.
2. **Asking me any clarifying questions** about scope, preferences, or things I didn't cover.
3. **Proposing a concrete file/project structure** for the Swift app + webview project. Show me the directory tree and the responsibility of each major file.
4. **Then** we start building week-one scope, step by step. Don't dump 2,000 lines of code at me — we build incrementally, I review each piece, we iterate.

Assume I'm a competent developer but not a Swift expert. Explain Swift-specific idioms when they come up. I'm fluent in JS/TS, Python, and general systems thinking.

Let's go.
