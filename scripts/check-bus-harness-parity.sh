#!/usr/bin/env bash
#
# check-bus-harness-parity.sh — Xcode pre-build phase.
#
# Asserts the canonical `webview/bus-harness.html` (authored) and the bundled
# copy at `App/Resources/webview/bus-harness.html` (shipped, committed by
# Plan 02-03) are byte-identical. Prevents silent drift between the two.
#
# If you changed the canonical file, re-copy it to the bundle location.
# If you changed the bundle copy directly — don't. Edit the canonical file.
#
# Usage:
#   scripts/check-bus-harness-parity.sh                     # production
#   REPO=/tmp/fix scripts/check-bus-harness-parity.sh       # test mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"

CANONICAL="$REPO/webview/bus-harness.html"
BUNDLE="$REPO/App/Resources/webview/bus-harness.html"

if [[ ! -f "$CANONICAL" ]]; then
    echo "FAIL: canonical bus-harness.html missing: $CANONICAL" >&2
    exit 1
fi

if [[ ! -f "$BUNDLE" ]]; then
    {
        echo "FAIL: bundle bus-harness.html missing: $BUNDLE"
        echo "  Copy from $CANONICAL to $BUNDLE and commit."
    } >&2
    exit 1
fi

if ! /usr/bin/diff -q "$CANONICAL" "$BUNDLE" >/dev/null 2>&1; then
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
        /usr/bin/diff "$CANONICAL" "$BUNDLE" || true
    } >&2
    exit 1
fi

echo "bus-harness.html parity OK"
