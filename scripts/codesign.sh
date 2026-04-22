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
