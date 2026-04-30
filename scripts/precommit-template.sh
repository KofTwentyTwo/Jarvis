#!/usr/bin/env bash
# precommit-template.sh — committed pre-commit hook source.
#
# Install via symlink (run once per clone):
#   ln -sf ../../scripts/precommit-template.sh .git/hooks/pre-commit
#
# The symlink form means subsequent updates to this file are picked up
# automatically (no re-install needed). `.git/hooks/pre-commit` itself is
# local-only and not committed; this template lives under scripts/ so it
# travels with the repo.
#
# Hooks invoked (append further checks below as the project adds them):
#   1. scripts/check-corpus-secrets.sh — D-07 secret-pattern guard against
#      packages/Harness/Corpora/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

"${REPO}/scripts/check-corpus-secrets.sh"
