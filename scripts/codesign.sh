#!/bin/bash
# codesign.sh — deepest-first walker for the Jarvis bundle.
#
# Signs every nested .app under Contents/Helpers/ with its own per-helper
# .entitlements first, then signs the main app last. Never uses --deep
# (TN2206 / Pitfall #3) — --deep re-signs nested bundles with the parent's
# entitlements and strips per-helper grants.
#
# Expected env from Xcode:
#   BUILT_PRODUCTS_DIR, WRAPPER_NAME, EXPANDED_CODE_SIGN_IDENTITY,
#   OTHER_CODE_SIGN_FLAGS, SRCROOT
set -euo pipefail

APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
HELPERS_DIR="${APP}/Contents/Helpers"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
FLAGS="${OTHER_CODE_SIGN_FLAGS:---options=runtime --timestamp}"

if [ -z "${IDENTITY:-}" ]; then
  echo "error: EXPANDED_CODE_SIGN_IDENTITY is empty — is CODE_SIGN_IDENTITY configured?" >&2
  exit 1
fi

# 1. Sign each nested helper .app DEEPEST-FIRST via `find -depth`.
#    Each helper carries its OWN .entitlements under Contents/Resources/
#    matching the helper's binary name (<HelperName>.app/Contents/Resources/<HelperName>.entitlements).
if [ -d "$HELPERS_DIR" ]; then
  while IFS= read -r HELPER; do
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

# 1b. Sign nested XCTest plugin bundles under Contents/PlugIns/ DEEPEST-FIRST.
#     XCTest bundles (e.g., JarvisEntitlementProbeTests.xctest) are signed without
#     entitlements — they ride on the main app's entitlement set via the test host,
#     and forcing entitlements on a .xctest breaks XCTest runtime loading. Signing
#     is still mandatory because codesign refuses to sign a container whose nested
#     bundles are unsigned.
#
#     Empty xctest directory shells appear in the bundle before Xcode has compiled
#     the test binary (the Run Script phases on the Jarvis target can run before
#     the dependent test target's compile step). Skip any xctest that lacks an
#     Info.plist or a MacOS/<binary> — those are pre-compile artifacts and will be
#     signed by a later build iteration once the binary is produced.
PLUGINS_DIR="${APP}/Contents/PlugIns"
if [ -d "$PLUGINS_DIR" ]; then
  while IFS= read -r PLUGIN; do
    PLUGIN_NAME="$(basename "$PLUGIN" .xctest)"
    PLUGIN_INFO="$PLUGIN/Contents/Info.plist"
    PLUGIN_BIN="$PLUGIN/Contents/MacOS/$PLUGIN_NAME"
    if [ ! -f "$PLUGIN_INFO" ] || [ ! -f "$PLUGIN_BIN" ]; then
      # Empty xctest directory shells can appear in BUILT_PRODUCTS_DIR before Xcode
      # has compiled the test binary (build-for-testing materializes the destination
      # path early so PBXCopyFilesBuildPhase has something to target). codesign on
      # the parent bundle refuses to sign a container with an unsigned empty
      # subdirectory. Remove the empty shell so the main-app sign succeeds; Xcode
      # re-creates + populates it in a later build iteration and the test-target's
      # own codesign step handles signing.
      echo "codesign (plugin removed — empty shell, not yet compiled): $PLUGIN"
      rm -rf "$PLUGIN"
      continue
    fi
    echo "codesign (plugin): $PLUGIN"
    # shellcheck disable=SC2086
    /usr/bin/codesign --force --sign "$IDENTITY" $FLAGS \
      "$PLUGIN"
  done < <(find "$PLUGINS_DIR" -depth -name "*.xctest" -type d)
fi

# 2. Sign the main app LAST with its own entitlements.
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

# Note: the -deep flag is intentionally absent — the nested-helpers walk above
# is how we enforce per-helper entitlements. verify-codesign-settings.sh lints
# the pbxproj for its absence as a belt-and-braces defense.

echo "codesign complete"
