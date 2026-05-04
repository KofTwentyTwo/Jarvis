# Bus

Typed Swift↔JS message protocol over `WKScriptMessageHandler`. The webview is a pure rendering layer; this package is the only legitimate way Swift talks to the HUD and back.

## Key public types

| Type | Purpose |
|------|---------|
| `BusOutbound` (enum) | Messages Swift→JS — `hello`, `hudState`, `tokenDelta`, `audioLevel`, `toolCallStart/End`, `turnStarted/Ended`, `sessionHistory` |
| `BusInbound` (enum) | Messages JS→Swift — `helloAck`, `uiReady`, `frameAttachRequested`, `chatSubmit`, `chatCancelAndSubmit` |
| `OutboundBatcher` (actor) | Coalesces `tokenDelta` on a 32 ms tick; forwards everything else immediately |
| `WebviewBridge` | The `WKScriptMessageHandler` boundary (the only place that calls `evaluateJavaScript`) |
| `Handshake` | Version-negotiation flow on first `uiReady` |
| `BusReply` / `BusError` | Reply + error types for request/response patterns |

## Depends on

`Logging`. External: `swift-log`.

## Used by

`App/AppDelegate`, every subsystem that emits to the HUD, the webview-side TS package `webview/packages/bus`.

## Key invariants / contracts

- **Hand-written `Codable`.** Both `BusOutbound` and `BusInbound` declare `Codable` in extensions with explicit `init(from:)` / `encode(to:)`. Swift's synthesized `Codable` would produce `{"hudState": {"_0": "idle"}}` instead of `{"type":"hudState","state":"idle"}`. Adding a case without updating both methods is a compile error — schema-drift preventer at the language level.
- **Schema version sync.** `Protocol.swift` carries the version; `webview/packages/bus/src/version.ts` carries the TS mirror. `scripts/check-bus-protocol-version.sh` requires both to match.
- **Harness parity.** `scripts/check-bus-harness-parity.sh` requires the TS bus fixtures to round-trip through the Swift decoder.
- **No `evaluateJavaScript` outside `WebviewBridge`.** Grep-gated by `scripts/check-no-evaluate-javascript.sh`.
- **Single writer to `HudState`.** `scripts/check-single-writer-hudstate.sh` enforces.

## Tests

58 XCTest. Round-trip encoding tests, version-negotiation tests, batcher coalescing tests, content-world isolation tests (`WebviewBridgeOutboundTests` asserts `WKContentWorld.page`).

## Notable files

- `Sources/Bus/BusOutbound.swift` — Swift→JS event union + hand-written Codable
- `Sources/Bus/BusInbound.swift` — JS→Swift event union + hand-written Codable
- `Sources/Bus/OutboundBatcher.swift` — token-coalescing actor
- `Sources/Bus/WebviewBridge.swift` — WKScriptMessageHandler boundary
- `Sources/Bus/Protocol.swift` — version constant
