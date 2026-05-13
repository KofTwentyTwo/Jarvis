# Multi-runner expansion on Grogu — design

**Date:** 2026-05-13
**Status:** approved (brainstorm phase, awaiting implementation plan)
**Workstream:** A — local CI capacity scaling
**Related issues:** #180 (single-runner setup), #182 (zombie cleanup), #186 (auto-release), #188 (age-filter)

## Problem

Develop CI wall-clock is bottlenecked on a single self-hosted runner (`Grogu-jarvis`) serializing the 13-package SwiftPM matrix. Each cold matrix job takes 1–2 minutes, so a full CI run is 13–15 minutes of serial work plus app-build on github-hosted in parallel. Grogu's hardware (24 physical cores, 128 GB RAM, 1.3 TB free on HD-2) is heavily under-utilized — single-runner load is ~5% of capacity.

Adding sibling runners would parallelize the matrix and roughly cut CI wall-clock by the runner count. Three runners is the recommended target: comfortably within hardware capacity (~24 cores used at peak when all three are mid-SwiftPM-build) without contending with interactive developer work.

## Goal

Three self-hosted runners on Grogu (`Grogu-jarvis`, `Grogu-jarvis-2`, `Grogu-jarvis-3`), each with its own `_work/` directory on HD-2, each registered as a LaunchAgent under james.maes's user session, all sharing labels `[self-hosted, macOS, ARM64, jarvis]` so GitHub Actions dispatches matrix jobs to whichever runner is free.

**Acceptance bar (minimum):** a green develop CI run after registration where `gh run view --json jobs` shows ≥3 SPM matrix jobs in `in_progress` state simultaneously. Warm-cache persistence and runner-health monitoring are explicit non-goals for this phase — they fall to follow-up tickets.

## Components

| Runner | Agent dir | `_work` symlink target | LaunchAgent plist | GitHub name |
|---|---|---|---|---|
| 1 (existing) | `~/actions-runner-jarvis/` | `/Volumes/HD-2/jarvis-runner-work/` | `actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis.plist` | `Grogu-jarvis` |
| 2 (new) | `~/actions-runner-jarvis-2/` | `/Volumes/HD-2/jarvis-runner-work-2/` | `actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2.plist` | `Grogu-jarvis-2` |
| 3 (new) | `~/actions-runner-jarvis-3/` | `/Volumes/HD-2/jarvis-runner-work-3/` | `actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-3.plist` | `Grogu-jarvis-3` |

All three runners share the same label set; jobs targeting `runs-on: [self-hosted, macOS, jarvis]` will dispatch to any free runner.

Agent binaries are v2.334.0 (osx-arm64) — already extracted into the new runner dirs as a pre-staging step; only `config.sh` + `svc.sh install/start` remain.

## Precondition

PR #189 (age-filter for the orphan-process cleanup step) **must be on `develop`** before either new runner starts accepting jobs. The current cleanup step kills ANY `xctest`/`swift-test`/`swift-driver` process at job start; with concurrent runners, sibling cleanup steps would mutually destroy each other's in-flight tests. PR #189 narrows the kill set to processes ≥1 hour old — concurrent CI jobs (typically <10 min) are safe.

The gating sequence is enforced operationally, not via code: don't run `./svc.sh start` on runner 2 or 3 until `git log origin/develop` shows the age-filter merge.

## Sequence — register one runner

For each `N` in `{2, 3}`:

1. Obtain a fresh registration token (1-hour expiry):
   ```
   gh api -X POST /repos/KofTwentyTwo/Jarvis/actions/runners/registration-token
   ```
2. Configure:
   ```
   cd ~/actions-runner-jarvis-N
   ./config.sh \
     --url https://github.com/KofTwentyTwo/Jarvis \
     --token "$TOKEN" \
     --name "Grogu-jarvis-N" \
     --labels "jarvis" \
     --work "_work" \
     --unattended \
     --replace
   ```
3. Install as LaunchAgent + start:
   ```
   ./svc.sh install
   ./svc.sh start
   ```
4. Verify online via GitHub API:
   ```
   gh api /repos/KofTwentyTwo/Jarvis/actions/runners -q '.runners[] | select(.name=="Grogu-jarvis-N") | {status, busy, labels}'
   ```
   Expected: `status=online, busy=false, labels=[self-hosted, macOS, ARM64, jarvis]`.

