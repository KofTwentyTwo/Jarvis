# Jarvis

A personal, always-on macOS AI assistant styled after the Iron Man HUD. Native Swift/SwiftUI host with an embedded React + React Three Fiber HUD, driven by an agent loop that speaks Claude Opus 4.7 primarily and local Ollama (`qwen2.5-coder:32b`) as a first-class alternative, with MCP tool servers, fully-local voice (openWakeWord + SpeechAnalyzer + Orpheus via mlx-audio-swift), and local memory (SQLite + FTS5 + sqlite-vec). Personal use only — single user, single machine.

## Status

Pre-implementation. Planning complete; Phase 1 (Foundations) is next.

## Project structure

Authoritative state lives in `.planning/`:

| Path | Purpose |
|------|---------|
| `.planning/PROJECT.md` | Project context, core value, active requirements, key decisions |
| `.planning/REQUIREMENTS.md` | 78 v1 requirements with REQ-IDs, mapped to phases |
| `.planning/ROADMAP.md` | 8 phases with dependency DAG, goals, success criteria |
| `.planning/STATE.md` | Current position, scaffold-time verifications, accumulated context |
| `.planning/config.json` | GSD workflow configuration |
| `.planning/research/` | Synthesized research (stack, features, architecture, pitfalls) — see `RESEARCH-DELTAS.md` for corrections that supersede the primary research |
| `.planning/source-material/` | Pre-GSD artifacts (BRIEF, PLAN/IMPL-week-one rev 3, AUDIT R1–R4) preserved for reference; no longer authoritative |
| `CLAUDE.md` | Project instruction for AI coding agents working in this repo |

## Working on this project

This is a [GSD (Get Shit Done)](https://github.com/anthropics/gsd) project — planning, execution, and verification flow through `/gsd-*` slash commands:

```
/gsd-discuss-phase 1     # clarify Phase 1 approach before planning
/gsd-plan-phase 1        # decompose Phase 1 into plans
/gsd-execute-phase 1     # run the plans
/gsd-verify-phase 1      # verify success criteria
```

Each step commits atomically so context loss doesn't destroy work.

See `CLAUDE.md` for architectural decisions and collaboration conventions.
