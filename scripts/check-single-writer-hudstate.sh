#!/usr/bin/env bash
# HUD-08 single-writer invariant guard.
#
# `BusOutbound.hudState(_:)` may only be CONSTRUCTED inside
# `App/HUD/HudStateCoordinator.swift`. Any other Swift source constructing
# `.hudState(...)` is a protocol-level bug — it races the coordinator and
# defeats the point of the precedence ladder.
#
# Allowlist:
#   - packages/Bus/Sources/Bus/BusOutbound.swift   (DEFINES the case)
#   - App/HUD/HudStateCoordinator.swift            (sole constructor)
#   - packages/Bus/Sources/Bus/Protocol.swift      (case ref in fixtures)
#   - any file under /Tests/                       (drives the coordinator directly)
#
# TODO(Plan 03-05): wire this script as a pre-build phase in project.yml
# once AppDelegate actually constructs the coordinator + bridge closure.
# Activating it earlier would be a no-op (no caller exists yet).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HITS=$(grep -rn '\.hudState(' App/ packages/ --include='*.swift' 2>/dev/null \
    | grep -v '/Tests/' \
    | grep -v 'App/HUD/HudStateCoordinator.swift' \
    | grep -v 'packages/Bus/Sources/Bus/BusOutbound.swift' \
    | grep -v 'packages/Bus/Sources/Bus/Protocol.swift' \
    | grep -v '^[^:]*:[[:space:]]*//' || true)

if [[ -n "$HITS" ]]; then
    echo "HUD-08 violation: BusOutbound.hudState(_:) constructed outside HudStateCoordinator:" >&2
    echo "$HITS" >&2
    exit 1
fi

exit 0
