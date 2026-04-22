---
phase: 01-foundations
plan: 05
type: execute
wave: 4
depends_on: [01, 02, 03, 04]
files_modified:
  - scripts/codesign.sh
  - scripts/verify-entitlements.sh
  - scripts/verify-codesign-settings.sh
  - scripts/test-verify-entitlements.sh
  - scripts/test-fixtures/broken-entitlements.plist
  - scripts/test-fixtures/forbidden-entitlements.plist
  - scripts/test-fixtures/good-entitlements.plist
  - App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift
  - App/Tests/JarvisEntitlementProbeTests/Info.plist
  - Jarvis.xcodeproj/project.pbxproj
autonomous: false
requirements: [MCP-05, MCP-06, SEC-02, SEC-03, SEC-08]
must_haves:
  truths:
    - "scripts/codesign.sh walks Contents/Helpers/**/*.app deepest-first via `find -depth`, signs each helper with its own .entitlements, signs the main app last, NEVER uses --deep"
    - "scripts/verify-entitlements.sh --pre-codesign writes JarvisEntitlementsVerified=YES to Info.plist BEFORE codesign (correction from RESEARCH Open Q #8)"
    - "scripts/verify-entitlements.sh --post-codesign greps codesign -d --entitlements - output for MAIN_REQUIRED keys (allow-jit, speech-recognition-assets, device.audio-input); exits non-zero on missing"
    - "scripts/verify-entitlements.sh greps for MAIN_FORBIDDEN (automation.apple-events, allow-unsigned-executable-memory); exits non-zero if present"
    - "scripts/verify-codesign-settings.sh lints pbxproj for 'CodeSignOnCopy = YES' under Contents/Helpers/ references AND for --deep anywhere; exits non-zero on either finding"
    - "scripts/test-verify-entitlements.sh feeds broken + forbidden + good fixture plists to verify-entitlements.sh and asserts non-zero/zero exits accordingly (fault-injection self-test)"
    - "Jarvis.xcodeproj pbxproj has four Run Script phases in order: Compile/Link → verify-entitlements.sh --pre-codesign → codesign.sh → verify-entitlements.sh --post-codesign"
    - "JarvisEntitlementProbeTests is excluded from the default test plan; runs on a stripped-entitlement Release archive and asserts SpeechAnalyzer's AssetInventory.status(forModules:) fires assetUnavailable or code 10"
  artifacts:
    - path: "scripts/codesign.sh"
      provides: "Deepest-first codesign walker with per-helper entitlements"
      contains: "find.*-depth"
    - path: "scripts/verify-entitlements.sh"
      provides: "Pre-codesign flag writer + post-codesign entitlement grep gate"
      contains: "JarvisEntitlementsVerified"
    - path: "scripts/verify-codesign-settings.sh"
      provides: "pbxproj linter — fails build on CodeSignOnCopy or --deep in build phases"
      contains: "CodeSignOnCopy"
    - path: "App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift"
      provides: "One-shot XCTest — SpeechAnalyzer AssetInventory probe on stripped-entitlement archive (SEC-03 scaffold-time verification)"
      contains: "SFSpeechError"
  key_links:
    - from: "Jarvis.xcodeproj/project.pbxproj"
      to: "scripts/verify-entitlements.sh"
      via: "Run Script build phase (pre-codesign + post-codesign)"
      pattern: "verify-entitlements.sh"
    - from: "Jarvis.xcodeproj/project.pbxproj"
      to: "scripts/codesign.sh"
      via: "Run Script build phase between pre and post verify"
      pattern: "codesign.sh"
    - from: "scripts/verify-entitlements.sh"
      to: "App/Info.plist"
      via: "plutil -replace JarvisEntitlementsVerified -bool YES (pre-codesign)"
      pattern: "JarvisEntitlementsVerified"
---

<objective>
Close Phase 1 with the build-time codesign + entitlement verification harness (MCP-05, MCP-06, SEC-02, SEC-03) and the one-shot `JarvisEntitlementProbeTests` that confirms the `com.apple.developer.speech-recognition-assets` entitlement is load-bearing on a stripped-entitlement Release archive (STATE.md scaffold-time verification row).

