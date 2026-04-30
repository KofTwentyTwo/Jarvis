---
phase: 8
slug: hardening
status: populated
nyquist_compliant: true
wave_0_complete: planned
created: 2026-04-30
---

# Phase 8 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
>
> **Authoritative source of truth for the per-requirement test map lives in `.planning/phases/08-hardening/08-RESEARCH.md` § Validation Architecture.** This file tracks execution status as tasks land; fill the table incrementally as plans are executed.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | `swift-testing` (Xcode 26 bundled) for new P8 corpus-driven suites; XCTest retained for inherited/host suites |
| **Config file** | `packages/Harness/Package.swift` (new); existing `Package.swift` files in each consumed package |
| **Quick run command** | `swift test --package-path packages/Harness --filter <SuiteName>` |
| **Full suite command** | `scripts/shipping-gate.sh` (wraps `jarvis-eval all` — fixture-only by default; add `--live` for live Anthropic + live Ollama) |
| **Release-archive probes** | `xcodebuild archive -scheme Jarvis -configuration Release` then `scripts/shipping-gate.sh --live` for the full pre-ship gate |
| **Estimated runtime** | Per-pillar suite: 5–60s. Full fixture-only `shipping-gate.sh`: ~3–5 min. With `--live`: ~10–15 min (Ollama 32B inference dominates). |

---

## Sampling Rate

- **After every task commit:** `swift test --package-path packages/Harness --filter <SuiteUnderDevelopment>` — individual pillar being worked on
- **After every plan wave:** `jarvis-eval all --skip-live` — full matrix minus opt-in live pillars
- **Before `/gsd-verify-phase`:** `scripts/shipping-gate.sh` (fixture-only) must be green
- **Phase gate:** `scripts/shipping-gate.sh --live` (full matrix including live Anthropic + live Ollama) must pass before declaring P8 complete
- **Max feedback latency:** 60s per pillar; 5 min full fixture suite

---

## Per-Plan Verification Map

| Plan | Pillar | Requirement | Test Type | Automated Command | Wave 0 Need | Status |
|------|--------|-------------|-----------|-------------------|-------------|--------|
| 08-01 | Replay oracle | OBS-03 | integration | `jarvis-eval replay <session>` | new | ⬜ pending |
| 08-01 | Drift classifier | OBS-03 | unit | `swift test --filter DriftClassifierTests` | new | ⬜ pending |
| 08-01 | Replay-golden corpus | OBS-03 | integration | `jarvis-eval replay --all Corpora/replay-golden/` | new | ⬜ pending |
| 08-02 | Injection corpus | OBS-04(a) | integration | `jarvis-eval corpus-injection` | new | ⬜ pending |
| 08-02 | SSE fixture corpus | OBS-04(b) | unit | `jarvis-eval corpus-sse` | new | ⬜ pending |
| 08-02 | NDJSON fixture corpus | OBS-04(c)-fixture | unit | `jarvis-eval corpus-ndjson` | new | ⬜ pending |
| 08-02 | Wake hysteresis corpus | OBS-04(e) | integration | `jarvis-eval wake-corpus` | new | ⬜ pending |
| 08-03 | Live Ollama | OBS-04(c)-live | integration | `jarvis-eval corpus-ndjson --live` | new | ⬜ pending |
| 08-03 | Tool-cap recovery | OBS-04(d) | integration | `jarvis-eval cap-recovery` | new | ⬜ pending |
| 08-03 | MCP crash-recovery | OBS-04(f) | integration | `jarvis-eval mcp-crash` | new | ⬜ pending |
| 08-03 | Audio-graph rebuild | OBS-04(g) | integration | `jarvis-eval audio-rebuild` | new | ⬜ pending |
| 08-04 | Checklist runner | OBS-04(h) | structural | `jarvis-eval checklist` | new | ⬜ pending |
| 08-04 | Shipping gate (full) | OBS-03 + OBS-04 | integration | `scripts/shipping-gate.sh` | new | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `packages/Harness/Package.swift` — new SPM manifest depending on Agent, LLM, MCP, Voice, Memory, Config, Logging, ReplayLog
- [ ] `packages/Harness/Sources/jarvis-eval/main.swift` — swift-argument-parser CLI entry
- [ ] `packages/Harness/Sources/Harness/Corpus/{InjectionCorpus,SSEFixtureCorpus,NDJSONFixtureCorpus,WakeHysteresisCorpus}.swift`
- [ ] `packages/Harness/Sources/Harness/Oracle/{DriftClassifier,ExclusionList,DriftReport}.swift`
- [ ] `packages/Harness/Sources/Harness/Runners/{ReplayRunner,InjectionCorpusRunner,SSEFixtureRunner,NDJSONFixtureRunner,LiveOllamaRunner,ToolCapRecoveryRunner,WakeHysteresisRunner,MCPCrashRunner,AudioGraphRebuildRunner,ChecklistRunner}.swift`
- [ ] `packages/Harness/Sources/Harness/Adapters/{ReplayMCPAdapter,MockLLMProvider}.swift`
- [ ] `packages/Harness/Sources/Harness/FDLeakDetector.swift`
- [ ] `packages/Harness/Tests/HarnessTests/{DriftClassifierTests,ExclusionListTests,FDLeakDetectorTests}.swift`
- [ ] `packages/Harness/Corpora/{injection,sse-anthropic,ndjson-ollama,wake-hysteresis,replay-golden,checklist}/...`
- [ ] `scripts/shipping-gate.sh`
- [ ] `scripts/capture-anthropic-sse.sh`
- [ ] `scripts/promote-replay-session.sh`
- [ ] `.planning/phases/{01..07}-*/checklist.yaml` — sweep-authored manifests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Six P6 HUMAN-UAT gates (VOICE-07/09/12/13/14) | OBS-04(h) via inherited debt | Physical hardware + microphone + Release archive required | Run gates per `.planning/phases/06-voice/06-HUMAN-UAT.md` after Xcode 26 launch fragility resolved |
| Orpheus empirical TTFA measurement | OBS-04(h) via inherited debt | Live MLX inference timing on host hardware | `JARVIS_REAL_MODELS=1 swift test --filter OrpheusTTFATests`; flip `features.tts.tier2 = "ttskit"` if > 250 ms |
| AVAudioEngine synthetic device-change injection | OBS-04(g) | API availability unconfirmed (researcher A6); plug/unplug USB-C audio interface mid-utterance if synthetic injection unavailable | Operator unplugs/plugs audio interface during a `.speaking` turn; harness records pre/post graph state |
| Live Anthropic SSE shape regression check | OBS-04(b) — release-time only | Costs Anthropic credits, flakiness from network | `jarvis-eval corpus-sse --live` before tagging a release |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify (P8 is uniformly verifiable — every pillar has a CLI subcommand)
- [ ] Wave 0 covers all MISSING references (new SPM module + corpus directories)
- [ ] No watch-mode flags (CI-style discrete invocations only)
- [ ] Feedback latency < 60s per pillar; < 5 min full fixture suite
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-04-30 (research § Validation Architecture is comprehensive; gaps closed by 4-plan decomposition in 08-CONTEXT.md D-01)
