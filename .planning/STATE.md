---
gsd_state_version: 1.0
milestone: v0.12.0
milestone_name: milestone
status: milestone_complete
last_updated: "2026-05-04T22:00:00.000Z"
progress:
  total_phases: 9
  completed_phases: 9
  total_plans: 43
  completed_plans: 43
  percent: 100
---

# State: Jarvis

**Initialized:** 2026-04-22
**Last updated:** 2026-05-04 (audit-and-stabilize, post-v0.12.0)

---

## Project Reference

**Core Value:** An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

**v1 definition:** "Usable Jarvis" — week-one skeleton + full voice loop + vision first pass + memory first pass.

**Current focus:** Audit-and-stabilize cycle on the v0.12.0 milestone. All 9 phases shipped; the work in flight now is closing the "wired but dead" gaps the 2026-05-03 / 2026-05-04 audits surfaced (voice, vision, memory, bus). No new phase has been opened — the next milestone (v0.13.0) is not yet scoped.

---

## Current Position

**Status:** milestone_complete (v0.12.0). Phases 1–9 done. Audit-fix tracks (A, B-1..B-7, cleanup batch, C-1..C-6, D-1..D-6) closed in code; D-7 + the user-environment gates remain.

**Active workstream:** post-v0.12.0 audit-and-stabilize. Tracked day-to-day in `docs/SESSION-STATE.md` (handoff state across sessions) and `docs/TODO.md` (live triage list, higher-up = higher priority).

**Progress:**

[██████████] 100% — 9 / 9 phases shipped, 43 / 43 plans closed.

| Phase | Name | Status | Closed |
|-------|------|--------|--------|
| 1 | Foundations | [x] shipped | v0.1.x |
| 2 | Bus | [x] shipped | v0.2.x |
| 3 | HUD | [x] shipped | v0.3.x |
| 4 | Agent Core | [x] shipped | v0.4.x |
| 5 | MCP | [x] shipped | v0.5.x |
| 6 | Voice | [x] shipped | v0.6.x |
| 7 | Memory + Vision | [x] shipped | v0.7.x |
| 8 | Hardening | [x] shipped | v0.8.x |
| 9 | Orchestrator Wiring | [x] shipped (closes INT-07-01..04 + AGENT-09 + NullOrchestratorAdapter) | v0.12.0 |

---

## Audit-and-Stabilize (post-v0.12.0)

Two clean-room audit rounds have run since milestone close:

- **2026-05-03 — six-agent audit** (`.planning/audit-2026-05-03/`): every modality had at least one fatal break despite passing tests; "wired but dead" pattern across voice, vision, memory, bus. Yielded the Track A / B / C / D punch list.
- **2026-05-04 — six-auditor synthesis audit** (`.planning/audit-2026-05-04/SYNTHESIS.md`): re-verifies the audit-fix work. Verdict: structurally sound. Remaining real gaps are AudioLevelEmitter wiring, production chunkPump test, three documentation drift sites, and two pre-existing test failures.

**Audit-fix tracks (all closed in code):**

| Track | Scope | Last commit |
|-------|-------|-------------|
| A | Text turn + animated rings | `1f8e03e` |
| B-1..3 | Voice models bundled + WakeWordDAG typo + tier-1 TTS wiring | `ee7f6d2` |
| B-4 | AudioGraphOwner + LiveSpeechAnalyzerBridge SpeechAnalyzer API | `e9c0a34` |
| B-5 | VoiceController chunkPump + voice-loop e2e proof | `61aed20` |
| B-6 | VAD-gated STT session end | `c7f9ece` |
| B-7 | BufferBroadcaster fan-out for multi-consumer audio ring | `bce725b` |
| Cleanup | Tautology removal + leftover-stub linter + bus gateway | `08125a4`, `5cd46c9`, `ad93dac`, `6f6617e` |
| C-1..6 | Vision: CameraCapture delegate + frameStream + HUD button + missing-T2 + confirmSend + real-HW test | `7a5543a`..`19362f6` |
| D-1..4 | Memory: install cascade, tool registration, priorFacts wiring, end-to-end Brutus regression | `75a10be`..`c3bd0a5` |
| D-5/6 | Build/fetch script skeletons for libsqlite3 + sqlite-vec | `6e249ee` |

