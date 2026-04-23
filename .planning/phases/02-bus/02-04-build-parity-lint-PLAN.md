---
phase: 02-bus
plan: 04
type: execute
wave: 2
depends_on: [01, 02]
files_modified:
  - scripts/check-bus-protocol-version.sh
  - scripts/check-no-evaluate-javascript.sh
  - scripts/check-bus-harness-parity.sh
  - scripts/test-check-bus-protocol-version.sh
  - scripts/test-check-no-evaluate-javascript.sh
  - scripts/test-fixtures/bus-mismatch/swift/Protocol.swift
  - scripts/test-fixtures/bus-mismatch/ts/protocol.ts
  - scripts/test-fixtures/bus-mismatch/swift-fixtures/hello.json
  - scripts/test-fixtures/bus-mismatch/ts-fixtures/hello.json
  - scripts/test-fixtures/bus-evaluate-js/bad.swift
  - scripts/test-fixtures/bus-evaluate-js/good.swift
  - project.yml
autonomous: true
requirements: [HUD-04, SEC-09]

must_haves:
  truths:
    - "`scripts/check-bus-protocol-version.sh` greps the Swift constant at `packages/Bus/Sources/Bus/Protocol.swift`, greps the TS constant at `webview/packages/bus/src/protocol.ts`, and fails with exit 1 if they differ"
    - "`scripts/check-bus-protocol-version.sh` also diffs the Swift fixture directory (`packages/Bus/Tests/BusTests/Fixtures/`) against the TS fixture directory (`webview/packages/bus/fixtures/`) — any difference fails the build"
    - "`scripts/check-bus-protocol-version.sh` runs as an Xcode **pre-build** phase on the Jarvis target — runs BEFORE `Compile Sources`, not after — so constant drift is caught before Swift even compiles the stale value"
    - "`scripts/check-no-evaluate-javascript.sh` greps the entire Swift codebase (`App/` + `packages/`) for `\\.evaluateJavaScript(` — any hit outside `Tests/`/`tests/`/`test-fixtures/` fails the build with a line-pointing error message"
    - "`scripts/check-no-evaluate-javascript.sh` runs as the second Xcode pre-build phase, peer of the protocol-version check"
    - "`scripts/check-bus-harness-parity.sh` runs `diff` between `webview/bus-harness.html` and `App/Resources/webview/bus-harness.html` — any drift fails the build. This keeps the committed bundle copy in sync with the canonical webview/ source"
    - "Both check scripts have test fixtures — `scripts/test-check-bus-protocol-version.sh` invokes the protocol checker against the `scripts/test-fixtures/bus-mismatch/` directory and asserts the checker exits non-zero with a mismatch message"
    - "All three checks are wired as the FIRST three pre-build phases in `project.yml` under the Jarvis target — before `Compile Sources`, before the existing verify-entitlements / codesign / verify-entitlements / verify-codesign-settings post-build chain"
  artifacts:
    - path: "scripts/check-bus-protocol-version.sh"
      provides: "Build-breaking parity script for BUS_PROTOCOL_VERSION + fixture directory diff"
      contains: "BUS_PROTOCOL_VERSION"
    - path: "scripts/check-no-evaluate-javascript.sh"
      provides: "Build-breaking lint script forbidding `.evaluateJavaScript(` outside tests"
      contains: "evaluateJavaScript"
    - path: "scripts/check-bus-harness-parity.sh"
      provides: "Build-breaking lint script ensuring `webview/bus-harness.html` and `App/Resources/webview/bus-harness.html` stay byte-identical"
    - path: "scripts/test-check-bus-protocol-version.sh"
      provides: "CI/dev-time smoke test: drives the checker against a fixture that IS mismatched, asserts exit code 1"
    - path: "scripts/test-check-no-evaluate-javascript.sh"
      provides: "CI/dev-time smoke: drives the JS-lint checker against a fixture that DOES contain evaluateJavaScript, asserts exit code 1"
    - path: "scripts/test-fixtures/bus-mismatch/"
      provides: "Fixture with Swift at v2.0.0 and TS at v1.9.0 — the checker must refuse it"
    - path: "scripts/test-fixtures/bus-evaluate-js/"
      provides: "Fixture containing a bad.swift with a `.evaluateJavaScript(` call — the checker must refuse it"
    - path: "project.yml"
      provides: "Three new preBuildScripts on the Jarvis target — checks run BEFORE Compile Sources"
  key_links:
    - from: "project.yml"
      to: "scripts/check-bus-protocol-version.sh"
      via: "preBuildScripts on Jarvis target"
      pattern: "check-bus-protocol-version\\.sh"
    - from: "project.yml"
      to: "scripts/check-no-evaluate-javascript.sh"
      via: "preBuildScripts on Jarvis target"
      pattern: "check-no-evaluate-javascript\\.sh"
    - from: "scripts/check-bus-protocol-version.sh"
      to: "packages/Bus/Sources/Bus/Protocol.swift + webview/packages/bus/src/protocol.ts"
      via: "regex-grep of `BUS_PROTOCOL_VERSION`"
      pattern: "BUS_PROTOCOL_VERSION"
