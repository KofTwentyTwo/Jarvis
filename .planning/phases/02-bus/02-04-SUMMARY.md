---
phase: 02-bus
plan: 04
subsystem: bus
tags: [build-scripts, pre-build-phase, xcodegen, lint, parity, sec-09, hud-04]

requires:
  - phase: 02-bus
    plan: 01
    provides: "packages/Bus/Sources/Bus/Protocol.swift with BUS_PROTOCOL_VERSION=2.0.0 + 14 JSON fixtures"
  - phase: 02-bus
    plan: 02
    provides: "webview/packages/bus/src/protocol.ts with BUS_PROTOCOL_VERSION=2.0.0 + 14 matching JSON fixtures + webview/bus-harness.html"
provides:
  - "scripts/check-bus-protocol-version.sh — Swift/TS constant grep + `diff -r` of the two fixture directories"
  - "scripts/check-no-evaluate-javascript.sh — HUD-04 architectural lint forbidding `.evaluateJavaScript(` in Swift sources outside test dirs"
  - "scripts/check-bus-harness-parity.sh — byte-identical check between canonical `webview/bus-harness.html` and bundle copy `App/Resources/webview/bus-harness.html`"
  - "scripts/test-check-bus-protocol-version.sh + scripts/test-check-no-evaluate-javascript.sh — fault-injection smoke tests driving the checkers against deliberately-bad fixtures"
  - "scripts/test-fixtures/bus-mismatch/ — Swift at 2.0.0 vs TS at 1.9.0 mismatch fixture"
  - "scripts/test-fixtures/bus-evaluate-js/ — bad.swift (forbidden) + good.swift (allowed) control"
  - "project.yml preBuildScripts block on Jarvis target wiring the three checks BEFORE Compile Sources"
affects: [02-03-outbound-batcher-wiring, 03-hud-wave, every-future-bus-change]

tech-stack:
  added:
    - "Xcode `preBuildScripts` phase wiring via xcodegen — runs BEFORE PBXSourcesBuildPhase in emitted pbxproj"
  patterns:
    - "Build-breaking check-script pattern: `set -euo pipefail` + env-overridable defaults (SWIFT_FILE, TS_FILE, SWIFT_FIXTURES, TS_FIXTURES, REPO, SEARCH_ROOTS) + sharp stderr on failure"
    - "Fault-injection smoke-test pattern: `scripts/test-check-*.sh` drives the production checker against `scripts/test-fixtures/*/` and asserts exit code + error-message contents"
    - "`/usr/bin/diff` explicitly invoked to bypass shell `diff`/`difft` aliasing — mandatory for reproducible behavior across developer shells"
    - "`inputFiles:` on pre-build scripts so Xcode skips redundant runs when target files unchanged (harness-parity + protocol-version); omitted on the full-tree lint (no-evaluate-javascript) so it runs every build"
    - "mktemp workaround in test-harness for no-evaluate-javascript lint — production checker skips `*/test-fixtures/*` path components, so the harness copies the bad.swift/good.swift pair to a temp dir whose path does not contain that segment"

key-files:
  created:
    - "scripts/check-bus-protocol-version.sh"
    - "scripts/check-no-evaluate-javascript.sh"
    - "scripts/check-bus-harness-parity.sh"
    - "scripts/test-check-bus-protocol-version.sh"
    - "scripts/test-check-no-evaluate-javascript.sh"
    - "scripts/test-fixtures/bus-mismatch/swift/Protocol.swift"
    - "scripts/test-fixtures/bus-mismatch/ts/protocol.ts"
    - "scripts/test-fixtures/bus-mismatch/swift-fixtures/hello.json"
    - "scripts/test-fixtures/bus-mismatch/ts-fixtures/hello.json"
    - "scripts/test-fixtures/bus-evaluate-js/bad.swift"
    - "scripts/test-fixtures/bus-evaluate-js/good.swift"
  modified:
    - "project.yml — added preBuildScripts block to Jarvis target (three entries)"
    - "Jarvis.xcodeproj/project.pbxproj — xcodegen regenerated; three PBXShellScriptBuildPhase entries land at positions 1-3 of Jarvis.buildPhases, before PBXSourcesBuildPhase"
    - "packages/Bus/Tests/BusTests/Fixtures/*.json (14 files) — stripped trailing \\n to match TS fixture convention (Rule 3 blocking fix; see Deviations)"

