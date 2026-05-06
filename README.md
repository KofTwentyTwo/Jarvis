# Jarvis

A personal, always-on macOS AI assistant styled after the Iron Man HUD. Native Swift host with an embedded React + React Three Fiber HUD, driven by an agent loop that streams Claude Opus 4.7 (primary) or local Ollama (`qwen2.5-coder:32b`) over an `LLMProvider` protocol, with MCP tool servers, fully-local voice (openWakeWord + SpeechAnalyzer + AVSpeechSynthesizer / Orpheus), local memory (SQLite + FTS5 + sqlite-vec), and on-device vision capture. Personal use only — single user, single machine.

## Status

`develop` at app version **0.1.0** (Info.plist `CFBundleShortVersionString`). Nine planned phases shipped; Phase 10 (self-awareness diagnostics) mid-flight — Wave 1 landed at `3974a15` (four self-knowledge MCP tools). Post-milestone audit-and-stabilize closures (Tracks A, B-1..7, C-1..6, D-1..6) are in. Day-to-day state lives in [`docs/SESSION-STATE.md`](docs/SESSION-STATE.md) and [`docs/TODO.md`](docs/TODO.md); milestone-level state in [`.planning/STATE.md`](.planning/STATE.md).

What works today, against the live tree:

| Modality | State |
|----------|-------|
| Text turns (Anthropic + Ollama) | Working end-to-end; HUD chat panel + token streaming |
| Voice loop (wake word → VAD-gated STT → orchestrator → tier-1 TTS) | Wired end-to-end; HUMAN-UAT pending on real hardware |
| Tier-2 TTS (Orpheus) | Deferred — `B-8` requires ~6 GB MLX weight download; degrades to tier-1 |
| Vision (camera capture, frame-attach to a turn) | Wired; T2 vision provider explicitly missing pending sidecar |
| Memory (extraction + hybrid search) | Code-complete; functionally OFF until `vec0.dylib` ships (Track D-5/D-6) and `ollama pull nomic-embed-text` runs (D-7) |
| MCP tools | Helpers: `get_time`, `get_clipboard`, `run_applescript` (HUD-confirmation-gated). In-process: `search_memory`, `forget_fact` (memory; gated on store + vec availability), and the Phase 10 Wave 1 self-knowledge set — `list_audio_devices`, `get_active_audio_route`, `get_self_state`, `list_camera_devices` (`74b9ac2`). |

Personal-use only; not multi-tenant, not auth'd, not a commercial product. See [`.planning/PROJECT.md`](.planning/PROJECT.md) for project context.

## Architecture quick-take

- **Native Swift / SwiftUI host** owns window management, OS integration (mic, camera, AppleScript, hotkeys, file I/O), the agent orchestrator, and persistent storage.
- **`WKWebView` hosts a React + React Three Fiber HUD** for visuals only — particle ring, chat panel, camera button. The webview is a pure rendering layer; Swift holds all truth.
- **Bidirectional typed JSON Bus** over `WKScriptMessageHandler` ([`packages/Bus`](packages/Bus)) carries state changes Swift→JS and user actions JS→Swift.
- **`LLMProvider` protocol** is provider-agnostic: `AnthropicProvider` (Opus 4.7 streaming) and `OllamaProvider` (`/api/chat` + `/v1/chat/completions`) both conform. Swap is a config toggle.
- **MCP for tools, separately codesigned helper apps under `Contents/Helpers/`.** Each helper has its own TCC identity; `mcp-applescript` is the only one with Apple Events entitlement.

Full detail in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Repository layout

| Path | Purpose |
|------|---------|
| [`App/`](App) | Swift host — `AppDelegate`, MenuBar, HUD window, Settings, Wizard, MCP runtime wiring |
| [`packages/`](packages) | 13 Swift packages under SPM (one per subsystem). See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the dependency graph. |
| [`webview/`](webview) | pnpm workspace — `@jarvis/bus` (TS mirror of the Swift Bus protocol) and `@jarvis/hud` (React + R3F HUD bundle) |
| [`mcp-servers/`](mcp-servers) | Out-of-process MCP helpers — `mcp-time`, `mcp-clipboard`, `mcp-applescript` |
| [`scripts/`](scripts) | Build/codesign scripts and 18 boundary-gate `check-*.sh` invariant linters |
| [`Resources/`](Resources) | Bundled assets — voice ONNX models, HUD bundle target, app icon source |
| [`docs/`](docs) | Live cross-session state — `SESSION-STATE.md`, `TODO.md` |
| [`.planning/`](.planning) | GSD workflow artifacts — phase plans/summaries, audit reports, research syntheses, roadmap |
| [`CLAUDE.md`](CLAUDE.md) | Project conventions and architectural decisions for AI coding agents |

## Build & test

Requires Xcode 16+ on macOS 26 Tahoe (Apple Silicon).

**SPM packages — fast, offline:**

```bash
swift test --package-path packages/AgentCore
swift test --package-path packages/Voice
swift test --package-path packages/Memory
# … one per package; see CLAUDE.md > Build / test for the full list
```

**App target** (`xcodebuild build -configuration Debug` wrapper — `swift test` doesn't compile the App target on Xcode 26):

```bash
bash scripts/check-app-builds.sh
```

**Webview HUD bundle:**

```bash
bash scripts/build-webview.sh
# or, in webview/ during dev:
cd webview && pnpm install && pnpm --filter @jarvis/hud dev
cd webview && pnpm --filter @jarvis/hud test    # vitest
```

**Boundary gates** (18 grep-based architectural invariant checks; run before pushing):

```bash
for s in scripts/check-*.sh; do bash "$s" || break; done
```

**Real-hardware / real-network env-flag tests** (interactive only):

```bash
JARVIS_REAL_MODELS=1 swift test --package-path packages/Memory --filter MemoryRegressionCorpusTests
JARVIS_REAL_CAMERA=1 swift test --package-path packages/Vision --filter CameraCaptureRealHardwareTests
JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice --filter OrpheusTTFATests
```

## Key documents

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — top-level diagram, subsystem deep-dives, anti-patterns, navigation cheat sheet
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — dev environment setup, GSD workflow, commit conventions, anti-patterns
- [`CLAUDE.md`](CLAUDE.md) — settled architectural decisions and AI agent collaboration conventions
- [`docs/SESSION-STATE.md`](docs/SESSION-STATE.md) — current session state, recent commits, what's next
- [`docs/TODO.md`](docs/TODO.md) — live triage list

## License

Personal use only. No license is granted; no contributions are solicited from outside collaborators. The repository is public-shaped purely for portability across the author's machines.
