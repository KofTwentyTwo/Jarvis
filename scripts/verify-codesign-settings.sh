#!/bin/bash
# verify-codesign-settings.sh — pbxproj linter for codesign hygiene.
#
# Fails the build if the pbxproj carries:
#   (1) CodeSignOnCopy = YES anywhere — Xcode's "Code Sign On Copy" re-signs
#       nested helpers with the parent target's identity, stripping per-helper
#       entitlements (MCP-06 / R1 H-B2).
#   (2) --deep anywhere in codesign-adjacent settings — TN2206 / Pitfall #3.
#   (3) OTHER_CODE_SIGN_FLAGS missing --options=runtime or --timestamp —
#       Hardened Runtime + secure timestamp must be on every sign call.
#
# Strips NeXTSTEP-plist comments (// and /* */) before grep so the linter is
# not self-invalidated by a comment that happens to mention a forbidden flag.
set -euo pipefail

PBXPROJ="${SRCROOT:-$(pwd)}/Jarvis.xcodeproj/project.pbxproj"
if [ ! -f "$PBXPROJ" ]; then
  echo "error: pbxproj not found at $PBXPROJ" >&2
  exit 1
fi

# Strip // line comments and /* ... */ block comments before grep.
STRIPPED="$(/usr/bin/sed 's|//.*$||; s|/\*.*\*/||g' "$PBXPROJ")"

# Rule 1: CodeSignOnCopy = YES must NOT appear anywhere in the pbxproj.
if echo "$STRIPPED" | /usr/bin/grep -E 'CodeSignOnCopy[[:space:]]*=[[:space:]]*YES' > /dev/null; then
  echo "error: pbxproj contains 'CodeSignOnCopy = YES' — forbidden (MCP-06 / R1 H-B2)" >&2
  exit 1
fi

# Rule 2: --deep flag must NOT appear anywhere codesign-adjacent.
if echo "$STRIPPED" | /usr/bin/grep -E -- '(--deep|"--deep")' > /dev/null; then
  echo "error: pbxproj contains '--deep' flag — forbidden (TN2206 / Pitfall #3)" >&2
  exit 1
fi

# Rule 3: OTHER_CODE_SIGN_FLAGS must include --options=runtime and --timestamp.
if ! echo "$STRIPPED" | /usr/bin/grep -E 'OTHER_CODE_SIGN_FLAGS.*--options=runtime' > /dev/null; then
  echo "error: pbxproj OTHER_CODE_SIGN_FLAGS must include --options=runtime" >&2
  exit 1
fi
if ! echo "$STRIPPED" | /usr/bin/grep -E 'OTHER_CODE_SIGN_FLAGS.*--timestamp' > /dev/null; then
  echo "error: pbxproj OTHER_CODE_SIGN_FLAGS must include --timestamp" >&2
  exit 1
fi

# Rule 4 (WR-07 REVIEW 05): each helper target MUST keep
# `CODE_SIGNING_ALLOWED = NO` for both Debug and Release. The codesign.sh
# postBuildScript handles per-helper signing with deepest-first walk and
# per-helper entitlements. If a developer flips CODE_SIGNING_ALLOWED on
# (e.g., via Xcode UI), Xcode will sign helpers with the parent target's
# identity, stripping per-helper entitlements (MCP-06 / R1 H-B2 hazard).
#
# We can't assert "every helper has NO" without parsing target/config
# pairs out of the pbxproj. Instead we assert: every PRESENCE of
# CODE_SIGNING_ALLOWED in helper-target-context must be `= NO`. xcodegen
# only writes CODE_SIGNING_ALLOWED for targets that override the base; if
# any line says `CODE_SIGNING_ALLOWED = YES` anywhere in the pbxproj, fail.
if echo "$STRIPPED" | /usr/bin/grep -E 'CODE_SIGNING_ALLOWED[[:space:]]*=[[:space:]]*YES' > /dev/null; then
  echo "error: pbxproj contains 'CODE_SIGNING_ALLOWED = YES' — helper targets must keep this NO so codesign.sh applies per-helper identity (WR-07)" >&2
  exit 1
fi

# Rule 5 (WR-07): explicit positive check that the three helper targets
# each declare CODE_SIGNING_ALLOWED = NO at least once in the pbxproj —
# defense-in-depth so a deletion of the project.yml override gets caught.
#
# Strategy: pbxproj buildSettings are emitted alphabetically, so
# CODE_SIGNING_ALLOWED comes BEFORE PRODUCT_NAME inside a target's
# settings block. Walk the file holding the most-recent
# CODE_SIGNING_ALLOWED value in a state variable; when we hit
# `PRODUCT_NAME = $helper`, assert the held value was NO. A target
# without an explicit toggle would inherit base settings (also NO under
# project.yml) — but xcodegen emits the override every time so absence
# would mean someone deleted the override, which is what WR-07 catches.
for HELPER in mcp-time mcp-clipboard mcp-applescript; do
  if ! /usr/bin/awk -v h="$HELPER" '
    /buildSettings[[:space:]]*=/ { last_csa = "" }
    /CODE_SIGNING_ALLOWED[[:space:]]*=[[:space:]]*NO/ { last_csa = "NO" }
    /CODE_SIGNING_ALLOWED[[:space:]]*=[[:space:]]*YES/ { last_csa = "YES" }
    $0 ~ "PRODUCT_NAME[[:space:]]*=[[:space:]]*\""h"\"" {
      if (last_csa == "NO") { found = 1 }
      else if (last_csa == "YES") { print "YES detected for "h > "/dev/stderr"; exit 2 }
    }
    END { exit (found ? 0 : 1) }
  ' "$PBXPROJ"; then
    echo "error: helper target '$HELPER' is missing 'CODE_SIGNING_ALLOWED = NO' in pbxproj — WR-07 requires per-helper signing via codesign.sh" >&2
    exit 1
  fi
done

echo "verify-codesign-settings: pbxproj lint passed"
