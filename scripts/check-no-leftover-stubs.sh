#!/usr/bin/env bash
# check-no-leftover-stubs.sh
#
# F2 — fail the build if production code carries stub markers left over
# from incremental plans. Catches the pattern that produced BLOCKER-INT-1
# (a `NoopBusGateway` shipping in `applicationWillFinishLaunching`) and
# similar "the test wires the real thing, production wires the stub"
# divergences enumerated in `.planning/audit-2026-05-03/SYNTHESIS.md`.
#
# Patterns flagged (precision over recall — false positives waste time):
#
#   1. Comments containing the literal `Replaced in 0` (e.g.
#      `Replaced in 06-05`, `Replaced in 07-12`). These are scaffold
#      planning markers; once the plan is done, the comment is stale and
#      almost always indicates the replacement never happened.
#
#   2. Comments containing `TODO: Plan ` or `TODO: 0X-` (where X is a
#      digit). Same shape — incremental-plan reminder that survived the
#      plan's close. Matches `// TODO: 06-05 …`, `// TODO: Plan 7 …`.
#
#   3. Function bodies whose ONLY non-whitespace content is one of the
#      sentinel comments `// TODO: implement`, `// Placeholder`, or
#      `// Stub`. Detected by looking at the line immediately after `{`
#      and the line immediately before the matching `}` — a 2-line
#      function.
#
#   4. Type instantiations of `Noop*` or types whose name ends in
#      `Stub` outside of test code. Allowlist: the `Dormant*` family
#      and `dormantVoiceContinuation` are real continuation patterns
#      (App/AppDelegate.swift:99 etc.), not stubs — `Dormant` indicates
#      "intentionally idle until a producer arrives," distinct from
#      "this is a placeholder." If a future stub is named `Dormant…` to
#      sneak past this gate, audit will catch it; lint will not.
#
# Scope:
#   - Scans `App/` and `packages/*/Sources/` (recursive).
#   - Excludes `.build/`, `.planning/source-material/`, test directories,
#     and the script itself.
#
# Usage:
#   bash scripts/check-no-leftover-stubs.sh        # scan repo
#   bash scripts/check-no-leftover-stubs.sh --self # print scan-set, debug
#
# Exit:
#   0 — clean (PASS line printed)
#   1 — at least one leftover stub marker found (FAIL line + file:lines)
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# Files in scope: production Swift only.
mapfile -t FILES < <(find App packages -type f -name '*.swift' \
    -not -path '*/.build/*' \
    -not -path '*/Tests/*' \
    -not -path '*/test-fixtures/*' \
    -not -path '*/.planning/source-material/*' \
    2>/dev/null)

if [ "${1:-}" = "--self" ]; then
    printf '%s\n' "${FILES[@]}"
    exit 0
fi

# Pattern 1: `Replaced in 0` (anywhere, but only inside comments — Swift
# string-literal containing "Replaced in 0" is implausible enough that
# we don't bother stripping strings).
PATTERN_1='Replaced in 0'

# Pattern 2: `TODO: Plan ` or `TODO: 0[0-9]-`.
PATTERN_2='TODO: Plan |TODO: 0[0-9]-'

# Pattern 3: 2-line stub function bodies. Implemented as a sed/awk pass
# below, not a regex.

# Pattern 4: production Noop* instantiation. The protocol-level pattern
# is `let foo = Noop…(` or `= Noop…(`. We scan for instantiations rather
# than declarations so that a `struct NoopX` definition doesn't trigger
# itself (the BlockerInt-1 fix kept some `Noop*` *definitions* in test
# code; what we care about is production code that *uses* one).
PATTERN_4='=\s*Noop[A-Z][A-Za-z0-9_]*\s*\(|=\s*[A-Z][A-Za-z0-9_]*Stub\s*\('

# Inline allowlist: substrings that, if they appear on a matched line,
# suppress the match. Keep this minimal.
ALLOWLIST_SUBSTRINGS=(
    "dormantVoiceContinuation"   # real producer-stream pattern
    "DormantVoiceBusEmitter"     # real producer-stream pattern
)

is_allowlisted_line() {
    local line="$1"
    for sub in "${ALLOWLIST_SUBSTRINGS[@]}"; do
        if [[ "$line" == *"$sub"* ]]; then return 0; fi
    done
    return 1
}

FOUND=0

# Pattern 1 + 2 + 4 in one pass.
for f in "${FILES[@]}"; do
    while IFS=: read -r lineno line; do
        if is_allowlisted_line "$line"; then continue; fi
        echo "  $f:$lineno: $line" | sed 's/^[[:space:]]*//'
        FOUND=$((FOUND + 1))
    done < <(grep -nE "$PATTERN_1|$PATTERN_2|$PATTERN_4" "$f" 2>/dev/null || true)
done

# Pattern 3: 2-line stub function bodies. We look for the EXACT shape:
#
#   func name(...) -> ... {
#       // TODO: implement     (or // Placeholder, or // Stub)
#   }
#
# i.e. open-brace line, then a single sentinel-comment line, then a
# close-brace line. Anything richer (real code below, multiple
# statements) is NOT a stub.
for f in "${FILES[@]}"; do
    awk '
        /\{[[:space:]]*$/ {
            open_line = NR
            next_open = 1
            stub_line = 0
            next
        }
        next_open == 1 {
            # First line after open-brace must be exactly a sentinel comment.
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "// TODO: implement" || line == "// Placeholder" || line == "// Stub") {
                stub_line = NR
                stub_text = line
                next_open = 2
                next
            } else {
                next_open = 0
                next
            }
        }
        next_open == 2 {
            # Next line after sentinel must be the closing brace.
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "}") {
                printf "%s:%d: 2-line stub body { … %s … }\n", FILENAME, stub_line, stub_text
            }
            next_open = 0
            next
        }
    ' "$f" | while read -r m; do
        echo "  $m"
        FOUND=$((FOUND + 1))
    done
done

# The while-loop above runs in a subshell so $FOUND mutations don't
# escape. Recount instead.
PATTERN3_HITS=0
for f in "${FILES[@]}"; do
    PATTERN3_HITS=$((PATTERN3_HITS + $(awk '
        /\{[[:space:]]*$/ { next_open = 1; next }
        next_open == 1 {
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (line == "// TODO: implement" || line == "// Placeholder" || line == "// Stub") {
                next_open = 2; next
            } else { next_open = 0; next }
        }
        next_open == 2 {
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (line == "}") { print "x" }
            next_open = 0; next
        }
    ' "$f" | wc -l | tr -d ' ')))
done
FOUND=$((FOUND + PATTERN3_HITS))

if [ "$FOUND" -gt 0 ]; then
    echo "[check-no-leftover-stubs] FAIL — $FOUND leftover stub markers above" >&2
    exit 1
fi

echo "[check-no-leftover-stubs] PASS"
exit 0