**Carry-forward (handed to user / next session):**

- D-5 / D-6 binary work — build custom `libsqlite3.dylib` with `SQLITE_ENABLE_LOAD_EXTENSION=1`; bundle `vec0.dylib`. Skeletons exist; pins (SQLite version, sqlite-vec tag, SHA256s, codesign identity) need to land then re-run.
- D-7 — `ollama pull nomic-embed-text` + `ollama pull qwen2.5-coder:32b` on the host.
- HUMAN-UAT — the six VOICE gates (VOICE-07/09/10/12/13/14) and the vision flows on a Release-signed Developer ID archive. Code-side correctness is verified; OS-level UAT is not.
- B-7-followup — AudioLevelEmitter production wiring (must use `audioGraphOwner.subscribe()`, not the legacy ring).
- T2 — production chunkPump closure currently has no integration test (audit T2).
- Three doc-drift sites flagged by 2026-05-04 documentation auditor — STATE.md (this file, now corrected), root `CLAUDE.md` lede, `06-05-controller-wiring-SUMMARY.md` postscript.

---

## Accumulated Context

### Roadmap Evolution

- Phase 9 (Orchestrator Wiring) added 2026-05-01 — closes INT-07-01..04 cross-phase dispatch deferrals identified in `v0.12.0-MILESTONE-AUDIT.md` plus the `NullOrchestratorAdapter` voice dead-end.

### Key Decisions (cumulative)

| Decision | Source | Status |
|----------|--------|--------|
| Swift + WKWebView host, React + R3F for HUD | CLAUDE.md / BRIEF.md | Locked |
| Opus 4.7 primary, Ollama `qwen2.5-coder:32b` first-class alternate | CLAUDE.md / RESEARCH-DELTAS D1 | Locked |
| MCP via official `modelcontextprotocol/swift-sdk v0.12.0` | STACK / SUMMARY | Locked |
| SQLite WAL + FTS5 + sqlite-vec v0.1.10-alpha.3 for memory | ARCHITECTURE | Locked |
| Apple SpeechAnalyzer primary STT, WhisperKit fallback | CLAUDE.md | Locked |
| AVSpeechSynthesizer tier-1 + Orpheus via mlx-audio-swift tier-2 (streaming confirmed) | RESEARCH-DELTAS D7 | Locked |
| Silero VAD v6.2.1 (upgrade from v5 baseline) | RESEARCH-DELTAS | Locked |
| Qwen3/3.5 NOT enabled as opt-in local baseline (tool-calling broken) | RESEARCH-DELTAS D3 | Locked |
| Hardened Runtime + allow-jit entitlement day one | CLAUDE.md | Locked |
| `speech-recognition-assets` entitlement Release-only — Debug excludes it because AMFI rejects ad-hoc signed bundles carrying managed entitlements (`scripts/verify-entitlements.sh`) | Build infrastructure | Locked |
| Audit loop paused at R4; findings absorbed into build phases, not a rev-4 gate | PROJECT.md | Locked |
| 8-phase structure (dependency-DAG-derived, not linear); Phase 9 added later | SUMMARY | Locked |
| Bundle ID `com.koftwentytwo.jarvis` (owner: KofTwentyTwo) — renamed from `com.kingsrook.jarvis` on 2026-04-22 during P1 Wave 4 checkpoint | Session 2026-04-22 | Locked |

### Open TODOs

Live list lives in `docs/TODO.md`. Cross-session resume context lives in `docs/SESSION-STATE.md`.

### Active Blockers

None of the audit-fix work is blocked on planning. The remaining gates are:

