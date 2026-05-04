#!/usr/bin/env bash
# check-applescript-confirmation.sh
#
# P3-18 / security LOW-3 — defense-in-depth grep gate. The
# `run_applescript` MCP tool MUST be registered with
# `requiresConfirmation: true` so the HUD's confirmation panel gates
# every AppleScript execution. Today the registration lives in
# `App/MCP/MCPRuntimeWiring.swift:119`; this gate fails the build if any
# production registration drifts to `requiresConfirmation: false` (or
# omits the flag, which would default to false at the registry level).
#
# Why a grep gate when there's also a runtime test
# (`MCPRuntimeWiringTests.requiresConfirmation` asserts the flag)?
# Defense in depth — the test covers the path the test exercises; the
# grep gate covers every line of source. A future contributor adding a
# second registration site (e.g. an in-process AppleScript tool) won't
# accidentally ship an unconfirmed path; the lint catches the regression
# before the test does.
#
# Scope:
#   - Scans `App/` and `packages/MCP/Sources/` for production references
#     to `run_applescript`.
#   - Skips `*/Tests/*`, `*/test-fixtures/*`, `.build/`, this script.
#   - Ignores pure comment / docstring lines (the literal in a `///` or
#     `//` comment is not a registration).
#
# Detection:
#   For each non-comment, non-test, non-string-literal-only line
#   containing `run_applescript`, the gate looks within a tight window
#   (the line itself plus up to 5 following lines, terminated early at
#   the next `)`) — i.e. the body of the enclosing `register(...)` call.
#   That window MUST contain `requiresConfirmation: true`. Anything else
#   (`false`, omitted, or a `true` outside the call body) fails the gate.
#
# Exit:
#   0 — clean (PASS)
#   1 — at least one production `run_applescript` site missing
#       `requiresConfirmation: true` inside its register-call body
#       (FAIL + file:line citation)
#
# Usage:
#   bash scripts/check-applescript-confirmation.sh
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# Production sources: App/** and packages/MCP/Sources/**.
mapfile -t FILES < <(find App packages/MCP/Sources -type f -name '*.swift' \
    -not -path '*/.build/*' \
    -not -path '*/Tests/*' \
    -not -path '*/test-fixtures/*' \
    2>/dev/null)

# Lines to scan beyond the `run_applescript` line for the closing `)`
# of the enclosing call. Real registrations close within 1-3 lines; 5
# is a safe ceiling for a wrapped call without picking up a sibling
# `register(...)` block below.
WINDOW_DOWN=5

is_comment_line() {
    # Returns 0 (true) when the line, after stripping leading whitespace,
    # starts with `//`, `///`, `/**`, or `*` (block-comment continuation).
    local line="$1"
    local stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
        //*|/\*\*|\**) return 0 ;;
        *) return 1 ;;
    esac
}

FOUND=0

for f in "${FILES[@]}"; do
    # Find every line containing the literal `run_applescript`. We grep
    # the raw file (no comment-strip), then filter comment lines per-hit
    # because is_comment_line needs the whole line.
    while IFS=: read -r lineno line; do
        if is_comment_line "$line"; then
            continue
        fi

        # Walk from the hit line down for up to WINDOW_DOWN lines, until
        # we see a `)` that closes the enclosing call. Accumulate the
        # text we see in `block`. The hit line itself is included — many
        # registrations fit on one line (`registry.register(toolName:
        # "run_applescript", …, requiresConfirmation: true)`).
        block=""
        end=$(( lineno + WINDOW_DOWN ))
        cur=$lineno
        while [ "$cur" -le "$end" ]; do
            cur_line="$(sed -n "${cur}p" "$f")"
            block="${block}
${cur_line}"
            # Stop at the first un-escaped `)` — that's the close of the
            # enclosing register call. (Swift call expressions don't
            # contain bare `)` except as the call terminator; this is
            # heuristic, not a parser, but it's correct for the
            # registration shapes used in this codebase.)
            case "$cur_line" in
                *\)*) break ;;
            esac
            cur=$((cur + 1))
        done

        if ! printf '%s\n' "$block" | grep -qE 'requiresConfirmation:[[:space:]]*true'; then
            echo "  $f:$lineno: run_applescript registration missing requiresConfirmation: true within the enclosing call body"
            echo "    >>> $line"
            FOUND=$((FOUND + 1))
        fi
    done < <(grep -nE 'run_applescript' "$f" 2>/dev/null || true)
done

if [ "$FOUND" -gt 0 ]; then
    echo "[check-applescript-confirmation] FAIL — $FOUND missing requiresConfirmation" >&2
    exit 1
fi

echo "[check-applescript-confirmation] PASS"
exit 0
