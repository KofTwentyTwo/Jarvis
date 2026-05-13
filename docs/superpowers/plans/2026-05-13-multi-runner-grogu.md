# Multi-Runner Expansion on Grogu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scale Grogu from 1 to 3 self-hosted GitHub Actions runners so the 13-package SwiftPM matrix parallelizes, cutting develop CI wall-clock from ~13 min serial to ~5 min.

**Architecture:** Two new LaunchAgent runners (`Grogu-jarvis-2`, `Grogu-jarvis-3`), each in its own `~/actions-runner-jarvis-{2,3}/` directory with `_work/` symlinked to `/Volumes/HD-2/jarvis-runner-work-{2,3}/`. All three runners share labels `[self-hosted, macOS, ARM64, jarvis]` so matrix jobs dispatch to whichever is free.

**Tech Stack:** GitHub Actions self-hosted runner v2.334.0 (osx-arm64), `gh` CLI for token + verification, macOS LaunchAgents for per-user service management.

**Spec:** `docs/superpowers/specs/2026-05-13-multi-runner-grogu-design.md`

**Related issues:** #180 (single-runner setup), #182 (zombie cleanup), #186 (auto-release), #188 (age-filter — precondition).

---

## File Structure

This plan is primarily operational; the only repo file modified is `CLAUDE.md` (runner inventory documentation).

| Change | Path | Responsibility |
|---|---|---|
| **System (new)** | `~/actions-runner-jarvis-2/` | Runner-2 agent binary tree (already pre-staged) |
| **System (new)** | `~/actions-runner-jarvis-2/_work` → `/Volumes/HD-2/jarvis-runner-work-2/` | Symlink for build artifacts (already pre-staged) |
| **System (new)** | `~/Library/LaunchAgents/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2.plist` | LaunchAgent service plist (created by `svc.sh install`) |
| **System (new)** | `~/actions-runner-jarvis-3/` | Runner-3 agent binary tree (already pre-staged) |
| **System (new)** | `~/actions-runner-jarvis-3/_work` → `/Volumes/HD-2/jarvis-runner-work-3/` | Symlink (already pre-staged) |
| **System (new)** | `~/Library/LaunchAgents/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-3.plist` | LaunchAgent plist |
| **Repo (modify)** | `CLAUDE.md` | Runner inventory section updated to list all 3 runners |

The pre-staging step (download + extract agent + create `_work` symlinks for runner 2 and 3) was performed earlier in the session. Task 2 step 1 verifies that pre-stage rather than redoing it.

---

## Task 1: Verify precondition — PR #189 merged to develop

**Files:**
- Read-only check: `origin/develop` git log

PR #189 (age-filter zombie reaper) MUST be on `develop` before either new runner starts accepting jobs. The current cleanup step kills any `xctest`/`swift-test`/`swift-driver` regardless of age; concurrent runners' cleanup steps would mutually kill each other's in-flight tests.

- [ ] **Step 1: Fetch latest develop**

```bash
git fetch origin develop
```

Expected: no output, or "Updating <hash>..<hash>".

- [ ] **Step 2: Verify the age-filter commit is on develop**

```bash
git log origin/develop --grep="age-filter zombie reaper" --oneline | head -3
```

Expected: at least one line containing `676c54d ci(actions): age-filter zombie reaper (>= 1h) for multi-runner safety` (the exact SHA prefix may differ post-squash-merge).

If empty: PR #189 is not yet merged. Stop the plan here and re-run from Task 1 once it is. Do NOT proceed to Task 2 — starting concurrent runners against an un-filtered cleanup step will trigger mutual xctest kill.

---

## Task 2: Register Grogu-jarvis-2

**Files:**
- System: `~/actions-runner-jarvis-2/` (pre-staged binaries — verify only)
- System: `~/actions-runner-jarvis-2/_work` symlink (pre-staged — verify only)
- System (new): `~/actions-runner-jarvis-2/.runner` (created by `config.sh`)
- System (new): `~/Library/LaunchAgents/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2.plist` (created by `svc.sh install`)

- [ ] **Step 1: Verify pre-stage**

```bash
test -x ~/actions-runner-jarvis-2/config.sh && \
  readlink ~/actions-runner-jarvis-2/_work | grep -q '/Volumes/HD-2/jarvis-runner-work-2$' && \
  echo "OK: pre-stage intact" || echo "FAIL"
```

Expected: `OK: pre-stage intact`.

