# PR + Dependency Triage — 2026-05-12

Lane: PR + dependency triage (read-only recommendations).
Worktree: `.claude/worktrees/agent-a6ba0dc849806eae5/`.
Branch: `chore/pr-deps-triage-v0.1` off `develop@ba42b69`.

## TL;DR

- **4 of 5 Dependabot PRs are SAFE-MERGE** (#144 jsdom, #145 vite, #147 plugin-react, #148 R3F). All pass `pnpm --filter @jarvis/hud test` (10/10 files, 97/97 tests) and `pnpm --filter @jarvis/hud build` in isolated worktrees.
- **1 Dependabot PR is NEEDS-INVESTIGATION**: #146 (TypeScript 5.9.3 → 6.0.3). Runtime tests + build pass, but `pnpm --filter @jarvis/hud typecheck` fails with 3 new errors at `webview/packages/hud/src/hud/SegmentedRing.tsx:92` — TS 6's stricter indexed-access narrowing. Fix is mechanical (add `if (!m) continue` or non-null assertion) but is a code change outside the dep upgrade, so the PR can't merge cleanly on its own.
- **Both moderate CVEs (#1 esbuild, #2 vite) are NOT covered by any of the 5 Dependabot PRs.** They both trace to the same root cause: `vitest@2 / vitest@3` transitively depends on `vite@5.4.21`, which pulls `esbuild@0.21.5`. Direct `vite@8.0.x` (the dependabot PR) is already non-vulnerable; the fix is to **bump vitest to 4.x** so the transitive vite goes to 6.0+. Vitest 4 is a major upgrade and Dependabot hasn't opened that PR yet. Both advisories are **dev-tooling only** (no production exposure — vite/esbuild never ship in the HUD IIFE bundle, and there's no public-facing dev server for a personal macOS app).
- **5 stashes: 4 DROP, 1 PRESERVE-AS-BRANCH.** Stashes 0, 1, 2, 4 are obsolete — `develop` already has the equivalent commits (`ba42b69` README, `50c2783` DevOverlay wiring, `RequestBody.swift:91 stream: true`, `f06bf0b` wake-word survives rebuild). Stash 3 ("sibling-agent-work") introduces a Voice Log menu item that doesn't yet exist on develop — preserve as `wip/stash-3-voice-log-menu` for later (the issue `Voice Log` is on the v1.1 milestone).
- **Active lane PRs (read-only)**: PR #150 (HUD chat autoscroll), #151 (bus+HUD S1 cluster), #152 (vision v0.1 cluster) all open and draft. No housekeeping action recommended.

## Dependabot PRs

| PR # | Package | From → To | Type | Verdict | Evidence |
|------|---------|-----------|------|---------|----------|
| [#144](https://github.com/KofTwentyTwo/Jarvis/pull/144) | `jsdom` | 25.0.1 → 29.1.1 | devDep (major×4) | SAFE-MERGE | install OK · 97/97 tests pass · build OK · `prepare` install-script change flagged by Dependabot (jsdom 29 only — review release note manually but no malicious content reported) · jsdom 29 requires Node 22.13+ (project engine is `>=20.0.0`; current host is Node 26) |
| [#145](https://github.com/KofTwentyTwo/Jarvis/pull/145) | `vite` | 8.0.10 → 8.0.12 | devDep (patch) | SAFE-MERGE | install OK · 97/97 tests pass · build OK · changelog is bug fixes + rolldown 1.0.0 GA; no breaking surface for the HUD IIFE config |
| [#146](https://github.com/KofTwentyTwo/Jarvis/pull/146) | `typescript` | 5.9.3 → 6.0.3 | devDep (major) | NEEDS-INVESTIGATION | install OK · 97/97 tests pass · build OK · **typecheck FAILS**: 3× TS18048 at `webview/packages/hud/src/hud/SegmentedRing.tsx:92` (`'m' is possibly 'undefined'`). TS 6 narrows array index access more strictly. Mechanical fix: add `if (!m) continue` before line 92 inside the `for` loop. Not blocked — but the typecheck must be either fixed in the same PR or the typecheck gate (if any CI hook exists) ignored. Recommend rebasing the PR after landing the source fix, OR adding the fix on top of the dependabot branch via `gh pr checkout 146 && fix && git commit && git push` before merging. |
| [#147](https://github.com/KofTwentyTwo/Jarvis/pull/147) | `@vitejs/plugin-react` | 5.2.0 → 6.0.1 | devDep (major) | SAFE-MERGE | install OK · 97/97 tests pass · build OK · v6 dropped Babel as a dep; verified `webview/packages/hud/vite.config.ts` does NOT pass any `babel: {...}` option to `react()` — the breaking change does not affect this project |
| [#148](https://github.com/KofTwentyTwo/Jarvis/pull/148) | `@react-three/fiber` | 9.6.0 → 9.6.1 | runtime dep (patch) | SAFE-MERGE | install OK · 97/97 tests pass · build OK · pure patch release |

All test runs done from isolated `git worktree add` to detached PR HEADs (under `/tmp/dep-pr-tests/pr<N>/`); no pollution of `develop` or the triage branch.

## Security advisories

Both open Dependabot alerts at https://github.com/KofTwentyTwo/Jarvis/security/dependabot.

### Alert #1 — esbuild GHSA-67mh-4wv8-2f99 (moderate)

- **Package**: `esbuild` (devDep, transitive)
- **Installed**: `esbuild@0.21.5` (in `webview/pnpm-lock.yaml`)
- **Vulnerable range**: `<= 0.24.2`
- **Patched**: `0.25.0`
- **Summary**: esbuild dev server allows any website to send any requests to the dev server and read the response (CORS-on-dev-server flaw).
- **Origin chain**: `vitest@2.1.9 / vitest@3.2.4` → `vite@5.4.21` → `esbuild@0.21.5`. The direct `vite@^8.0.0` in the HUD package devDeps pulls `esbuild@0.25+` cleanly, but vitest still drags in vite 5.
- **Covered by a Dependabot PR?** **No.** None of the 5 open PRs touch vitest.
- **Exposure window**: dev-tooling only. esbuild's vulnerable surface is its **local dev server**, used only when a developer runs `pnpm --filter @jarvis/hud dev` or `vitest --watch`. This is a personal macOS app; the dev server never binds anything publicly accessible. Risk in practice: low — an attacker would need to lure the developer to a malicious page while the dev server is running on localhost.
- **Remediation**: Bump `vitest` to `^4.0.0` in both `webview/package.json` (root devDep) and `webview/packages/hud/package.json` (hud devDep). Vitest 4 requires vite `^6 || ^7 || ^8`, which transitively bumps esbuild past 0.25. Vitest 4 is a major upgrade and may require test-config tweaks; treat as a separate small PR (`chore(deps): bump vitest to 4.x`), not bundled with the dependabot PRs.

### Alert #2 — vite GHSA-4w7w-66w2-5vf9 (moderate)

- **Package**: `vite` (devDep, transitive)
- **Installed**: `vite@5.4.21` (transitive via vitest) AND `vite@8.0.10` (direct devDep in hud)
- **Vulnerable range**: `<= 6.4.1`
- **Patched**: `6.4.2`
- **Summary**: Vite vulnerable to path traversal in optimized-deps `.map` handling.
- **Origin chain**: same as alert #1 — vitest transitive vite 5.x. The direct vite 8.0.x is already non-vulnerable.
- **Covered by a Dependabot PR?** **Indirectly no.** Even after #145 merges, the direct vite stays at 8.0.12 (non-vulnerable) but the **transitive vite@5.4.21 remains** because vitest 2/3 pins it.
- **Exposure window**: same as alert #1 — local dev server only.
- **Remediation**: same as alert #1 — bump vitest to 4.x. The two alerts are one fix.

**Summary**: both moderate CVEs are real but dev-tooling only and trace to a single transitive (`vitest@2/3 → vite@5.4.21 → esbuild@0.21.5`). Single remediation closes both. Recommend a fresh `chore(deps): bump vitest to 4.x` PR rather than waiting on Dependabot — the 5 open PRs do not address this.

## Stash triage

`git stash list` (sees all 5; stash list is per-repo not per-worktree):

| Index | Descriptor (from `git stash list`) | Content summary | Verdict | Morning command |
|-------|-----------------------------------|-----------------|---------|-----------------|
| 0 | `On develop: concurrent-readme-agent-edits` | README.md only, 21+/47- lines. Reword of "Scope" paragraph, adds TODO comment for HUD demo gif, restructures Build & run section. | **DROP** — `b2710ee docs(readme): branding pass`, `0cc94c6 docs(branding): restore MIT section`, and `ba42b69 docs: BUILDING.md + finalize README MIT license` on develop already do a deeper rework of the same surface. The stash predates the current README structure and would conflict. | `git stash drop stash@{0}` |
| 1 | `On develop: partial-work-from-failed-parallel-dispatch-2026-05-06` | 4 files / 211+ /14-: AppDelegate.swift adds DevSnapshotEmitter + DevOverlayBridge + DevOverlayViewModel wiring; MenuBarContextMenu.swift; pbxproj/project.yml updates for VoiceLog target. | **DROP** — `50c2783 feat(devoverlay): wire DevSnapshotEmitter end-to-end + add tabbed view` (May 12) is the canonical end-to-end wiring of exactly this surface, with `6ea2852 feat(devoverlay,logging): live log stream` extending it. The Voice Log menu/target portion overlaps with stash 3 (see below) and is on the v1.1 milestone, not v0.1. | `git stash drop stash@{1}` |
| 2 | `WIP on develop: d8983af fix(anthropic): add stream:true to request body` | 2 files / 38+ /14-: MenuBarContextMenu.swift adds Voice Log item; WakeWordDAG.swift renames `cancel()` → `stopFeed()`. | **DROP** — `f06bf0b fix(voice): wake-word survives audio-graph rebuild` (May 12, closes #28) implements the canonical fix using `stopFeed()` and re-arming after rebuild. The stash is an earlier, less complete attempt at the same fix. The Voice Log menu item piece is duplicated in stash 3. | `git stash drop stash@{2}` |
| 3 | `On develop: sibling-agent-work` | 6 files / 119+ /7-: MenuBarContextMenu.swift adds `voiceLogToggleAction`, MenuBarIconControllerTests update, AudioGraphOwner.swift adds 32 lines, VoiceController.swift +3, VoiceInterfaces.swift +48, WakeWordDAG.swift refactor. | **PRESERVE-AS-BRANCH** — the wake-word/audio-graph portion is now redundant with `f06bf0b`, BUT the `voiceLogToggleAction` plumbing on `MenuBarContextMenu.build` + the matching test updates are NOT on develop yet, and Voice Log is a tracked v1.1 milestone item. Salvage the menu-bar plumbing for when Voice Log lands; drop the Voice/WakeWord portion that conflicts with `f06bf0b`. Safer to preserve the whole diff as a branch and let whoever picks up Voice Log cherry-pick what survives. | `git stash branch wip/stash-3-voice-log-menu stash@{3}` (this both creates the branch from the stash's parent commit and drops the stash); then `git push -u origin wip/stash-3-voice-log-menu` |
| 4 | `WIP on develop: d8983af fix(anthropic): add stream:true to request body` | 5 files / 149+ /16-: AppDelegate.swift wake-word rebuild consumer (re-arms DAG against new ring), AudioGraphOwner.swift, WakeWordDAG.swift, MenuBarContextMenu.swift Voice Log item, project.yml. | **DROP** — same diagnosis as stash 2 plus the AppDelegate rebuild-consumer change. `f06bf0b` is the canonical fix; the commit body explicitly describes this fix ("setCancelInFlight now invokes stopFeed() instead of cancel()" + "rebuild-completion consumer now re-arms the DAG against the new ring"). Stash 4 is the WIP that became `f06bf0b`. | `git stash drop stash@{4}` |

Verification that `stream: true` is on develop (the four `stream:true` stashes are tagged WIPs *after* commit `d8983af` which is the fix itself): `packages/AgentCore/Sources/AnthropicProvider/RequestBody.swift:91` contains `stream: true`. Confirmed.

**Morning execution order matters for stash 3**: do `git stash branch wip/stash-3-voice-log-menu stash@{3}` FIRST (it drops stash@{3} as part of the branch operation and renumbers the remaining stashes). Then drop the remaining stashes by NAME, not index, OR re-list and drop highest-to-lowest.

## Active lane PRs (read-only)

| PR # | Branch | Owner lane | State | Notes |
|------|--------|-----------|-------|-------|
| [#150](https://github.com/KofTwentyTwo/Jarvis/pull/150) | `fix/hud-chat-autoscroll-v0.1` | F | OPEN, DRAFT | "fix(hud): chat panel auto-scroll on streaming append — B-06 tactical (#51)" |
| [#151](https://github.com/KofTwentyTwo/Jarvis/pull/151) | `fix/bus-hud-s1-v0.1` | D | OPEN, DRAFT | "fix(bus,hud): v0.1 S1 cluster — webview didFail + menu-bar icon transition" |
| [#152](https://github.com/KofTwentyTwo/Jarvis/pull/152) | `fix/vision-v0.1` | E | OPEN, DRAFT | "fix(vision): v0.1 cluster — T2 honesty + pendingFrame leak + TCC revoke observation" |

I touched none of these. Other lane branches (`fix/voice-crit-v0.1`, `fix/memory-crit-v0.1`, `fix/mcp-crit-v0.1`, `feat/app-ux-surfaces-v0.1`) were not open as PRs at the time of this triage (in flight as worktrees per `git worktree list`).

PR #149 (`docs: BUILDING.md + finalize README MIT license section`) merged at 2026-05-12T20:57:48Z and is part of `develop@ba42b69`.

## Recommended morning sequence

Run in this order. Each step is independent; stop and inspect if any step surprises you.

1. **Merge the 4 SAFE-MERGE Dependabot PRs** (any order; Dependabot will rebase the others on conflict):
   ```bash
   gh pr merge 144 --squash --auto    # jsdom 25 → 29
   gh pr merge 145 --squash --auto    # vite 8.0.10 → 8.0.12
   gh pr merge 147 --squash --auto    # plugin-react 5 → 6
   gh pr merge 148 --squash --auto    # @react-three/fiber 9.6.0 → 9.6.1
   ```

2. **Fix the TypeScript 6 typecheck regression then merge PR #146**:
   ```bash
   gh pr checkout 146
   # In webview/packages/hud/src/hud/SegmentedRing.tsx around line 90:
   # Inside the for loop, after `const m = initialMatrices[i]`, add:
   #   if (!m) continue
   # (or use a non-null assertion `initialMatrices[i]!` if the invariant is clear).
   cd webview && pnpm --filter @jarvis/bus build && pnpm --filter @jarvis/hud typecheck
   # Expect 0 errors.
   git add -A && git commit -m "fix(hud): narrow initialMatrices index access for TS 6"
   git push
   gh pr merge 146 --squash --auto
   ```

3. **Close both CVE alerts in one focused PR** (NOT bundled with the dependabot PRs):
   ```bash
   git checkout -b chore/deps/vitest-4 develop
   cd webview
   # Update both package.json files: vitest "^2.1.0" → "^4.0.0" and "^3.0.0" → "^4.0.0"
   pnpm install
   pnpm --filter @jarvis/bus build && pnpm --filter @jarvis/hud test
   # Inspect any vitest-4 breakages, fix, then:
   git add -A && git commit -m "chore(deps): bump vitest to 4.x — closes GHSA-67mh-4wv8-2f99, GHSA-4w7w-66w2-5vf9"
   git push -u origin chore/deps/vitest-4 && gh pr create --fill --base develop
   ```

4. **Stash cleanup** (do branch-from-stash FIRST, then drop the rest from highest to lowest to avoid renumbering surprises):
   ```bash
   git stash branch wip/stash-3-voice-log-menu stash@{3}
   # That branch now exists locally with the stash applied; check it out separately to push:
   git push -u origin wip/stash-3-voice-log-menu
   git checkout -                # back to wherever you were
   # Now drop the obsolete stashes. After the `stash branch` above, stash@{3} is gone;
   # stash@{4} has become stash@{3}. Safest is to re-`git stash list` then drop top-down:
   git stash list
   # Expect 4 stashes; drop from top:
   git stash drop stash@{3}      # was stash@{4} (WIP stream:true + wake-word)
   git stash drop stash@{2}      # was stash@{2} (WIP stream:true + Voice Log menu)
   git stash drop stash@{1}      # was stash@{1} (DevSnapshotEmitter partial)
   git stash drop stash@{0}      # was stash@{0} (concurrent README edits)
   git stash list                # empty
   ```

5. **Triage report PR** (this PR — see "PR URL" in the final report message). Convert from draft to ready when you're happy with the recommendations, then merge or close as desired.

### What this triage does NOT cover

- Whether vitest 4 introduces test-config breakages (not tested — would require running the full suite against vitest 4, which is a code change outside the dep upgrade).
- The `prepare` install-script change flagged on jsdom 29 was not deeply audited beyond Dependabot's surfacing — recommend a quick visual diff of `jsdom@29.1.1` vs `jsdom@25.0.1` `prepare` if you want extra confidence before merging #144.
- Build-time regression in production HUD bundle is checked only via `pnpm --filter @jarvis/hud build` succeeding. Visual/runtime regressions in the rendered HUD are NOT covered — that's a manual smoke test once changes land on develop.
