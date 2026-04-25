#!/bin/bash
# verify-entitlements.sh — two-phase entitlement verification + JarvisEntitlementsVerified flag writer.
#
# Modes:
#   --pre-codesign     Reads source App/Jarvis.entitlements + not-yet-signed Info.plist.
#                      If both satisfy the MAIN_REQUIRED + MAIN_FORBIDDEN lists and carry
#                      the required Info.plist usage keys, writes
#                      JarvisEntitlementsVerified=YES into the unsigned Info.plist so the
#                      flag becomes part of the signed content (RESEARCH Open Q #8 correction
#                      — writing after codesign invalidates the signature).
#
#   --post-codesign    Reads the signed entitlements via `codesign -d --entitlements -`,
#                      greps for MAIN_REQUIRED + MAIN_FORBIDDEN + per-helper rules.
#                      NEVER writes. Strips plist XML comments before grep to defend
#                      against the self-invalidating-grep footgun.
#
#   --verify-fixture <plist>
#                      Used by scripts/test-verify-entitlements.sh. Runs the source-entitlements
#                      check against the named fixture file so the harness can fault-inject.
#
#   --verify-helper-fixture <plist> <helper-name>
#                      Plan 05-03 fault-injection mode: treats <plist> as if it were the result
#                      of `codesign -d --entitlements - --xml` for the named helper, runs the
#                      per-helper required/forbidden rules. Lets the test harness exercise
#                      every branch of `check_helper_entitlements_xml` without needing a real
#                      signed bundle.
#
# Expected env (from Xcode) in --pre/--post-codesign modes:
#   BUILT_PRODUCTS_DIR, WRAPPER_NAME, SRCROOT
set -euo pipefail

MODE="${1:-}"
APP="${BUILT_PRODUCTS_DIR:-}/${WRAPPER_NAME:-}"
INFO_PLIST="${APP}/Contents/Info.plist"

# Debug vs Release entitlement split (added 2026-04-23 to fix AMFI rejection on ad-hoc
# signed Debug bundles carrying the managed `speech-recognition-assets` entitlement —
# RunningBoard error 5 / launchd spawn failure on `xcodebuild test`).
#   Debug:   Jarvis.Debug.entitlements   — no speech-recognition-assets; includes get-task-allow (XCTest attach)
#   Release: Jarvis.Release.entitlements — full managed entitlement set as shipping wants
# Falls back to the historical Jarvis.entitlements path for harness calls outside a Xcode build context.
CONFIGURATION="${CONFIGURATION:-}"
if [ "$CONFIGURATION" = "Debug" ]; then
  MAIN_ENT_SOURCE="${SRCROOT:-}/App/Jarvis.Debug.entitlements"
elif [ "$CONFIGURATION" = "Release" ]; then
  MAIN_ENT_SOURCE="${SRCROOT:-}/App/Jarvis.Release.entitlements"
elif [ -f "${SRCROOT:-}/App/Jarvis.entitlements" ]; then
  MAIN_ENT_SOURCE="${SRCROOT:-}/App/Jarvis.entitlements"
else
  MAIN_ENT_SOURCE="${SRCROOT:-}/App/Jarvis.Release.entitlements"
fi

# Required entitlements on the MAIN app (Release — shipping posture).
# Debug intentionally excludes `speech-recognition-assets` because AMFI rejects
# ad-hoc signed bundles carrying managed entitlements.
MAIN_REQUIRED_RELEASE=(
  "com.apple.security.cs.allow-jit"
  "com.apple.developer.speech-recognition-assets"
  "com.apple.security.device.audio-input"
)
MAIN_REQUIRED_DEBUG=(
  "com.apple.security.cs.allow-jit"
  "com.apple.security.device.audio-input"
  "com.apple.security.get-task-allow"
)
if [ "$CONFIGURATION" = "Debug" ]; then
  MAIN_REQUIRED=("${MAIN_REQUIRED_DEBUG[@]}")
else
  MAIN_REQUIRED=("${MAIN_REQUIRED_RELEASE[@]}")
fi