If FAIL: re-run the pre-stage block from earlier in the session — `mkdir -p` the dirs on HD-2, download `actions-runner-osx-arm64-2.334.0.tar.gz`, extract into `~/actions-runner-jarvis-2/`, `ln -s /Volumes/HD-2/jarvis-runner-work-2 ~/actions-runner-jarvis-2/_work`.

- [ ] **Step 2: Get a fresh registration token**

```bash
TOKEN=$(gh api -X POST /repos/KofTwentyTwo/Jarvis/actions/runners/registration-token -q '.token')
test -n "$TOKEN" && echo "Token acquired (len=${#TOKEN})" || echo "FAIL"
```

Expected: `Token acquired (len=33)` or similar non-zero length. Token expires in 1 hour; do not pause between this step and step 4.

If FAIL: check `gh auth status` — the active account must have `workflow` scope on the KofTwentyTwo/Jarvis repo.

- [ ] **Step 3: Configure runner-2 (unattended)**

```bash
cd ~/actions-runner-jarvis-2
./config.sh \
  --url https://github.com/KofTwentyTwo/Jarvis \
  --token "$TOKEN" \
  --name "Grogu-jarvis-2" \
  --labels "jarvis" \
  --work "_work" \
  --unattended \
  --replace 2>&1 | grep -v -i 'token' | tail -10
```

Expected last lines include `√ Connected to GitHub`, `√ Runner successfully added`, `√ Settings Saved.`. The `grep -v token` strips any line containing the literal token string from the logged output as a defense-in-depth measure (the token itself is short-lived but should not be left in scrollback).

- [ ] **Step 4: Install + start as LaunchAgent**

```bash
cd ~/actions-runner-jarvis-2
./svc.sh install
./svc.sh start
./svc.sh status
```

Expected last block:
```
status actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2:
/Users/james.maes/Library/LaunchAgents/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2.plist

Started:
<PID> 0 actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2
```

(PID will vary.)

- [ ] **Step 5: Verify runner-2 is online via GitHub API**

```bash
gh api /repos/KofTwentyTwo/Jarvis/actions/runners \
  -q '.runners[] | select(.name=="Grogu-jarvis-2") | {name, status, busy, labels: [.labels[].name]}'
```

Expected:
```json
{"busy":false,"labels":["self-hosted","macOS","ARM64","jarvis"],"name":"Grogu-jarvis-2","status":"online"}
```

If `status` is anything other than `online`, check `~/Library/Logs/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-2/stdout.log` for the runner-side error and stop the plan.

---

## Task 3: Register Grogu-jarvis-3

Identical sequence to Task 2 with `-2` replaced by `-3` everywhere. Per the spec's sequential-validation principle, do NOT start runner-3 until runner-2 is confirmed `status=online, busy=false`.

**Files:**
- System: `~/actions-runner-jarvis-3/` (pre-staged — verify only)
- System: `~/actions-runner-jarvis-3/_work` symlink (pre-staged — verify only)
- System (new): `~/actions-runner-jarvis-3/.runner` (created by `config.sh`)
- System (new): `~/Library/LaunchAgents/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-3.plist`

- [ ] **Step 1: Verify pre-stage**

```bash
test -x ~/actions-runner-jarvis-3/config.sh && \
  readlink ~/actions-runner-jarvis-3/_work | grep -q '/Volumes/HD-2/jarvis-runner-work-3$' && \
  echo "OK: pre-stage intact" || echo "FAIL"
```

Expected: `OK: pre-stage intact`.

- [ ] **Step 2: Get a fresh registration token**

```bash
TOKEN=$(gh api -X POST /repos/KofTwentyTwo/Jarvis/actions/runners/registration-token -q '.token')
test -n "$TOKEN" && echo "Token acquired (len=${#TOKEN})" || echo "FAIL"
```

Expected: `Token acquired (len=33)` or similar.

- [ ] **Step 3: Configure runner-3 (unattended)**

```bash
cd ~/actions-runner-jarvis-3
./config.sh \
  --url https://github.com/KofTwentyTwo/Jarvis \
  --token "$TOKEN" \
  --name "Grogu-jarvis-3" \
  --labels "jarvis" \
  --work "_work" \
  --unattended \
  --replace 2>&1 | grep -v -i 'token' | tail -10
```

Expected last lines: `√ Connected to GitHub`, `√ Runner successfully added`, `√ Settings Saved.`

- [ ] **Step 4: Install + start as LaunchAgent**

```bash
cd ~/actions-runner-jarvis-3
./svc.sh install
./svc.sh start
./svc.sh status
```

