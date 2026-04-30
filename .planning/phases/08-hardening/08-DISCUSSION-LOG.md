# Phase 8: Hardening — Discussion Log

**Date:** 2026-04-30
**Mode:** auto / yolo (per `.planning/config.json` + auto-mode session flag)
**Outcome:** User opted out of per-area deliberation. Decisions locked from research recommendations + STATE.md inherited-debt guidance.

---

## Session Shape

The discuss-phase orchestrator analyzed the phase against:
- ROADMAP.md §Phase 8 (success criteria 1–2 + 8-pillar matrix labels (a)–(h))
- 08-RESEARCH.md (827 lines, HIGH/MEDIUM confidence breakdown, 7 pitfalls, 8 assumptions, 5 open questions with researcher recommendations)
- STATE.md "Phase 6 → Phase 8 Deferred Items" (Xcode 26 launch fragility, 6 P6 UAT gates, Orpheus TTFA)
- Existing codebase scout (12 packages already present, 18 `scripts/check-*.sh` mechanization seeds, P4 Replay/DevOverlay landed)

Six gray areas were identified:
1. Plan structure / decomposition
2. Live-mode policy (fixture-only vs live in shipping gate)
3. Replay golden corpus shape
4. Inherited P6/P7 deferred-debt scope
5. Checklist bootstrap strategy (retroactive sweep vs per-phase ownership)
6. Pillar-specific thresholds (wake FAR/FRR, MCP crash count)

The user was offered selection across four of these (plan-structure, live-mode, golden-corpus, checklist-bootstrap). User responded **"none"** — explicit opt-out of per-area deliberation.

---

## Resolution Strategy

Auto mode + YOLO config + opt-out signal mean: lock decisions per researcher recommendations and STATE.md guidance. No further deliberation needed.

**Decisions captured in 08-CONTEXT.md (D-01 .. D-24):**

| Area | Decision | Source |
|------|----------|--------|
| Plan structure | 4 plans (oracle / corpora / live+integration / checklist+gate) | RESEARCH §Summary "Primary recommendation" |
| Harness location | New `packages/Harness` SPM module + `jarvis-eval` CLI | RESEARCH §Recommended Project Structure |
| Test framework | `swift-testing` for new P8 suites; XCTest retained for inherited | RESEARCH §State of the Art + §Pattern 3 |
| Live-mode policy | Fixture-only is the gate; `--live` opt-in with env-var guard | RESEARCH §Open Q #2 + §Security Domain |
| Replay golden corpus | 5–10 hand-selected sessions covering 8 archetypes | RESEARCH §Open Q #1 |
| Replay schema versioning | Bump on shape change; oracle rejects older versions | RESEARCH §Pitfall 1 |
| P6/P7 inherited debt | In scope per STATE.md; lands in plan 08-03 as Wave-1 prereq | STATE.md "Phase 6 → Phase 8 Deferred Items" |
| Audio-rebuild graceful degradation | Probe AVAudioEngine API early; downgrade device-change to MANUAL if unavailable | RESEARCH A6 + §Pitfall 7 |
| Checklist bootstrap | P8 retroactive sweep of P1–P7; per-phase ownership going forward | RESEARCH §Open Q #5 |
| Mechanization types | swift_test / script / grep_negative / grep_positive / plist_check / codesign_grep / MANUAL | RESEARCH §"Looks done but isn't" + §Security Domain |
| Wake FAR/FRR thresholds | Fail at FAR>1.0/hr OR FRR>10%; warn between published targets and fail line | RESEARCH §Open Q #3 |
| MCP crash count | Profile-then-decide: 100 if at most 200ms/crash, else 50 with --extended | RESEARCH §Open Q #4 |
| Drift exclusion list | Inherits OBS-02 verbatim; adds nondeterministicUnderSampling set | RESEARCH §Pattern 2 |
| Tool-cap recovery test | Both event-count AND outbound HTTP body inspection | RESEARCH §Pitfall 5 |
| Injection corpus shape | 20+ items, majority .toolResult/.mcpHelperOutput vectors | RESEARCH §Pitfall 2 |
| Jarvis-specific corpus items | 6 mandatory inclusions enumerated | RESEARCH §Code Examples |
| Penetration depth corpus items | 2–3 expected to reach confirmation-sheet layer | RESEARCH A8 |

---

## Deferred Ideas (preserved for v2)

- Automated daily evaluation run with regression alerts (OBS-V2-02)
- Multi-model regression grid (Opus vs Haiku vs Qwen3-when-fixed vs Llama 4)
- Automated fuzzing / mutation-based injection generation
- Formal coverage metrics (branch coverage, mutation score)
- Production observability stack (Datadog / OTel export)
- Cross-platform CI matrix
- Full historical replay against every recorded session (gated behind `--all` opt-in audit)

---

## Next Steps

CONTEXT.md committed → `/gsd-plan-phase 8 --chain --auto` to autonomously plan + execute + verify Phase 8.