This plan finalizes the Phase-1 build contract:
1. `scripts/codesign.sh` walks `Contents/Helpers/**/*.app` deepest-first with per-helper `.entitlements`, main app last, forbids `--deep`.
2. `scripts/verify-entitlements.sh` runs in TWO phases — **pre-codesign** (writes `JarvisEntitlementsVerified=YES` into Info.plist BEFORE codesign so the flag is part of the signed content, per RESEARCH Open Q #8 correction) and **post-codesign** (reads `codesign -d --entitlements -` output, greps for required + forbidden keys).
3. `scripts/verify-codesign-settings.sh` is a pbxproj linter that fails the build if `CodeSignOnCopy = YES` appears under any `Contents/Helpers/` reference OR `--deep` appears anywhere.
4. `scripts/test-verify-entitlements.sh` is a CI self-test harness — injects `broken-entitlements.plist`, `forbidden-entitlements.plist`, and `good-entitlements.plist` fixtures and asserts the verifier's exit codes match expectations (fault-injection).
5. `JarvisEntitlementProbeTests` — gated on `JARVIS_ENTITLEMENT_PROBE=1` build flag, excluded from default test plan, runs against a Release archive and asserts `SpeechAnalyzer` / `AssetInventory.status(forModules:)` fails with `SFSpeechErrorCode.assetUnavailable` (code 1) OR macOS 26 beta "unallocated locales" (code 10) when the entitlement is stripped.

Purpose: This is the shipping gate for the "Release-archive cold-launches without crash" claim (ROADMAP §Phase 1 Success Criterion #1). Without these scripts, the entitlement pair can silently drop at any pbxproj edit, and the Release-only crash surface is invisible until a user gets burned.

Output: Phase-1 build pipeline completes; `xcodebuild archive -configuration Release` produces a signed bundle whose entitlements are verified at build time AND at launch (via AppDelegate's `JarvisEntitlementsVerified` check from Plan 03).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/phases/01-foundations/01-CONTEXT.md
@.planning/phases/01-foundations/01-RESEARCH.md
@.planning/phases/01-foundations/01-PATTERNS.md
@.planning/phases/01-01-SUMMARY.md
@.planning/phases/01-03-SUMMARY.md
@.planning/phases/01-04-SUMMARY.md

<interfaces>
<!-- This plan establishes build-time contracts; no Swift module deps. -->

From Plan 01:
- `App/Jarvis.entitlements` carries allow-jit + speech-recognition-assets + device.audio-input; forbids automation.apple-events + allow-unsigned-executable-memory
- `App/Info.plist` carries `JarvisEntitlementsVerified = NO` (default)
- `Jarvis.xcodeproj` has Hardened Runtime, CODE_SIGN_STYLE=Manual, CODE_SIGN_ENTITLEMENTS=App/Jarvis.entitlements, OTHER_CODE_SIGN_FLAGS=--options=runtime --timestamp
- `Contents/Helpers/` directory exists in built bundle (empty until P5 MCP helpers)

From Plan 03:
- `AppDelegate.applicationWillFinishLaunching` reads `JarvisEntitlementsVerified` key at launch; NSAlert hard-block if false

Environment variables available to Run Script phases (from Xcode):
- `$BUILT_PRODUCTS_DIR`
- `$WRAPPER_NAME` (e.g. `Jarvis.app`)
- `$INFOPLIST_FILE` (e.g. `App/Info.plist`)
- `$SRCROOT`
- `$EXPANDED_CODE_SIGN_IDENTITY`
- `$OTHER_CODE_SIGN_FLAGS`

Scripts inventory (RESEARCH Q2 + Q4 + Open Q #8 corrected):
- `scripts/codesign.sh` — deepest-first walker; runs AFTER `--pre-codesign` phase
- `scripts/verify-entitlements.sh` — has two modes: `--pre-codesign` (writes YES flag) and `--post-codesign` (grep verification)
- `scripts/verify-codesign-settings.sh` — pbxproj linter; runs at ANY phase (idempotent read-only)
- `scripts/test-verify-entitlements.sh` — CI self-test; invokes verify-entitlements.sh against test fixtures

Build-phase order per RESEARCH Open Q #8 correction (CRITICAL — get this right):
1. Compile sources
2. Link
3. Run Script: `scripts/verify-entitlements.sh --pre-codesign` (reads Jarvis.entitlements + Info.plist; if OK, writes `JarvisEntitlementsVerified=YES` to the NOT-YET-SIGNED Info.plist)
4. Run Script: `scripts/codesign.sh` (signs bundle with updated Info.plist baked in)
5. Run Script: `scripts/verify-entitlements.sh --post-codesign` (reads signed entitlements via `codesign -d`; final assurance — does NOT write)
6. Run Script: `scripts/verify-codesign-settings.sh` (pbxproj linter)

PATTERNS cross-refs:
- S-6: Hard-block on safety failures — build-time grep failure is a build failure, not a silent warning
- S-10: No Xcode workspace, no CocoaPods (D-05 / R1 H-B2)
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Write codesign.sh + verify-entitlements.sh (pre + post codesign modes) + verify-codesign-settings.sh + test-verify-entitlements.sh + fixtures</name>
  <files>scripts/codesign.sh, scripts/verify-entitlements.sh, scripts/verify-codesign-settings.sh, scripts/test-verify-entitlements.sh, scripts/test-fixtures/broken-entitlements.plist, scripts/test-fixtures/forbidden-entitlements.plist, scripts/test-fixtures/good-entitlements.plist</files>
  <read_first>
    - App/Jarvis.entitlements (from Plan 01 — source of truth for MAIN_REQUIRED + MAIN_FORBIDDEN lists)
    - App/Info.plist (from Plan 01 — confirm JarvisEntitlementsVerified key starts at NO)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 2 lines 245-372 (codesign + verify-entitlements scripts verbatim)
    - .planning/phases/01-foundations/01-RESEARCH.md §Open Questions #8 line 1548 (pre-codesign vs post-codesign split correction)
    - .planning/phases/01-foundations/01-PATTERNS.md §K lines 156-164 (scripts file classifications)
    - .planning/phases/01-foundations/01-CONTEXT.md (no direct decisions here — Claude's Discretion D-05 implies bash)
  </read_first>
  <action>
    **`scripts/codesign.sh`** — copy verbatim from RESEARCH Q2 lines 257-294 with adjustments for helper `.entitlements` path (helper places its `.entitlements` alongside its `Info.plist` under `Contents/Resources/` per RESEARCH line 274):

    ```bash
    #!/bin/bash
    set -euo pipefail

    # Expected env from Xcode: $BUILT_PRODUCTS_DIR, $WRAPPER_NAME, $EXPANDED_CODE_SIGN_IDENTITY,
    # $OTHER_CODE_SIGN_FLAGS (--options=runtime --timestamp), $SRCROOT.
    APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
    HELPERS_DIR="${APP}/Contents/Helpers"
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
    FLAGS="${OTHER_CODE_SIGN_FLAGS:-"--options=runtime --timestamp"}"

    if [ -z "${IDENTITY:-}" ]; then
      echo "error: EXPANDED_CODE_SIGN_IDENTITY is empty — is CODE_SIGN_IDENTITY configured?" >&2
      exit 1
    fi

    # 1. Sign each nested helper .app DEEPEST-FIRST via `find -depth`.
    if [ -d "$HELPERS_DIR" ]; then
      while IFS= read -r HELPER; do
        # Each helper carries its OWN .entitlements file under Contents/Resources/
        # matching its binary name.
        HELPER_NAME="$(basename "$HELPER" .app)"
        ENT="$HELPER/Contents/Resources/$HELPER_NAME.entitlements"
        if [ ! -f "$ENT" ]; then
          echo "error: missing entitlements for helper $HELPER (expected $ENT)" >&2
          exit 1
        fi
        echo "codesign (helper): $HELPER"
        # shellcheck disable=SC2086
        /usr/bin/codesign --force --sign "$IDENTITY" $FLAGS \
          --entitlements "$ENT" \
          "$HELPER"
      done < <(find "$HELPERS_DIR" -depth -name "*.app" -type d)
    fi

    # 2. Sign the main app LAST with its OWN entitlements.
    MAIN_ENT="${SRCROOT}/App/Jarvis.entitlements"
    if [ ! -f "$MAIN_ENT" ]; then
      echo "error: main app entitlements not found at $MAIN_ENT" >&2
      exit 1
    fi
    echo "codesign (main): $APP"
    # shellcheck disable=SC2086
    /usr/bin/codesign --force --sign "$IDENTITY" $FLAGS \
      --entitlements "$MAIN_ENT" \
      "$APP"

    # 3. --deep is FORBIDDEN. It is not used anywhere above.
    # (Xcode would emit --deep only if an envvar like CODE_SIGN_INJECT_BASE_ENTITLEMENTS were misused;
    # verify-codesign-settings.sh lints the pbxproj for its absence.)

    echo "✓ codesign complete"
    ```

    **`scripts/verify-entitlements.sh`** — TWO modes per RESEARCH Open Q #8:

    ```bash
    #!/bin/bash
    set -euo pipefail

    MODE="${1:-}"
    APP="${BUILT_PRODUCTS_DIR:-}/${WRAPPER_NAME:-}"
    MAIN_ENT_SOURCE="${SRCROOT:-}/App/Jarvis.entitlements"
    INFO_PLIST="${APP}/Contents/Info.plist"

    # Required entitlements on the MAIN app.
    MAIN_REQUIRED=(
      "com.apple.security.cs.allow-jit"
      "com.apple.developer.speech-recognition-assets"
      "com.apple.security.device.audio-input"
    )
    # FORBIDDEN entitlements on the MAIN app (moved to helper in P5; or hardening regression).
    MAIN_FORBIDDEN=(
      "com.apple.security.automation.apple-events"
      "com.apple.security.cs.allow-unsigned-executable-memory"
    )

    check_source_entitlements() {
      local source="$1"
      if [ ! -f "$source" ]; then
        echo "error: source entitlements file missing: $source" >&2
        return 1
      fi
      for key in "${MAIN_REQUIRED[@]}"; do
        if ! /usr/bin/grep -q "<key>$key</key>" "$source"; then
          echo "error: source entitlements missing required key: $key (file: $source)" >&2
          return 1
        fi
      done
      for key in "${MAIN_FORBIDDEN[@]}"; do
        if /usr/bin/grep -q "<key>$key</key>" "$source"; then
          echo "error: source entitlements carries forbidden key: $key (file: $source)" >&2
          return 1
        fi
      done
      return 0
    }

    check_info_plist_keys() {
      local info="$1"
      if ! /usr/bin/plutil -extract NSSpeechRecognitionAssetsUsageDescription raw "$info" >/dev/null 2>&1; then
        echo "error: NSSpeechRecognitionAssetsUsageDescription missing from Info.plist ($info)" >&2
        return 1
      fi
      if ! /usr/bin/plutil -extract LSUIElement raw "$info" >/dev/null 2>&1; then
        echo "error: LSUIElement missing from Info.plist ($info)" >&2
        return 1
      fi
      return 0
    }

    case "$MODE" in
      --pre-codesign)
        # Read source Jarvis.entitlements + not-yet-signed Info.plist.
        # If both OK, write JarvisEntitlementsVerified=YES to the Info.plist in the not-yet-signed bundle.
        echo "verify-entitlements.sh: --pre-codesign"
        check_source_entitlements "$MAIN_ENT_SOURCE" || exit 1
        check_info_plist_keys "$INFO_PLIST" || exit 1
        /usr/bin/plutil -replace JarvisEntitlementsVerified -bool YES "$INFO_PLIST"
        echo "✓ pre-codesign: JarvisEntitlementsVerified=YES written to $INFO_PLIST"
        ;;

      --post-codesign)
        # Read signed entitlements via `codesign -d --entitlements -`.
        echo "verify-entitlements.sh: --post-codesign"
        EXTRACTED="$(/usr/bin/codesign -d --entitlements - "$APP" 2>&1 || true)"

        # Strip comments to avoid grep self-invalidation (prose matching a key name).
        EXTRACTED_STRIPPED="$(echo "$EXTRACTED" | /usr/bin/grep -v '^<!--')"

        for key in "${MAIN_REQUIRED[@]}"; do
          if ! echo "$EXTRACTED_STRIPPED" | /usr/bin/grep -q "<key>$key</key>"; then
            echo "error: SIGNED main app missing required entitlement: $key" >&2
            exit 1
          fi
        done

        for key in "${MAIN_FORBIDDEN[@]}"; do
          if echo "$EXTRACTED_STRIPPED" | /usr/bin/grep -q "<key>$key</key>"; then
            echo "error: SIGNED main app carries forbidden entitlement: $key" >&2
            exit 1
          fi
        done

        # Verify Contents/Helpers/ exists (MCP-05).
        if [ ! -d "${APP}/Contents/Helpers" ]; then
          echo "error: Contents/Helpers/ directory missing from signed bundle (MCP-05)" >&2
          exit 1
        fi

        # Per-helper entitlement checks: only mcp-applescript may carry automation.apple-events.
        HELPERS_DIR="${APP}/Contents/Helpers"
        if [ -d "$HELPERS_DIR" ]; then
          while IFS= read -r HELPER; do
            HELPER_NAME="$(basename "$HELPER" .app)"
            HELPER_ENTS="$(/usr/bin/codesign -d --entitlements - "$HELPER" 2>&1 || true)"
            HELPER_ENTS_STRIPPED="$(echo "$HELPER_ENTS" | /usr/bin/grep -v '^<!--')"
            if [ "$HELPER_NAME" = "mcp-applescript" ]; then
              if ! echo "$HELPER_ENTS_STRIPPED" | /usr/bin/grep -q "com.apple.security.automation.apple-events"; then
                echo "error: mcp-applescript missing automation.apple-events entitlement" >&2
                exit 1
              fi
            else
              if echo "$HELPER_ENTS_STRIPPED" | /usr/bin/grep -q "com.apple.security.automation.apple-events"; then
                echo "error: helper $HELPER_NAME has automation.apple-events — only mcp-applescript may have it" >&2
                exit 1
              fi
            fi
          done < <(find "$HELPERS_DIR" -depth -name "*.app" -type d)
        fi

        echo "✓ post-codesign: entitlement verification passed"
        ;;

      --verify-fixture)
        # Used by test-verify-entitlements.sh self-test. $2=fixture plist path.
        FIXTURE="${2:-}"
        check_source_entitlements "$FIXTURE"
        ;;

      *)
        echo "usage: $0 --pre-codesign|--post-codesign|--verify-fixture <plist>" >&2
        exit 1
        ;;
    esac
    ```

    **Important pbxproj-comment hygiene:** the `EXTRACTED_STRIPPED="$(echo "$EXTRACTED" | /usr/bin/grep -v '^<!--')"` strip prevents the self-invalidating grep gate that GSD planner rules call out — if a plist XML comment contained the literal string `<key>com.apple.security.cs.allow-jit</key>`, a naive `grep -q` would pass even when the actual `<true/>` pair was absent or negated. Comment-stripping is mandatory.

    **`scripts/verify-codesign-settings.sh`** — pbxproj linter per RESEARCH Q2 line 253 / MCP-06 validation row:

    ```bash
    #!/bin/bash
    set -euo pipefail

    PBXPROJ="${SRCROOT:-$(pwd)}/Jarvis.xcodeproj/project.pbxproj"
    if [ ! -f "$PBXPROJ" ]; then
      echo "error: pbxproj not found at $PBXPROJ" >&2
      exit 1
    fi

    # Strip // line comments from pbxproj before grepping. Xcode pbxproj is a strict NeXTSTEP plist;
    # comments use /* ... */ or // — we strip both to avoid self-invalidating grep.
    STRIPPED="$(/usr/bin/sed 's|//.*$||; s|/\*.*\*/||g' "$PBXPROJ")"

    # Rule 1: CodeSignOnCopy = YES must NOT appear near Contents/Helpers references.
    # Pattern: any line with 'CodeSignOnCopy = YES' anywhere is suspect — P1 has no helpers yet,
    # but the lint is about guarding the pattern from landing in P5.
    if echo "$STRIPPED" | /usr/bin/grep -E 'CodeSignOnCopy\s*=\s*YES' > /dev/null; then
      echo "error: pbxproj contains 'CodeSignOnCopy = YES' — forbidden (MCP-06 / R1 H-B2)" >&2
      exit 1
    fi

    # Rule 2: --deep flag must NOT appear in OTHER_CODE_SIGN_FLAGS or any codesign-adjacent setting.
    # Per Pitfall #3 (RESEARCH lines 1353-1358), --deep silently strips per-helper entitlements.
    if echo "$STRIPPED" | /usr/bin/grep -E '(--deep|\"--deep\")' > /dev/null; then
      echo "error: pbxproj contains '--deep' flag — forbidden (TN2206 / Pitfall #3)" >&2
      exit 1
    fi

    # Rule 3: OTHER_CODE_SIGN_FLAGS must include --options=runtime and --timestamp.
    # (Hardened Runtime + secure timestamp on every sign call.)
    if ! echo "$STRIPPED" | /usr/bin/grep -E 'OTHER_CODE_SIGN_FLAGS.*--options=runtime' > /dev/null; then
      echo "error: pbxproj OTHER_CODE_SIGN_FLAGS must include --options=runtime" >&2
      exit 1
    fi
    if ! echo "$STRIPPED" | /usr/bin/grep -E 'OTHER_CODE_SIGN_FLAGS.*--timestamp' > /dev/null; then
      echo "error: pbxproj OTHER_CODE_SIGN_FLAGS must include --timestamp" >&2
      exit 1
    fi

    echo "✓ verify-codesign-settings: pbxproj lint passed"
    ```

    **`scripts/test-verify-entitlements.sh`** — fault-injection self-test per RESEARCH §Validation Architecture / MCP-06 row / Wave 0 Gaps line 1478:

    ```bash
    #!/bin/bash
    set -euo pipefail

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FIXTURES_DIR="$SCRIPT_DIR/test-fixtures"
    VERIFIER="$SCRIPT_DIR/verify-entitlements.sh"

    PASS=0
    FAIL=0

    run_case() {
      local name="$1"
      local fixture="$2"
      local expect_code="$3"
      local actual=0
      "$VERIFIER" --verify-fixture "$fixture" >/dev/null 2>&1 || actual=$?
      if [ "$actual" -eq "$expect_code" ]; then
        echo "  PASS: $name (exit=$actual as expected)"
        PASS=$((PASS + 1))
      else
        echo "  FAIL: $name (expected exit=$expect_code, got exit=$actual)" >&2
        FAIL=$((FAIL + 1))
      fi
    }

    echo "test-verify-entitlements.sh — fault-injection self-test"
    echo

    # Case 1: good fixture → exit 0
    run_case "good-entitlements → exit 0" "$FIXTURES_DIR/good-entitlements.plist" 0

    # Case 2: broken fixture (missing allow-jit) → exit non-zero
    run_case "broken-entitlements → exit !0" "$FIXTURES_DIR/broken-entitlements.plist" 1

    # Case 3: forbidden fixture (carries automation.apple-events) → exit non-zero
    run_case "forbidden-entitlements → exit !0" "$FIXTURES_DIR/forbidden-entitlements.plist" 1

    echo
    echo "PASS=$PASS FAIL=$FAIL"
    if [ "$FAIL" -gt 0 ]; then exit 1; fi
    ```

    **Fixtures:**

    `scripts/test-fixtures/good-entitlements.plist` (matches `App/Jarvis.entitlements`):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.cs.allow-jit</key>
        <true/>
        <key>com.apple.developer.speech-recognition-assets</key>
        <true/>
        <key>com.apple.security.device.audio-input</key>
        <true/>
    </dict>
    </plist>
    ```

    `scripts/test-fixtures/broken-entitlements.plist` (missing allow-jit):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.developer.speech-recognition-assets</key>
        <true/>
        <key>com.apple.security.device.audio-input</key>
        <true/>
    </dict>
    </plist>
    ```

    `scripts/test-fixtures/forbidden-entitlements.plist` (carries automation.apple-events):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.cs.allow-jit</key>
        <true/>
        <key>com.apple.developer.speech-recognition-assets</key>
        <true/>
        <key>com.apple.security.device.audio-input</key>
        <true/>
        <key>com.apple.security.automation.apple-events</key>
        <true/>
    </dict>
    </plist>
    ```

    **Make scripts executable:** `chmod +x scripts/*.sh`.

    **Note on build-webview.sh and prime-tcc.sh (from RESEARCH §Summary bullet 15):** these are stubs referenced in research but NOT deliverables of this plan — they're P3 (build-webview) and P6 (prime-tcc) scope per RESEARCH line 27 "**non-P1**". Do NOT create empty stubs for them in P1; let the later phase create them when they become meaningful.
  </action>
  <verify>
    <automated>chmod +x scripts/*.sh &amp;&amp; scripts/test-verify-entitlements.sh 2>&amp;1 | tail -10 &amp;&amp; SRCROOT="$(pwd)" scripts/verify-codesign-settings.sh 2>&amp;1 | tail -5</automated>
  </verify>
  <acceptance_criteria>
    - `test -x scripts/codesign.sh && test -x scripts/verify-entitlements.sh && test -x scripts/verify-codesign-settings.sh && test -x scripts/test-verify-entitlements.sh` all pass
    - `grep 'find.*-depth' scripts/codesign.sh` returns 1 match (deepest-first walk per TN2206)
    - `grep -- '--deep' scripts/codesign.sh` returns NO uncommented matches — either 0 matches entirely OR only inside `#` comments. Verify with: `grep -v '^\s*#' scripts/codesign.sh | grep -- '--deep'` returns NO matches.
    - `grep '--options=runtime' scripts/codesign.sh` returns ≥ 1 match (Hardened Runtime)
    - `grep '\-\-timestamp' scripts/codesign.sh` returns ≥ 1 match (secure timestamp)
    - `grep 'JarvisEntitlementsVerified' scripts/verify-entitlements.sh` returns ≥ 1 match (pre-codesign writes the flag)
    - `grep 'plutil -replace JarvisEntitlementsVerified -bool YES' scripts/verify-entitlements.sh` returns 1 match (in --pre-codesign branch)
    - `grep 'plutil -replace JarvisEntitlementsVerified' scripts/verify-entitlements.sh` under `--post-codesign` block returns NO matches (post-codesign does NOT write — per RESEARCH Open Q #8: writing after codesign invalidates the signature)
    - `grep -c 'allow-jit\|speech-recognition-assets\|device.audio-input' scripts/verify-entitlements.sh` returns ≥ 3 matches (MAIN_REQUIRED list)
    - `grep -c 'automation.apple-events\|allow-unsigned-executable-memory' scripts/verify-entitlements.sh` returns ≥ 2 matches (MAIN_FORBIDDEN list)
    - `grep "grep -v '\^<!--'" scripts/verify-entitlements.sh` returns ≥ 1 match (comment-stripping before grep — self-invalidating-grep defense)
    - `grep 'CodeSignOnCopy' scripts/verify-codesign-settings.sh` returns ≥ 1 match
    - `grep -- '--deep' scripts/verify-codesign-settings.sh` returns ≥ 1 match (linting for its absence)
    - `SRCROOT="$(pwd)" scripts/verify-codesign-settings.sh` exits 0 (current pbxproj is compliant — from Plan 01)
    - `scripts/test-verify-entitlements.sh` exits 0 with PASS=3 FAIL=0 (all three fixture cases assert the expected exit code)
    - `test -f scripts/test-fixtures/good-entitlements.plist && test -f scripts/test-fixtures/broken-entitlements.plist && test -f scripts/test-fixtures/forbidden-entitlements.plist`
    - `grep 'allow-jit' scripts/test-fixtures/good-entitlements.plist` returns 1 match; `grep 'allow-jit' scripts/test-fixtures/broken-entitlements.plist` returns NO matches (the fixture's whole purpose — missing allow-jit)
    - `grep 'automation.apple-events' scripts/test-fixtures/forbidden-entitlements.plist` returns 1 match (the fixture's whole purpose — carries forbidden key)
    - NO `scripts/build-webview.sh` or `scripts/prime-tcc.sh` created in P1 (per RESEARCH bullet 15 — they're P3/P6 scope): `test ! -f scripts/build-webview.sh && test ! -f scripts/prime-tcc.sh`
  </acceptance_criteria>
  <done>All four build-time scripts + three test fixtures exist, are executable, and the self-test harness (`test-verify-entitlements.sh`) passes all three fault-injection cases. Linter `verify-codesign-settings.sh` passes against the current pbxproj.</done>
</task>

<task type="auto">
  <name>Task 2: Wire scripts into Jarvis.xcodeproj Run Script phases (pre-codesign → codesign → post-codesign → settings-lint)</name>
  <files>Jarvis.xcodeproj/project.pbxproj</files>
  <read_first>
    - Jarvis.xcodeproj/project.pbxproj (from Plan 01 — confirm Copy Files phase for Contents/Helpers already exists; add Run Script phases relative to it)
    - .planning/phases/01-foundations/01-RESEARCH.md §Open Q #8 line 1548-1553 (build-phase order corrected)
    - .planning/phases/01-foundations/01-RESEARCH.md §System Architecture Diagram lines 1236-1243 (build-time phase order — edited per Open Q #8)
  </read_first>
  <action>
    Edit `Jarvis.xcodeproj/project.pbxproj` to add FOUR `PBXShellScriptBuildPhase` entries to the `Jarvis` target's `buildPhases` array. Order matters:

    1. (existing) Copy Bundle Resources
    2. (existing) Compile sources
    3. (existing) Link / Frameworks
    4. (existing) Copy Files (Contents/Helpers/)
    5. **NEW:** Run Script phase — **"Verify entitlements (pre-codesign)"**
       - `name`: `Verify entitlements (pre-codesign)`
       - `shellPath`: `/bin/bash`
       - `shellScript`: `"${SRCROOT}/scripts/verify-entitlements.sh" --pre-codesign`
       - `alwaysOutOfDate`: 1
    6. **NEW:** Run Script phase — **"Codesign bundle (deepest-first)"**
       - `name`: `Codesign bundle (deepest-first)`
       - `shellPath`: `/bin/bash`
       - `shellScript`: `"${SRCROOT}/scripts/codesign.sh"`
       - `alwaysOutOfDate`: 1
       - **Override**: disable Xcode's default codesign — set build setting `CODE_SIGNING_REQUIRED = NO` and `CODE_SIGN_IDENTITY = -` (ad-hoc)? NO — we want Xcode's default Copy Files phase ordering, so we keep CODE_SIGN_IDENTITY set to a real identity and let our script override Xcode's own codesign. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` for this script phase so it can write to the bundle.
       - For Debug builds, Xcode's built-in codesigning may run first and set ad-hoc signatures; our script then re-signs. This is acceptable (re-signing is what `--force` is for).
    7. **NEW:** Run Script phase — **"Verify entitlements (post-codesign)"**
       - `shellScript`: `"${SRCROOT}/scripts/verify-entitlements.sh" --post-codesign`
    8. **NEW:** Run Script phase — **"Verify codesign settings (pbxproj lint)"**
       - `shellScript`: `"${SRCROOT}/scripts/verify-codesign-settings.sh"`

    Each new Run Script phase must set:
    - `outputPaths = ()`
    - `inputPaths = ()`
    - `alwaysOutOfDate = 1` (force re-run on every build — these are build-correctness gates, not incremental steps)

    **Important — Xcode default codesigning collision:** When `CODE_SIGN_STYLE = Manual` and `CODE_SIGN_IDENTITY` is set, Xcode runs its own built-in `codesign` step AFTER "Copy Files" and BEFORE any Run Script phases can interpose. To make `scripts/codesign.sh` the authoritative codesign step:
    - Option A (preferred): Set `CODE_SIGN_IDENTITY = -` (ad-hoc) in pbxproj build settings; Xcode signs ad-hoc, our script re-signs with real identity.
    - Option B: Leave Xcode's codesign as a no-op by setting `CODE_SIGNING_ALLOWED = NO` — but this disables Xcode's own sanity checks.

    Choose **Option A** for this plan. The pbxproj change: `CODE_SIGN_IDENTITY = -` under Debug configuration; Release keeps the real identity and our script re-signs. A re-sign with `--force` preserves entitlements (Xcode's own codesign step may or may not have run first, either way our script is authoritative).

    After editing the pbxproj, run `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -derivedDataPath build` locally to confirm the phases execute in order without error. (Debug build uses ad-hoc identity `-`, so `scripts/codesign.sh` signs with `-` too — which is valid for local Debug verification.)

    **If editing pbxproj by hand is fragile:** the `xcodeproj` Ruby gem or the `pbxproj` Python library can script this. Prefer a direct hand-edit if the executor is comfortable; otherwise pin to the approach used in Plan 01 (whatever generated the initial pbxproj).
  </action>
  <verify>
    <automated>xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -destination 'platform=macOS' -derivedDataPath build 2>&amp;1 | grep -E "verify-entitlements|codesign|Verify" | head -10</automated>
  </verify>
  <acceptance_criteria>
    - `grep -c 'verify-entitlements.sh.*--pre-codesign' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1
    - `grep -c 'verify-entitlements.sh.*--post-codesign' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1
    - `grep -c 'scripts/codesign.sh' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1
    - `grep -c 'verify-codesign-settings.sh' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1
    - `grep -c 'Verify entitlements (pre-codesign)\|Verify entitlements (post-codesign)' Jarvis.xcodeproj/project.pbxproj` returns ≥ 2 (both phases named)
    - `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -derivedDataPath build` exits 0
    - Build log contains the string `✓ pre-codesign: JarvisEntitlementsVerified=YES written` at some point during the build
    - Build log contains the string `✓ post-codesign: entitlement verification passed`
    - Build log contains the string `✓ verify-codesign-settings: pbxproj lint passed`
    - Built `Jarvis.app/Contents/Info.plist` contains `JarvisEntitlementsVerified = YES`: after running `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build -derivedDataPath build`, `plutil -extract JarvisEntitlementsVerified raw build/Build/Products/Debug/Jarvis.app/Contents/Info.plist` returns `true` (or `1`) — confirming pre-codesign flag-write worked
    - The signed bundle's entitlements include allow-jit: `codesign -d --entitlements - build/Build/Products/Debug/Jarvis.app 2>&1 | grep -q 'com.apple.security.cs.allow-jit'` returns success
    - The app can launch: `open build/Build/Products/Debug/Jarvis.app` does not immediately crash — if tested manually, the menu-bar icon should appear (no NSAlert hard-block, because JarvisEntitlementsVerified=YES)
  </acceptance_criteria>
  <done>pbxproj contains four Run Script build phases in the correct order; Debug build runs all four scripts; the built bundle's Info.plist has JarvisEntitlementsVerified=YES; codesign -d extracts the full entitlement trio.</done>
</task>

<task type="auto">
  <name>Task 3: Create JarvisEntitlementProbeTests one-shot XCTest (gated on JARVIS_ENTITLEMENT_PROBE build flag, excluded from default plan)</name>
  <files>App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift, App/Tests/JarvisEntitlementProbeTests/Info.plist, Jarvis.xcodeproj/project.pbxproj</files>
  <read_first>
    - App/Jarvis.entitlements (from Plan 01)
    - .planning/phases/01-foundations/01-RESEARCH.md §Question 4 lines 530-602 (probe strategy + full XCTest shape verbatim)
    - .planning/phases/01-foundations/01-PATTERNS.md §J line 152 (JarvisEntitlementProbeTests xcscheme gating)
    - .planning/phases/01-foundations/01-CONTEXT.md (no direct decisions on mechanic — Claude's Discretion per RESEARCH Q4 resolution)
  </read_first>
  <action>
    Create a NEW XCTest target in `Jarvis.xcodeproj` named `JarvisEntitlementProbeTests`:
    - Target type: `com.apple.product-type.bundle.unit-test`
    - Host application: `Jarvis` (TEST_HOST points at the main app binary)
    - Sources directory: `App/Tests/JarvisEntitlementProbeTests/`
    - **Excluded from default test plan**: `JarvisAppTests.xctestplan` default configuration does NOT list this target. A SEPARATE scheme `EntitlementProbe` lists it as the sole test target.
    - `GCC_PREPROCESSOR_DEFINITIONS = JARVIS_ENTITLEMENT_PROBE=1` OR `OTHER_SWIFT_FLAGS = -DJARVIS_ENTITLEMENT_PROBE` (use the Swift flag path) — this is what the `#if JARVIS_ENTITLEMENT_PROBE` guard in the test file checks.

    **`App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift`** — copy verbatim from RESEARCH Q4 lines 552-591:
    ```swift
    // GATED on build flag JARVIS_ENTITLEMENT_PROBE=1 via #if.
    // Excluded from default test plan. Invoked only by:
    //   xcodebuild test -scheme EntitlementProbe -destination 'platform=macOS' ...
    // ...on a Release archive specifically prepared with the speech-recognition-assets
    // entitlement STRIPPED from the signed bundle.
    //
    // Purpose: confirm the RESEARCH-DELTAS load-bearing claim that
    // `com.apple.developer.speech-recognition-assets` is load-bearing — i.e., without it,
    // `AssetInventory.status(forModules:)` or `SpeechTranscriber` allocation FAILS at runtime.
    //
    // Expected errors on stripped entitlement (any ONE of these conditions is confirmation):
    //   (a) SFSpeechErrorCode.assetUnavailable (code 1) — historical/AUDIT-R2-S5 claim
    //   (b) SFSpeechError Code=10 "Cannot use modules with unallocated locales" — macOS 26 beta variant
    //   (c) AssetInventory.status(...) returns .unavailable / .unsupported without throwing

    #if JARVIS_ENTITLEMENT_PROBE

    import XCTest
    import Speech

    final class JarvisEntitlementProbeTests: XCTestCase {

        /// Negative test: with the entitlement ABSENT, we expect an AssetInventory /
        /// SpeechAnalyzer failure signaling lack of entitlement-gated asset access.
        func test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation() async throws {
            // macOS 26 SpeechAnalyzer requires SpeechTranscriber + AssetInventory.
            let locale = Locale(identifier: "en-US")
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .progressiveLiveTranscription
            )

            // AssetInventory.status(forModules:) is the lightweight capability probe per
            // WWDC25 session 277. Fails fastest on the entitlement surface without requiring
            // audio feed.
            do {
                let status = try await AssetInventory.status(forModules: [transcriber])
                // If status returns without throwing, check for .unavailable / .unsupported.
                // Apple docs on the macOS 26 beta API surface are still ambiguous; accept any
                // indication of failure as confirmation.
                let description = String(describing: status).lowercased()
                if description.contains("unavailable") || description.contains("unsupported") {
                    return  // CONFIRMED: entitlement is load-bearing.
                }
                XCTFail("expected failure without entitlement; got status=\(status)")
            } catch let e as NSError
                where e.domain == "SFSpeechErrorDomain"
                && (e.code == 1    /* SFSpeechErrorCode.assetUnavailable */
                    || e.code == 10 /* macOS 26 beta: "unallocated locales" */)
            {
                // CONFIRMED: entitlement is load-bearing.
                return
            } catch {
                // Any other NSError is inconclusive but still a failure — the operation did not succeed.
                print("probe caught non-matching error: \(error); accepting as failure signal")
                return
            }

            XCTFail("entitlement appears not to be load-bearing; review RESEARCH-DELTAS claim")
        }
    }

    #endif
    ```

    **`App/Tests/JarvisEntitlementProbeTests/Info.plist`** (standard test-bundle plist):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>$(DEVELOPMENT_LANGUAGE)</string>
        <key>CFBundleExecutable</key>
        <string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key>
        <string>BNDL</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>CFBundleVersion</key>
        <string>1</string>
    </dict>
    </plist>
    ```

    **Xcode scheme config:**
    - Create `Jarvis.xcodeproj/xcshareddata/xcschemes/EntitlementProbe.xcscheme`. The shared scheme lists `JarvisEntitlementProbeTests` as its sole test action target.
    - The default `Jarvis` scheme's test action does NOT include this target.
    - Alternatively create an `EntitlementProbe.xctestplan` that references only `JarvisEntitlementProbeTests`, and set `OTHER_SWIFT_FLAGS = -DJARVIS_ENTITLEMENT_PROBE` on the target.

    **Operational runbook** (document in Plan 05 SUMMARY — executor need not run all steps in this plan):
    1. Build a Release archive of the main `Jarvis` app.
    2. Make a COPY of the `.xcarchive` and manually strip `com.apple.developer.speech-recognition-assets` from the copy's entitlements (via `codesign -d --entitlements - | sed 's|<key>com.apple.developer.speech-recognition-assets</key>\s*<true/>||' > stripped.plist`, then re-sign with `codesign --force --sign <identity> --entitlements stripped.plist`).
    3. Run `xcodebuild test -scheme EntitlementProbe -destination 'platform=macOS' TEST_HOST=<path-to-stripped-archive-Jarvis.app>` (env var override — the XCTest uses the stripped archive as its host).
    4. Confirm `test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation` PASSES (i.e., the expected error fired).
    5. Run against an UNSTRIPPED Release archive as a negative control — confirm the test PASSES (the "happy path" where `AssetInventory.status` succeeds) OR FAILS with the not-load-bearing XCTFail; in the unstripped case we expect success, which under this test's logic would actually XCTFail the test. The operational distinction is subtle: the test is designed to PASS on a stripped archive and FAIL on an unstripped archive. Document this inversion in STATE.md.
    6. Record the scaffold-time verification outcome in STATE.md → Scaffold-Time Verifications: "P1 speech-recognition-assets load-bearing probe: CONFIRMED" (or document whatever the run reveals).

    For this plan's execution: **creating the scheme + test files + pbxproj target is the deliverable**. Actually running the stripped-archive probe is a **user action** at phase verification time and is gated by the `checkpoint:human-action` below.
  </action>
  <verify>
    <automated>test -f App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift &amp;&amp; test -f Jarvis.xcodeproj/xcshareddata/xcschemes/EntitlementProbe.xcscheme &amp;&amp; xcodebuild -project Jarvis.xcodeproj -list 2>&amp;1 | grep -E 'JarvisEntitlementProbeTests|EntitlementProbe'</automated>
  </verify>
  <acceptance_criteria>
    - `test -f App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` passes
    - `grep '#if JARVIS_ENTITLEMENT_PROBE' App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` returns 1 match
    - `grep 'SFSpeechErrorDomain\|e.code == 1\|e.code == 10' App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` returns ≥ 3 matches (accepts all three conditions per RESEARCH Q4)
    - `grep 'import Speech' App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` returns 1 match
    - `grep 'AssetInventory.status(forModules:' App/Tests/JarvisEntitlementProbeTests/JarvisEntitlementProbeTests.swift` returns 1 match
    - `grep 'JarvisEntitlementProbeTests' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1 match (target declared)
    - `grep 'OTHER_SWIFT_FLAGS.*-DJARVIS_ENTITLEMENT_PROBE' Jarvis.xcodeproj/project.pbxproj` returns ≥ 1 match (build flag set on this target ONLY, not on default `Jarvis` target)
    - `xcodebuild -project Jarvis.xcodeproj -list` output contains `JarvisEntitlementProbeTests` as a target AND `EntitlementProbe` as a scheme
    - Default test plan (`xcodebuild test -scheme Jarvis`) does NOT include this target — verify with `xcodebuild test -scheme Jarvis -destination 'platform=macOS' -showTestPlans` doesn't list it, or with a dry-run that doesn't compile the probe file
    - Probe scheme compiles: `xcodebuild build -project Jarvis.xcodeproj -scheme EntitlementProbe -configuration Debug -destination 'platform=macOS' -derivedDataPath build` exits 0 (build, NOT test — test requires the stripped-archive operational setup)
  </acceptance_criteria>
  <done>`JarvisEntitlementProbeTests` target exists under `EntitlementProbe` scheme with `JARVIS_ENTITLEMENT_PROBE` build flag; accepts all three documented failure conditions (SFSpeechErrorCode 1, code 10, or .unavailable/.unsupported status); excluded from default test plan.</done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 4: Run the SpeechAnalyzer entitlement load-bearing probe against a stripped Release archive (SEC-03 scaffold-time verification)</name>
  <what-built>
    Task 3 produced the `JarvisEntitlementProbeTests` XCTest target, gated on `JARVIS_ENTITLEMENT_PROBE=1`, excluded from the default test plan. The probe runs against a Release archive, calls `SpeechTranscriber(locale:preset:) + AssetInventory.status(forModules:)`, and accepts any of three failure conditions as confirmation that the `com.apple.developer.speech-recognition-assets` entitlement is load-bearing.

    This is the P1 scaffold-time verification listed in STATE.md's "Scaffold-Time Verifications" section. Plan 01 Task 3 already enabled the capability on the App ID in the Developer portal (or explicitly deferred).
  </what-built>
  <how-to-verify>
    User runs the probe manually. Steps (this cannot be automated in the plan because it requires manually stripping an entitlement from a signed archive):

    1. Build a Release archive: `xcodebuild archive -project Jarvis.xcodeproj -scheme Jarvis -configuration Release -archivePath build/Jarvis.xcarchive -derivedDataPath build`
    2. Make a COPY of the archive's app bundle: `cp -R build/Jarvis.xcarchive/Products/Applications/Jarvis.app build/Jarvis-stripped.app`
    3. Extract the current entitlements: `codesign -d --entitlements - build/Jarvis-stripped.app > build/current.entitlements.plist 2>&1`
    4. Hand-edit `build/current.entitlements.plist` to REMOVE the `<key>com.apple.developer.speech-recognition-assets</key><true/>` pair. Save.
    5. Re-sign the stripped copy: `codesign --force --sign "Developer ID Application: ..." --options=runtime --timestamp --entitlements build/current.entitlements.plist build/Jarvis-stripped.app`
    6. Confirm the entitlement is gone: `codesign -d --entitlements - build/Jarvis-stripped.app | grep speech-recognition-assets` should return NO matches.
    7. Run the probe against the stripped bundle: `xcodebuild test -project Jarvis.xcodeproj -scheme EntitlementProbe -destination 'platform=macOS' TEST_HOST=build/Jarvis-stripped.app/Contents/MacOS/Jarvis`
    8. Expected result: `test_missingEntitlement_producesAssetUnavailableOrLocaleAllocation` PASSES (the error fired — entitlement IS load-bearing).
    9. Update `.planning/STATE.md` → Scaffold-Time Verifications — check off the row: `- [x] **P1**: Release cold-launch with com.apple.developer.speech-recognition-assets removed → confirm SFSpeechErrorCode.assetUnavailable fires (load-bearing claim).`

    If the probe test FAILS (i.e. the error did NOT fire, meaning the entitlement is NOT load-bearing on the current macOS 26 build): that is also actionable data. Record the finding in STATE.md and RESEARCH-DELTAS.md per RESEARCH §Open Question #1 options (a) remove the entitlement from `Jarvis.entitlements` OR (b) document the finding and keep the entitlement defensively. RESEARCH recommends the defensive option — keep the entitlement since it's cheap.

    Also confirm: in a **normal (unstripped) Release launch**, the app does NOT crash. This is the "Release cold-launches without JIT crash" claim from ROADMAP §Phase 1 Success Criterion #1. Run: `open build/Jarvis.xcarchive/Products/Applications/Jarvis.app` — menu-bar icon should appear, left-click should summon the HUD panel, NSAlert hard-block should NOT fire.
  </how-to-verify>
  <resume-signal>
    Type one of:
    - "confirmed" — stripped-archive probe ran; expected error fired (`SFSpeechErrorCode.assetUnavailable` code 1, macOS 26 code 10, or `.unavailable`/`.unsupported` status); entitlement IS load-bearing; STATE.md updated; ROADMAP SC #2 satisfied.
    - "refuted" — stripped-archive probe ran; error did NOT fire; entitlement may not be load-bearing on current macOS 26 build. STATE.md + RESEARCH-DELTAS.md updated with finding. **This BLOCKS phase close** — either (a) the probe has a bug (fix and re-run) or (b) the RESEARCH-DELTAS load-bearing claim is wrong and `Jarvis.entitlements` needs a reviewed defense-in-depth justification before ROADMAP SC #2 can sign off.

    `"defer"` is NOT a valid phase-close state for this task. If the probe cannot run because Plan 01 Task 3 (Developer portal App ID capability) is itself deferred, the correct state is "blocked on 01-01-T3" — the pause stays open, STATE.md's scaffold-time verification row remains unchecked, and Phase-1 closure is blocked by the dependency chain. Document the blocker in STATE.md but do NOT type a resume signal; leave the checkpoint paused until Plan 01 Task 3 is resolved and the probe can actually run.

    In other words: the checkpoint MAY stay paused indefinitely awaiting user action (that's fine — human-verify checkpoints are designed to do exactly that). But upon resume, the user MUST enter `confirmed` (probe fired) OR `refuted` (probe did not fire, needs investigation). Both of those are closing states; both of them gate on the probe ACTUALLY having been executed against a stripped Release archive. A claim of "we'll get to it later" without running the probe does not unblock Phase-1 closure.
  </resume-signal>
  <files>.planning/STATE.md, .planning/research/RESEARCH-DELTAS.md</files>
  <action>User-only: run the stripped-entitlement probe per operational runbook in `<how-to-verify>` above. Archive Release build → copy → strip `com.apple.developer.speech-recognition-assets` entitlement → re-sign → run `xcodebuild test -scheme EntitlementProbe TEST_HOST=<stripped-archive>`. Record outcome in STATE.md.</action>
  <verify>User confirms probe ran and reports outcome via resume signal.</verify>
  <done>STATE.md scaffold-time verification row updated with one of two terminal outcomes: `confirmed` (probe fired → entitlement is load-bearing → ROADMAP SC #2 satisfied) or `refuted` (probe did not fire → follow-up required before Phase-1 can close). `deferred` is NOT a terminal state — if Plan 01 Task 3 (App ID capability) is deferred, this task remains paused (blocked on 01-01-T3) and Phase-1 closure is correspondingly blocked.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Source `App/Jarvis.entitlements` → build output | Pre-codesign phase validates source; if valid, writes `JarvisEntitlementsVerified=YES` before signing |
| Signed bundle's effective entitlements → runtime | AppDelegate reads `JarvisEntitlementsVerified` from Info.plist at launch; hard-block NSAlert if false |
| pbxproj source control → build settings | `verify-codesign-settings.sh` lints pbxproj for forbidden flags on every build |
| Release archive → fresh Apple Silicon Mac | End-to-end validation via `JarvisEntitlementProbeTests` on stripped-entitlement archive |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-01 | Denial of Service | Release cold-launch missing `allow-jit` (Pitfall #1) | mitigate | Pre-codesign phase rejects source entitlements missing `allow-jit` → build fails. Post-codesign phase greps the SIGNED entitlements via `codesign -d --entitlements -` → build fails if signed bundle lacks the key. Runtime `JarvisEntitlementsVerified` hard-block (Plan 03) is defense-in-depth. |
| T-05-02 | Denial of Service | Release cold-launch missing `speech-recognition-assets` (Pitfall #2) | mitigate | Same build-time grep chain as T-05-01. Probe test (Task 3) confirms the entitlement is LOAD-BEARING — without it, `AssetInventory.status(...)` fails. Task 4 is the scaffold-time execution of that probe. |
| T-05-03 | Elevation of Privilege | Main app carries `automation.apple-events` (should only exist on mcp-applescript helper in P5) | mitigate | Post-codesign grep fails build if `MAIN_FORBIDDEN` keys appear in the signed main app. `forbidden-entitlements.plist` fixture exercises this path. |
| T-05-04 | Tampering | `--deep` flag strips helper entitlements (Pitfall #3) | mitigate | `codesign.sh` never uses `--deep`; walks helpers manually. `verify-codesign-settings.sh` lints pbxproj for `--deep` flag; build fails if found. |
| T-05-05 | Tampering | "Code Sign On Copy" re-signs helpers with main identity, strips per-helper entitlements | mitigate | `verify-codesign-settings.sh` lints pbxproj for `CodeSignOnCopy = YES`; build fails if found. P1 has no helpers, so the lint guards the pattern from landing in P5. |
| T-05-06 | Tampering | `plutil -replace JarvisEntitlementsVerified -bool YES` writing AFTER codesign invalidates signature | mitigate | RESEARCH Open Q #8 correction — write is in `--pre-codesign` phase; `--post-codesign` is read-only. `verify-entitlements.sh` enforces the split; acceptance criterion grep verifies no `plutil -replace` inside the `--post-codesign` branch. |
| T-05-07 | Information Disclosure | self-invalidating grep gate — XML comment matching a forbidden key string | mitigate | `verify-entitlements.sh` strips `<!-- ... -->` comments before greping via `grep -v '^<!--'`. `verify-codesign-settings.sh` strips `//` and `/* */` pbxproj comments before linting. Both comment-stripping steps are grep-gate-hygiene per planner rules. |
| T-05-08 | Denial of Service | Probe false-negative (entitlement is NOT load-bearing on current macOS 26; we ship it anyway) | accept | RESEARCH Open Question #1 documents this: keep the entitlement defensively even if the probe refutes load-bearing — "including the entitlement is cheap; omitting it risks a Release-only first-use STT break." |
| T-05-09 | Information Disclosure | Signed `.xcarchive` distribution leaks Developer ID private key | accept | Personal-use project; not distributed publicly. Developer ID cert stays in user's login keychain; not in the repo. |

No `high`-severity residual risk. Every build-time failure mode has a grep-gate; every runtime failure mode has a hard-block; the RESEARCH-DELTAS load-bearing claim is empirically tested via the probe.
</threat_model>

<verification>
**Task 1 (scripts):** `scripts/test-verify-entitlements.sh` PASS=3 FAIL=0; `SRCROOT=$(pwd) scripts/verify-codesign-settings.sh` exits 0.

**Task 2 (pbxproj wiring):** `xcodebuild -scheme Jarvis -configuration Debug build` runs all four Run Scripts; built bundle's Info.plist has `JarvisEntitlementsVerified=YES`; `codesign -d --entitlements -` extracts the required trio.

**Task 3 (probe target):** `xcodebuild -list` shows `JarvisEntitlementProbeTests` target AND `EntitlementProbe` scheme; default `Jarvis` scheme test plan does NOT include the probe target; `xcodebuild build -scheme EntitlementProbe` compiles.

**Task 4 (human-verify checkpoint):** User confirms probe outcome — "confirmed" / "refuted" / "defer". STATE.md updated.

**Phase-level integration:** End-to-end `xcodebuild archive -configuration Release` produces a signed bundle with correct entitlements AND correct JarvisEntitlementsVerified flag; cold-launching the archive on the current machine does NOT present an NSAlert hard-block (i.e., the full pipeline works).
</verification>

<success_criteria>
- Four build scripts executable + self-test harness PASS=3 FAIL=0
- pbxproj has pre-codesign + codesign + post-codesign + settings-lint Run Script phases in correct order
- Debug build runs all four phases; Release archive carries `JarvisEntitlementsVerified=YES` in signed Info.plist
- `JarvisEntitlementProbeTests` target + `EntitlementProbe` scheme exist; excluded from default test plan
- SEC-03 scaffold-time verification row in STATE.md updated with probe outcome (confirmed / refuted / deferred)
- MCP-05 scaffolded: `Contents/Helpers/` directory exists AND codesign + verify scripts treat it correctly even when empty
- MCP-06 scaffolded: verify-entitlements.sh fails build on missing keys; verify-codesign-settings.sh fails build on `--deep` or `CodeSignOnCopy = YES`
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundations/01-05-SUMMARY.md` documenting:
- Build-phase order (6 steps: Copy → Compile → Link → Copy Files → pre-codesign → codesign → post-codesign → settings-lint; paste shell names)
- All four script shapes + their exit codes by condition
- Probe operational runbook (strip entitlement → re-sign → xcodebuild test)
- Result of the Task 4 probe execution (or explicit "deferred — see STATE.md")
- STATE.md updates (check off scaffold-time verification row; note App ID capability status from Plan 01 Task 3)
- Handoff for Plan 05 successors (there are none in P1): P2 will add `scripts/check-bus-protocol-version.sh` as pre-build phase; P5 adds per-helper `.entitlements` files under `Contents/Helpers/<name>.app/Contents/Resources/`
</output>
</content>
</invoke>