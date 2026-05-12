# Handoff — End of 2026-05-12

**Session date:** 2026-05-12
**Branch:** `develop` (push current)
**HEAD:** `0cc94c6` — `docs(branding): assets/branding/ + restore MIT license section`
**Open PR:** [#149](https://github.com/KofTwentyTwo/Jarvis/pull/149) (draft, `docs/public-launch-building`) — adds `BUILDING.md` + a `ced7a4f` README MIT-cleanup commit that removes the stale `<!-- TODO: LICENSE -->` block. **Merge after a quick review — first action next session.**
**Total open issues:** **141** across 6 milestones (v0.1: 27 / v0.2: 23 / v0.5: 31 / v0.8: 36 / v1.0: 13 / v1.1: 11).

---

## What landed today

Walking a new reader from `70dd0d4` (yesterday's handoff commit) to `0cc94c6`. 28 commits, six themes.

**1. Round 2/3/4 strict-mode arc.** Yesterday's handoff scoped Rounds 2 + 3 (boot health probes + Status menu panel). Both shipped — `687b80b` (boot-phase probes, NOT FAKED, structured logs), `67748f5` (Status… NSPanel with live re-probe on open), `b2f0abb` (await probe registration inline to close the runAll race). Round 4 was added in-session because the user surfaced "agent should know its own state": `cfd469f` (severity model `ok/soft/loud/critical`), `79955b6` (non-dismissible banners for critical), `23b4ca7` (agent system-prompt preamble injects subsystem state), `a9531e6` (menu-bar icon turns red when degraded), `740bed4` (tag-agnostic ollama probe + in-process MCP tool counts). The "Toby fix" — agent now refuses to lie about remembering when memory is degraded — was validated mid-dogfood against a fresh conversation.

**2. Schema FK fix (`a5999e2`).** Latent for the project's entire history: `facts.source_turn_id REFERENCES turns(id)` was incompatible with the writer's FNV-hash strategy for synthesizing turn ids. Every fact INSERT failed silently with `SQLITE_CONSTRAINT_FOREIGNKEY`. Dropped the FK; facts now persist. One fact ("user name is Toby") exists in the live DB — the extraction itself is a separate single-turn-context bug, see Memory issues below.

**3. Xcode 26 build race (`1557302`).** `ProcessInfoPlistFile` was being scheduled **after** `verify-entitlements --pre-codesign`, silently reverting `JarvisEntitlementsVerified` back to false on every clean build. The diagnostic agent caught it via 250 ms `plutil` polling. Fix: declared the Info.plist as an `inputFile` of pre-codesign so Xcode schedules them in dependency order.

**4. Audit pass (`.planning/audit-2026-05-12/`, 5 reports).** Five parallel agents covered Memory / Voice / Vision / MCP+Agent / Bus+HUD, plus a DevOverlay diagnosis. ~37 findings filed as GitHub issues. Headline "wired but dead" examples (all open):
- Memory M-1 (#12): `facts_vec` never written — semantic search permanently empty (RRF degrades to FTS5-only).
- Memory M-2 (#13): replay log poisoned by synthetic `memory-trigger-<hash>` turn_ids; all batches FK-fail since 18:48.
- Memory M-3 (#14): `search_memory` missing from agent preamble — proactive recall dead by discovery gap.
- Voice P0-1 (#28): wake-word dies on every audio-graph rebuild — `cancelInFlight` calls `cancel()` not `stopFeed()`.
- Voice P0-2 (#29): STT backend hard-coded to `"speech_analyzer"`; `whisperKitFallback` config + camelCase/snake_case mismatch dead.
- MCP CRIT-1 (#20): `ReplayingToolResultObserver.turnIDResolver` permanently nil — SEC-07 dual-write + ME-04 channel dead in prod.
- Bus/HUD S1-2 (#41): `MenuBarIconController.transition(to:)` production-dead — icon never animates per agent state.
- Bus/HUD S1-1 (#40): `BridgeNavigationDelegate` missing `didFail*` arm — silent black HUD on bundle / JS load failure.
- Bus/HUD S1-3 (#42, **closed today**): DevOverlay was a hollow shell — fixed in the next theme.

**5. Dev Overlay (`8d94c1c` → `50c2783` → `6ea2852`).** Started with the diagnosis (panel rendered nothing because the snapshot emitter was never instantiated). Built a 4-tab AppKit `NSPanel` (Agent / Tools / Health / Logs); wired `DevSnapshotEmitter` end-to-end so each tab has live data. Added a `LogBroadcaster` actor + `BroadcastLogHandler` that joins the swift-log multiplex so every log line streams live to the Logs tab; channel + level filters, substring search, Cmd+P pause. Closes Bus/HUD S1-3.

**6. Tracking migration to GitHub Issues** (`4f4a558`, `60f179c`, `2a872fc`). 141 issues now live on GitHub across 6 milestones (audit findings + carry-forwards + the M-0..M-7 migration epic with 54 sub-issues + comment-cleanup tiered work + v1.1 backlog + PTT/InputMonitoring v1 holes). `docs/TODO.md` deprecated to crosswalk-only. `CLAUDE.md` declares GitHub Issues canonical. `docs/SESSION-STATE.md` points at GitHub for live state.

**7. Code-commenting style guide (`b763273`, 583 lines).** "Felt orientation in 30s" guide locked. `App/AppDelegate.swift` brought to standard as the P0 exemplar (`281b909`) — pattern proven; P1 files (#66–#69) now unblocked.

**8. Roadmap + branding** (`61e06fb` and the marketing series `4e69114`, `e0c5bcb`, `9b62db5`, `c4c32f7`, `b2710ee`, `e1fcdc5`, `0cc94c6`). `.planning/ROADMAP-2026-05-12.md` defines 6 user-outcome milestones (v0.1 "It actually works" / v0.2 audit punch-list / v0.5 M-0..M-3 / v0.8 M-4..M-7 / v1.0 / v1.1). README rewritten with mermaid diagrams + acknowledgments + culture section. MIT confirmed; rationale at `.planning/decisions/license.md`. Standard repo files added: LICENSE, SECURITY.md, CHANGELOG.md, issue + PR templates, dependabot config, branding assets.

## Commits (chronological, `70dd0d4..0cc94c6`)

```
5718bdd test(memory): rename qwen25Coder32B test to qwen36
687b80b feat(round-2): boot-phase health probes — NOT FAKED, structured logs
67748f5 feat(round-3): Status… menu item + NSPanel — live re-probe on open
b2f0abb fix(round-2): await probe registration inline to close runAll race
cfd469f feat(round-4): probe severity model — ok/soft/loud/critical
79955b6 feat(round-4): non-dismissible banners for critical subsystem failures
23b4ca7 feat(round-4): agent system prompt knows when subsystems are degraded
a9531e6 feat(round-4): menu-bar icon turns red when subsystems are degraded
740bed4 fix(round-4): tag-agnostic ollama probe + mcp probe counts in-process tools
beb9d51 test(agent-core): update qwen2.5-coder literal to q8_0 variant
1557302 fix(build): force ProcessInfoPlistFile before pre-codesign
b763273 docs(style): code-commenting style guide — felt orientation in 30s
a5999e2 fix(memory): drop broken FK on facts.source_turn_id — closes Toby-fact persistence
8d94c1c docs(devoverlay): diagnose why the panel renders nothing
50c2783 feat(devoverlay): wire DevSnapshotEmitter end-to-end + add tabbed view
4f4a558 docs(claude.md): declare GitHub Issues as canonical tracker
60f179c docs(todo): deprecate TODO.md — issues moved to GitHub
2a872fc docs(session-state): point to GitHub Issues; preserve handoff narrative
6ea2852 feat(devoverlay,logging): live log stream — every swift-log line into the overlay
61e06fb docs(roadmap): user-outcome-focused milestone roadmap
9b62db5 docs(github): add LICENSE + SECURITY.md
e0c5bcb docs(github): issue + PR templates + dependabot config
4e69114 docs(changelog): add CHANGELOG.md with milestone history
c4c32f7 docs(readme): refresh — diagrams + architecture + culture + roadmap
e1fcdc5 docs(license): MIT decision + rationale
b2710ee docs(readme): branding pass — badges, MIT license, acknowledgments
281b909 docs(appdelegate): apply commenting style guide (P0 of #64)
0cc94c6 docs(branding): assets/branding/ + restore MIT license section
```

## Open PRs

- **[#149](https://github.com/KofTwentyTwo/Jarvis/pull/149)** `docs/public-launch-building` — draft. Contains BUILDING.md + a README MIT-cleanup commit (`ced7a4f`) that removes the stale `<!-- TODO: LICENSE -->` block. **Mark ready + merge first thing next session.**

## State of the system

### What's working

- 8/8 BootHealth subsystems probe and report `ok` on the user's machine.
- Round 4 strict-mode preamble — proven mid-dogfood ("Toby" conversation — agent refused to fabricate memory).
- Schema fix — facts now persist (1 row in the live DB).
- Dev Overlay — 4 tabs render, live log stream works.
- All 18 boundary gates green at HEAD.

### What's known-broken — top v0.1 issues (per ROADMAP)

Pulled from `gh issue list --milestone "v0.1 — It actually works (basic capabilities)"`:

- **Vision** — #1 (T2 escalation always dies; `t2Available=true` with `MissingT2Provider` wired), #2 (FrameAttachController leaks pendingFrame on `.rejected`), #3 (mid-session camera TCC revoke unobserved).
- **Memory** — #12 (facts_vec never written), #13 (replay log poisoned), #14 (search_memory missing from preamble), #15 (FNV hash vs turns.id correlation), #16 (raw FTS5 MATCH crashes on punctuation).
- **MCP** — #20 (turnIDResolver permanently nil), #21 (tool-result double-capped 8KB).
- **Voice (P0 cluster)** — #28 (wake-word dies on rebuild), #29 (STT backend hard-coded), #30 (.ttsStopped only on barge-in), #31 (VoiceTTSAdapter.tierResolver never wired), #32 (OpenWakeWordSession buffers grow unbounded), #33 (BootHealthProbe gap for wake/STT/TTS), #34 (Silero VAD hidden state persists), #36 (AgentHudIntent stream dormant).
- **Bus/HUD** — #40 (no didFail arm), #41 (MenuBarIconController production-dead).
- **Carry-forward** — #51 (B-06 chat scroll, M-7 partial).
- **DX / env** — #58 (Ollama baseline reconcile: CLAUDE.md says `qwen2.5-coder:32b` but user has q8_0), #87 (PTT v1 hole), #88 (InputMonitoring banner v1 hole), #89 (startup surfaces).

### Repo state caveats

- **Repo is still PRIVATE** — `gh repo view --json visibility` returns `PRIVATE`. The marketing/branding pass today assumed public; **user decision pending** on whether to flip visibility before v0.1 ships.
- **5 stashes** accumulated from today's concurrent agents — `git stash list` shows: concurrent README edits, partial parallel-dispatch work (2026-05-06), 2× `stream:true` Anthropic fix, sibling-agent work. Triage when convenient — see #63.
- **2 moderate Dependabot vulnerabilities** flagged on push: https://github.com/KofTwentyTwo/Jarvis/security/dependabot.
- Untracked at session end: `.claude/scheduled_tasks.lock`, `build-devoverlay/` (both ignorable).

## Suggested next session

The user discussed a 24h v0.1 fan-out sprint earlier today. Plan:

1. **Read this handoff + `.planning/ROADMAP-2026-05-12.md` first** to orient.
2. **Merge PR #149** (BUILDING.md + README MIT cleanup) before any other work.
3. **Flip repo visibility decision** — public if marketing pass should pay off; stay private otherwise.
4. **Start v0.1 fan-out** (independent lanes, fan out parallel where state isolates):
   - Voice CRIT cluster (#28–#36) — one focused session, audio-graph + cancellation surgery
   - Memory CRIT cluster (#12–#16) — facts_vec write + replay poison + search_memory preamble + FNV correlation + FTS5 sanitization
   - MCP CRITs (#20, #21)
   - Bus/HUD S1s (#40, #41)
   - Vision (#1, #2, #3)
   - B-06 chat scroll (#51) — independent webview lane
   - #87 PTT + #88 InputMonitoring banner — v1 requirement holes
   - #89 startup surfaces — small DX win
5. **After v0.1 lands:** M-0 starts on its own feature branch (M-0 is infrastructure, doesn't block v0.1).

## Carry-forward bugs status

- B-01a / B-01b — closed earlier sessions
- B-02 — closed 2026-05-11 (tactical patch in `48ad8d6`)
- B-03 → closes in M-5 ([#48](https://github.com/KofTwentyTwo/Jarvis/issues/48))
- B-04, B-05 → close in M-6 ([#49](https://github.com/KofTwentyTwo/Jarvis/issues/49), [#50](https://github.com/KofTwentyTwo/Jarvis/issues/50))
- B-06 → closes in M-7, partial; webview-DOM out of harness scope ([#51](https://github.com/KofTwentyTwo/Jarvis/issues/51))
- B-07 → deferred to v1.1 post-M-6 ([#52](https://github.com/KofTwentyTwo/Jarvis/issues/52) + #63 stash triage)
- B-08 → closes in M-1 ([#53](https://github.com/KofTwentyTwo/Jarvis/issues/53))

## Pending environment work

- D-7 (`ollama pull nomic-embed-text`) — **DONE today**.
- D-7 secondary: vanilla `qwen2.5-coder:32b` mentioned in CLAUDE.md baseline but user has q8_0; reconcile via #58 / #60.
- 5 stashes triage (#63).
- 2 Dependabot moderate vulns triage.

## Pointers (where canonical content lives)

- **Roadmap:** `.planning/ROADMAP-2026-05-12.md`
- **GitHub Milestones:** https://github.com/KofTwentyTwo/Jarvis/milestones
- **GitHub Issues:** https://github.com/KofTwentyTwo/Jarvis/issues
- **Code-commenting guide:** `.planning/code-commenting-guide.md`
- **License rationale:** `.planning/decisions/license.md`
- **Audit reports:** `.planning/audit-2026-05-12/*.md`
- **API migration plan:** `.planning/architecture/JARVIS-API-MIGRATION-PLAN.md`
- **Active session-state:** `docs/SESSION-STATE.md`
- **Open PR:** https://github.com/KofTwentyTwo/Jarvis/pull/149

---