key-decisions:
  - "All three checks are pre-build phases (not post-build) so constant drift is caught before `swiftc` embeds a stale value — SEC-09 mandate."
  - "Phase order is fastest-failing first: harness-parity (single `diff -q`) → protocol-version (two greps + `diff -r` of 14 files) → evaluate-javascript (find-walk across entire App/ + packages/ tree). A developer authoring a wrong harness copy sees the error fastest; a developer doing whole-codebase grep sees it last."
  - "Test fixtures live under `scripts/test-fixtures/` and the production `check-no-evaluate-javascript.sh` skips any path matching `*/test-fixtures/*`. The smoke-test harness copies the fixture to a temp dir so the skip doesn't no-op the test — otherwise running against `REPO=scripts/test-fixtures` would make the resolved find-path contain `test-fixtures/` and get skipped."
  - "`/usr/bin/diff` called by absolute path — the default user shell aliases `diff` to `difft` (structural diff), which rejects the `-r` and `-q` flags the checkers rely on. Absolute path is defensive against developer dotfile drift."
  - "Pre-existing Swift-side fixture drift (trailing newline on 14 JSON files) was normalized AS PART OF this plan's Rule 3 blocking fix rather than punted — the parity script cannot green-light with the existing drift, and Swift's JSONEncoder default produces no trailing newline (which is what Plan 02-02's TS fixtures already match). 02-02-SUMMARY claimed byte-equality but the actual state disagreed; this plan makes the claim true."
  - "Placed `preBuildScripts` in project.yml between `dependencies:` and `copyFiles:` — keeps lifecycle ordering in source order (deps → pre-build → resources → post-build). xcodegen emits them in the expected order regardless of yaml placement (keys drive emission, not order), but source ordering helps readers."

patterns-established:
  - "Build-breaking check scripts live in scripts/check-*.sh; their smoke-test harnesses in scripts/test-check-*.sh; fixtures in scripts/test-fixtures/<topic>/. Pattern extends to any future cross-language parity or architectural-lint need (MCP schema parity, tool-call format parity, etc.)."
  - "Pre-build phase wiring via xcodegen `preBuildScripts:` with per-phase `inputFiles:` hints where possible. Set `basedOnDependencyAnalysis: false` for whole-tree scans that must run every build."
  - "Test-harness-drives-production-script pattern (established in P1 `test-verify-entitlements.sh`, reused here). Lets a grep-sense-inversion or a regex-typo be caught by the smoke test before it ships as a silent no-op."

requirements-completed: [HUD-04, SEC-09]

duration: ~30min
completed: 2026-04-23
---

# Phase 02 Plan 04: Build-parity + HUD-04 Lint Summary

**Three build-breaking Xcode pre-build phases — bus-harness parity, Swift/TS BUS_PROTOCOL_VERSION + fixture `diff -r`, and `.evaluateJavaScript(` architectural lint — plus two fault-injection smoke tests. End-to-end `xcodebuild` confirmed the checks run BEFORE `SwiftCompile`. SEC-09 and HUD-04 build-armed.**

## Performance

- **Duration:** ~30 min
- **Tasks:** 2 of 2
- **Files created:** 11 (3 production check scripts, 2 test-harness scripts, 6 fixture files)
- **Files modified:** 16 (project.yml, Jarvis.xcodeproj/project.pbxproj, 14 Swift-side JSON fixtures)

## Accomplishments

