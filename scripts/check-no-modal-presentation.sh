#!/usr/bin/env bash
# check-no-modal-presentation.sh
#
# Plan 05-05 Task 5 — preBuildScript that rejects modal-presentation API
# calls (runModal, beginModalSession, NSApp.run, NSApplication.shared.run,
# NSAlert(...).runModal()) anywhere in the codebase EXCEPT explicitly
# allowlisted files. Modal presentation parks the @MainActor and breaks
# the always-on-top HUD's responsiveness — RESEARCH §Recommendation 4 +
# Pattern 5 + AUDIT-R4-Sec4 enforce this.
#
# Allowlist (paths relative to repo root):
#   - packages/Shell/Sources/Shell/TCCAlertService.swift
#       Phase 1 NSAlert hard-block path (the "Jarvis can't start" modal).
#       The plan's path was "App/TCC/TCCAlertService.swift" but the file
#       was migrated into the Shell package; the lint follows the
#       file's actual location.
#   - packages/MCP/Sources/MCP/ConfirmationPresenter.swift
#       Plan 05-05 sanctioned NSPanel.beginSheet path. The presenter
#       references runModal in DOC COMMENTS only; the comment-stripping
#       grep step prevents false positives, but the file is allowlisted
#       for defense-in-depth.
#
# Wired as a preBuildScript in project.yml on the Jarvis target, BEFORE
# the postBuildScript verify-entitlements --pre-codesign — build fails
# fast on regression.
#
# Modes:
#   no args:                     scan App/** + packages/**/Sources/** in repo
#   --fixture <path>:            scan ONLY the given file (used by self-test)
#
# Exit codes:
#   0 — clean
#   1 — at least one forbidden modal call found outside allowlist
set -euo pipefail

ALLOWLIST=(
    "packages/Shell/Sources/Shell/TCCAlertService.swift"
    "packages/MCP/Sources/MCP/ConfirmationPresenter.swift"
)

# WR-01 (REVIEW 05): tighten the grep so it only fires on actual call
# sites, not bare identifiers, doc-comment mentions, or string literals.
# Each alternation now requires either a `.method(` (instance call) or
# `Type.method(` (static call) shape — so `let docs = "Use NSApp.run() ..."`
# inside a string no longer triggers the lint after the pre-strip pass
# below scrubs string literals.
PATTERN='\.runModal[[:space:]]*\(|\.beginModalSession[[:space:]]*\(|NSApp\.run[[:space:]]*\(|NSApplication\.shared\.run[[:space:]]*\('

is_allowlisted() {
    local path="$1"
    local rel="${path#./}"
    # Also tolerate SRCROOT-prefixed absolute paths in case the build phase
    # runs the script with an absolute argument.
    rel="${rel#${SRCROOT:-}/}"
    for allowed in "${ALLOWLIST[@]}"; do
        if [ "$rel" = "$allowed" ]; then return 0; fi
    done
    return 1
}

scan_file() {
    local file="$1"
    # WR-01 (REVIEW 05): pre-strip line comments, block comments, and
    # string literals before grep — otherwise documentation that mentions
    # `NSApp.run()` inside quotes or `/* */` blocks would false-positive
    # after the previous fix only stripped LEADING `//` lines.
    #
    # The sed pipeline:
    #   1. `s|//.*$||`            strip trailing line comments
    #   2. `/\/\*/,/\*\//d`        delete lines from `/*` to `*/` inclusive
    #   3. `s/"[^"]*"//g`          strip "..." string literals (one-line)
    #
    # The block-comment delete is line-based (whole-line removal, not
    # per-character), so a line that opens AND closes a block comment
    # plus has a real call site on the same line would be incorrectly
    # filtered out. That's an acceptable trade — the codebase doesn't use
    # this idiom and the false-negative is bounded.
    local matches
    matches="$(sed -E 's|//.*$||; /\/\*/,/\*\//d; s/"[^"]*"//g' "$file" | grep -E "$PATTERN" || true)"
    if [ -n "$matches" ]; then
        if is_allowlisted "$file"; then
            return 0
        fi
        echo "error: forbidden modal-presentation call in $file:" >&2
        echo "$matches" >&2
        return 1
    fi
    return 0
}

if [ "${1:-}" = "--fixture" ]; then
    scan_file "$2"
    exit $?
fi

# Determine repo root — when called from xcodebuild, SRCROOT is set; when
# run from CLI, default to the script's parent directory.
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

FOUND_ANY=0
while IFS= read -r f; do
    if ! scan_file "$f"; then
        FOUND_ANY=1
    fi
done < <(find App packages -type f -name '*.swift' \
             -not -path '*/.build/*' \
             -not -path '*/Tests/*' \
             -not -path '*/test-fixtures/*' \
             2>/dev/null)

if [ "$FOUND_ANY" -ne 0 ]; then
    echo "check-no-modal-presentation.sh: FAIL" >&2
    exit 1
fi
echo "check-no-modal-presentation.sh: OK"
exit 0
