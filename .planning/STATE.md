---
gsd_state_version: 1.0
milestone: v0.12.0
milestone_name: milestone
status: executing
last_updated: "2026-04-27T19:30:00.000Z"
progress:
  total_phases: 8
  completed_phases: 5
  total_plans: 29
  completed_plans: 29
  percent: 100
---

# State: Jarvis

**Initialized:** 2026-04-22
**Last updated:** 2026-04-22

---

## Project Reference

**Core Value:** An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

**v1 definition:** "Usable Jarvis" — week-one skeleton + full voice loop + vision first pass + memory first pass.

**Current focus:** Phase 06 — voice

---

## Current Position

Phase: 06 (voice) — EXECUTING
Plan: 1 of 5
**Phase:** 03
**Plan:** Not started
**Status:** Executing Phase 06

**Progress:**

```
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

**Next action when work resumes (including cross-machine pickup):**

1. `git pull` to get the current `develop` branch.
2. Run `/gsd-execute-phase 1` to execute Wave 1 (scaffold) first, then Waves 2a+2b in parallel, then Wave 3, then Wave 4.

**Phase 1 plans (all authored and verified):**

| Plan | Wave | depends_on | REQ-IDs | Autonomous |
|------|------|------------|---------|------------|
| `01-01-scaffold` | 1 | [] | SHELL-04, SHELL-05, SEC-02, SEC-03, MCP-05 | no (App ID capability is manual) |
| `01-02-keychain-config-logging` | 2 | [01] | SEC-01, AGENT-05, SEC-05, SEC-08, OBS-05, OBS-06 | yes |
| `01-03-app-shell-ui` | 2 | [01] | SHELL-01, SHELL-03, SHELL-04 | yes |
| `01-04-shell-wizard-wiring` | 3 | [01, 02, 03] | SHELL-01, SHELL-02, SHELL-03, SHELL-05, SHELL-06, SEC-04 | yes |
| `01-05-codesign-entitlement-probe` | 4 | [01, 02, 03, 04] | MCP-05, MCP-06, SEC-02, SEC-03, SEC-08 | no (stripped-archive probe human-verify) |

Plans 02 and 03 can run in parallel (Wave 2). VALIDATION.md carries per-task Nyquist rows for all 16 tasks.

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

**Last known-good checkpoint:** 2026-04-22 — Phase 1 **planning complete** (5 PLAN.md + VALIDATION.md per-task map populated + ROADMAP Phase-1 Plans: list finalized). Ready for `/gsd-execute-phase 1`.

**Context to re-load after compaction or cross-machine pickup:**

1. `CLAUDE.md` (authoritative architectural decisions)
2. `.planning/STATE.md` (this file)
3. `.planning/PROJECT.md`
4. `.planning/ROADMAP.md` §Phase 1
5. `.planning/REQUIREMENTS.md` (17 REQ-IDs for P1)
6. `.planning/phases/01-foundations/01-CONTEXT.md` (D-01..D-20)
7. `.planning/phases/01-foundations/01-RESEARCH.md` (Standard Stack, Validation Architecture, Open Questions)
8. `.planning/phases/01-foundations/01-UI-SPEC.md` §Open Items for Planner
9. `.planning/phases/01-foundations/01-PATTERNS.md` §Shared Patterns S-1..S-10 and §Highest-Risk Scaffolds
10. `.planning/research/RESEARCH-DELTAS.md` (authoritative on conflicts with base research)

---

*STATE initialized 2026-04-22 at ROADMAP completion. Last updated 2026-04-22 mid `/gsd-plan-phase 1`.*