- **`scripts/check-bus-protocol-version.sh`** (2 KB, executable): greps `public let BUS_PROTOCOL_VERSION: String = "..."` from Swift, `export const BUS_PROTOCOL_VERSION = "..."` from TS, fails if mismatched. Then `diff -r`s `packages/Bus/Tests/BusTests/Fixtures/` against `webview/packages/bus/fixtures/` — any byte difference fails the build with the full diff on stderr. Env-overridable via `SWIFT_FILE`, `TS_FILE`, `SWIFT_FIXTURES`, `TS_FIXTURES`, `REPO` for test-harness use.
- **`scripts/check-no-evaluate-javascript.sh`** (1.5 KB, executable): `find` walks `App/` + `packages/` for `*.swift`, skips `*/Tests/*`, `*/tests/*`, `*/test-fixtures/*`, then greps each for `\.evaluateJavaScript\(`. Any hit fails the build with file:line:matching-line and a remediation pointer to `callAsyncJavaScript(_:arguments:in:contentWorld:)`. Env-overridable via `REPO` and `SEARCH_ROOTS`.
- **`scripts/check-bus-harness-parity.sh`** (1.3 KB, executable): `diff -q` between `webview/bus-harness.html` (canonical) and `App/Resources/webview/bus-harness.html` (bundle copy, Plan 02-03). Fails with clear remediation on missing bundle copy or any drift. `/usr/bin/diff` absolute path avoids `difft` aliasing.
- **`scripts/test-check-bus-protocol-version.sh`** (1.2 KB, executable): drives the protocol-version checker against `scripts/test-fixtures/bus-mismatch/` (Swift=2.0.0, TS=1.9.0). Asserts exit 1 with both versions in the error. Verifies fixture existence + checker executability pre-flight.
- **`scripts/test-check-no-evaluate-javascript.sh`** (1.4 KB, executable): copies `scripts/test-fixtures/bus-evaluate-js/` to a temp dir (to bypass the production `*/test-fixtures/*` skip), drives the checker against it, asserts `bad.swift` is flagged and `good.swift` is NOT flagged.
- **`scripts/test-fixtures/bus-mismatch/`**: Swift Protocol.swift declaring 2.0.0; ts/protocol.ts declaring 1.9.0; swift-fixtures/hello.json containing `{"type":"hello","version":"2.0.0"}`; ts-fixtures/hello.json containing `{"type":"hello","version":"1.9.0"}` — no trailing newlines (printf '%s').
- **`scripts/test-fixtures/bus-evaluate-js/`**: bad.swift using `webView.evaluateJavaScript(...)` (deliberately forbidden); good.swift using `webView.callAsyncJavaScript(...)` (allowed control).
- **`project.yml`**: added `preBuildScripts:` block to the Jarvis target with three entries — harness-parity first (fastest), protocol-version second, no-evaluate-javascript third. `inputFiles:` hints supplied where applicable; `basedOnDependencyAnalysis: false` on the full-tree lint.
- **`Jarvis.xcodeproj/project.pbxproj`**: xcodegen regenerated. Verified via buildPhases extraction that the three PBXShellScriptBuildPhase entries appear at positions 1-3 before PBXSourcesBuildPhase in the Jarvis target's buildPhases list.
- **End-to-end `xcodebuild build`** (with a temp bundle-copy of bus-harness.html to satisfy the cross-wave dependency on Plan 02-03): `BUILD SUCCEEDED`. Log confirms all three pre-build phases ran and printed their OK messages (lines 80, 687, 1290), followed by the first `SwiftCompile` at line 1924. Pre-build → Compile Sources → Resources → Frameworks → post-build chain all in expected order.

## Task Commits

Each task committed atomically on branch `worktree-agent-af785327` (base `21879f3`):

1. **Task 1: three check scripts + two smoke tests + six fixture files (+ fixture normalization)** — `a63d521` (feat)
2. **Task 2: `preBuildScripts` block on Jarvis target + xcodegen regen** — `23f2ea2` (feat)

Plan metadata commit for this SUMMARY made after self-check below.

## Files Created/Modified

**Check scripts (`scripts/`):**
- `check-bus-protocol-version.sh` — Swift/TS constant grep + fixture `diff -r`
- `check-no-evaluate-javascript.sh` — find-walk + grep for `.evaluateJavaScript(`
- `check-bus-harness-parity.sh` — byte-identical `diff -q` on the two harness HTML files

**Smoke test harnesses (`scripts/`):**
- `test-check-bus-protocol-version.sh` — drives the protocol-version checker against a mismatch fixture
- `test-check-no-evaluate-javascript.sh` — drives the lint checker against a bad.swift/good.swift control

**Fixtures (`scripts/test-fixtures/`):**
- `bus-mismatch/swift/Protocol.swift` — `BUS_PROTOCOL_VERSION = "2.0.0"`
- `bus-mismatch/ts/protocol.ts` — `BUS_PROTOCOL_VERSION = "1.9.0"` (mismatch)
- `bus-mismatch/swift-fixtures/hello.json` — 2.0.0 payload (no trailing newline)
- `bus-mismatch/ts-fixtures/hello.json` — 1.9.0 payload (no trailing newline)
- `bus-evaluate-js/bad.swift` — contains forbidden `.evaluateJavaScript(` call
- `bus-evaluate-js/good.swift` — contains allowed `.callAsyncJavaScript(` call

