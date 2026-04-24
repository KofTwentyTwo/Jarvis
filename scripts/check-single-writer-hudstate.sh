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
#   - packages/Bus/Sources/Bus/Protocol.swift      (case ref in fixtures)
#   - App/HUD/HudStateCoordinator.swift            (sole logical writer)
#   - App/HUD/HudStateBridge.swift                 (App→Bus rawValue bridge)
#   - App/AppDelegate.swift                        (wiring-layer emit closure)
#   - any file under /Tests/                       (drives the coordinator directly)
#
# Why AppDelegate is on the allowlist (Plan 03-05): `installBus()` constructs
# the coordinator with an emit closure that builds `.hudState(busHudState(from:))`
# and hands it to `WebviewBridge.send(_:)`. This is the single wiring site;
# Phase 4 + later plans drive the coordinator via its three input AsyncStreams
# (agent / voice / confirmation) and must NOT add new `.hudState(...)` call
# sites anywhere else. If they do, this lint fires.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HITS=$(grep -rn '\.hudState(' App/ packages/ --include='*.swift' 2>/dev/null \
    | grep -v '/Tests/' \
    | grep -v 'App/HUD/HudStateCoordinator.swift' \
    | grep -v 'App/HUD/HudStateBridge.swift' \
    | grep -v 'App/AppDelegate.swift' \
    | grep -v 'packages/Bus/Sources/Bus/BusOutbound.swift' \
    | grep -v 'packages/Bus/Sources/Bus/Protocol.swift' \
    | grep -v '^[^:]*:[[:space:]]*//' || true)

if [[ -n "$HITS" ]]; then
    echo "HUD-08 violation: BusOutbound.hudState(_:) constructed outside HudStateCoordinator:" >&2
    echo "$HITS" >&2
    exit 1
fi

exit 0
