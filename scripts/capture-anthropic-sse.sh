#!/usr/bin/env bash
#
# scripts/capture-anthropic-sse.sh
#
# Operator helper: record a live Anthropic SSE response into a fixture file
# under packages/Harness/Corpora/sse-anthropic/<fixture-name>.sse.
#
# CRITICAL D-07 invariant: Authorization: Bearer <token> and x-api-key: <token>
# headers MUST be redacted BEFORE the bytes hit disk. Two-layer defense:
#   1. sed pipeline rewrites any echoed Authorization / x-api-key line to
#      `<header>: <REDACTED>` before the file is written.
#   2. Post-write grep for known API-key patterns (sk-ant-, AKIA, ghp_,
#      sk-<32+>) — if anything matches, abort and delete the partial file.
# A pre-commit hook (Plan 08-04) is the third layer.
#
# Usage:
#   ANTHROPIC_API_KEY=$(security find-generic-password \
#       -s 'com.koftwentytwo.jarvis.anthropic' -w) \
#   scripts/capture-anthropic-sse.sh <fixture-name> <prompt-file>
#
# Example:
#   scripts/capture-anthropic-sse.sh tool-use-fresh prompts/tool-use.txt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY env var required}"

FIXTURE_NAME="${1:?fixture name required}"
PROMPT_FILE="${2:?prompt file required}"

OUT_DIR="${REPO}/packages/Harness/Corpora/sse-anthropic"
OUT_PATH="${OUT_DIR}/${FIXTURE_NAME}.sse"

mkdir -p "$OUT_DIR"
PROMPT="$(cat "$PROMPT_FILE")"

# Capture, redact, write. The sed pipeline runs BEFORE the redirect so the
# raw key never lands on disk. Both Authorization: Bearer ... and x-api-key:
# ... patterns are rewritten to <header>: <REDACTED>. Case-insensitive match
# (gI flag) — Anthropic returns headers verbatim in some echo modes.
curl -sN https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: extended-cache-ttl-2025-04-11" \
    -H "content-type: application/json" \
    -H "accept: text/event-stream" \
    -d "$(jq -n --arg p "$PROMPT" \
        '{model:"claude-opus-4-7",max_tokens:1024,stream:true,messages:[{role:"user",content:$p}]}')" \
    | sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
    | sed -E 's/(x-api-key:[[:space:]]*)[^[:space:]]+/\1<REDACTED>/gI' \
    > "$OUT_PATH"

echo "Wrote: $OUT_PATH"

# Layer 2: scan the committed bytes for any known key pattern. If any
# pattern matches, we either failed to redact or the API key leaked into
# the response body. Either way, abort and delete the file.
if grep -E "sk-ant-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{32,}" "$OUT_PATH" >/dev/null 2>&1; then
    echo "ERROR: API key pattern detected in $OUT_PATH after redaction. Aborting." >&2
    rm -f "$OUT_PATH"
    exit 1
fi

echo "OK: no API key patterns detected in $OUT_PATH"
