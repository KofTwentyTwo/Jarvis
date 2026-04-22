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

echo "verify-codesign-settings: pbxproj lint passed"