---

<objective>
Install the build-time safety nets around the bus. Plans 01-03 delivered the
runtime machinery; this plan makes it impossible to ship a broken version of
it without the build catching the break first. Three scripts + their wiring:

1. **`scripts/check-bus-protocol-version.sh`** — Xcode pre-build phase that
   (a) greps both the Swift and TS `BUS_PROTOCOL_VERSION` constants,
   (b) fails with a sharp error if they differ,
   (c) diffs the two fixture directories to ensure byte-equality.
   This is SEC-09's load-bearing build-breaker.

2. **`scripts/check-no-evaluate-javascript.sh`** — Xcode pre-build phase that
   greps the entire Swift codebase (`App/**/*.swift`, `packages/**/*.swift`)
   for `\.evaluateJavaScript(` and fails on any hit outside test source
   directories. This is HUD-04's lint enforcement.

3. **`scripts/check-bus-harness-parity.sh`** — pre-build phase that asserts
   `webview/bus-harness.html` (canonical) and `App/Resources/webview/bus-harness.html`
   (bundle copy Plan 03 commits) are byte-identical. Prevents silent drift
   between the canonical source and the committed bundle copy.

All three scripts run as the FIRST three pre-build phases of the `Jarvis`
target — they run BEFORE `Compile Sources`, so a stale constant is caught
before `swiftc` embeds it. Failure is hard: `exit 1` + a sharp stderr
message pointing at the file, the line, and the offending value.

Each script has a peer test-harness script under `scripts/test-*.sh` +
fixture directory under `scripts/test-fixtures/` — dev-time smoke tests that
run the checker against a deliberately-bad input and assert it refuses.

Purpose: Plan 01's hand-written Codable + exhaustive switches defend against
drift AT RUNTIME. Plan 02's Vitest + strict TS defend AT COMPILE TIME on the
TS side. This plan defends AT BUILD TIME for cross-language parity (constants,
fixtures, harness HTML) and for the HUD-04 lint rule.

Output: Three pre-build check scripts + two test-harness scripts + two
fixture directories + updated `project.yml`. No Swift or TS code changes.
Can run in parallel with Plan 03 — scripts live under `scripts/`, fixtures
under `scripts/test-fixtures/`, only `project.yml` overlaps with Plan 03
(sequential dependency on project.yml writes is the reason this is Wave 2).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/phases/02-bus/02-RESEARCH.md
@.planning/phases/02-bus/02-01-swift-bus-package-PLAN.md
@.planning/phases/02-bus/02-02-ts-bus-package-PLAN.md
@.planning/phases/02-bus/02-03-outbound-batcher-wiring-PLAN.md

<!-- Existing P1 scripts — same pattern family -->
@scripts/verify-entitlements.sh
@scripts/verify-codesign-settings.sh
@project.yml

<interfaces>
<!-- Ground truth after Plans 01 + 02 are complete -->
```
packages/Bus/Sources/Bus/Protocol.swift:
  public let BUS_PROTOCOL_VERSION: String = "2.0.0"

webview/packages/bus/src/protocol.ts:
  export const BUS_PROTOCOL_VERSION = "2.0.0";

packages/Bus/Tests/BusTests/Fixtures/*.json  (14 files)
webview/packages/bus/fixtures/*.json         (14 files — byte-identical)

webview/bus-harness.html
App/Resources/webview/bus-harness.html       (committed by Plan 03; this plan enforces parity)
```

<!-- project.yml existing post-build phase order (from P1) -->
```yaml
postBuildScripts:
  - name: Create Contents/Helpers directory
  - name: Verify entitlements (pre-codesign)
  - name: Codesign bundle (deepest-first)
  - name: Verify entitlements (post-codesign)
  - name: Verify codesign settings (pbxproj lint)
```

