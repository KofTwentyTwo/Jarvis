#!/usr/bin/env bash
# check-corpus-secrets.sh — D-07 pre-commit guard.
#
# Greps packages/Harness/Corpora/ for live API key patterns. Non-zero
# exit aborts the commit. The four patterns covered:
#   sk-ant-[A-Za-z0-9]{40,}    Anthropic
#   AKIA[0-9A-Z]{16}           AWS access key
#   ghp_[A-Za-z0-9]{36}        GitHub PAT
#   sk-[A-Za-z0-9]{32,}        Generic OpenAI-style
#
# Install as a pre-commit hook (option A: symlink template):
#   ln -sf ../../scripts/precommit-template.sh .git/hooks/pre-commit
#
# Or option B: invoke directly from .git/hooks/pre-commit:
#   "${REPO}/scripts/check-corpus-secrets.sh"
#
# Variable indirection per S-6:
#   REPO=...        override repo root detection
#   CORPORA_PATH=...  override Corpora/ path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${CORPORA_PATH:=$REPO/packages/Harness/Corpora}"
# Replay/eval session SQLite files may carry a tool_call body that
# accidentally inlines an API key. Scan them too — D-07 review-followup.
: "${REPLAY_GLOB:=$REPO/Corpora/replay-golden}"
: "${EVAL_GLOB:=$REPO/Corpora/evaluation}"

PATTERNS=(
    "sk-ant-[A-Za-z0-9]{40,}"
    "AKIA[0-9A-Z]{16}"
    "ghp_[A-Za-z0-9]{36}"
    "sk-[A-Za-z0-9]{32,}"
)

HITS=0

if [[ -d "$CORPORA_PATH" ]]; then
    for pat in "${PATTERNS[@]}"; do
        if grep -rE "$pat" "$CORPORA_PATH" 2>/dev/null; then
            echo "ERROR: D-07 violation — pattern '$pat' detected in Corpora/" >&2
            HITS=$((HITS + 1))
        fi
    done
fi

# Scan recorded SQLite session files. SQLite is a binary container — `grep`
# against the file works because key patterns are ASCII and stored verbatim.
# We scan only files matching well-known suffixes so a stray DB elsewhere in
# the tree (e.g. dev caches) isn't gated. `sqlite3` is preferred when
# available (it dumps tool_call rows as text) but plain grep is the
# acceptable fallback so the hook stays portable.
scan_sqlite() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    while IFS= read -r -d '' db; do
        local hits_in_db=0
        if command -v sqlite3 >/dev/null 2>&1; then
            local dump
            dump=$(sqlite3 -readonly "$db" \
                "SELECT payload_text, tool_call_args, tool_result_text FROM events WHERE kind LIKE 'tool_%';" \
                2>/dev/null || true)
            for pat in "${PATTERNS[@]}"; do
                if echo "$dump" | grep -qE "$pat"; then
                    echo "ERROR: D-07 violation — pattern '$pat' detected in SQLite events of $db" >&2
                    hits_in_db=$((hits_in_db + 1))
                fi
            done
        else
            for pat in "${PATTERNS[@]}"; do
                if grep -aE "$pat" "$db" >/dev/null 2>&1; then
                    echo "ERROR: D-07 violation — pattern '$pat' detected in SQLite blob $db" >&2
                    hits_in_db=$((hits_in_db + 1))
                fi
            done
        fi
        HITS=$((HITS + hits_in_db))
    done < <(find "$target_dir" \
        \( -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db" \
           -o -name "*.replay" -o -name "*.evaluation" \) \
        -type f -print0 2>/dev/null)
}

scan_sqlite "$REPLAY_GLOB"
scan_sqlite "$EVAL_GLOB"
# Also scan the Harness-bundled corpora (golden replays staged inside SPM).
scan_sqlite "$REPO/packages/Harness/Corpora"

if [[ $HITS -gt 0 ]]; then
    echo "" >&2
    echo "Aborting commit. Redact the secret(s) above and re-stage." >&2
    echo "If this is a false positive, scrub the byte sequence and re-run." >&2
    exit 1
fi

exit 0
