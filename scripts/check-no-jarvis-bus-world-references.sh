#!/usr/bin/env bash
#
# check-no-jarvis-bus-world-references.sh
#
# Issue #45 boundary gate.
#
# The named `WKContentWorld("JarvisBusWorld")` was retired in `fb41c5f` —
# the bus message handler and `Injection.js` user script now both register
# against `WKContentWorld.page` (the default page world). Old doc-comments
# and test fixtures hung onto the name for months afterward; #45 closed
# the cleanup.
#
# This gate prevents new code or comments from re-introducing the literal
# string `JarvisBusWorld` outside the historical reference corpora:
#
#   - `.planning/`              archived plans / audit reports / handoffs
#   - `docs/`                   spec documents that explain the migration
#   - `node_modules/`           vendored deps (out of repo control anyway)
#   - `.build/`, build/         SwiftPM + Xcode derived data
#   - `webview/packages/*/dist/` TypeScript build output (regenerated from src)
#   - this script itself        we have to reference the literal to grep for it
#   - `.git/`                   git internals
#
# Fails CI if any other tracked file contains the literal string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

# Use `git grep` so we automatically respect .gitignore (so dist/ etc. that
# aren't tracked don't trip the gate even if they exist on disk locally).
# `--cached` would miss new working-tree files; default mode greps the
# working tree filtered by tracked-or-untracked-not-ignored, which is what
# we want before a commit.
matches=$(git grep --no-color -n "JarvisBusWorld" -- \
    ':!.planning/' \
    ':!docs/' \
    ':!scripts/check-no-jarvis-bus-world-references.sh' \
    ':!webview/packages/*/dist/' \
    || true)

if [ -n "$matches" ]; then
    echo "[check-no-jarvis-bus-world-references] FAIL: tracked source still references the retired 'JarvisBusWorld' named content world." >&2
    echo "" >&2
    echo "$matches" >&2
    echo "" >&2
    echo "[check-no-jarvis-bus-world-references] Rewrite these to 'page world' / 'shared world' / 'defensive double-install guard' — see #45 and the JSDoc in webview/packages/bus/src/bridge.ts for the canonical phrasing." >&2
    exit 1
fi

echo "[check-no-jarvis-bus-world-references] PASS (no tracked source references the retired named world)"
