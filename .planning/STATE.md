# State: Jarvis

**Initialized:** 2026-04-22
**Last updated:** 2026-04-22

---

## Project Reference

**Core Value:** An always-on, always-summonable Jarvis I can talk to naturally and use to get things done on my Mac — the LLM is how it thinks, the HUD is how it shows up.

**v1 definition:** "Usable Jarvis" — week-one skeleton + full voice loop + vision first pass + memory first pass.

**Current focus:** Phase 1 — Foundations. Scaffold Xcode project, wire entitlement pair from day one, establish codesign layout + TCC envelope, Keychain, config snapshot split, structured logs.

---

## Current Position

**Phase:** 1 (Foundations)
**Plan:** Not started
**Status:** Roadmap complete, awaiting `/gsd-plan-phase 1`

**Progress:**

```
[                    ] 0 / 8 phases complete
```

- [ ] Phase 1: Foundations
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

### Open TODOs

(Populated by `/gsd-plan-phase` and per-turn execution. Empty at roadmap stage.)

### Active Blockers

None. Ready for `/gsd-plan-phase 1`.

### Scaffold-Time Verifications (must resolve during their owning phase)

- [ ] **P1**: Release cold-launch with `com.apple.developer.speech-recognition-assets` removed → confirm `SFSpeechErrorCode.assetUnavailable` fires (load-bearing claim).
- [ ] **P1**: Input Monitoring TCC denial surfaces HUD banner, not silent no-op (R4-S2).
- [ ] **P6**: Silero v6.2.1 preserves 512-sample/32ms/16kHz chunk contract from v5.
- [ ] **P6**: Orpheus empirical TTFA measurement on Apple Silicon host lands in 150–250 ms target.
- [ ] **P6**: AEC post-format probe on macOS 26 Tahoe resolves 24 kHz (Tahoe) vs 16 kHz (Sonoma) correctly.

### Deferred Research Questions

- Default global hotkey — currently "ship unset + first-launch shortcut-recorder" (SHELL-02). No further decision needed pre-P1.
- Ambient corner mode — v1.x (deferred from v1 per Out of Scope).
- "Memory updated" surface — v1 is DevOverlay row (MEM-08); toast stays v1.x.

---

## Session Continuity

**Next action when work resumes:**
1. Run `/gsd-plan-phase 1` to decompose Phase 1 (Foundations) into executable plans.
2. Expected plan count (standard granularity): 3–5 plans for P1.
3. Phase 1 deliverable: a cold-launched Release build of the bare shell with all entitlements, TCC envelope, Keychain, codesign layout, and config substrate verifiable end-to-end on a fresh machine.

**Last known-good checkpoint:** Roadmap written, STATE initialized, REQUIREMENTS.md traceability updated with phase names.

**Context to re-load after compaction:**
1. `.planning/PROJECT.md`
2. `.planning/REQUIREMENTS.md`
3. `.planning/ROADMAP.md`
4. `.planning/STATE.md` (this file)
5. `.planning/research/SUMMARY.md` + `RESEARCH-DELTAS.md`
6. `CLAUDE.md` (authoritative architectural decisions)

---

*STATE initialized 2026-04-22 at ROADMAP completion.*