Sequential ordering (runner 2 fully online before configuring runner 3) makes any misconfiguration easy to bisect.

## Acceptance validation

After both runners are online:

1. Retrigger a stuck or cancelled CI run via `gh run rerun <id>` (PR #185 already has a failed AgentCore job that can serve as the test bed).
2. While the run is in progress, run:
   ```
   gh run view <id> --json jobs -q '.jobs[] | select(.status == "in_progress") | .name'
   ```
   Expected: at least 3 SPM matrix job names listed simultaneously, e.g., `SPM Bus`, `SPM Memory`, `SPM Voice`.
3. Cross-verify on Grogu:
   ```
   gh api /repos/KofTwentyTwo/Jarvis/actions/runners -q '.runners[] | {name, busy}'
   ```
   Expected: at least 3 runners with `busy=true` during peak matrix execution.
4. Wait for the run to terminate. Confirm `conclusion = success` (no cross-runner interference caused failures).

## Failure modes & mitigations

| Mode | Probability | Mitigation |
|---|---|---|
| Mutual xctest kill from un-filtered cleanup | High (without #189) | PR #189 precondition — age-filter at ≥1h. Don't start new runners until merged. |
| HD-2 disk pressure | Negligible | 1.3 TB free; 3 `_work` dirs × ~10 GB peak = 30 GB. |
| CPU/RAM saturation | Low | 3 concurrent SwiftPM builds peak at ~24 cores + ~24 GB. Within 24/128 budget. Headroom for interactive work. |
| Keychain races (`unlock-keychain`) | Negligible | `security unlock-keychain` is idempotent; default-keychain set persistently for the user. |
| Shared SwiftPM global cache races | Low | `~/Library/Caches/org.swift.swiftpm` is mostly read-after-populate. If contention surfaces, the per-package `actions/checkout clean: true` wipes per-job state cleanly. |
| Test port conflicts | Low | Jarvis tests use process-local Mach IPC (WKWebView) and per-process temp DBs (SQLite). No fixed-port servers found in audit. |
| One runner goes offline silently | Medium | Surfaces only at the next CI run (other runners pick up jobs). No alerting — explicit follow-up scope. |
| Runner agent auto-update breaks during long-running job | Low | Unlikely on a single-job timescale; runner updates happen between jobs. |

## Rollback

Each runner is independently revertible.

- **Pause a runner** (keeps registration): `cd ~/actions-runner-jarvis-N && ./svc.sh stop`
- **Deregister a runner** (free the slot):
  - On Grogu: `./svc.sh uninstall`
  - Via GitHub: `gh api -X DELETE /repos/KofTwentyTwo/Jarvis/actions/runners/<id>` (or `./config.sh remove --token $(gh api -X POST /repos/.../actions/runners/remove-token)`)
- **Revert to single runner**: stop + uninstall + deregister runners 2 and 3. Workflow unchanged (the `runs-on` selector targets the shared label set, not specific runners).

No code or workflow changes are required to roll back, which is the strongest possible safety property for an infrastructure change.

## Out of scope

- Warm-cache persistence (`actions/checkout clean: false` or custom DerivedData paths). Saves ~3 min per CI run but adds workflow complexity. Follow-up issue.
- Runner-health monitoring / alerting. Currently relies on `gh api .../actions/runners` snapshots and manual log inspection on Grogu. Follow-up issue.
- Per-runner-distinct labels (e.g., `runner-2`, `runner-3`). Default identical labels maximize matrix parallelism; per-runner labels would only matter for targeting a specific machine, which we don't need.
- Scaling beyond 3 runners. Hardware can support more, but matrix size (13 jobs) caps useful parallelism at ~4 runners. Cross that bridge only if matrix grows.

## Definition of done

- `gh api /repos/KofTwentyTwo/Jarvis/actions/runners` shows three runners, all `status=online`.
- A retriggered CI run shows ≥3 SPM jobs `in_progress` simultaneously at peak.
- The retriggered run terminates `success` (no failures attributable to multi-runner setup).
- `CLAUDE.md` updated with the new runner inventory and operational notes.
- Spec document committed and merged.

## References

- #180 — original single-runner setup
- #182 — zombie cleanup
- #188 — age-filter for multi-runner safety (precondition)
- `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/brainstorming` — process this design followed
