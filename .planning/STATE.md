---
gsd_state_version: 1.0
milestone: v0.12.0
milestone_name: milestone
status: executing
last_updated: "2026-05-01T19:26:01.288Z"
progress:
  total_phases: 9
  completed_phases: 8
  total_plans: 43
  completed_plans: 39
  percent: 91
---

# State: Jarvis

**Initialized:** 2026-04-22
**Last updated:** 2026-04-22

---

## Project Reference

**Core Value:** An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

**v1 definition:** "Usable Jarvis" — week-one skeleton + full voice loop + vision first pass + memory first pass.

**Current focus:** Phase 09 — orchestrator-wiring

---

## Current Position

Phase: 09 (orchestrator-wiring) — EXECUTING
Plan: 1 of 4
**Phase:** 07 (memory-vision) — PLANNED
**Plans:** 6 (07-01..07-06; all written + verified by gsd-plan-checker, no issues)
**Status:** Executing Phase 09

**Progress:**

[██████████] 100%
[                    ] 0 / 8 phases complete

```

- [ ] Phase 1: Foundations — **planned** (5 plans across 4 waves, 17/17 REQ-IDs covered); ready to execute
- [ ] Phase 2: Bus
- [ ] Phase 3: HUD
- [ ] Phase 4: Agent Core
- [ ] Phase 5: MCP
- [ ] Phase 6: Voice
- [ ] Phase 7: Memory + Vision
- [ ] Phase 8: Hardening

---

## Performance Metrics

**Planning phase cadence:**

- PROJECT.md initialized: 2026-04-21
- REQUIREMENTS.md defined: 2026-04-22 (78 v1 requirements across 10 categories)
- Research synthesis complete: 2026-04-21 (SUMMARY + STACK + FEATURES + ARCHITECTURE + PITFALLS + RESEARCH-DELTAS)
- Four rounds of whiteroom audit (AUDIT-R1 through AUDIT-R4) — R4 paused at 22 HIGH + 22 MEDIUM findings absorbed into build phases
- ROADMAP.md defined: 2026-04-22 (8 phases, dependency-DAG-derived)

**Execution metrics:** (populated as phases complete)

- Turnaround per phase: —
- Plans per phase avg: —
- Eval matrix pass rate: —

---

## Accumulated Context

### Roadmap Evolution

- Phase 9 added: Phase 9 (Orchestrator Wiring) added 2026-05-01 — closes INT-07-01..04 cross-phase dispatch deferrals identified in v0.12.0-MILESTONE-AUDIT.md plus the NullOrchestratorAdapter voice dead-end

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
| `speech-recognition-assets` entitlement + Info.plist key day one (verify load-bearing at scaffold) | RESEARCH-DELTAS | Locked |
| Audit loop paused at R4; findings absorbed into build phases, not a rev-4 gate | PROJECT.md | Locked |
| 8-phase structure (dependency-DAG-derived, not linear) | SUMMARY | Locked |
| Bundle ID `com.koftwentytwo.jarvis` (owner: KofTwentyTwo) — renamed from `com.kingsrook.jarvis` on 2026-04-22 during P1 Wave 4 checkpoint; App ID not yet registered at developer.apple.com | Session 2026-04-22 | Locked |

### Open TODOs

(Populated by `/gsd-plan-phase` and per-turn execution. Empty at roadmap stage.)

### Active Blockers

None. Ready for `/gsd-plan-phase 1`.

### Phase 6 → Phase 8 Deferred Items (recorded 2026-04-27)

Plan 06-05's six HUMAN-UAT launch-driven gates were deferred to Phase 8 because attempts to launch the ad-hoc Debug `Jarvis.app` surfaced a pre-existing Xcode 26 / Swift 6 / Info.plist / preview-dylib codesign fragility that is independent of Plan 06-05's Voice work. Code-side correctness is fully verified (64 swift tests pass; App target compiles cleanly with the new Voice package wiring; all five VOICE-07/09/12/13/14 invariants covered by deterministic XCTest cases). Sign-off carried in `.planning/phases/06-voice/06-HUMAN-UAT.md` "Deferral Note" section.

Phase 8 (Hardening) inherits:

- [ ] Resolve Xcode 26 ad-hoc-Debug-bundle launch fragility (`SWIFT_ENABLE_DEBUG_DYLIB=NO` is set but ignored; Info.plist marker write is reverted post-build by something downstream of post-codesign; `codesign --verify` reports `invalid Info.plist (plist or signature have been modified)` after a clean build's BUILD SUCCEEDED)
- [ ] Drive Plan 06-05's six UAT gates (VOICE-07 happy path, VOICE-14 barge-in, VOICE-13 PTT, VOICE-12 mute-wake-word + PTT-still-armed, VOICE-09 AEC banner, VOICE-10 mic re-grant) on a Release-signed Developer ID archive
- [ ] Empirical Orpheus TTFA measurement (target 150–250 ms) — once Release archive launches, run `JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests` interactively; if > 250 ms, flip `features.tts.tier2 = "ttskit"` in default config

### Scaffold-Time Verifications (must resolve during their owning phase)

- [ ] **P1**: Release cold-launch with `com.apple.developer.speech-recognition-assets` removed → confirm `SFSpeechErrorCode.assetUnavailable` fires (load-bearing claim).
- [ ] **P1**: Input Monitoring TCC denial surfaces HUD banner, not silent no-op (R4-S2).
- [ ] **P6**: Silero v6.2.1 preserves 512-sample/32ms/16kHz chunk contract from v5.
- [ ] **P6**: Orpheus empirical TTFA measurement on Apple Silicon host lands in 150–250 ms target. *(Now grouped with Phase 8 deferred items above; same blocker.)*
- [ ] **P6**: AEC post-format probe on macOS 26 Tahoe resolves 24 kHz (Tahoe) vs 16 kHz (Sonoma) correctly.

### Deferred Research Questions

- Default global hotkey — currently "ship unset + first-launch shortcut-recorder" (SHELL-02). No further decision needed pre-P1.
- Ambient corner mode — v1.x (deferred from v1 per Out of Scope).
- "Memory updated" surface — v1 is DevOverlay row (MEM-08); toast stays v1.x.

---

## Session Continuity

**Resumed 2026-04-29** from `HANDOFF.json` mid-`/gsd-plan-phase 7` (planner stream timeout after 1/6 plans). Workflow chose `--chunked --skip-ui`: outline (~2 min) → 5 per-plan Tasks (~3-20 min each, parallelized in background) → plan-checker (PASSED, no issues, no revision iterations needed). Coverage gates: REQ 13/13, Decisions 16/16. Cosmetic non-blocker: `gsd-sdk roadmap.annotate-dependencies 07` errored with a `t.trim is not a function` upstream bug — wave headers + cross-cutting truths NOT applied to ROADMAP; plans themselves are unaffected.

`HANDOFF.json` and Phase 7 `.continue-here.md` are now superseded by this STATE.md update; safe to delete on next resume cycle.

**Re-resumed 2026-04-29** via `/gsd-resume-work` — STATE.md loaded cleanly, no interrupted agents, no pending todos. Routing user to `/clear` + `/gsd-execute-phase 7`.

---

**Next action when work resumes (including cross-machine pickup):**

1. `git pull` to get the current `develop` branch.
2. Run `/gsd-execute-phase 7` to execute Wave 1 (07-01 already on disk pre-resume), then Wave 2 (07-02 + 07-04 in parallel — disjoint scope), Wave 3 (07-03), Wave 4 (07-05), Wave 5 (07-06 integration closer).

**Phase 7 plans (all authored and verified by gsd-plan-checker — VERIFICATION PASSED, no issues):**

| Plan | Wave | depends_on | REQ-IDs | Autonomous | Commit |
|------|------|------------|---------|------------|--------|
| `07-01` Memory schema + sqlite-vec store | 1 | [] | MEM-01, MEM-02 | yes | `4009d89` |
| `07-02` Embedder + Extractor + bg orchestrator | 2 | [01] | MEM-03, MEM-04, MEM-05, MEM-06 | yes | `f94bf9a` |
| `07-03` Memory read + MCP + DevOverlay | 3 | [02] | MEM-07, MEM-08, TEXT-03 | yes | `97e855f` |
| `07-04` Vision capture + Presence | 2 | [01] | VISION-01, VISION-02, VISION-03 | yes | `e697eaa` |
| `07-05` Frame-attach + multimodal + T1/T2/T3 | 4 | [04] | VISION-04 | yes | `8de01bc` |
| `07-06` AppDelegate wiring + regression corpus + 4 grep gates | 5 | [03, 05] | (integration; verifies all 13) | yes | `6e70dd3` |

Wave 2 (07-02 + 07-04) is the parallelism win: disjoint `files_modified` (`packages/Memory/*` vs `packages/Vision/*`).

**Phase 7 pre-plan artifacts (all committed):**

| File | Size | Purpose |
|------|------|---------|
| `07-CONTEXT.md` | 21 KB | D-01..D-18 LOCKED decisions from `/gsd-discuss-phase 7` |
| `07-RESEARCH.md` | 18 KB / 290 lines | schema/SQL, mem0 prompt template, supersede transaction, hybrid search RRF, presence pipeline, Camera TCC, package layout, pitfalls |
| `07-PATTERNS.md` | 63 KB / 1,423 lines | 23 new + 7 modified surfaces with code excerpts; 5 highest-risk scaffolds flagged |
| `07-PLAN-OUTLINE.md` | 5 KB | chunked-mode manifest of the 6-plan / 5-wave decomposition |

**Phase 1 pre-plan artifacts (all committed):**

| File | Size | Commit | Purpose |
|------|------|--------|---------|
| `01-CONTEXT.md` | 17 KB | `b17ebe5` | 20 locked decisions D-01..D-20 from discuss-phase |
| `01-DISCUSSION-LOG.md` | 15 KB | `b17ebe5` | Source material for CONTEXT |
| `01-UI-SPEC.md` | 51 KB | `e5709db` / `5fc373b` | Approved design contract (6/6 dimensions PASS); 10 "Open Items for Planner" |
| `01-RESEARCH.md` | 110 KB | `57baac5` | 10 planner-questions answered + Standard Stack + Validation Architecture + 8 Open Questions/Pitfalls |
| `01-VALIDATION.md` | 5 KB | `2d61e7c` | Nyquist sampling strategy (points at RESEARCH §Validation Architecture for detailed map) |
| `01-PATTERNS.md` | 43 KB | `0efef01` | 51 files classified (all greenfield); S-1..S-10 shared patterns; 3 highest-risk scaffolds flagged |

**Load-bearing deviations from original research:**

- **RESEARCH §Open Q #8:** `verify-entitlements.sh` must run in a **pre-codesign** phase (not post-codesign) or the `JarvisEntitlementsVerified=YES` write invalidates the signature. Planner MUST order build phases: compile → `verify-entitlements.sh --pre-codesign` → `codesign.sh` → `verify-entitlements.sh --post-codesign`.
- **RESEARCH §Open Q #2:** Enabling `com.apple.developer.speech-recognition-assets` capability on the Developer portal App ID (`com.koftwentytwo.jarvis`) is a **manual human step** in developer.apple.com — not scriptable. Planner must include a task with `autonomous: false`.
- **RESEARCH Q1:** Keychain → raw `Security.framework` (not `KeychainAccess` SPM). ~60 LOC wrapper in `packages/Keychain`.
- **RESEARCH Q3:** swift-log → `MultiplexLogHandler([FileLogHandler, OSLogHandler])`; file rotation hand-rolled (~80 LOC) to match D-18 spec exactly.
- **PATTERNS §S-3:** `redact()` lives in `FileLogHandler` only — NOT in `os.Logger` handler. Callers must redact before logging untrusted variables.

**Last known-good checkpoint:** 2026-04-29 — Phase 7 **planning complete** (6 PLAN.md verified by gsd-plan-checker, REQ 13/13 + D 16/16 coverage). Ready for `/gsd-execute-phase 7`.

**Context to re-load after compaction or cross-machine pickup:**

1. `CLAUDE.md` (authoritative architectural decisions)
2. `.planning/STATE.md` (this file)
3. `.planning/PROJECT.md`
4. `.planning/ROADMAP.md` §Phase 7
5. `.planning/REQUIREMENTS.md` (13 REQ-IDs for P7)
6. `.planning/phases/07-memory-vision/07-CONTEXT.md` (D-01..D-18 LOCKED)
7. `.planning/phases/07-memory-vision/07-RESEARCH.md` (no `## Validation Architecture` — Dimension 8 satisfied per-task)
8. `.planning/phases/07-memory-vision/07-PATTERNS.md` (analog-file map; do NOT re-run pattern-mapper)
9. `.planning/phases/07-memory-vision/07-PLAN-OUTLINE.md` + `07-01..07-06-PLAN.md` (the contract for execute-phase)
10. `.planning/research/RESEARCH-DELTAS.md` (authoritative on conflicts with base research)

---

*STATE initialized 2026-04-22 at ROADMAP completion. Last updated 2026-04-29 at end of `/gsd-plan-phase 7 --skip-ui --chunked`.*