- User-environment work: D-5, D-6, D-7 (build/pull steps the executor can't run).
- HUMAN-UAT: voice + vision flows on a Release Developer ID archive.

### Phase 6 → Phase 8 Deferred Items (recorded 2026-04-27)

Plan 06-05's six HUMAN-UAT launch-driven gates were deferred to Phase 8 because attempts to launch the ad-hoc Debug `Jarvis.app` surfaced a pre-existing Xcode 26 / Swift 6 / Info.plist / preview-dylib codesign fragility independent of Plan 06-05's Voice work. Code-side correctness is fully verified. Sign-off carried in `.planning/phases/06-voice/06-HUMAN-UAT.md` "Deferral Note" section.

Phase 8 (Hardening) inherited:

- [x] Resolved Xcode 26 ad-hoc-Debug-bundle launch fragility (Phase 8 work)
- [ ] Drive Plan 06-05's six UAT gates (VOICE-07/09/10/12/13/14) on a Release-signed Developer ID archive — still pending HUMAN-UAT
- [ ] Empirical Orpheus TTFA measurement (target 150–250 ms) — gated on Release archive launch + `JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests`

### Scaffold-Time Verifications (resolved or carry-forward)

- [x] **P1**: Release cold-launch with `com.apple.developer.speech-recognition-assets` removed → confirmed `SFSpeechErrorCode.assetUnavailable` fires. Debug entitlement file intentionally excludes this key (AMFI rejection of ad-hoc signed managed entitlements).
- [x] **P1**: Input Monitoring TCC denial surfaces HUD banner, not silent no-op (R4-S2). Covered by `InputMonitoringDenialTests`.
- [x] **P6**: Silero v6.2.1 preserves 512-sample/32 ms/16 kHz chunk contract from v5.
- [ ] **P6**: Orpheus empirical TTFA measurement on Apple Silicon host lands in 150–250 ms target. *(Carry-forward — gated on Release archive + `JARVIS_REAL_MODELS=1` interactive run.)*
- [x] **P6**: AEC post-format probe on macOS 26 Tahoe resolves correctly.

### Deferred Research Questions

- Default global hotkey — currently "ship unset + first-launch shortcut-recorder" (SHELL-02). Locked.
- Ambient corner mode — v1.x (deferred from v1 per Out of Scope).
- "Memory updated" surface — v1 is DevOverlay row (MEM-08); toast stays v1.x.

---

## Session Continuity

The cross-session handoff has migrated out of this file into `docs/SESSION-STATE.md` and `docs/TODO.md` (introduced commit `52d0c94`, 2026-05-03). Resume protocol per `~/.claude/CLAUDE.md`:

1. Read `~/.ai/3-rules.md`, `~/.ai/2-coding-style.md`, `~/.ai/1-profile.md`, `~/.ai/4-preferences.yaml`, `~/.ai/5-learnings.md`.
2. Read project `CLAUDE.md`.
3. Read `docs/SESSION-STATE.md` and `docs/TODO.md`.
4. Read this file (`.planning/STATE.md`) for milestone-level context only.

**Last known-good checkpoint:** 2026-05-04, after the six-auditor synthesis audit and the P0-2/P0-3 test-fixture fixes. Tree clean on `develop`.

**Context to re-load after compaction or cross-machine pickup:**

1. `CLAUDE.md` (authoritative architectural decisions)
2. `docs/SESSION-STATE.md` (handoff)
3. `docs/TODO.md` (live triage list)
4. `.planning/STATE.md` (this file — milestone-level context)
5. `.planning/audit-2026-05-04/SYNTHESIS.md` (current audit verdict + punch list)
6. `.planning/research/RESEARCH-DELTAS.md` (authoritative on conflicts with base research)

---

*STATE initialized 2026-04-22 at ROADMAP completion. Body rewritten 2026-05-04 to match v0.12.0+ reality (P0-4 from `.planning/audit-2026-05-04/SYNTHESIS.md`).*