# FORBIDDEN entitlements on the MAIN app (moved to helpers in P5; hardening regression).
# Debug MUST NOT carry `speech-recognition-assets` — that's a Release-only entitlement.
MAIN_FORBIDDEN_BASE=(
  "com.apple.security.automation.apple-events"
  "com.apple.security.cs.allow-unsigned-executable-memory"
)
if [ "$CONFIGURATION" = "Debug" ]; then
  MAIN_FORBIDDEN=("${MAIN_FORBIDDEN_BASE[@]}" "com.apple.developer.speech-recognition-assets")
else
  MAIN_FORBIDDEN=("${MAIN_FORBIDDEN_BASE[@]}" "com.apple.security.get-task-allow")
fi

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

# Plan 05-03: per-helper bidirectional entitlement rules.
#
# Drives off two arrays per helper name — required (must be present) and
# forbidden (must NOT be present). The post-codesign walker reads each
# helper's signed entitlements via `codesign -d --entitlements -` and pipes
# them through this function; the fault-injection harness pipes a fixture
# file through it instead.
#
# Adding a new helper: extend the case block below. There is intentionally no
# wildcard / default-allow branch — an unknown helper name is a build failure
# so authoring drift can't smuggle in an entitlement set the verifier doesn't
# know about.
check_helper_entitlements_xml() {
  local helper_name="$1"
  local xml_stripped="$2"   # already stripped of XML comments by caller

  local required=()
  local forbidden=()

  case "$helper_name" in
    mcp-applescript)
      required=("com.apple.security.automation.apple-events")
      forbidden=(
        "com.apple.security.cs.allow-jit"
        "com.apple.developer.speech-recognition-assets"
        "com.apple.security.device.audio-input"
        "com.apple.security.cs.allow-unsigned-executable-memory"
      )
      ;;
    mcp-time|mcp-clipboard)
      required=()
      forbidden=(
        "com.apple.security.automation.apple-events"
        "com.apple.developer.speech-recognition-assets"
        "com.apple.security.cs.allow-jit"
        "com.apple.security.device.audio-input"
        "com.apple.security.cs.allow-unsigned-executable-memory"
      )
      ;;
    *)
      echo "error: unknown helper '$helper_name' — extend check_helper_entitlements_xml in verify-entitlements.sh" >&2
      return 1
      ;;
  esac

  # `${array[@]}` on an EMPTY array under `set -u` (bash 3.2 / macOS default)
  # raises "unbound variable". Guard with `${#array[@]}` so empty required /
  # forbidden lists are valid (mcp-time/clipboard have no required keys).
  if [ "${#required[@]}" -gt 0 ]; then
    for key in "${required[@]}"; do
      if ! echo "$xml_stripped" | /usr/bin/grep -q "<key>$key</key>"; then
        echo "error: helper '$helper_name' MISSING required entitlement: $key" >&2
        return 1
      fi
    done
  fi
  if [ "${#forbidden[@]}" -gt 0 ]; then
    for key in "${forbidden[@]}"; do
      if echo "$xml_stripped" | /usr/bin/grep -q "<key>$key</key>"; then
        echo "error: helper '$helper_name' carries FORBIDDEN entitlement: $key" >&2
        return 1
      fi
    done
  fi
  return 0
}