Expected: `Started: <PID> 0 actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis-3`.

- [ ] **Step 5: Verify runner-3 is online**

```bash
gh api /repos/KofTwentyTwo/Jarvis/actions/runners \
  -q '.runners[] | select(.name=="Grogu-jarvis-3") | {name, status, busy, labels: [.labels[].name]}'
```

Expected:
```json
{"busy":false,"labels":["self-hosted","macOS","ARM64","jarvis"],"name":"Grogu-jarvis-3","status":"online"}
```

- [ ] **Step 6: Confirm all 3 runners visible**

```bash
gh api /repos/KofTwentyTwo/Jarvis/actions/runners \
  -q '.runners | length, [.runners[].name] | sort'
```

Expected (exactly):
```
3
["Grogu-jarvis","Grogu-jarvis-2","Grogu-jarvis-3"]
```

If the count is anything other than 3, stop and investigate which runner failed to register.

---

## Task 4: Acceptance — observe matrix parallelism

**Files:** none.

**Premise:** PR #185 (`fix/agent-cache-text-blocks-23-24`) was cancelled earlier in this session with one previously-failed SPM job. Rerun it to get a CI run with the new runner topology in effect. Watch for ≥3 SPM jobs in `in_progress` simultaneously.

- [ ] **Step 1: Identify the PR #185 run id**

```bash
RUN_ID=$(gh run list --branch fix/agent-cache-text-blocks-23-24 --workflow=CI --limit 1 --json databaseId -q '.[0].databaseId')
echo "PR #185 latest run: $RUN_ID"
```

Expected: a numeric run id, e.g. `25827802988`.

- [ ] **Step 2: Trigger a full rerun**

```bash
gh run rerun "$RUN_ID" --repo KofTwentyTwo/Jarvis
sleep 5
gh run view "$RUN_ID" --json status,conclusion -q '"\(.status) / \(.conclusion // "(none)")"'
```

Expected: `queued / (none)` or `in_progress / (none)`. (Using `gh run rerun` without `--failed` reruns the whole workflow so we observe a fresh matrix dispatch across all runners.)

- [ ] **Step 3: Wait for matrix dispatch, then sample concurrent jobs**

Wait ~60-90 seconds for the webview/boundary jobs to complete and the SPM matrix to start dispatching.

```bash
sleep 90
gh run view "$RUN_ID" --json jobs -q '[.jobs[] | select(.name | startswith("SPM ")) | select(.status == "in_progress") | .name] | "in_progress count: \(length)\nnames: \(.)"'
```

Expected: `in_progress count: 3` (or higher if the matrix has dispatched more quickly than expected) followed by three SPM job names.

If `in_progress count: 1`: GitHub may have only just started dispatching. Wait another 60 seconds and re-sample. If still 1 after 5 minutes, investigate — possibly one or both new runners are offline. Cross-check with `gh api /repos/.../actions/runners -q '.runners[].busy'` (should show ≥2 `true`).

- [ ] **Step 4: Cross-verify on Grogu**

```bash
gh api /repos/KofTwentyTwo/Jarvis/actions/runners \
  -q '[.runners[] | select(.busy == true) | .name] | "busy runners: \(length)\nnames: \(.)"'
```

Expected: `busy runners: 3` and the three runner names. (If 2, the matrix is partially dispatched; if 1, only the original runner is being used — investigate.)

- [ ] **Step 5: Wait for the run to terminate**

```bash
gh run watch "$RUN_ID" --repo KofTwentyTwo/Jarvis --exit-status
echo "Exit: $?"
```

Expected: process exits with 0 and a `✓ run completed with 'success'` message. Wall-clock from trigger to completion should be approximately 5–7 minutes (vs the prior ~13 min single-runner baseline). If the run conclusion is `failure`, inspect failed jobs via `gh run view "$RUN_ID" --log-failed` to determine whether the failure is multi-runner-related (e.g., test-suite race) or pre-existing flakiness (e.g., the AgentCore deadlock seen earlier).

---

## Task 5: Update CLAUDE.md with the new runner inventory

**Files:**
- Modify: `CLAUDE.md` (the "Self-hosted CI runner (Grogu)" section)

- [ ] **Step 1: Create a branch**

```bash
git fetch origin develop
git checkout -b docs/multi-runner-inventory origin/develop
```

Expected: `Switched to a new branch 'docs/multi-runner-inventory'`.

- [ ] **Step 2: Locate the runner section in CLAUDE.md**