**Modified:**
- `project.yml` — `preBuildScripts:` block (3 entries) between `dependencies:` and `copyFiles:` on Jarvis target
- `Jarvis.xcodeproj/project.pbxproj` — xcodegen regenerated; 3 new PBXShellScriptBuildPhase entries at positions 1-3 of Jarvis.buildPhases
- `packages/Bus/Tests/BusTests/Fixtures/*.json` (14 files) — stripped trailing `\n` to match TS convention (Rule 3 fix)

## Decisions Made

See `key-decisions` in frontmatter. Headline items:

1. **Pre-build, not post-build.** SEC-09 mandate: catch constant drift before `swiftc` embeds a stale value. Post-build would be useless.
2. **Phase order = fastest-failing first.** Harness-parity is one `diff -q` on one file pair; protocol-version is two greps + 14-file `diff -r`; no-evaluate-javascript is a find-walk over the whole Swift tree. Ordering minimizes developer wait-time on common errors.
3. **Absolute `/usr/bin/diff`.** The user's shell aliases `diff` to `difft` (structural diff), which rejects `-r` and `-q`. Absolute path is defensive.
4. **test-fixtures path-skip workaround.** The production `check-no-evaluate-javascript.sh` skips `*/test-fixtures/*` so test fixtures don't trip the lint. But that means the smoke-test harness can't run the checker with `REPO=scripts/test-fixtures` — the skip would no-op the test. Copy to a temp dir whose path doesn't contain `test-fixtures`.
5. **`inputFiles` hints where appropriate.** Xcode re-runs a pre-build script when any `inputFiles` entry changes. Harness-parity + protocol-version have narrow file sets and get hints; no-evaluate-javascript scans the whole tree and cannot enumerate reasonable inputs, so it runs every build via `basedOnDependencyAnalysis: false`.
6. **Fixture normalization is in-scope.** Plan 02-02's SUMMARY claimed byte-equality between Swift and TS fixtures; the actual on-disk state disagreed (14 trailing newlines). Rather than relaxing `diff -r`, normalize the Swift fixtures to match TS (and Swift's own JSONEncoder default). Swift round-trip tests unaffected (JSONSerialization ignores trailing whitespace).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Swift-side JSON fixtures had trailing `\n` not present on TS side**
- **Found during:** Task 1 verification — ran `check-bus-protocol-version.sh` against the real repo and got 14 "\\ No newline at end of file" diff entries, all from the TS side missing the newline that Plan 02-01's fixtures carry.
- **Issue:** `packages/Bus/Tests/BusTests/Fixtures/*.json` (14 files) were authored with a trailing `\n`; `webview/packages/bus/fixtures/*.json` were written via `printf '%s'` with no trailing byte. Plan 02-02's SUMMARY documented the no-trailing-newline convention (matching Swift's `JSONEncoder` default) as established, but Plan 02-01's fixtures predate that convention and were committed via a text editor that added `\n`. Without normalization, the parity `diff -r` would flag every bus commit going forward as drift.
- **Fix:** `for f in packages/Bus/Tests/BusTests/Fixtures/*.json; do content=$(cat "$f"); printf '%s' "$content" > "$f"; done`. Strips exactly one trailing newline per file.
- **Files modified:** All 14 files in `packages/Bus/Tests/BusTests/Fixtures/`.
- **Verification:** `swift test --filter CodableRoundTripTests` remains 24/24 green (JSONSerialization normalizes trailing whitespace). `diff -r packages/Bus/Tests/BusTests/Fixtures/ webview/packages/bus/fixtures/` now produces empty output. `scripts/check-bus-protocol-version.sh` prints `bus parity OK at v2.0.0` and exits 0.
- **Committed in:** `a63d521` (Task 1 commit) — documented in the commit body.