case "$MODE" in
  --pre-codesign)
    # Read source Jarvis.entitlements + not-yet-signed Info.plist.
    # If both OK, write JarvisEntitlementsVerified=YES to the Info.plist in the unsigned bundle.
    echo "verify-entitlements.sh: --pre-codesign"
    check_source_entitlements "$MAIN_ENT_SOURCE" || exit 1
    check_info_plist_keys "$INFO_PLIST" || exit 1
    /usr/bin/plutil -replace JarvisEntitlementsVerified -bool YES "$INFO_PLIST"
    echo "pre-codesign: JarvisEntitlementsVerified=YES written to $INFO_PLIST"
    ;;

  --post-codesign)
    # Read signed entitlements via `codesign -d --entitlements - --xml`.
    # The --xml flag forces the legacy XML plist output; without it macOS 26's codesign
    # emits a `[Dict] [Key] ...` rich-text dump that the XML grep below does not match.
    echo "verify-entitlements.sh: --post-codesign"
    # WR-12: previously this line was `codesign … 2>&1 || true`, which merged
    # stderr into stdout AND swallowed the exit code. A codesign failure
    # (binary not signed, corrupted bundle, etc.) would produce error text
    # that the greps might coincidentally pass. Split streams and check
    # the exit status explicitly.
    if ! EXTRACTED="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/tmp/codesign-main.err)"; then
      echo "error: codesign -d failed on $APP" >&2
      cat /tmp/codesign-main.err >&2 || true
      rm -f /tmp/codesign-main.err
      exit 1
    fi
    rm -f /tmp/codesign-main.err

    # Strip XML comments to avoid self-invalidating grep (a prose <!-- com.apple.security.cs.allow-jit -->
    # comment would satisfy a naive grep even if the actual entitlement is absent).
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

    # Per-helper bidirectional entitlement rules (Plan 05-03).
    # Each helper's signed entitlements are checked against required +
    # forbidden lists in `check_helper_entitlements_xml`. mcp-applescript
    # MUST carry automation.apple-events; no other helper may.
    #
    # WR-12: `-depth` (bottom-up) was inherited from the codesign script where
    # deepest-first matters for signing. Verification order doesn't matter;
    # drop `-depth` for readability.
    HELPERS_DIR="${APP}/Contents/Helpers"
    if [ -d "$HELPERS_DIR" ]; then
      while IFS= read -r HELPER; do
        HELPER_NAME="$(basename "$HELPER" .app)"
        # WR-12: check codesign's exit code explicitly — an unsigned or
        # corrupted helper previously emitted error text into HELPER_ENTS
        # that the grep could coincidentally pass, letting an unsigned helper
        # ship.
        if ! HELPER_ENTS="$(/usr/bin/codesign -d --entitlements - --xml "$HELPER" 2>/tmp/codesign-helper.err)"; then
          echo "error: codesign -d failed on helper $HELPER_NAME" >&2
          cat /tmp/codesign-helper.err >&2 || true
          rm -f /tmp/codesign-helper.err
          exit 1
        fi
        rm -f /tmp/codesign-helper.err
        HELPER_ENTS_STRIPPED="$(echo "$HELPER_ENTS" | /usr/bin/grep -v '^<!--')"
        check_helper_entitlements_xml "$HELPER_NAME" "$HELPER_ENTS_STRIPPED" || exit 1
        echo "post-codesign: helper '$HELPER_NAME' entitlements OK"
      done < <(find "$HELPERS_DIR" -name "*.app" -type d)
    fi

    echo "post-codesign: entitlement verification passed"
    ;;

  --verify-fixture)
    # Used by test-verify-entitlements.sh self-test. $2=fixture plist path.
    FIXTURE="${2:-}"
    if [ -z "$FIXTURE" ]; then
      echo "usage: $0 --verify-fixture <plist>" >&2
      exit 2
    fi
    check_source_entitlements "$FIXTURE"
    ;;

  --verify-helper-fixture)
    # Plan 05-03 self-test mode: feed a plist file in for a named helper and
    # run check_helper_entitlements_xml against it. Mirrors what the post-
    # codesign walker would do if it had observed those signed entitlements.
    FIXTURE="${2:-}"
    HELPER_NAME="${3:-}"
    if [ -z "$FIXTURE" ] || [ -z "$HELPER_NAME" ]; then
      echo "usage: $0 --verify-helper-fixture <plist> <helper-name>" >&2
      exit 2
    fi
    if [ ! -f "$FIXTURE" ]; then
      echo "error: fixture plist missing: $FIXTURE" >&2
      exit 1
    fi
    FIXTURE_STRIPPED="$(/usr/bin/grep -v '^<!--' "$FIXTURE" | /usr/bin/grep -v '^[[:space:]]*<!--')"
    check_helper_entitlements_xml "$HELPER_NAME" "$FIXTURE_STRIPPED"
    ;;

  *)
    echo "usage: $0 --pre-codesign|--post-codesign|--verify-fixture <plist>|--verify-helper-fixture <plist> <helper-name>" >&2
    exit 1
    ;;
esac
