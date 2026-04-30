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

PATTERNS=(
    "sk-ant-[A-Za-z0-9]{40,}"
    "AKIA[0-9A-Z]{16}"
    "ghp_[A-Za-z0-9]{36}"
    "sk-[A-Za-z0-9]{32,}"
)

if [[ ! -d "$CORPORA_PATH" ]]; then
    # Corpora directory missing is not a violation — first commits / fresh
    # checkouts may legitimately predate it.
    exit 0
fi

HITS=0
for pat in "${PATTERNS[@]}"; do
    if grep -rE "$pat" "$CORPORA_PATH" 2>/dev/null; then
        echo "ERROR: D-07 violation — pattern '$pat' detected in Corpora/" >&2
        HITS=$((HITS + 1))
    fi
done

if [[ $HITS -gt 0 ]]; then
    echo "" >&2
    echo "Aborting commit. Redact the secret(s) above and re-stage." >&2
    echo "If this is a false positive, scrub the byte sequence and re-run." >&2
    exit 1
fi

exit 0
