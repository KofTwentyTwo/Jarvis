# Changelog

All notable changes to Jarvis are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/). Project uses
[Semantic Versioning](https://semver.org/) starting at v0.1 (no
tagged releases yet — see GitHub Milestones for the roadmap).

## [Unreleased]

### Added

- 2026-05-12 — Boot-health probe set with strict-mode escalation
  (Round 2 + Round 3 + Round 4). 8 NOT FAKED probes covering memory,
  Anthropic, Ollama, voice, vision, MCP, replay, webview. Severity
  tiers (critical/loud/soft) drive menu-bar icon color,
  non-dismissible banners, and agent system-prompt awareness
  ("DO NOT promise to remember if memory is degraded").
- 2026-05-12 — Status panel (right-click menu bar → Status…) with
  live re-probe on open + Copy report JSON.
- 2026-05-12 — Dev Overlay with 4 tabs (Agent / Tools / Health / Logs).
  Logs tab streams every swift-log line in real time, with channel +
  level filters, substring search, Cmd+P pause/resume.
- 2026-05-12 — In-code commenting style guide
  (`.planning/code-commenting-guide.md`).
- 2026-05-12 — Standard GitHub repo files: LICENSE (MIT), SECURITY.md,
  CHANGELOG.md, issue/PR templates, dependabot config.

### Changed

- 2026-05-12 — GitHub Issues is now the canonical tracker.
  `docs/TODO.md` is a deprecated cross-walk to issue numbers.
- 2026-05-12 — Memory extractor swapped to `qwen3.6`; agent-loop
  local fallback uses `qwen2.5-coder:32b` q8_0 variant.

### Fixed

- 2026-05-12 — `facts.source_turn_id` schema FK dropped; facts can
  now persist instead of failing with `SQLITE_CONSTRAINT_FOREIGNKEY`.
- 2026-05-12 — Xcode 26 `ProcessInfoPlistFile` build race that was
  silently reverting `JarvisEntitlementsVerified` to false.
- 2026-05-11 — B-02: turn-history threading (`MemoryStore.appendTurn`
  + orchestrator `sessionHistoryLookup`).

## Milestone history

Historical entries are grouped by milestone rather than by commit.
Per-phase artifacts live under `.planning/phases/<N>/`; per-commit
detail is in `git log`.

### v0.12.0 — May 2026 (Phase 9 + audit-and-stabilize)

- **Phase 9 — Orchestrator Wiring.** Closed `INT-07-01..04`:
  `TurnTranscriptStore` actor, `OrchestratorEventBroadcaster` fan-out,
  `MemoryExtractionCoordinator` with generic `AsyncSequence` input.
- **Memory substrate (D5/D6).** Real SQLite + vec0 statically linked,
  hard-fail on boot if DB load fails, `memory_stats` tool exposed.
- **Phase 10 Wave 1 — Self-knowledge MCP tools.** Four in-process
  tools (`list_tools`, `tool_help`, `runtime_status`, `agent_info`)
  wired into the live runtime. Substrate fix B-01b
  (`InProcessAwareToolDispatcher` composite routing).
- **API design swarm v1.0 contract locked.** Architectural pivot to
  API-first orchestration boundary.
- **Audit-2026-05-03 + audit-2026-05-04 follow-up.** Closed the
  "wired but dead" gaps surfaced by the audits.

### v0.11.0 — April 2026 (Phases 5–8)

- **Phase 5 — MCP.** Adopted `modelcontextprotocol/swift-sdk v0.12.0`;
  retired the hand-rolled NDJSON JSON-RPC implementation. Helpers as
  separately codesigned nested `.app` bundles with per-helper TCC.
- **Phase 6 — Voice.** openWakeWord via ONNX Runtime (sidecar
  rejected), Silero VAD v6.2.1, Apple SpeechAnalyzer primary STT,
  WhisperKit fallback via `argmaxinc/argmax-oss-swift v0.18.0`. TTS
  tiers: `AVSpeechSynthesizer` + Orpheus via `mlx-audio-swift v0.1.2`
  with `TTSKit` fallback.
- **Phase 7 — Memory + Vision.** SQLite FTS5 + sqlite-vec, mem0-style
  ADD/UPDATE/NOOP extraction, `nomic-embed-text` embeddings.
  `FrameAttachController` always-confirm, `VisionRouter` heuristic +
  context builder, `VllmMlxSidecar` for multimodal routing.
- **Phase 8 — Hardening.** Eval harness (`jarvis-eval`), replay
  oracle, corpora curation, live + integration runners, shipping-gate
  + checklist runner, four cross-plan grep gates, FD-leak detector,
  MCP crash fixture, AVAudioEngine route-change probe. Cinematic HUD
  redesign — arc-reactor ring stack.

### v0.10.0 and earlier — April 2026 (Phases 0–4)

- **Foundations → Bus → HUD → Agent Core.** Swift menu-bar app +
  borderless transparent WKWebView, typed JSON message bus
  (`WKScriptMessageHandler`), React + R3F HUD skeleton with single
  pulsing particle ring, `LLMProvider` protocol with `AnthropicProvider`
  (Opus 4.7 streaming) and `OllamaProvider` (Qwen 2.5-Coder 32B
  streaming), tool-call loop, token streaming to webview.
- **Initial three MCP tools.** `get_time`, `get_clipboard`,
  `run_applescript` (gated behind HUD confirmation).
- **Migration to GSD.** Pre-GSD source material moved to
  `.planning/source-material/`; `.planning/` becomes authoritative.

(Per-commit detail: `git log --oneline`.)
