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
# Expected env (from Xcode) in --pre/--post-codesign modes:
#   BUILT_PRODUCTS_DIR, WRAPPER_NAME, SRCROOT
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
# FORBIDDEN entitlements on the MAIN app (moved to helpers in P5; hardening regression).
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

    # Per-helper entitlement checks: only mcp-applescript may carry automation.apple-events.
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

  *)
    echo "usage: $0 --pre-codesign|--post-codesign|--verify-fixture <plist>" >&2
    exit 1
    ;;
esac
