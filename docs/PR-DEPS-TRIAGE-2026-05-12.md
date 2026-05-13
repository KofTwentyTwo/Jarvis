# PR + dependency triage — 2026-05-12

**Lane:** `chore/pr-deps-triage-v0.1` (worktree: `.claude/worktrees/agent-a6ba0dc849806eae5/`)
**Scope:** read-only audit of open PRs, Dependabot updates, security alerts, leftover stashes, and sibling agent lanes. **Recommends; does not merge.**
**Base:** `develop @ ba42b691` ("docs: BUILDING.md + finalize README MIT license section (#149)").
**Open PRs:** 8 (3 user-authored drafts; 5 Dependabot).
**Open issues:** 141 across 6 milestones (no change since 2026-05-12 end-of-day handoff).
**Open Dependabot security alerts:** 2 (both moderate, dev-only).

---

## TL;DR

1. **Security alerts (#1, #2) are real but dev-scope only.** Both stem from `vite@5.4.21` + transitive `esbuild@0.21.5` that vitest@2.1.9 pulls into the lockfile.
2. **Dependabot PR #145 (vite 8.0.12) only partially closes the alerts.** It eliminates the vulnerable resolutions inside `packages/hud` (which already uses vitest@3.x), but the webview workspace root (`.`) and `packages/bus` still pin `vitest: ^2.1.0` which resolves to vitest@2.1.9 → vite@5.4.21 → esbuild@0.21.5.
3. **Full closure requires a follow-up:** either bump `vitest` from `^2.1.0` → `^3.0.0` in `webview/package.json` and `webview/packages/bus/package.json`, or add `pnpm.overrides` pinning `vite >=8.0.5` and `esbuild >=0.25.0`. The override is the lower-risk option for a v0.1 timeframe.
4. **All 8 open PRs show CircleCI Pipeline `ERROR`** — likely the same upstream/config-level failure (no per-PR job output, all started 2026-05-12 between 19:59 and 21:39Z). Worth checking the latest CircleCI config before merging anything dependency-related; the boundary-gate scripts + `scripts/check-app-builds.sh` + `pnpm --filter @jarvis/hud test` should be run locally before merge regardless.
5. **5 stashes on the main checkout** (1 belongs to this lane; 4 pre-existing). None block this lane; flagged below for owner triage.
6. **8 sibling agent lanes are active** (memory-crit, vision, mcp-crit, bus-hud-s1, voice, ci/github-actions, plus two anonymous worktrees). PRs #150–#152 cover three of them; the other lanes have local commits not yet pushed to PRs.

---

## Security alerts (live as of 2026-05-12)

Confirmed via `gh api /repos/KofTwentyTwo/Jarvis/dependabot/alerts --jq '.[] | select(.state == "open")'`.

### Alert #2 — Vite path traversal in optimized deps `.map` handling

| Field | Value |
|---|---|
| Severity | Moderate |
| GHSA | **GHSA-4w7w-66w2-5vf9** |
| CVE | **CVE-2026-39365** |
| Package | `vite` (npm) |
| Lockfile | `webview/pnpm-lock.yaml` |
| Scope | Development dependency |
| Vulnerable ranges | `<= 6.4.1`, `>= 7.0.0 <= 7.3.1`, `>= 8.0.0 <= 8.0.4` |
| Patched | `6.4.2` / `7.3.2` / `8.0.5` |
| Current resolutions | `vite@5.4.21` (vulnerable), `vite@8.0.10` (already patched on the 8.x branch — but alert remains open because of the 5.x instance) |

### Alert #1 — esbuild dev server exposes responses to any website

| Field | Value |
|---|---|
| Severity | Moderate |
| GHSA | **GHSA-67mh-4wv8-2f99** |
| CVE | none assigned |
| Package | `esbuild` (npm) |
| Lockfile | `webview/pnpm-lock.yaml` |
| Scope | Development dependency |
| Vulnerable range | `<= 0.24.2` |
| Patched | `0.25.0` |
| Current resolution | `esbuild@0.21.5` (direct dep of `vite@5.4.21`) |

### Dependency-graph trace (why both alerts exist)

```
webview/package.json                  vitest: ^2.1.0
  └─ vitest@2.1.9
       ├─ @vitest/mocker@2.1.9 (optional peer: vite@5.4.21)
       └─ vite-node@2.1.9     (peer:           vite@5.4.21)
            └─ vite@5.4.21
                 └─ esbuild@0.21.5  ← Alert #1
                 (vite@5.4.21 itself  ← Alert #2)

webview/packages/bus/package.json     vitest: ^2.1.0   (same path as above)

webview/packages/hud/package.json     vitest: ^3.0.0
  └─ vitest@3.2.4
       └─ vite@5.4.21  (pre-PR-#145)  →  vite@7.3.3 (post-PR-#145, patched)
            esbuild now optional peer; resolved to 0.27.7 (patched).
```

The `vite@8.0.10` listed as devDep of `packages/hud` is **not** the vulnerable surface — vite 8 removed esbuild as a hard dep (it's an optional peer in 8.x), and 8.0.10 is past the 8.0.5 patch line for the path-traversal CVE. The vulnerable surface is exclusively `vite@5.4.21` (dragged in by vitest@2.x via its hard `vite` runtime dep) plus its bundled `esbuild@0.21.5`.

### Does PR #145 (vite 8.0.10 → 8.0.12) resolve the alerts?

**Partially.** `gh pr diff 145` shows that after the bump:

- `packages/hud` resolves to `vite@8.0.12` + `esbuild@0.27.7` (both patched).
- `@vitest/mocker@3.2.4` and `vitest@3.2.4` (used by `packages/hud`) get re-resolved to `vite@7.3.3` (patched on the 7.x branch).
- **`vitest@2.1.9` and its `@vitest/mocker@2.1.9` still resolve to `vite@5.4.21`** — Dependabot did not touch the root or `packages/bus` because their declared `vitest: ^2.1.0` range still has 2.1.9 as latest-satisfying.

Net: `vite@5.4.21` + `esbuild@0.21.5` remain in the lockfile after PR #145 lands, so the GitHub Dependabot alerts will **not** auto-close.

### Real exposure (dev-only)

Both advisories require an attacker to coax a victim into visiting a malicious page **while** their machine has the Vite/esbuild dev server bound (default loopback `localhost:5173` for the HUD's `pnpm --filter @jarvis/hud dev`):

- **esbuild GHSA-67mh-4wv8-2f99:** dev server CORS is permissive — any website the user has open in another tab can `fetch()` against `localhost:<dev-server-port>` and read responses, exposing source files and bundle output that the dev server happily serves.
- **vite CVE-2026-39365:** path-traversal via the optimized-deps `.map` URL handler — same threat model, leaks files outside the project root that the dev server has read access to.

This is a real but **narrow** window — only when (a) the user is actively running the HUD dev server, AND (b) the user has a malicious tab open in their default browser. Production builds (`bash scripts/build-webview.sh`) bundle the JS statically and ship no dev server; the shipped macOS app has zero exposure. No CI surface is affected (CircleCI doesn't run the dev server). The vulnerable packages cannot escape `webview/`.

### Recommendation (alerts)

1. **Land PR #145** first — closes the high-watermark vite + brings hud-package vitest 3.x onto patched vite 7.3.3. Loses no functionality.
2. **Then close the 5.x residue** with one of:
   - **(preferred, surgical)** add a `pnpm.overrides` block to `webview/package.json` pinning `vite >=8.0.5` and `esbuild >=0.25.0`. One file, one commit, both alerts auto-close on next Dependabot scan. Minimal risk because vitest 2.1.9 declares vite as a peer (range `^5.0.0`, but pnpm overrides bypass peer-range gating); behavior change isolated to the dev-only test runner.
   - **(cleaner, follow-on)** bump `vitest` from `^2.1.0` → `^3.0.0` in `webview/package.json` and `webview/packages/bus/package.json`. Vitest 2 → 3 is a major; the bus and root barely use vitest (root has no tests, `packages/bus` has a handful) so the migration is low-cost. File as a separate issue / PR to keep this lane scoped.
3. After both alerts close: run `pnpm install` against the resolved lockfile and confirm `pnpm --filter @jarvis/hud test` + `bash scripts/build-webview.sh` still green.

---

## Open PRs (full inventory)

### User-authored drafts (sibling-lane work, not for this triage to merge)

| # | Branch | Title | Files | +/− | CI | Notes |
|---|---|---|---|---|---|---|
| **#152** | `fix/vision-v0.1` | fix(vision): v0.1 cluster — T2 honesty + pendingFrame leak + TCC revoke observation | 8 | +394/−9 | ERROR | Sibling lane — `agent-a9d9e02cdc3817942` worktree is on this branch. |
| **#151** | `fix/bus-hud-s1-v0.1` | fix(bus,hud): v0.1 S1 cluster — webview didFail + menu-bar icon transition | 7 | +529/−13 | ERROR | Sibling lane — `agent-af4da0a50eb1a9531` worktree. |
| **#150** | `fix/hud-chat-autoscroll-v0.1` | fix(hud): chat panel auto-scroll on streaming append — B-06 tactical (#51) | 3 | +293/−1 | ERROR | No matching open worktree — branch only. |

All three are drafts. The PR creator (the owner) should mark them ready when their respective lane completes. **Out of scope for this triage** — flagged in the active-lanes section below.

### Dependabot PRs

All five opened 2026-05-12 between 19:59 and 20:00 UTC. All are MERGEABLE, all show `mergeStateStatus: UNSTABLE` (CircleCI Pipeline ERROR). None have human review attached.

| # | Branch | Bump | Notes |
|---|---|---|---|
| **#145** | `dependabot/.../vite-8.0.12` | `vite 8.0.10 → 8.0.12` | **Highest priority — partially closes Alerts #1 and #2.** Drags `@vitest/mocker@3.2.4` + `vitest@3.2.4` (hud workspace) onto `vite@7.3.3` and `esbuild@0.27.7` (both patched). Does NOT touch root/bus vitest@2.1.9 → `vite@5.4.21` residue (the remaining vulnerability surface). +428/−100, 2 files (`packages/hud/package.json`, `pnpm-lock.yaml`). |
| **#148** | `dependabot/.../react-three/fiber-9.6.1` | `@react-three/fiber 9.6.0 → 9.6.1` | Patch-level bump on a production HUD dependency. Low risk; safe to merge after the vite PR. +9/−9. |
| **#147** | `dependabot/.../vitejs/plugin-react-6.0.1` | `@vitejs/plugin-react 5.2.0 → 6.0.1` | Major-version bump on the React Vite plugin. Need to verify it pairs with vite 8.x and doesn't break the dev server. **Hold until after #145 lands** so we test against the bumped vite. +18/−362 (lockfile churn). |
| **#146** | `dependabot/.../typescript-6.0.3` | `typescript 5.9.3 → 6.0.3` | Major TS bump. TypeScript 6 has tightened a number of inference rules and added stricter defaults; the existing R3F + bus type chains may surface new errors. **Treat as a discretionary upgrade, not security-driven.** Recommend running `pnpm -r typecheck` against the PR branch before merging. +12/−12. |
| **#144** | `dependabot/.../jsdom-29.1.1` | `jsdom 25.0.1 → 29.1.1` | 4 major versions in one bump (25 → 29). jsdom only affects `@jarvis/hud` test environment (vitest config). Run `pnpm --filter @jarvis/hud test` to verify the HUD tests still pass under jsdom 29. Risk: jsdom often tightens DOM-spec conformance; the testing-library tests might trip on stricter behavior. +202/−369. |

### Why every PR shows CircleCI ERROR

Every open PR (including the user drafts) lists `CircleCI Pipeline: ERROR` and **only** that one status context — no per-job results. That means the CircleCI pipeline itself failed before any job ran (typically a config-parse error or a missing required env var on the project). Pipeline IDs are sequential (48 → 53) and all errored within minutes of being triggered. This is a **single CI issue, not a per-PR problem** and is presumably being handled by the `ci/github-actions-v0.1` lane (worktree `agent-af1a17d5f3d47d96d`, branch ahead of develop by 1 commit `35316fcc docs(building): CI/CD section`). Coordinate with that lane before merging anything that depends on CI green.

**Pragmatic gate for this lane:** run the boundary-gate sweep + `scripts/check-app-builds.sh` + `pnpm --filter @jarvis/hud test` + `bash scripts/build-webview.sh` locally on the merge candidate before merging.

---

## Recommended morning sequence

Goal: clear both security alerts and the lowest-risk Dependabot PRs in one sitting, without stepping on sibling-lane work.

1. **Merge PR #145** (`vite 8.0.12`).
   - Verify locally first: check out `dependabot/npm_and_yarn/webview/vite-8.0.12`, run `pnpm install`, then `pnpm --filter @jarvis/hud test` and `bash scripts/build-webview.sh`. Both should pass.
   - Merge to `develop`.
2. **Wait ~5 min then re-fetch `gh api /repos/KofTwentyTwo/Jarvis/dependabot/alerts`.** Confirm Alert #1 and Alert #2 are **still open** (expected — see partial-closure analysis above). If they auto-closed, skip step 3.
3. **Add `pnpm.overrides`** to `webview/package.json` (separate small PR, ~5 lines). Suggested block:
   ```json
   "pnpm": {
     "overrides": {
       "vite": ">=8.0.5",
       "esbuild": ">=0.25.0"
     }
   }
   ```
   Then `cd webview && pnpm install` to regenerate the lockfile. Confirm `vite@5.4.21` and `esbuild@0.21.5` are gone from `webview/pnpm-lock.yaml` (`grep -E 'vite@5|esbuild@0\.21' webview/pnpm-lock.yaml` should return nothing). Run `pnpm --filter @jarvis/hud test` and `pnpm -r test` to confirm vitest 2.1.9 still works under overridden vite. Commit + merge. Re-verify alert closure.
4. **File a follow-up issue: "Bump webview root + packages/bus vitest from ^2.1.0 to ^3.0.0"** for v0.2. The override is a stop-gap; the real fix is dropping the obsolete vitest 2 surface.
5. **Merge PR #148** (`@react-three/fiber 9.6.1`) — patch-level bump, safest of the remaining Dependabot PRs. Quick smoke: `bash scripts/build-webview.sh` + visual HUD check.
6. **Decide on PRs #144, #146, #147:**
   - **#147** (`@vitejs/plugin-react` v5 → v6): only consider after #145 lands. Test in a local branch first by running `pnpm --filter @jarvis/hud dev` and confirming React Fast Refresh still works.
   - **#146** (TypeScript 5.9.3 → 6.0.3): defer to its own issue. Major TS bump deserves a focused diff review across the entire `packages/` tree. Don't merge as part of this morning sequence.
   - **#144** (jsdom 25 → 29): only merge after running `pnpm --filter @jarvis/hud test`. Defer if any test fails — file an issue with the regression detail.

---

## Stash triage (main checkout only — read-only)

`git -C /Users/james.maes/Git.Local/Kof22/Jarvis stash list` shows 6 stashes. **One** belongs to this lane; **five** are pre-existing. This lane created `stash@{0}` as a precaution when the main checkout was found to be on `feat/app-ux-surfaces-v0.1` with uncommitted PTT WizardState work that didn't belong to this triage branch. The uncommitted file was already restored to the working tree (`git stash pop --index` was run); the stash entry itself is retained because dropping it was denied by sandbox policy (correctly — the main checkout is outside this worktree's boundary).

| Stash | On branch | Files | Verdict |
|---|---|---|---|
| `stash@{0}` | `feat/app-ux-surfaces-v0.1` | `App/Wizard/WizardState.swift` (+16/−1) | **Created by this lane** as a safety net when stashing the main checkout's PTT work. Adds a `pttHotkey` `@Published` property with separate UserDefaults key (`Jarvis.pttHotkey`) — looks like in-progress work toward issue #87 (PTT v1 hole). Identical content is already restored in the working tree of the main checkout. **Owner action: drop** (`git stash drop stash@{0}`) once the working-tree copy is preserved (commit on `feat/app-ux-surfaces-v0.1` or re-stash under the right branch). |
| `stash@{1}` | `develop` "concurrent-readme-agent-edits" | `README.md` (+21/−47) | Pre-existing. Looks like a discarded outcome of an earlier parallel README edit. README has since been rewritten (`c4c32f7a docs(readme): refresh — diagrams + architecture + culture + roadmap`). **Owner action: review then drop** — likely superseded. |
| `stash@{2}` | `develop` "partial-work-from-failed-parallel-dispatch-2026-05-06" | `App/AppDelegate.swift` (+190/−24), `App/MenuBar/MenuBarContextMenu.swift` (+6/−0), `Jarvis.xcodeproj/project.pbxproj` (+18), `project.yml` (+11) | Pre-existing, 6 days old. Substantial AppDelegate diff — context unclear. Should be inspected in person; do not drop blind. **Owner action: diff and decide.** |
| `stash@{3}` | `develop` WIP on `d8983af` | `App/MenuBar/MenuBarContextMenu.swift` (+6/−0), `packages/Voice/.../WakeWordDAG.swift` (+32/−14) | Pre-existing, looks like wake-word work-in-progress. Possibly superseded by sibling-lane commit `307e3aa1 fix(voice): bound OpenWakeWordSession streaming buffers — closes #32` on `worktree-agent-a1e914121a58760e9`. **Owner action: compare against #32 work, drop if redundant.** |
| `stash@{4}` | `develop` "sibling-agent-work" | 6 files in `App/`, `packages/Voice/` (+112/−7) | Pre-existing. Multi-file Voice-stack work that overlaps with the active Voice lane (`worktree-agent-a1e914121a58760e9`). **Owner action: compare with the Voice lane's live diff before deciding.** |
| `stash@{5}` | `develop` WIP on `d8983af` | 5 files in `App/`, `packages/Voice/`, `project.yml` (+133/−16) | Pre-existing, similar profile to `stash@{4}` — appears to be an earlier WIP of the same Voice work. **Owner action: probably drop after `stash@{4}` is resolved.** |

This lane will not drop any stash (including its own `stash@{0}`) without explicit owner consent — bash permission for stash drop was denied with the rationale "operates on the main repo outside the agent's worktree boundary; risks irreversible loss of pre-existing local changes". That denial is correct and was respected.

---

## Active sibling lanes (read-only snapshot)

Nine agent worktrees currently locked under `.claude/worktrees/`. Each is a sibling lane operating against `develop`. None have been merged yet; their PRs (where opened) are the user-authored drafts listed above. This lane (`pr-deps-triage-v0.1`) is one of them.

| Worktree | Branch | HEAD | Dirty? | Apparent scope |
|---|---|---|---|---|
| `agent-a1e914121a58760e9` | `worktree-agent-a1e914121a58760e9` | `307e3aa1 fix(voice): bound OpenWakeWordSession streaming buffers — closes #32` | **YES** (3 files: AppDelegate, BootHealthProbes, VoiceTTSAdapter) | Voice P0 cluster — wake-word buffer bound (#32). Local commit not yet on a PR. |
| `agent-a319bcbaa2c678fc8` | `develop` | `ba42b691` (clean) | no | Reference checkout of develop. |
| `agent-a45db0204dbcdb92b` | `fix/memory-crit-v0.1` | `32248da7 fix(memory): kill replay-log poisoning — sentinel TurnID + batch split — closes #13` | no | Memory crit cluster (#13 replay-log poisoning). No PR opened yet. |
| `agent-a6ba0dc849806eae5` | `chore/pr-deps-triage-v0.1` | `ba42b691` (this lane's base) | no | **This lane.** |
| `agent-a9d9e02cdc3817942` | `fix/vision-v0.1` | `8a3881ff fix(vision): observe TCC revoke + wire becameAuthorized re-grant — closes #3` | no | Vision v0.1 cluster — already on PR #152 (draft). |
| `agent-aeee7944b881828a2` | `worktree-agent-aeee7944b881828a2` | `ba42b691` (clean) | no | Idle / placeholder. |
| `agent-af1a17d5f3d47d96d` | `ci/github-actions-v0.1` | `35316fcc docs(building): CI/CD section — workflow map, branch/tag conventions, opt-in tests` | no | CI/CD lane — likely the lane that will diagnose + fix the CircleCI Pipeline ERROR. No PR opened yet. |
| `agent-af4da0a50eb1a9531` | `fix/bus-hud-s1-v0.1` | `2bfe53f4 fix(hud): fan HudState emit to MenuBarIconController so icon animates per state — closes #41` | no | Bus/HUD S1 cluster — already on PR #151 (draft). |
| `agent-af935718c719b6312` | `fix/mcp-crit-v0.1` | `ba42b691` (no commits yet) | **YES** (3 files: AppDelegate, ReplayingToolResultObserver, MCPRuntimeWiringTests) | MCP crit cluster (#20 turnIDResolver nil). Work in progress; no commit yet. |

**Coordination note for the morning:** the only sibling lane whose work this triage interacts with is `ci/github-actions-v0.1` (because every PR in this triage shows CI ERROR). Suggest gating the morning sequence's "verify after merge" steps on the CI lane shipping its fix, OR explicitly accepting that this triage validates locally via boundary-gate scripts + `scripts/check-app-builds.sh` + `pnpm --filter @jarvis/hud test` + `bash scripts/build-webview.sh`. Either path is defensible — the local-verification path is faster.

---

## Out of scope for this lane

The following came up while triaging and are intentionally **not** acted on here:

- **Issue #58** (Ollama baseline reconcile — CLAUDE.md says `qwen2.5-coder:32b`, user actually has q8_0). Documentation drift; not a dependency issue.
- **Issue #87** (PTT v1 hole). The PTT work in `stash@{0}` is partial; the owner of `feat/app-ux-surfaces-v0.1` should finish it or convert it to a clean branch.
- **`build-devoverlay/` untracked directory in the main checkout.** Looks like a stray build product; not in any `.gitignore` rule we can verify from here. Owner should `rm -rf` or add to ignore.
- **`docs/HANDOFF-2026-05-13-overnight.md`** is currently an untracked file in the main checkout. Presumably belongs to a different overnight lane; flagging it because it would otherwise look like a missing artifact.

---

## Done-criteria for this lane

- [x] Report written at `docs/PR-DEPS-TRIAGE-2026-05-12.md`.
- [x] Branch `chore/pr-deps-triage-v0.1` (already existed; cleanly off `develop @ ba42b691`).
- [ ] Draft PR opened — pending push + `gh pr create` after this commit lands.
- [x] No merges, no destructive operations on sibling lanes, no stash drops on the main checkout.
