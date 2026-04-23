#!/usr/bin/env bash
#
# check-no-evaluate-javascript.sh — Xcode pre-build phase.
#
# Forbids `.evaluateJavaScript(` in Swift sources outside test directories.
# HUD-04 architecturally forbids the API — interpolating JSON into an
# evaluateJavaScript body is an XSS foothold (`</script>`, U+2028 line
# terminator, etc.). The one allowed JS entry is
# `callAsyncJavaScript(_:arguments:in:contentWorld:)`, which takes arguments
# as typed values and never string-interpolates the payload.
#
# Usage:
#   scripts/check-no-evaluate-javascript.sh                   # production
#   REPO=/tmp/fix SEARCH_ROOTS=my-fixture-dir \
#     scripts/check-no-evaluate-javascript.sh                 # test-harness mode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${SEARCH_ROOTS:=App packages}"

HITS=()

for root in $SEARCH_ROOTS; do
    full="$REPO/$root"
    [[ -d "$full" ]] || continue

    while IFS= read -r -d '' file; do
        # Skip test directories — tests may reference the forbidden API
        # in comments, string literals, or control fixtures.
        case "$file" in
            */Tests/*) continue ;;
            */tests/*) continue ;;
            */test-fixtures/*) continue ;;
        esac
        if matches=$(grep -nE '\.evaluateJavaScript\(' "$file" 2>/dev/null); then
            while IFS= read -r m; do
                HITS+=("$file:$m")
            done <<<"$matches"
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