<!-- This plan ADDS preBuildScripts that run BEFORE Compile Sources.
     Xcodegen supports both `preBuildScripts` and `postBuildScripts` as
     top-level lists on a target. `preBuildScripts` are emitted BEFORE
     `PBXSourcesBuildPhase` (Compile Sources) in the generated pbxproj
     buildPhases list — confirmed by xcodegen docs and by inspecting the
     emitted pbxproj for peer projects. -->
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Write the three check scripts + their test harnesses + test fixtures</name>
  <files>
    scripts/check-bus-protocol-version.sh,
    scripts/check-no-evaluate-javascript.sh,
    scripts/check-bus-harness-parity.sh,
    scripts/test-check-bus-protocol-version.sh,
    scripts/test-check-no-evaluate-javascript.sh,
    scripts/test-fixtures/bus-mismatch/swift/Protocol.swift,
    scripts/test-fixtures/bus-mismatch/ts/protocol.ts,
    scripts/test-fixtures/bus-mismatch/swift-fixtures/hello.json,
    scripts/test-fixtures/bus-mismatch/ts-fixtures/hello.json,
    scripts/test-fixtures/bus-evaluate-js/bad.swift,
    scripts/test-fixtures/bus-evaluate-js/good.swift
  </files>
  <action>
    **Decisions honored:** Script shape follows RESEARCH §SEC-09 sketch with
    additions for fixture directory diff + harness parity.
    Follow the existing `scripts/verify-entitlements.sh` /
    `scripts/verify-codesign-settings.sh` style (bash, `set -euo pipefail`,
    `REPO="$(cd "$(dirname "$0")/.." && pwd)"`).
    Test-harness pattern mirrors existing `scripts/test-verify-entitlements.sh`.

    **1. `scripts/check-bus-protocol-version.sh`:**
    ```bash
    #!/usr/bin/env bash
    #
    # Xcode pre-build phase: asserts the Swift and TS BUS_PROTOCOL_VERSION
    # constants match, and that the fixture directories are byte-identical.
    # Load-bearing for SEC-09 — the build is the final drift catcher.
    #
    # Fails the build with a sharp, pointer-to-line error on mismatch.
    #
    # Usage:
    #   scripts/check-bus-protocol-version.sh                    # production
    #   REPO=/tmp/fix scripts/check-bus-protocol-version.sh      # test mode

    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    : "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

    : "${SWIFT_FILE:=$REPO/packages/Bus/Sources/Bus/Protocol.swift}"
    : "${TS_FILE:=$REPO/webview/packages/bus/src/protocol.ts}"
    : "${SWIFT_FIXTURES:=$REPO/packages/Bus/Tests/BusTests/Fixtures}"
    : "${TS_FIXTURES:=$REPO/webview/packages/bus/fixtures}"

    err() { echo "FAIL: $*" >&2; exit 1; }

    [[ -f "$SWIFT_FILE" ]] || err "Swift protocol file not found: $SWIFT_FILE"
    [[ -f "$TS_FILE" ]] || err "TS protocol file not found: $TS_FILE"

    # Extract Swift constant — matches `public let BUS_PROTOCOL_VERSION: String = "x.y.z"`
    SWIFT_VER=$(grep -E '^[[:space:]]*public[[:space:]]+let[[:space:]]+BUS_PROTOCOL_VERSION[[:space:]]*:[[:space:]]*String[[:space:]]*=' "$SWIFT_FILE" \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 1)
    [[ -n "$SWIFT_VER" ]] || err "BUS_PROTOCOL_VERSION not found or malformed in $SWIFT_FILE"

    # Extract TS constant — matches `export const BUS_PROTOCOL_VERSION = "x.y.z"`
    TS_VER=$(grep -E '^export[[:space:]]+const[[:space:]]+BUS_PROTOCOL_VERSION[[:space:]]*=' "$TS_FILE" \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 1)
    [[ -n "$TS_VER" ]] || err "BUS_PROTOCOL_VERSION not found or malformed in $TS_FILE"

    if [[ "$SWIFT_VER" != "$TS_VER" ]]; then
        {
            echo "FAIL: BUS_PROTOCOL_VERSION mismatch"
            echo "  Swift ($SWIFT_FILE): $SWIFT_VER"
            echo "  TS    ($TS_FILE):    $TS_VER"
            echo "  Bump both to the same value before building. This is SEC-09's build-breaker."
        } >&2
        exit 1
    fi

    # Assert fixture directories are byte-identical.
    if [[ -d "$SWIFT_FIXTURES" && -d "$TS_FIXTURES" ]]; then
        if ! diff -r "$SWIFT_FIXTURES" "$TS_FIXTURES" >/tmp/bus-fixture-diff.$$ 2>&1; then
            {
                echo "FAIL: fixture directories differ"
                echo "  Swift: $SWIFT_FIXTURES"
                echo "  TS:    $TS_FIXTURES"
                cat /tmp/bus-fixture-diff.$$
            } >&2
            rm -f /tmp/bus-fixture-diff.$$
            exit 1
        fi
        rm -f /tmp/bus-fixture-diff.$$
    else
        # In production both must exist; in test mode (REPO override) either can be absent.
        if [[ "$REPO" == "$(cd "$SCRIPT_DIR/.." && pwd)" ]]; then
            [[ -d "$SWIFT_FIXTURES" ]] || err "fixtures missing: $SWIFT_FIXTURES"
            [[ -d "$TS_FIXTURES" ]] || err "fixtures missing: $TS_FIXTURES"
        fi
    fi

    # Note: the full Vitest + XCTest round-trip runs as part of `swift test` /
    # `pnpm test`, not on every build (adds 5-10s of incremental pain). The
    # grep + diff-r covers the wire-shape risk at build time.

    echo "bus parity OK at v$SWIFT_VER"
    ```

    **2. `scripts/check-no-evaluate-javascript.sh`:**
    ```bash
    #!/usr/bin/env bash
    #
    # Xcode pre-build phase: forbids `.evaluateJavaScript(` in Swift sources
    # outside test directories. HUD-04 architecturally forbids the API —
    # `callAsyncJavaScript(_:arguments:in:contentWorld:)` is the one allowed
    # JS entry. Interpolating JSON into `evaluateJavaScript` is an XSS
    # foothold (</script>, U+2028).
    #
    # Usage:
    #   scripts/check-no-evaluate-javascript.sh                   # production
    #   REPO=/tmp/fix SEARCH_ROOTS=fixture                        # test mode

    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    : "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
    : "${SEARCH_ROOTS:=App packages}"

    HITS=()

    for root in $SEARCH_ROOTS; do
        full="$REPO/$root"
        [[ -d "$full" ]] || continue

        while IFS= read -r -d '' file; do
            # Skip test directories — tests may reference the forbidden API
            # in comments or as string literals.
            case "$file" in
                */Tests/*) continue ;;
                */tests/*) continue ;;
                */test-fixtures/*) continue ;;
            esac
            if matches=$(grep -nE '\.evaluateJavaScript\(' "$file" 2>/dev/null); then
                while IFS= read -r m; do
                    HITS+=("$file:$m")
                done <<< "$matches"
            fi
        done < <(find "$full" -name '*.swift' -type f -print0)
    done

    if [[ ${#HITS[@]} -gt 0 ]]; then
        {
            echo "FAIL: forbidden .evaluateJavaScript( call in Swift sources — HUD-04 violation"
            for hit in "${HITS[@]}"; do echo "  $hit"; done
            echo ""
            echo "Use webView.callAsyncJavaScript(_:arguments:in:contentWorld:) with a"
            echo "primitive-string payload argument instead. Interpolating JSON into an"
            echo "evaluateJavaScript body is an XSS foothold (</script>, U+2028)."
            echo ""
            echo "See packages/Bus/Sources/Bus/WebviewBridge.swift for the canonical pattern."
        } >&2
        exit 1
    fi

    echo "no evaluateJavaScript calls — HUD-04 OK"
    ```

    **3. `scripts/check-bus-harness-parity.sh`:**
    ```bash
    #!/usr/bin/env bash
    #
    # Xcode pre-build phase: asserts webview/bus-harness.html (canonical) and
    # App/Resources/webview/bus-harness.html (bundle copy) are byte-identical.
    # Plan 03 commits both; this script prevents silent drift between them.

    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    : "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

    CANONICAL="$REPO/webview/bus-harness.html"
    BUNDLE="$REPO/App/Resources/webview/bus-harness.html"

    [[ -f "$CANONICAL" ]] || { echo "FAIL: canonical bus-harness.html missing: $CANONICAL" >&2; exit 1; }
    [[ -f "$BUNDLE" ]] || {
        echo "FAIL: bundle bus-harness.html missing: $BUNDLE" >&2
        echo "   Copy from $CANONICAL to $BUNDLE and commit." >&2
        exit 1
    }

    if ! diff -q "$CANONICAL" "$BUNDLE" >/dev/null 2>&1; then
        {
            echo "FAIL: bus-harness.html drift between canonical and bundle copy"
            echo "  Canonical: $CANONICAL"
            echo "  Bundle:    $BUNDLE"
            echo ""
            echo "If you changed the canonical file, copy it:"
            echo "  cp \"$CANONICAL\" \"$BUNDLE\""
            echo ""
            echo "If you changed the bundle copy directly: don't. Edit the canonical file."
            echo ""
            echo "Diff:"
            diff "$CANONICAL" "$BUNDLE" || true
        } >&2
        exit 1
    fi

    echo "bus-harness.html parity OK"
    ```

    **4. Test fixtures — `scripts/test-fixtures/bus-mismatch/`:**

    `scripts/test-fixtures/bus-mismatch/swift/Protocol.swift`:
    ```
    public let BUS_PROTOCOL_VERSION: String = "2.0.0"
    ```

    `scripts/test-fixtures/bus-mismatch/ts/protocol.ts`:
    ```
    export const BUS_PROTOCOL_VERSION = "1.9.0";
    ```

    `scripts/test-fixtures/bus-mismatch/swift-fixtures/hello.json`:
    ```
    {"type":"hello","version":"2.0.0"}
    ```

    `scripts/test-fixtures/bus-mismatch/ts-fixtures/hello.json`:
    ```
    {"type":"hello","version":"1.9.0"}
    ```

    (The constant check fires before the fixture diff — the test asserts the
    constant failure path. The fixture diff is exercised implicitly.)

    **5. Test fixtures — `scripts/test-fixtures/bus-evaluate-js/`:**

    `scripts/test-fixtures/bus-evaluate-js/bad.swift`:
    ```swift
    // Deliberately bad: contains a forbidden evaluateJavaScript call.
    // The lint script must flag this file.
    import WebKit

    func badCall(_ webView: WKWebView, _ json: String) {
        webView.evaluateJavaScript("window.foo(\(json))")
    }
    ```

    `scripts/test-fixtures/bus-evaluate-js/good.swift`:
    ```swift
    // Control file: uses the allowed API. Must NOT be flagged.
    import WebKit

    func goodCall(_ webView: WKWebView, _ json: String) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.foo(payload)",
            arguments: ["payload": json],
            in: nil,
            contentWorld: .defaultClient
        )
    }
    ```

    **6. `scripts/test-check-bus-protocol-version.sh`:**
    ```bash
    #!/usr/bin/env bash
    # Smoke test: drives check-bus-protocol-version.sh against a fixture repo
    # where Swift is at v2.0.0 and TS is at v1.9.0. Expects exit 1.

    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    FIX_DIR="$SCRIPT_DIR/test-fixtures/bus-mismatch"

    tmp="/tmp/bus-check-test.$$"
    if env \
        SWIFT_FILE="$FIX_DIR/swift/Protocol.swift" \
        TS_FILE="$FIX_DIR/ts/protocol.ts" \
        SWIFT_FIXTURES="$FIX_DIR/swift-fixtures" \
        TS_FIXTURES="$FIX_DIR/ts-fixtures" \
        REPO="$FIX_DIR" \
        "$SCRIPT_DIR/check-bus-protocol-version.sh" >"$tmp" 2>&1; then
        echo "FAIL: check-bus-protocol-version.sh accepted a mismatch fixture" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi

    if ! grep -q "2.0.0" "$tmp" || ! grep -q "1.9.0" "$tmp"; then
        echo "FAIL: error message should mention both versions" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi
    rm -f "$tmp"

    echo "check-bus-protocol-version.sh correctly rejected mismatch fixture"
    ```

    **7. `scripts/test-check-no-evaluate-javascript.sh`:**
    ```bash
    #!/usr/bin/env bash
    # Smoke test: drives check-no-evaluate-javascript.sh against a fixture dir
    # containing a deliberately-bad .swift file. Expects exit 1 mentioning bad.swift
    # and NOT good.swift.

    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    tmp="/tmp/bus-js-test.$$"
    # SEARCH_ROOTS is relative to REPO; point at the fixture directory.
    if env \
        REPO="$SCRIPT_DIR/test-fixtures" \
        SEARCH_ROOTS="bus-evaluate-js" \
        "$SCRIPT_DIR/check-no-evaluate-javascript.sh" >"$tmp" 2>&1; then
        echo "FAIL: check-no-evaluate-javascript.sh accepted a bad fixture" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi

    if ! grep -q "bad.swift" "$tmp"; then
        echo "FAIL: error should mention bad.swift" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi
    if grep -q "good.swift" "$tmp"; then
        echo "FAIL: good.swift falsely flagged" >&2
        cat "$tmp" >&2
        rm -f "$tmp"
        exit 1
    fi
    rm -f "$tmp"

    echo "check-no-evaluate-javascript.sh correctly rejected bad fixture"
    ```

    **NOTE ON TEST-FIXTURES SKIP:** The production `check-no-evaluate-javascript.sh`
    skips `*/test-fixtures/*` — but when the smoke test drives it with
    `SEARCH_ROOTS=bus-evaluate-js`, the resolved find-path is
    `$REPO/bus-evaluate-js/bad.swift`, which does NOT contain the substring
    `test-fixtures` as a path-component because `REPO=$SCRIPT_DIR/test-fixtures`.
    Verify this by reading the production `case "$file" in`: the `find` output
    will be something like `/Users/.../scripts/test-fixtures/bus-evaluate-js/bad.swift`,
    which DOES contain `test-fixtures/` as a path component, so the case
    `*/test-fixtures/*) continue ;;` would skip it. This is a hazard — the
    test fixture directory is IN the test-fixtures parent.

    **Fix:** The test harness must set a REPO that does not contain
    `test-fixtures` in its path so the skip doesn't fire. Solution: copy
    the fixture to a temp location before running the test. Updated harness:

    ```bash
    # Updated scripts/test-check-no-evaluate-javascript.sh:
    set -euo pipefail
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT
    cp -r "$SCRIPT_DIR/test-fixtures/bus-evaluate-js" "$workdir/"

    tmp="/tmp/bus-js-test.$$"
    if env REPO="$workdir" SEARCH_ROOTS="bus-evaluate-js" \
        "$SCRIPT_DIR/check-no-evaluate-javascript.sh" >"$tmp" 2>&1; then
        echo "FAIL: accepted bad fixture" >&2
        cat "$tmp" >&2; rm -f "$tmp"; exit 1
    fi
    grep -q "bad.swift" "$tmp" || { echo "FAIL: bad.swift not flagged" >&2; cat "$tmp" >&2; rm -f "$tmp"; exit 1; }
    grep -q "good.swift" "$tmp" && { echo "FAIL: good.swift falsely flagged" >&2; cat "$tmp" >&2; rm -f "$tmp"; exit 1; }
    rm -f "$tmp"
    echo "check-no-evaluate-javascript.sh correctly rejected bad fixture"
    ```

    Use this updated version. Same pattern applies to the protocol-version
    test harness — but that one doesn't scan directories recursively, so
    the path-containing-`test-fixtures` issue doesn't apply to it.

    **8. `chmod +x`** — set executable bits as the final step of this task:
    ```bash
    chmod +x scripts/check-bus-protocol-version.sh \
             scripts/check-no-evaluate-javascript.sh \
             scripts/check-bus-harness-parity.sh \
             scripts/test-check-bus-protocol-version.sh \
             scripts/test-check-no-evaluate-javascript.sh
    ```
  </action>
  <verify>
    <automated>chmod +x scripts/check-bus-protocol-version.sh scripts/check-no-evaluate-javascript.sh scripts/check-bus-harness-parity.sh scripts/test-check-bus-protocol-version.sh scripts/test-check-no-evaluate-javascript.sh && bash scripts/check-bus-protocol-version.sh && bash scripts/check-no-evaluate-javascript.sh && bash scripts/check-bus-harness-parity.sh && bash scripts/test-check-bus-protocol-version.sh && bash scripts/test-check-no-evaluate-javascript.sh</automated>
  </verify>
  <done>
    All three production check scripts exit 0 when run against the real repo (Plans 01+02+03 are green).
    `scripts/test-check-bus-protocol-version.sh` confirms the version checker refuses the v2.0.0/v1.9.0 mismatch fixture with a message naming both versions.
    `scripts/test-check-no-evaluate-javascript.sh` confirms the JS-lint checker refuses `bad.swift` and does NOT flag `good.swift`.
    All scripts have mode 0755 — `ls -l scripts/check-*.sh scripts/test-check-*.sh` shows `-rwxr-xr-x`.
  </done>
</task>

<task type="auto">
  <name>Task 2: Wire the three checks as Xcode pre-build phases in project.yml</name>
  <files>
    project.yml
  </files>
  <action>
    **Decisions honored:** Pre-build phase (not post-build) per SEC-09 +
    RESEARCH §Open Question "Tertiary". Use xcodegen `preBuildScripts` key
    (runs before Compile Sources — confirmed by xcodegen emission patterns).

    **1. Edit `project.yml`** — under `targets.Jarvis`, ADD a `preBuildScripts:`
    list (peer of the existing `postBuildScripts:`). Place it IMMEDIATELY after
    `dependencies:` (if present in Plan 03's update) or after `copyFiles:` —
    whichever is the last block before `postBuildScripts:`.

    The three entries, in order (fastest-failing check first so we fail fast
    on the most common authoring errors):
    ```yaml
        preBuildScripts:
          - name: Check bus-harness.html parity (canonical vs bundle)
            script: |
              "${SRCROOT}/scripts/check-bus-harness-parity.sh"
            runOnlyWhenInstalling: false
            basedOnDependencyAnalysis: false
            inputFiles:
              - $(SRCROOT)/webview/bus-harness.html
              - $(SRCROOT)/App/Resources/webview/bus-harness.html
          - name: Check bus protocol version (Swift/TS parity)
            script: |
              "${SRCROOT}/scripts/check-bus-protocol-version.sh"
            runOnlyWhenInstalling: false
            basedOnDependencyAnalysis: false
            inputFiles:
              - $(SRCROOT)/packages/Bus/Sources/Bus/Protocol.swift
              - $(SRCROOT)/webview/packages/bus/src/protocol.ts
          - name: Check no evaluateJavaScript calls (HUD-04)
            script: |
              "${SRCROOT}/scripts/check-no-evaluate-javascript.sh"
            runOnlyWhenInstalling: false
            basedOnDependencyAnalysis: false
    ```

    `inputFiles` on the first two scripts hints Xcode when to rerun them —
    only when one of the named files changes. The third (`evaluateJavaScript`
    check) doesn't use `inputFiles` because it scans the whole codebase;
    `basedOnDependencyAnalysis: false` forces it to run on every build.

    **2. Regenerate the Xcode project:**
    ```bash
    xcodegen generate
    ```

    Apply the P1 PBXCopyFilesBuildPhase re-insertion dance if xcodegen strips
    the empty copyFiles phase per 01-03 / 01-04 SUMMARY pattern (this plan's
    change to project.yml doesn't remove the copyFiles phase, but xcodegen
    regeneration has historically stripped it regardless).

    **3. Manual verification that the generated pbxproj puts these scripts
    BEFORE Compile Sources:**

    Read the generated `Jarvis.xcodeproj/project.pbxproj` and locate the
    `PBXNativeTarget` for `Jarvis`. Its `buildPhases` array must list the
    three `PBXShellScriptBuildPhase` IDs for our three checks BEFORE the
    `PBXSourcesBuildPhase` ID. If xcodegen emits them post-compile, the
    build-break is useless for constants already embedded in compiled code.

    Quick grep check:
    ```bash
    grep -c 'Check bus protocol version' Jarvis.xcodeproj/project.pbxproj
    ```
    Should be ≥ 2 (once in the phase definition, once in the buildPhases
    list referencing it).

    More thorough check — extract the buildPhases order:
    ```bash
    awk '/isa = PBXNativeTarget;.*Jarvis/,/\};/' Jarvis.xcodeproj/project.pbxproj \
        | grep -E '(buildPhases|Sources|Check bus|Check no evaluate|Check bus-harness)'
    ```
    The three "Check" entries must appear in the buildPhases list at
    positions BEFORE the `Sources` (compile) entry.

    **4. Verify build-time behavior end-to-end:**
    ```bash
    xcodebuild -project Jarvis.xcodeproj -scheme Jarvis clean build \
        -destination 'platform=macOS' -configuration Debug 2>&1 | tee /tmp/build.log | tail -40
    ```

    Expect to see in the output BEFORE any `CompileSwift` lines:
    - `Check bus-harness.html parity (canonical vs bundle)` → `bus-harness.html parity OK`
    - `Check bus protocol version (Swift/TS parity)` → `bus parity OK at v2.0.0`
    - `Check no evaluateJavaScript calls (HUD-04)` → `no evaluateJavaScript calls — HUD-04 OK`

    Followed by the existing post-build chain:
    - `Create Contents/Helpers directory`
    - `Verify entitlements (pre-codesign)`
    - `Codesign bundle (deepest-first)`
    - `Verify entitlements (post-codesign)`
    - `Verify codesign settings (pbxproj lint)`

    **5. Negative-path verification (optional, run once and revert):**
    Deliberately introduce a mismatch to prove the build breaks:
    - Edit `webview/packages/bus/src/protocol.ts` to `BUS_PROTOCOL_VERSION = "1.9.0"`
    - Run `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis build` — must fail at the protocol-version check with a message naming both `2.0.0` and `1.9.0`.
    - Revert the change.

    Do the same for a deliberate `evaluateJavaScript` insertion in a non-test
    file — build must fail at the HUD-04 check. Revert.

    This negative-path verification is a one-shot smoke test — not something
    the automated verify-step exercises (it's destructive to the tree). Run
    manually at the end of execution to confirm the build-breaker actually breaks.
  </action>
  <verify>
    <automated>xcodegen generate && grep -c 'Check bus protocol version' Jarvis.xcodeproj/project.pbxproj && xcodebuild -project Jarvis.xcodeproj -scheme Jarvis build -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E '(Check bus|bus parity|no evaluateJavaScript|bus-harness\.html parity|Compile Swift)' | head -20</automated>
  </verify>
  <done>
    `project.yml` declares `preBuildScripts` on the `Jarvis` target with the three check scripts in the order: harness-parity → protocol-version → no-evaluate-javascript.
    `xcodegen generate` produces a `project.pbxproj` where the three shell-script phases appear in the `buildPhases` list BEFORE the `PBXSourcesBuildPhase` ID for the Jarvis target.
    `xcodebuild -scheme Jarvis build` prints the three "OK" messages and then compiles Swift — in that order.
    Negative-path manual smoke confirmed (once): deliberate mismatch triggers build failure; revert.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Canonical source ↔ bundle copy | `webview/bus-harness.html` (authored) vs `App/Resources/webview/bus-harness.html` (shipped). Drift = shipping stale content. |
| Swift constant ↔ TS constant | `BUS_PROTOCOL_VERSION` must match across the bridge; drift = runtime handshake failure. |
| Allowed WebKit API ↔ forbidden WebKit API | `callAsyncJavaScript` (safe) vs `evaluateJavaScript` (XSS foothold). One build-time regression = one shipped XSS surface. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-02-20 | Tampering | Developer pushes PR that bumps Swift `BUS_PROTOCOL_VERSION` but forgets TS | mitigate | `check-bus-protocol-version.sh` as pre-build phase — build fails locally AND in any CI that runs `xcodebuild`. |
| T-02-21 | Tampering | Developer adds a `BusOutbound` case without a fixture JSON | mitigate | Fixture-directory `diff -r` fails when the fixture sets are out of sync. (Also caught by Plan 01's round-trip tests at `swift test` time.) |
| T-02-22 | Elevation of Privilege | Developer copy-pastes `evaluateJavaScript` into a non-bus file, introducing XSS | mitigate | `check-no-evaluate-javascript.sh` greps App/ + packages/ on every build; test-harness smoke proves it catches `bad.swift`. |
| T-02-23 | Information Disclosure | Developer edits the canonical harness but forgets to re-copy to bundle | mitigate | `check-bus-harness-parity.sh` fails the build on any diff. |
| T-02-24 | Denial of Service | Check scripts flake on arbitrary CI / dev-machine | accept | Scripts use POSIX `bash`, `grep -E`, `sed -E`, `diff -r` — all baseline tools. `set -euo pipefail` makes unexpected failures loud. Budget: <200ms per check on a warm machine. |
| T-02-25 | Tampering | Attacker with local edit access bypasses the lint by editing the script | accept | Single-user personal project; local-access trust model. Commit signatures + branch protection are the external controls if ever needed. |
</threat_model>

<verification>
**Script correctness:**
- `bash scripts/check-bus-protocol-version.sh` → exits 0, prints `bus parity OK at v2.0.0`.
- `bash scripts/check-no-evaluate-javascript.sh` → exits 0, prints `no evaluateJavaScript calls — HUD-04 OK`.
- `bash scripts/check-bus-harness-parity.sh` → exits 0, prints `bus-harness.html parity OK`.

**Test-harness correctness (proves the scripts actually refuse bad inputs):**
- `bash scripts/test-check-bus-protocol-version.sh` → exits 0 (meaning: the checker correctly exited non-zero on the mismatch fixture; the test asserts that).
- `bash scripts/test-check-no-evaluate-javascript.sh` → exits 0 (checker flagged `bad.swift` but not `good.swift`).

**Xcode wiring:**
- `xcodegen generate && grep -c 'Check bus protocol version' Jarvis.xcodeproj/project.pbxproj` → ≥ 2.
- `xcodebuild -scheme Jarvis build` output includes all three `OK` messages before any `CompileSwift` line.

**Negative-path manual smoke (one-shot, revert after):**
- Bump the TS constant to `1.9.0`; `xcodebuild build` fails at check-bus-protocol-version with "BUS_PROTOCOL_VERSION mismatch". Revert.
- Add a spurious `evaluateJavaScript` to any non-test `App/` file; build fails at check-no-evaluate-javascript. Revert.
</verification>

<success_criteria>
1. Three pre-build check scripts exist, are executable (`chmod +x`), and each emit a clear "OK" message on success.
2. Two test-harness scripts exist and pass — proving the checkers correctly refuse deliberately-bad fixtures.
3. Two test-fixture directories exist under `scripts/test-fixtures/`: `bus-mismatch/` (Swift v2.0.0 vs TS v1.9.0) and `bus-evaluate-js/` (bad.swift + good.swift control).
4. `project.yml` declares `preBuildScripts:` on the `Jarvis` target with the three checks.
5. `xcodegen generate` regenerates `Jarvis.xcodeproj/project.pbxproj` with the three PBXShellScriptBuildPhase entries appearing in the target's `buildPhases` BEFORE the `PBXSourcesBuildPhase`.
6. `xcodebuild -scheme Jarvis build` succeeds on a clean state and prints the three OK messages before Swift compile.
7. Negative-path smoke confirms: mismatch of Swift/TS `BUS_PROTOCOL_VERSION` breaks the build; an `evaluateJavaScript` insertion in `App/` or `packages/` (outside tests) breaks the build; canonical/bundle harness drift breaks the build.
8. No changes to `App/`, `packages/Bus/`, or `webview/packages/bus/` source — this plan is strictly additive to `scripts/` + `project.yml` (save for the xcodegen-regenerated `project.pbxproj`).
</success_criteria>

<output>
After completion, create `.planning/phases/02-bus/02-04-SUMMARY.md` covering:
- Files created: 3 production check scripts, 2 test-harness scripts, 2 fixture directories (6 fixture files total)
- Files modified: `project.yml` (added `preBuildScripts:` block on Jarvis target), `Jarvis.xcodeproj/project.pbxproj` (xcodegen regenerated)
- Key decisions:
  - All three checks as pre-build phases (not post-build) so constant drift is caught before `swiftc` embeds a stale value
  - Harness-parity check first, protocol-version second, evaluateJavaScript-lint third — ordered fastest-failing first
  - Test fixtures live under `scripts/test-fixtures/` and are excluded from the production lint scan via `case */test-fixtures/*`
  - Test harness for `check-no-evaluate-javascript.sh` copies the fixture to a temp directory so the `*/test-fixtures/*` skip doesn't no-op the test
  - Round-trip test runs deferred from the pre-build phase — runs as part of `swift test` / `pnpm test` to keep incremental builds fast
- Patterns established:
  - Build-breaking check-script pattern: `set -euo pipefail` + env-overridable defaults + test-harness + fixture directory
  - Test-harness-drives-production-script pattern (reused from P1's `test-verify-entitlements.sh`)
  - `inputFiles` hints on pre-build scripts so Xcode skips redundant runs
- Requirements completed:
  - HUD-04 (build-time lint-enforced forbidden-API check — matches ROADMAP success criterion 1 verbatim: "no `evaluateJavaScript` string interpolation exists in the codebase (lint-enforced)")
  - SEC-09 (pre-build parity script: grep-constant + diff-fixtures — matches ROADMAP success criterion 3 verbatim)
- Handoff to P3+: every new `BusOutbound` case in future phases must (a) add a Swift fixture, (b) add a TS fixture (byte-identical), (c) if wire format changes, bump `BUS_PROTOCOL_VERSION` on BOTH sides — or the pre-build phase fails the build.
- Phase 2 complete: all 5 REQs (HUD-03/04/05/06/SEC-09) covered across 4 plans; bus is runtime-armed AND build-hardened.
</output>