```bash
grep -n "Where it lives\|Service:\|jarvis-runner.keychain" CLAUDE.md | head -3
```

Expected: three line numbers pointing into the `### Self-hosted CI runner (Grogu)` section.

- [ ] **Step 3: Replace the "Where it lives" + "Service" bullets with multi-runner equivalents**

Edit the two bullets via the `Edit` tool. The OLD text:

```
- **Where it lives:** `~/actions-runner-jarvis/` on Grogu. `_work/` symlinked to `/Volumes/HD-2/jarvis-runner-work/` (1.3 TB) to keep boot-disk pressure off.
- **Service:** launchd LaunchAgent `actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis` (`~/Library/LaunchAgents/`). Manage with `cd ~/actions-runner-jarvis && ./svc.sh {status,start,stop}`. Only runs while user is logged in.
```

The NEW text:

```
- **Where they live:** three runners on Grogu — `~/actions-runner-jarvis/` (Grogu-jarvis), `~/actions-runner-jarvis-2/` (Grogu-jarvis-2), `~/actions-runner-jarvis-3/` (Grogu-jarvis-3). Each `_work/` symlinked to `/Volumes/HD-2/jarvis-runner-work{,-2,-3}/` (1.3 TB available, ~10 GB peak per runner) to keep boot-disk pressure off.
- **Service:** one launchd LaunchAgent per runner — `actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis{,-2,-3}.plist` in `~/Library/LaunchAgents/`. Manage individually with `cd ~/actions-runner-jarvis-N && ./svc.sh {status,start,stop}` (omit `-N` for runner 1). All three only run while user is logged in.
- **Why three:** the 13-package SPM matrix parallelizes across runners. Single-runner serial = ~13 min CI; three-runner parallel = ~5 min. Grogu has 24 cores / 128 GB RAM; 3 concurrent SwiftPM cold builds peak at ~24 cores + ~24 GB, well within budget. See `docs/superpowers/specs/2026-05-13-multi-runner-grogu-design.md`.
```

- [ ] **Step 4: Stage + commit**

```bash
git add CLAUDE.md
git diff --cached --stat
git commit -m "docs(claude-md): runner inventory updated for 3-runner Grogu setup

Replaces single-runner 'Where it lives' / 'Service' bullets with the
3-runner inventory (Grogu-jarvis, -2, -3). Adds a brief 'Why three'
bullet documenting the parallelism win and links to the spec.

Refs #180"
```

Expected output: `[docs/multi-runner-inventory <sha>] docs(claude-md): runner inventory updated...` and `1 file changed`.

- [ ] **Step 5: Push + open PR**

```bash
git push -u origin docs/multi-runner-inventory
gh pr create --base develop --head docs/multi-runner-inventory \
  --title "docs(claude-md): runner inventory updated for 3-runner Grogu setup" \
  --body "Updates CLAUDE.md's \`Self-hosted CI runner\` section to reflect the new 3-runner Grogu topology (Grogu-jarvis, -2, -3) post-multi-runner-expansion. No behavior change — documentation only.

Spec: \`docs/superpowers/specs/2026-05-13-multi-runner-grogu-design.md\`
Plan: \`docs/superpowers/plans/2026-05-13-multi-runner-grogu.md\`

Refs #180"
```

Expected: the new PR URL is printed. Note the PR number; the runner-side CI for this PR is itself an acceptance test (it will exercise the new 3-runner topology).

---

## Definition of done

- All steps above are checked off.
- `gh api /repos/KofTwentyTwo/Jarvis/actions/runners` returns 3 runners, all `status=online`.
- The retriggered PR #185 CI run terminates with `conclusion=success` and showed ≥3 SPM jobs `in_progress` simultaneously during execution.
- `docs/multi-runner-inventory` PR is open (or merged) updating CLAUDE.md.

## Self-review (run by author before handoff)

- ✅ **Spec coverage:** every component in the spec is covered by a task — runner registration (Tasks 2+3), acceptance validation (Task 4), doc update (Task 5), precondition (Task 1).
- ✅ **No placeholders:** every step has concrete commands and expected output.
- ✅ **Type consistency:** runner names (`Grogu-jarvis-N`), labels (`jarvis`), plist paths, and `_work` symlink targets are spelled identically across tasks.
- ✅ **Spec out-of-scope items not present:** no warm-cache work, no monitoring/alerting, no per-runner labels.
- ✅ **Rollback path documented in spec, referenced as needed.**
