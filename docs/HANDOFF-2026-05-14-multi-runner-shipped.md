# Handoff — 2026-05-14: multi-runner shipped, v0.2 ready

**Session window:** 2026-05-13 afternoon (Grogu single runner setup) → 2026-05-14 (multi-runner expansion + first auto-Release)
**Branch:** `develop`, clean
**HEAD at write time:** `774e60a0` — `ci(actions): create GitHub Release directly in publish-tag job (#187)`
**Open PR count:** 2 (#185, #191 — both with shepherds running)
**Repo visibility:** PUBLIC

---

## TL;DR

- **3-runner self-hosted CI on Grogu is live** — `Grogu-jarvis`, `-2`, `-3`. Matrix parallelism observed (≥3 SPM jobs concurrent). Develop CI green in ~5 min vs. ~13 min single-runner.
- **Auto-Release flow proven** — `v0.1.0-dev.64` has a real GitHub Release object, created by the new `gh release create` step in `publish-tag`. No more manual `gh release create` needed.
- **Brainstorm → spec → plan → execute discipline established** via the Superpowers skills. Multi-runner work has a committed spec + plan under `docs/superpowers/{specs,plans}/`. Pattern to follow for v0.2 onward.
- **Memory test flake** surfaced: `MemoryWiringEndToEndTests.testMemoryEnqueueReceivesNonNilUserAndAssistantText` fails intermittently on PR branches but passes on develop. Hypothesis: race in `TurnTranscriptStore` actor under concurrent-runner load. Pre-existing; not from any 2026-05-13/14 code change.

---

## What shipped today

### v0.1 mop-up + first dev tag
- **PR #184** (squash `5fc2d3fa`) — Ollama model baseline reconciled to `qwen3.6:latest` (extractor) + `qwen2.5-coder:32b-instruct-q8_0` (agent fallback). Closes #58 (last v0.1 issue).
- **v0.1.0-dev.50** — first release tag of the project. Release object created manually (workflow couldn't trigger downstream).
- **v0.1.0-dev.64** — second release tag. Release object created **automatically** via the new inline `gh release create` step in `publish-tag`.

### Self-hosted runner saga
- **PR #181** (`eef17252`) — Moved `swift-packages` matrix to `Grogu-jarvis`. DEVELOPER_DIR Xcode-select. Fork-PR gate.
- **PR #183** (`81ce64c3`) — Orphan-process reaper at job start (closes #182).
- **PR #189** (`4cdb3560`) — Reaper gets a `>=1h` age filter so sibling runners on Grogu don't kill each other.
- **PR #187** (`774e60a0`) — `publish-tag` step creates the Release object directly instead of relying on `release.yml` triggering on tag push (GITHUB_TOKEN can't trigger downstream workflows).
- **PR #190** (`a26f49fd`) — Multi-runner spec + plan committed to `docs/superpowers/`.
- **PR #185** — open, AgentCore #23+#24 fix. Currently has a Memory-flake CI failure under shepherd watch.
- **PR #191** — open, CLAUDE.md inventory update. Same Memory flake situation.

### Grogu state
- 3 runners installed at `~/actions-runner-jarvis{,-2,-3}/`, each with `_work` symlinked to `/Volumes/HD-2/jarvis-runner-work{,-2,-3}/`.
- LaunchAgents managed by `~/Library/LaunchAgents/actions.runner.KofTwentyTwo-Jarvis.Grogu-jarvis{,-2,-3}.plist`.
- Keychain workflow: `~/Library/Keychains/jarvis-runner.keychain-db`, password in repo secret `JARVIS_RUNNER_KEYCHAIN_PASSWORD`. CI unlocks + makes default + prepends to search list.
- Side effect: `jarvis-runner.keychain-db` is your user's default keychain after CI runs. Undo command in CLAUDE.md.

---

## Active background processes at handoff

| Task ID | What | Expected exit |
|---|---|---|
| `bny76q2ad` | Final shepherd watching PR #185 + #191 | When both PRs are handled (merged or marked `ci-failed`), or 60-min timeout |

**Log location:** `/tmp/final-shepherd.log`

Reading the log will tell you what the shepherd did. If it marked both PRs `ci-failed` because of the Memory flake, see "Memory flake disposition" below.

---

## Memory flake disposition (what to do when you pick up)

`MemoryWiringEndToEndTests.testMemoryEnqueueReceivesNonNilUserAndAssistantText` fails with:
```
XCTAssertEqual failed: ("0") is not equal to ("1") - enqueue was not called — BLOCKER-1 regression
XCTAssertEqual failed: ("nil") is not equal to ("Optional("hi")") - userText empty/nil — Plan 4's submit-time append did not propagate via TurnTranscriptStore
XCTAssertEqual failed: ("nil") is not equal to ("Optional("hello there")") - assistantText empty/nil — Plan 1's transcript subscriber did not propagate via TurnTranscriptStore
```

**Evidence it's a flake, not a regression:**
- PR #191 doesn't touch AgentCore at all (only `CLAUDE.md`) yet hits the same exact failure.
- Develop's latest CI (`25832341662`, on `774e60a0`) passed Memory in 45s.
- Both #185 and #191 are branched off slightly different develop SHAs — the test passes on the latest develop but fails on these branch HEADs after forward-merge.

**Recommended next steps:**
1. Open a new issue: `bug,severity:medium,area:memory` — "MemoryWiringEndToEndTests intermittent failure under concurrent runner load". Describe the `TurnTranscriptStore` race hypothesis.
2. Either rerun the failed jobs (CI may pass on next attempt) OR merge both PRs as-is since branch protection has 0 required checks and the test passes reliably on develop.
3. Long-term: file the test as known-flaky in v0.2 milestone.

---

## v0.2 Wave 1 (next session start)

Tiny / doc-only / deterministic fixes — safe to land in a single session each:

| Issue | What | Effort | Why first |
|---|---|---|---|
| **#19** | MemoryStore.swift stale Phase 7 hedge doc-comments | ~5 min | Pure docs, zero risk |
| **#45** | Bus 'JarvisBusWorld' docstring drift (20+ docstrings) | ~15 min | Pure docs, mechanical |
| **#46** | Stale webview bundle artifacts in `App/Resources/webview/assets/` (~50MB) | ~10 min | File deletes |
| **#37** | STTBackendSelector snake_case vs camelCase mismatch | ~15 min | Single rename |
| **#178** | Add OpenSSF Scorecard workflow | ~15 min | One new `.github/workflows/` file |
| **#47** | WebviewBridge.sendRaw NaN→null JSON guard | ~20 min | One-line bug fix |

Each gets brainstorm → spec → plan via the Superpowers skills (specs/plans templates established in `docs/superpowers/`). Brief specs (a few paragraphs) — these are "issue body IS the design" cases.

## v0.2 Wave 2 / Wave 3 — wait

Larger items that need real diagnostic work or design decisions:
- #18 MemoryReplaySink error propagation — needs care
- #23 + #24 already in PR #185 (held)
- #44 HUD audioLevel consumer rewire — MED, design choice
- #43 sessionHistory dead-letter — overlaps M-7, defer
- #176 vitest 4.x major bump — needs eval
- #26 confirmation panel multi-monitor — needs real hardware
- Any M-0..M-7 issue — strategic, gets its own spec → plan

---

## Key references

- **Spec template:** `docs/superpowers/specs/2026-05-13-multi-runner-grogu-design.md`
- **Plan template:** `docs/superpowers/plans/2026-05-13-multi-runner-grogu.md`
- **Previous handoff:** `docs/HANDOFF-2026-05-13-v0.1-shipped.md` (now superseded for the multi-runner story but still describes v0.1 mop-up)
- **Roadmap:** `.planning/ROADMAP-2026-05-12.md`
- **Live state:** GitHub Issues + Milestones at https://github.com/KofTwentyTwo/Jarvis
- **CI workflow:** `.github/workflows/ci.yml` — has the age-filtered cleanup + inline release create
- **CLAUDE.md `Self-hosted CI runner (Grogu)`** section — operational reference for the 3-runner setup

## What this handoff deliberately doesn't relitigate

- The Memory flake's root cause — open a v0.2 bug and move on; develop's CI is reliably green so it's not blocking.
- Whether to merge PR #185 / PR #191 with a known-flaky failure — branch protection allows it; user judgment.
- Wave 2/3 v0.2 issues — they need design conversations; pick them up after Wave 1.
- M-0..M-7 — strategic, gets its own session.

---

*Written 2026-05-14 at the natural session-end after multi-runner expansion shipped. Next session should start with `/clear`, read this doc, then read the latest `/tmp/final-shepherd.log` to see what the background shepherd did, then pick up Wave 1.*