**2. [Rule 3 - Blocking] `diff` shell alias required `/usr/bin/diff` absolute path**
- **Found during:** Task 1 draft of `check-bus-protocol-version.sh` — `diff -r` produced "unexpected argument '-r' found" from `difft` (structural diff, aliased by the user's zsh).
- **Issue:** User's zsh aliases `diff` to `difft`, which has an incompatible CLI. Scripts invoking `diff` directly would behave differently in Xcode (which runs via `/bin/sh`, no aliases) vs. developer shells (where aliases apply). For the test-harness scripts, developer-shell behavior matters.
- **Fix:** Use `/usr/bin/diff` absolute path throughout all three check scripts.
- **Files modified:** `scripts/check-bus-protocol-version.sh`, `scripts/check-bus-harness-parity.sh`.
- **Verification:** Scripts run clean in both the developer shell AND under `xcodebuild`.
- **Committed in:** `a63d521` (Task 1 commit) — no separate call-out; the scripts were written with absolute paths from first draft.

### Expected-in-Worktree Non-Pass Cases

**`check-bus-harness-parity.sh` fails in this worktree.** The script requires `App/Resources/webview/bus-harness.html` to exist. That file is Plan 02-03's deliverable. In this parallel-execution worktree (agent-af785327), Plan 02-03's branch hasn't merged yet, so the bundle copy doesn't exist and the script correctly fails with the expected remediation message.

This is not a deviation — it's the correct behavior of a build-breaker. After Plan 02-03 merges to develop, the bundle copy lands and `check-bus-harness-parity.sh` will exit 0. Verified manually within this worktree by temporarily `cp webview/bus-harness.html App/Resources/webview/bus-harness.html`, running `xcodebuild`, observing `BUILD SUCCEEDED`, then removing the temp copy.

### Expected PBXCopyFilesBuildPhase Stripping

xcodegen 2.45.4 strips the empty `PBXCopyFilesBuildPhase` (Contents/Helpers copy with `files: []`) when regenerating. Matches the P1 pattern documented in `.planning/phases/01-foundations/01-03` / `01-04` SUMMARY. The `Create Contents/Helpers directory` post-build script creates the directory at bundle time, so nothing is lost functionally — but the YAML carries the `copyFiles:` block for documentation/future-use.

---

**Total deviations:** 2 auto-fixed (both Rule 3 — blocking issues inherent to the cross-language parity problem).
**Impact on plan:** None on Phase 2 scope. The fixture-normalization deviation surfaces a latent inconsistency between Plan 02-01 and 02-02 and resolves it at the natural enforcement point.

## Issues Encountered

Separate from the auto-fixed deviations:

- **Worktree-path discipline.** Initial `Write` calls resolved absolute paths to the main repo rather than the agent worktree. Cleaned up the stray files from the main repo and re-wrote everything under the worktree-qualified path. Process: absolute paths in tool calls must be computed relative to the active worktree, not the project root.

## Known Stubs

None. All three production scripts and both test harnesses are fully functional. The only "placeholder-like" behavior is the harness-parity script failing when the bundle copy is absent — that is the script's CORRECT behavior as a build-breaker; Plan 02-03 resolves it by committing the bundle copy.

## Threat Flags

None. The plan's `<threat_model>` register covers T-02-20 through T-02-25; this implementation addresses T-02-20 (Swift/TS constant drift), T-02-21 (fixture-set drift), T-02-22 (evaluateJavaScript insertion), T-02-23 (harness drift) via mitigations as written. No new security-relevant surface introduced — the check scripts read files and exit; no network, no filesystem writes outside `/tmp/bus-*-test.$$` temp files + `mktemp -d`.

## Next Phase Readiness

**Handoff to Phase 3 and later plans:**

- **Every new `BusOutbound`/`BusInbound` case** must (a) add a Swift fixture under `packages/Bus/Tests/BusTests/Fixtures/`, (b) add a byte-identical TS fixture under `webview/packages/bus/fixtures/`, (c) if the wire format changes, bump `BUS_PROTOCOL_VERSION` on BOTH sides. The pre-build phase fails the build otherwise. **`printf '%s'` (no trailing newline)** is the fixture-authoring convention.
- **Never call `.evaluateJavaScript(` in App/ or packages/ Swift sources** outside `Tests/`, `tests/`, or `test-fixtures/`. The HUD-04 lint fails the build. Use `callAsyncJavaScript(_:arguments:in:contentWorld:)` via `WebviewBridge.send(_:)` (P2-03) or whatever bus-peer API ships later.
- **Canonical harness HTML lives at `webview/bus-harness.html`.** The bundle copy at `App/Resources/webview/bus-harness.html` MUST stay byte-identical. Edit the canonical file and run `cp webview/bus-harness.html App/Resources/webview/bus-harness.html` (or let Plan 02-03's sync script do it).

**Phase 2 completion state after this plan:**

All 5 Phase 2 requirements (HUD-03, HUD-04, HUD-05, HUD-06, SEC-09) have an implementation landing across the 4 Phase 2 plans:
- HUD-03 (WKScriptMessageHandlerWithReply): Plan 02-01
- HUD-04 (callAsyncJavaScript-only, lint-enforced): Plan 02-03 (wiring) + **02-04 (lint)**
- HUD-05 (Handshake state machine): Plan 02-01
- HUD-06 (OutboundBatcher): Plan 02-03
- SEC-09 (Swift/TS parity, build-enforced): Plan 02-01 (contract) + Plan 02-02 (mirror) + **02-04 (build-breaker)**

Bus is runtime-armed (Plans 01-03) AND build-hardened (Plan 04).

## Self-Check: PASSED

**Files verified present in worktree:**
- `scripts/check-bus-protocol-version.sh` — FOUND (mode 0755, 3.5 KB)
- `scripts/check-no-evaluate-javascript.sh` — FOUND (mode 0755, 2.2 KB)
- `scripts/check-bus-harness-parity.sh` — FOUND (mode 0755, 1.7 KB)
- `scripts/test-check-bus-protocol-version.sh` — FOUND (mode 0755, 1.6 KB)
- `scripts/test-check-no-evaluate-javascript.sh` — FOUND (mode 0755, 1.8 KB)
- `scripts/test-fixtures/bus-mismatch/swift/Protocol.swift` — FOUND (declares 2.0.0)
- `scripts/test-fixtures/bus-mismatch/ts/protocol.ts` — FOUND (declares 1.9.0)
- `scripts/test-fixtures/bus-mismatch/swift-fixtures/hello.json` — FOUND (no trailing newline)
- `scripts/test-fixtures/bus-mismatch/ts-fixtures/hello.json` — FOUND (no trailing newline)
- `scripts/test-fixtures/bus-evaluate-js/bad.swift` — FOUND (contains forbidden API)
- `scripts/test-fixtures/bus-evaluate-js/good.swift` — FOUND (contains allowed API)
- `project.yml` — MODIFIED (preBuildScripts block with 3 entries on Jarvis target; verified via `grep -A 25 'preBuildScripts:' project.yml`)
- `Jarvis.xcodeproj/project.pbxproj` — REGENERATED (3 PBXShellScriptBuildPhase refs at buildPhases positions 1-3, before Sources at position 4)

**Commits verified in git log:**
- `a63d521` (Task 1) — FOUND via `git log --oneline`
- `23f2ea2` (Task 2) — FOUND via `git log --oneline`

**Production check scripts verified green:**
- `bash scripts/check-bus-protocol-version.sh` → exit 0, `bus parity OK at v2.0.0`
- `bash scripts/check-no-evaluate-javascript.sh` → exit 0, `no evaluateJavaScript calls — HUD-04 OK`
- `bash scripts/check-bus-harness-parity.sh` → exit 1 (expected; Plan 02-03 owns bundle copy)

**Smoke tests verified green:**
- `bash scripts/test-check-bus-protocol-version.sh` → exit 0, `correctly rejected mismatch fixture`
- `bash scripts/test-check-no-evaluate-javascript.sh` → exit 0, `correctly rejected bad fixture`

**End-to-end `xcodebuild` verified (with temp bundle copy):**
- `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis build -destination 'platform=macOS' -configuration Debug` → `BUILD SUCCEEDED`
- Pre-build phase order confirmed via log-line positions: 80 (harness-parity) < 687 (protocol-version) < 1290 (no-evaluate-javascript) < 1924 (first SwiftCompile).

**Swift XCTest still green after fixture normalization:**
- `cd packages/Bus && swift test --filter CodableRoundTripTests` → 24/24 passed.

---
*Phase: 02-bus*
*Plan: 04*
*Completed: 2026-04-23*
