---
phase: 02-bus
researched: 2026-04-22
depends_on: [01-foundations]
covers_reqs: [HUD-03, HUD-04, HUD-05, HUD-06, SEC-09]
---

# Phase 2: Bus — Research

**Researched:** 2026-04-22
**Domain:** Versioned, strictly-typed JSON message bus across the Swift ↔ WKWebView boundary with zero silent schema drift
**Confidence:** HIGH on every architectural decision (audit-converged + 2026 Apple docs confirm); MEDIUM on specific throttle primitive choice (three viable patterns — pick one at plan time); MEDIUM on hot-reload Dev-build scheme (not in requirements; noted for planner judgement).

---

## Summary for Planner

Phase 2 is the R4 dominant-failure-mode foreclosure phase. The deliverable is a narrow, well-tested bus package with:

1. **`packages/Bus`** — new local SPM target, Swift 6 strict concurrency. Exports `BusMessage` (discriminated-union `enum` with hand-written `Codable`), `BusInbound` / `BusOutbound` enums, `BusError`, `BUS_PROTOCOL_VERSION` constant, `WebviewBridge` (@MainActor), `OutboundBatcher` (actor or @MainActor class), `BridgeLogger` wrapper on `JarvisLogging`. Depends only on `Logging` and `Config`.
2. **`webview/packages/bus/`** — paired TS package (first content `webview/` directory — P3 expands it). Exports `BUS_PROTOCOL_VERSION` constant, TS mirror types (discriminated unions with `type` literals), `inboundTo<T>(msg) → Result<T, Error>` helpers, `outboundFromSwift<T>(json) → T | Error`. Ships its own `tsconfig.json` and one fixture-per-case round-trip test.
3. **`scripts/check-bus-protocol-version.sh`** — Xcode pre-build phase (not post-build) that (a) regex-greps `packages/Bus/Sources/Bus/Protocol.swift` for `BUS_PROTOCOL_VERSION = "…"`, (b) regex-greps `webview/packages/bus/src/protocol.ts` for `export const BUS_PROTOCOL_VERSION = "…"`, (c) fails build on mismatch with a sharp error, (d) runs Node-executed round-trip fixtures (one per enum case) asserting Swift emits what TS parses and vice versa.
4. **`WKScriptMessageHandlerWithReply`** for inbound (replaces the legacy handler). `replyHandler` signature is `(Any?, String?) -> Void`: pass `(payload, nil)` for success, `(nil, "error text")` for failure. Our `BusReply` struct serializes to `{ok: true, value: …}` or `{ok: false, error: "…"}` so JS resolves/rejects cleanly.
5. **`callAsyncJavaScript(_:arguments:in:contentWorld:completionHandler:)`** for outbound. JSON payload passed as a single primitive-string argument (`arguments: ["payload": jsonString]`). The JS-side entrypoint does `JSON.parse(payload)`. **Never** `evaluateJavaScript` with string interpolation — lint-banned.
6. **`BUS_PROTOCOL_VERSION` two-way handshake** — ShakeHand-first protocol: on `didFinishNavigation` Swift sends `{type: "hello", version: "2.0.0"}` via callAsyncJavaScript; JS replies with its own constant via a reserved `"helloAck"` inbound message within a 2 s timeout. Mismatch or timeout → native `NSAlert` (`.critical`) and `webView.stopLoading()` + do not route any further outbound; handshake success arms the bridge. This is the keystone Tuesday-morning-incident preventer.
7. **`OutboundBatcher`** — an `actor` with a single-tick coalescer. `audioLevel` and `tokenDelta` call `batcher.post(.audioLevel(x))`; the batcher keeps one `latest` value per batchable case-key and a `scheduled: Task?` that wakes on `Task.sleep(for: .milliseconds(33))`. State-transition events (`hudState`, `toolCall*`, `turnEnd`, `voiceEvent`) call `batcher.flushImmediate(msg)` which cancels any pending Task, drains the latest batchable values, then sends the flush-triggering message. No CADisplayLink; no DispatchSourceTimer. Pure Swift 6 async.
8. **Hand-written `Codable` with `type` discriminator.** Swift synthesis (SE-0295) produces a `{"hudState": {...}}` shape that does NOT match the `{"type": "hudState", ...}` shape TS consumers expect. Each enum has a private `Discriminator: String, CaseIterable, Codable` enum and a `CodingKeys` enum; `init(from:)` decodes the discriminator first and switches exhaustively; `encode(to:)` writes `"type"` first then associated-value keys.
9. **Exhaustive switches, zero `default:`** everywhere that maps `BusMessage` to anything (logging, routing, test fixtures). Adding a case is a compile error at every switch site — this is the load-bearing drift preventer.
10. **Structured logging** — `BridgeLogger` wraps `Logger(label: "bus")` (new fifth channel; document the addition alongside the existing four — or keep in `ui` channel; recommend new `bus` channel for clarity of replay traces). Every inbound message logs `{direction, type, handshakeArmed}` at `.debug`; every handshake-mismatch logs `.critical` with both versions.

**Primary recommendation:** Build `packages/Bus` as the P2 deliverable + pair TS package under `webview/packages/bus/` + one shell script. Keep the surface small (~6 files per side) so schema adds in P3+ are mechanical. The entire phase is 3 plans, roughly: (1) Protocol types + scripts/check, (2) Swift WebviewBridge + OutboundBatcher + tests, (3) TS mirror + handshake + fixture round-trip.

---

## User Constraints

### Locked Decisions (from CLAUDE.md + RESEARCH-DELTAS + REQUIREMENTS)

- **HUD-03:** Inbound uses `WKScriptMessageHandlerWithReply` — legacy `WKScriptMessageHandler` is forbidden. Replies are `Result`-shaped: either `success(payload)` or `failure(error)`. No silent swallowed exceptions.
- **HUD-04:** Outbound uses `callAsyncJavaScript(arguments:)` with primitive arguments only. `evaluateJavaScript("…\(json)…")` string interpolation is lint-enforced FORBIDDEN; attempts break the build.
- **HUD-05:** Two-way `BUS_PROTOCOL_VERSION` handshake runs at webview load. Mismatch → native `NSAlert` + refuse to finish loading the webview.
- **HUD-06:** `OutboundBatcher` coalesces `audioLevel` and `tokenDelta` at ~30 Hz (≈33 ms window); state-transition events bypass the batcher and flush immediately.
- **SEC-09:** `scripts/check-bus-protocol-version.sh` is an Xcode **pre-build** phase (not post-build) that reads both the Swift and TS constants, fails build on mismatch, and runs per-enum-case round-trip fixtures. Messages use a `type` discriminator with hand-written `Codable` + exhaustive switches (no `default` branches).
- **Top-level shape (from ARCHITECTURE.md):** Bus is pure rendering transport — Swift owns truth, webview is a rendering surface. `HudStateCoordinator` (P3) is the only callsite for `bridge.send(.hudState)`. P2 does not build `HudStateCoordinator` but MUST expose the `send(_:)` API it will consume.
- **Swift 6 strict concurrency** on every target (D-04 inherited from P1).
- **No Xcode workspace, no CocoaPods** (D-05). All packages are local SPM.

### Claude's Discretion (research-led)

- **`OutboundBatcher` primitive choice** — `actor` + `Task.sleep` vs `@MainActor final class` + detached Task vs `AsyncThrottleSequence`. Recommended: `actor` + `Task.sleep` (simplest, avoids MainActor contention for per-event buffer updates; final `send` hops to MainActor for the JS call).
- **Number of bus channels for logging** — new `bus` channel vs reuse `ui` channel. Recommended: new `bus` channel — OBS-06 explicitly lists four channels (agent/tools/ui/system), but the bus is busy enough in replay that mixing into `ui` muddies debugging. Adding a fifth channel is a 2-line change in `JarvisLogging` and is honestly forecast to be needed.
- **TS codegen vs hand-write** — generator (Sourcery, swift-openapi-generator) vs hand-write. Recommended: **hand-write** for P2. Only 6–8 message types in v1; generators cost more ceremony than they save at this scale; round-trip test + parity script cover drift. Revisit if message count crosses ~20.
- **Hot-reload Dev scheme** — not in requirements; noted below as Open Question. Recommend deferring to P3 (HUD phase) when the React bundle is non-empty.

### Deferred Ideas (OUT OF SCOPE for P2)

- `HudStateCoordinator` precedence-ladder resolver — **P3 scope**.
- Actual React/R3F content — **P3 scope**. P2 loads a static HTML stub (`bus-harness.html`) that only runs the handshake + a few synthetic test messages.
- Semantic message surface beyond the minimum handshake + a placeholder `hudState` + a placeholder `tokenDelta` — **P3/P4 scope**. P2 pins the shape of the discriminated union, not the complete vocabulary.
- Chat panel rendering, tool-call cards, streaming text — **P3 / TEXT-02 scope**.
- Dev/debug overlay inbound messages — **P4 scope (OBS-01)**.
- Confirmation-sheet inbound acks — **P5 scope (MCP-04)**.

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HUD-03 | `WKScriptMessageHandlerWithReply`; `Result`-shaped replies | Section § "HUD-03 deep-dive" — `MainActor.assumeIsolated` Swift 6 pattern, `BusReply` encoding |
| HUD-04 | `callAsyncJavaScript(arguments:)` primitive payload | Section § "HUD-04 deep-dive" — primitive string single-arg pattern, lint rule sketch |
| HUD-05 | Two-way `BUS_PROTOCOL_VERSION` handshake | Section § "HUD-05 deep-dive" — handshake protocol, timeout, NSAlert pattern |
| HUD-06 | `OutboundBatcher` ~30 Hz coalesce; immediate flush | Section § "HUD-06 deep-dive" — actor+Task.sleep pattern, batcher state machine |
| SEC-09 | `check-bus-protocol-version.sh` pre-build; type discriminator | Section § "SEC-09 deep-dive" — script shape, round-trip fixtures, Codable discipline |

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| JSON schema source of truth | Swift `packages/Bus` | TS mirror (`webview/packages/bus`) | Swift owns all truth (CLAUDE.md); TS mirrors what Swift declares |
| Inbound JSON parsing (JS→Swift) | Swift `WebviewBridge` (@MainActor) | — | `WKScriptMessage.body` must be read on main thread; decoder lives with its consumer |
| Outbound JSON serialization (Swift→JS) | Swift `WebviewBridge` + `OutboundBatcher` | — | Serialization + batching + callAsyncJavaScript all in Swift |
| Protocol version check at runtime | Swift (handshake) + JS (reply) | — | Both sides assert; mismatch kills the webview before any rendering |
| Protocol version check at build time | `scripts/check-bus-protocol-version.sh` (bash) | Node (fixture round-trip) | Shell greps; Node runs round-trip so TS types actually compile/execute |
| High-frequency event coalescing | Swift `OutboundBatcher` (actor) | — | Only Swift sees the firehose (audio, tokens); JS only sees throttled results |
| Handshake presentation on failure | Swift `NSAlert` (via `TCCAlertService` pattern from P1) | — | Native UI — we don't trust a webview that mismatched to render our alert |
| Schema drift prevention | Compile (exhaustive switches) + build (parity script) + runtime (handshake) | — | Three-layer defense; any layer on its own is insufficient |

---

## Standard Stack

### Core (already pinned from P1)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| WebKit | macOS 13+ system framework | WKWebView, `WKScriptMessageHandlerWithReply`, `callAsyncJavaScript` | Apple-provided; only option for embedded web content on macOS |
| Foundation | system | `JSONEncoder`/`JSONDecoder`, `UUID`, `Date` | Standard Swift JSON plumbing |
| swift-log (`apple/swift-log`) | 1.5.3+ | Bus channel logging via `Logger(label: "bus")` | Already pinned in `packages/Logging` from P1 (OBS-06) |

### Supporting (new in P2)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| TypeScript | 5.5+ | TS mirror types for bus protocol | P2 first TS code; P3 HUD pulls it in via pnpm |
| pnpm | 9.x | TS workspace tool (CLAUDE.md D-12) | Installing/building TS package; fixture runner |

### Alternatives Considered (and rejected for P2)

| Instead of | Could Use | Tradeoff | Rejected because |
|------------|-----------|----------|------------------|
| Hand-written `Codable` | Synthesized `Codable` (SE-0295) | Less code | Synthesized shape is `{"hudState": {…}}` — does NOT match `{"type": "hudState", …}` TS shape. Wire-format mismatch = P2 goal violation. |
| Hand-written TS types | Sourcery / swift-openapi-generator | Single source of truth | Added toolchain for ≤10 message types; generators are lossy for `UUID`/`Date` Swift ↔ TS; hand-write + parity script covers drift at P2 scale. |
| `actor` + `Task.sleep` batcher | `DispatchSourceTimer` / `CADisplayLink` / `AsyncThrottleSequence` | GCD-native / display-sync / combinator | `DispatchSourceTimer` leaks unless carefully retained; `CADisplayLink` is display-rate dependent (problematic at 120 Hz ProMotion); `AsyncThrottleSequence` is general-purpose but doesn't let us bypass the buffer for immediate-flush events cleanly. `actor + Task.sleep` is Swift 6-native and 40 LOC. |
| `evaluateJavaScript` + JSON interpolation | — | One less argument | **Security violation (codeql/swift-unsafe-js-eval, CLAUDE.md §ArchRules)** — XSS foothold via `</script>` / U+2028. This is the point of HUD-04. |
| Legacy `WKScriptMessageHandler` | — | Simpler | No reply channel → no way to surface decoder/handler errors back to JS. HUD-03 forbids. |

**Installation:**
- No new SPM dependencies — `packages/Bus` uses only Foundation + WebKit + existing `Logging`/`Config`.
- TS: `webview/package.json` with pnpm workspace; devDep `typescript@^5.5`, `vitest@^2` (for round-trip fixture runner — lighter than full Vite in P2).

**Version verification:**
```bash
# Pin at plan time
npm view typescript version   # expect 5.x
npm view vitest version        # expect 2.x
```

---

## System Architecture

```
Swift host process (Jarvis.app, @MainActor UI thread)
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│  packages/Bus                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Protocol.swift                                           │  │
│  │   BUS_PROTOCOL_VERSION: String = "2.0.0"                 │  │
│  │   enum BusOutbound: Codable { .hello, .hudState,         │  │
│  │     .tokenDelta, .audioLevel, .toolCallStart, ... }      │  │
│  │   enum BusInbound:  Codable { .helloAck, .uiReady, ... } │  │
│  │   struct BusReply: Codable { ok; value?; error? }        │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                        │
│  WebviewBridge.swift (@MainActor final class)                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  init(webView, messageHandlerName: "jarvisBus")          │  │
│  │   · installs `WKScriptMessageHandlerWithReply` in a      │  │
│  │     dedicated WKContentWorld ("JarvisBusWorld") to       │  │
│  │     avoid page-script clashes                            │  │
│  │   · kicks off handshake when `didFinish` nav fires       │  │
│  │   · `send(_ msg: BusOutbound) async` — JSONEncodes,      │  │
│  │     hops to main, `callAsyncJavaScript` primitive string │  │
│  │   · `onInbound: (BusInbound) async throws -> BusReply?`  │  │
│  │     — set by AppDelegate / P3 consumers                  │  │
│  └────┬──────────────────────────────────┬──────────────────┘  │
│       │                                  │                     │
│       ▼                                  ▼                     │
│  OutboundBatcher (actor)             Handshake state machine   │
│  ┌──────────────────────────────┐    ┌─────────────────────┐   │
│  │ latestAudio: Float? = nil    │    │ .idle               │   │
│  │ pendingTokens: [String] = [] │    │ .sentHello(at:Date) │   │
│  │ scheduled: Task?             │    │ .armed / .mismatch  │   │
│  │ post(_:) → enqueue           │    │ (2s timeout → alert)│   │
│  │ flushImmediate(_:) → cancel  │    └─────────────────────┘   │
│  │   pending → hop to bridge    │                              │
│  └──────────────────────────────┘                              │
└────────────────────┬───────────────────────────────────────────┘
                     │
         callAsyncJavaScript({payload: "<json>"}) / replyHandler
                     │
                     ▼
WKWebView (JavaScriptCore, com.apple.security.cs.allow-jit)
┌────────────────────────────────────────────────────────────────┐
│ webview/packages/bus/src/                                      │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ protocol.ts                                            │    │
│  │   export const BUS_PROTOCOL_VERSION = "2.0.0"          │    │
│  │   export type BusInbound = {type:"helloAck",…} | …     │    │
│  │   export type BusOutbound = {type:"hudState",…} | …    │    │
│  │   export const decodeOutbound: (s: string) => …        │    │
│  │   export const encodeInbound:  (m: BusInbound) => …    │    │
│  └────────────────────────────────────────────────────────┘    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ bridge.ts — thin glue exposed to page scripts          │    │
│  │   window.jarvisBus.send(msg) →                         │    │
│  │     webkit.messageHandlers.jarvisBus.postMessage(msg)  │    │
│  │                       .then(handleReply)               │    │
│  │   window.jarvisBus.onOutbound(handler) ← set by R3F    │    │
│  │   receive(jsonString) {                                │    │
│  │     const msg = decodeOutbound(jsonString)             │    │
│  │     handler?.(msg)                                     │    │
│  │   }                                                    │    │
│  └────────────────────────────────────────────────────────┘    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ fixtures/ — one JSON file per BusOutbound case         │    │
│  │  round-trip runner (vitest): parses each, re-stringifies│   │
│  │  asserts equivalence for cross-language parity         │    │
│  └────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────┘

Build-time parity (Xcode pre-build phase)
┌────────────────────────────────────────────────────────────────┐
│ scripts/check-bus-protocol-version.sh                          │
│  1. grep Swift constant   → SWIFT_VER                          │
│  2. grep TS constant      → TS_VER                             │
│  3. [[ SWIFT_VER == TS_VER ]] || fail                          │
│  4. pnpm --filter @jarvis/bus exec vitest run fixtures         │
│  5. on failure: print both versions + first failing fixture    │
└────────────────────────────────────────────────────────────────┘
```

---

## Technical Deep-Dive per Requirement

### HUD-03: `WKScriptMessageHandlerWithReply`

**Apple API (verified against developer.apple.com):**

```swift
public protocol WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    )
}
```

`replyHandler` semantics: pass `(value, nil)` for JS-side `Promise.resolve(value)`; pass `(nil, "err")` for `Promise.reject(new Error("err"))`. `value` must be plist-serializable (`NSNumber`, `NSString`, `NSArray`, `NSDictionary`, `NSNull`, nested). The classic Swift 6 strict-concurrency footgun (Apple DevForums 751086, filed FB13774556): the protocol is not `@MainActor`, `WKScriptMessage` is not `Sendable`, but `WKScriptMessage.body` must be read on main. Apple's recommended workaround is `MainActor.assumeIsolated { ... }` — Apple documents this as "last resort when it is not possible to express the current execution context definitely belongs to the main actor in other ways," which is precisely this case.

**Pattern sketch (Swift):**

```swift
@MainActor
final class WebviewBridge: NSObject {
    private let webView: WKWebView
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(label: JarvisLogChannel.bus.rawValue)
    var onInbound: (@MainActor (BusInbound) async throws -> BusReply?)?
    private(set) var handshakeState: HandshakeState = .idle

    // ... init installs handler in a dedicated content world ...
}

extension WebviewBridge: WKScriptMessageHandlerWithReply {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // Apple's documented workaround for Swift 6 strict concurrency —
        // the protocol can't be @MainActor but the body MUST be accessed on main.
        MainActor.assumeIsolated {
            guard let raw = message.body as? String else {
                replyHandler(nil, "bus: expected string payload")
                return
            }
            Task { @MainActor in
                do {
                    let inbound = try self.decoder.decode(
                        BusInbound.self, from: Data(raw.utf8)
                    )
                    // Handshake ack is handled inline to avoid callout to consumer
                    if case .helloAck(let version) = inbound {
                        self.handleHandshakeAck(version)
                        replyHandler(["ok": true], nil)
                        return
                    }
                    let reply = try await self.onInbound?(inbound)
                    replyHandler(self.encodeReply(reply), nil)
                } catch {
                    self.logger.error("inbound decode failed: \(error)")
                    replyHandler(nil, "bus: decode error: \(error)")
                }
            }
        }
    }

    private func encodeReply(_ reply: BusReply?) -> [String: Any] {
        // Reply is plist types — WebKit rejects arbitrary Codable
        guard let reply else { return ["ok": true] }
        if reply.ok {
            return ["ok": true, "value": reply.valueAsPlist ?? NSNull()]
        } else {
            return ["ok": false, "error": reply.error ?? "unknown"]
        }
    }
}
```

**Pattern sketch (JS):**

```ts
// webview/packages/bus/src/bridge.ts
type ReplyHandler<T = unknown> = { resolve(v: T): void; reject(e: Error): void };

async function send(msg: BusInbound): Promise<unknown> {
    const json = JSON.stringify(msg);
    // WebKit promise-returns when handler is WKScriptMessageHandlerWithReply
    return window.webkit.messageHandlers.jarvisBus.postMessage(json);
}
```

**Why no default branches:** Every inbound message handler (the `onInbound` closure in P3+) must switch over `BusInbound` exhaustively. Adding a case in the Swift enum → compile error in every switch site → can't land the change without updating every handler. This is the load-bearing drift preventer at the language level.

**Content world:** Install the handler in `WKContentWorld.world(name: "JarvisBusWorld")`, not `.defaultClient`. Prevents page-script (R3F and dependencies) from reading/intercepting our messages, and lets us inject our bridge stub without leaking globals onto `window`.

---

### HUD-04: `callAsyncJavaScript(arguments:)` with primitive payload

**Apple API signature (verified — WWDC20 session 10188 + docs):**

```swift
func callAsyncJavaScript(
    _ functionBody: String,
    arguments: [String: Any] = [:],
    in frame: WKFrameInfo? = nil,
    contentWorld: WKContentWorld,
    completionHandler: ((Result<Any?, Error>) -> Void)? = nil
)
// + async/await variant returning `Any?` throws
```

Keys in the `arguments` dictionary become JavaScript variables in the anonymous function wrapping `functionBody`. Values must be plist-serializable (`NSNumber`, `NSString`, `NSArray`, `NSDictionary`, `NSDate`). If `functionBody` returns a `Promise`, `completionHandler` fires on promise resolution — this is the "async" part. **Critical security property (per CodeQL swift-unsafe-js-eval):** arguments are passed by value, never concatenated into the function body, so untrusted JSON payloads cannot be evaluated as code.

**Pattern sketch (Swift):**

```swift
// In WebviewBridge (@MainActor)
func send(_ msg: BusOutbound) async throws {
    let data = try encoder.encode(msg)
    let json = String(decoding: data, as: UTF8.self)
    // Single primitive string argument; JS re-parses. NEVER interpolate.
    _ = try await webView.callAsyncJavaScript(
        """
        if (!window.jarvisBus || !window.jarvisBus.receive) {
            throw new Error("bus not mounted");
        }
        window.jarvisBus.receive(payload);
        """,
        arguments: ["payload": json],
        in: nil,
        contentWorld: .world(name: "JarvisBusWorld")
    )
}
```

**Pattern sketch (JS entrypoint, installed via WKUserScript at start of document):**

```ts
// Injected at document-start in the Jarvis content world
(function() {
    let handler: ((m: BusOutbound) => void) | null = null;
    window.jarvisBus = {
        receive(payload: string) {
            const msg = decodeOutbound(payload);   // discriminated-union parse
            if (!msg.ok) {
                console.error("bus decode failed:", msg.error);
                return;
            }
            handler?.(msg.value);
        },
        onOutbound(fn) { handler = fn; },
        send(inbound: BusInbound): Promise<unknown> {
            return window.webkit.messageHandlers.jarvisBus.postMessage(
                JSON.stringify(inbound)
            );
        },
    };
})();
```

**Lint rule (SEC-09 sibling):** ship `scripts/check-no-evaluate-javascript.sh` OR a custom SwiftLint rule that greps `App/**/*.swift` and `packages/**/*.swift` for `\.evaluateJavaScript\(` and fails the build if found outside `packages/Bus/Tests/` (tests may exercise the forbidden API for comparison). Wire as Xcode pre-build phase peer of `check-bus-protocol-version.sh`.

**Why no direct `evaluateJavaScript` calls:**
1. XSS via `</script>`, U+2028, U+2029 in untrusted content (tool results, user input).
2. No structured error channel — `evaluateJavaScript` returns strings, not typed replies.
3. No content-world isolation — page scripts can observe.
4. No promise-await — couldn't implement outbound waiting for a JS-side ack even if we wanted to.

**ThrowOnMissingBridge pattern:** The injected JS stub throws if `window.jarvisBus.receive` isn't wired. `callAsyncJavaScript` propagates the throw back as a Swift `Error`. Our `send(_:)` surfaces that as a `BusError.bridgeNotReady` and the `HudStateCoordinator` (P3) can log + retry once post-handshake. P2 scope: just propagate the error and log `.error`.

---

### HUD-05: Two-way `BUS_PROTOCOL_VERSION` handshake

**Failure mode (why we care):** the app ships with Swift bus at v2.0.0 and a stale webview bundle at v1.9.0. Schema shapes differ. Swift sends `{type: "hudState", state: "reconfiguring", ...}`; JS parser falls into a default branch it shouldn't have, logs a harmless `console.error`, keeps rendering the prior state. User sees frozen/wrong UI, can't file a useful bug report. Classic silent-drift disaster. HUD-05 prevents this by failing loud at load.

**Handshake protocol:**

```
T+0 (webView.load)
  Swift: WKNavigationDelegate.didFinish(navigation:)
  Swift: handshakeState = .sentHello(deadline: now + 2s)
  Swift: bridge.send(.hello(version: BUS_PROTOCOL_VERSION))
          via callAsyncJavaScript (outbound path, NOT batcher — flush immediate)

T+x (JS receives)
  JS: switch on msg.type === "hello":
       bridge.send({type: "helloAck", version: BUS_PROTOCOL_VERSION})

T+y (Swift receives)
  Swift: userContentController inbound path decodes BusInbound.helloAck(version)
  Swift: if version == BUS_PROTOCOL_VERSION:
           handshakeState = .armed
           onHandshakeArmed?()   // AppDelegate wires this to "let tokenDelta flow"
         else:
           handshakeState = .mismatched(swift: ours, js: theirs)
           presentHandshakeMismatchAlert(...)   // NSAlert .critical, modal
           webView.stopLoading()
           NSApp.terminate(nil)  // or — per planner taste — disable HUD summon

T+2s (if still not armed)
  Timer fires, handshakeState = .timedOut
  presentHandshakeTimeoutAlert(...)
  same termination path
```

**Alert shape (reuse `TCCAlertService` from P1):**

```swift
TCCAlertService.presentHardBlock(
    title: "Jarvis HUD couldn't start",
    informativeText: """
    The HUD bundle was built against a different bus protocol version \
    than the app. The app expects \(swiftVersion); the HUD reports \
    \(jsVersion). Please rebuild Jarvis from source.
    """
)
```

**Version string format:** `MAJOR.MINOR.PATCH`. P2 ships at `"2.0.0"` (bumping from the implicit v1 of the `WKScriptMessageHandler` era). Any structural schema change bumps `MAJOR`. Additive case adds bump `MINOR`. Fix/compat bumps `PATCH`. P2 scope enforces strict equality (major.minor.patch must all match); P3+ may relax to major-only if we need it. Strict-equality is the right default for a personal project with locked coupling.

**What the handshake does NOT cover:** message-shape drift *within* a version. A developer could forget to bump `BUS_PROTOCOL_VERSION` after adding a case. This is why `scripts/check-bus-protocol-version.sh` *also* runs the per-case round-trip fixture (SEC-09) — the handshake is the runtime net, the parity script is the build-time net.

**The "webview not loaded yet when we try to send hello" gotcha:** `callAsyncJavaScript` before the navigation completes fails with `WKError.javaScriptExceptionOccurred` because `window.jarvisBus` doesn't exist. Two fixes, and we do both:
1. Send hello from `WKNavigationDelegate.webView(_:didFinish:)` — guarantees the document is loaded.
2. Inject the `window.jarvisBus` stub via `WKUserScript` at `.atDocumentStart` — guarantees the receiver exists before any page script loads, no matter how slow the bundle.

---

### HUD-06: `OutboundBatcher` coalescing at ~30 Hz

**Which events coalesce:**

| Event | Coalesce? | Strategy |
|-------|-----------|----------|
| `audioLevel(rms: Float)` | YES | Latest value wins (volume is scalar; old values are obsolete) |
| `tokenDelta(text: String)` | YES | **Concat** — appended tokens within the window become a single `tokenDelta` of joined text |
| `hudState(HudState)` | NO | Flush immediately, cancel pending batched tokens first |
| `toolCallStart/End/Progress` | NO | Flush immediately |
| `turnStarted/Ended` | NO | Flush immediately |
| `voiceEvent(.reconfiguring*)` | NO | Flush immediately |
| `confirmationRequested/Resolved` | NO | Flush immediately |

The "flush immediately before a non-batchable event" rule is load-bearing: if we drop a `tokenDelta` because a state change beat it to the queue, the UI looks stuttery; if we preserve order by flushing first, every state change cleanly segments the visible token stream.

**Pattern sketch (Swift 6 actor):**

```swift
actor OutboundBatcher {
    private weak var bridge: WebviewBridge?
    private var latestAudio: Float? = nil
    private var pendingTokens: [String] = []
    private var scheduled: Task<Void, Never>? = nil
    private let window: Duration = .milliseconds(33) // ~30 Hz

    init(bridge: WebviewBridge) { self.bridge = bridge }

    func postAudio(_ rms: Float) {
        latestAudio = rms
        scheduleDrainIfNeeded()
    }

    func postToken(_ chunk: String) {
        pendingTokens.append(chunk)
        scheduleDrainIfNeeded()
    }

    /// Called for every state-transition event. Drains the batch, then sends
    /// the caller's message in-order. Exhaustive switch at the call site.
    func flushAndSend(_ msg: BusOutbound) async {
        scheduled?.cancel()
        scheduled = nil
        await drainLocked()
        await bridge?.sendRaw(msg)   // bypasses the batcher entirely
    }

    private func scheduleDrainIfNeeded() {
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            await self?.drainLocked()
            await self?.clearSchedule()
        }
    }

    private func drainLocked() async {
        if let audio = latestAudio {
            await bridge?.sendRaw(.audioLevel(rms: audio))
            latestAudio = nil
        }
        if !pendingTokens.isEmpty {
            let joined = pendingTokens.joined()
            pendingTokens.removeAll()
            await bridge?.sendRaw(.tokenDelta(text: joined))
        }
    }

    private func clearSchedule() { scheduled = nil }
}
```

**Why `actor` and not `@MainActor final class`:** the batcher's per-event bookkeeping doesn't need main-thread isolation, but the final JS call does. Keeping bookkeeping off the main actor reduces main-thread pressure during token storms. `bridge?.sendRaw(_:)` hops back to main for the actual `callAsyncJavaScript` call.

**Why `Task.sleep` and not `CADisplayLink`:** CADisplayLink is tied to display refresh (60 Hz minimum, 120 Hz ProMotion). We want a fixed 30 Hz regardless of display, and we don't want HUD rendering pressure to affect batching cadence. `Task.sleep(for: .milliseconds(33))` on a cooperative executor is exactly the right primitive.

**Why NOT `AsyncThrottleSequence`:** it's a beautiful combinator but doesn't give us a clean "cancel my throttle and send something else first" primitive. Our `flushAndSend` needs that. Hand-rolling is 40 LOC and matches our needs precisely.

**Test strategy (XCTest):**
1. Fake bridge records `sendRaw` calls with timestamps.
2. `postAudio(0.3)`, `postAudio(0.5)`, `postAudio(0.9)` in quick succession. After 50 ms, exactly one `sendRaw(.audioLevel(0.9))` should have been called.
3. `postToken("Hello, ")`, `postToken("world!")`. After 50 ms, exactly one `sendRaw(.tokenDelta("Hello, world!"))`.
4. `postToken("foo")` at T+0, `flushAndSend(.hudState(.speaking))` at T+10ms. Bridge sees `.tokenDelta("foo")` *then* `.hudState(.speaking)` — order preserved, single `sendRaw` per distinct message.
5. Ten `postAudio` calls within 33 ms followed by ten more within the next 33 ms → exactly two `.audioLevel` sends, values are the tenth-and-twentieth.

---

### SEC-09: `scripts/check-bus-protocol-version.sh` + discriminator discipline

**Script shape (bash, ~50 lines):**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_FILE="$REPO/packages/Bus/Sources/Bus/Protocol.swift"
TS_FILE="$REPO/webview/packages/bus/src/protocol.ts"

# 1. Grep Swift constant
SWIFT_VER=$(grep -E '^[[:space:]]*public let BUS_PROTOCOL_VERSION[[:space:]]*=' "$SWIFT_FILE" \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -n1)
[[ -z "$SWIFT_VER" ]] && { echo "FAIL: BUS_PROTOCOL_VERSION not found in $SWIFT_FILE"; exit 1; }

# 2. Grep TS constant
TS_VER=$(grep -E '^export const BUS_PROTOCOL_VERSION[[:space:]]*=' "$TS_FILE" \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -n1)
[[ -z "$TS_VER" ]] && { echo "FAIL: BUS_PROTOCOL_VERSION not found in $TS_FILE"; exit 1; }

# 3. Require strict equality
if [[ "$SWIFT_VER" != "$TS_VER" ]]; then
    cat >&2 <<EOF
FAIL: BUS_PROTOCOL_VERSION mismatch
  Swift ($SWIFT_FILE): $SWIFT_VER
  TS    ($TS_FILE):    $TS_VER
Bump both to the same value before building.
EOF
    exit 1
fi

# 4. Round-trip fixture runner (Node via pnpm + vitest)
cd "$REPO/webview"
pnpm --filter @jarvis/bus exec vitest run fixtures --reporter=dot

echo "bus parity OK at v$SWIFT_VER"
```

**Fixture shape (`webview/packages/bus/fixtures/`):**

One `.json` file per `BusOutbound` case, *authored by hand in TS type-check mode*:

```
fixtures/
├── hello.json                        {"type":"hello","version":"2.0.0"}
├── helloAck.json                     {"type":"helloAck","version":"2.0.0"}
├── hudState.idle.json
├── hudState.listening.json
├── hudState.thinking.json
├── hudState.speaking.json
├── hudState.awaitingConfirmation.json
├── hudState.reconfiguring.json
├── hudState.booting.json
├── tokenDelta.json
├── audioLevel.json
├── toolCallStart.json
├── toolCallEnd.json
├── turnStarted.json
└── turnEnded.json
```

Round-trip test (`fixtures/round-trip.test.ts`, run via vitest):

```ts
import { describe, it, expect } from "vitest";
import { decodeOutbound, encodeInbound, BUS_PROTOCOL_VERSION } from "../src/protocol";
import fixtures from "./*.json";     // glob import

describe("BusOutbound round-trip", () => {
    for (const [name, json] of Object.entries(fixtures)) {
        it(`parses + re-encodes ${name}`, () => {
            const parsed = decodeOutbound(JSON.stringify(json));
            expect(parsed.ok).toBe(true);
            const reEncoded = JSON.parse(JSON.stringify(parsed.value));
            expect(reEncoded).toEqual(json);
        });
    }
});
```

**Swift-side counterpart:** An XCTest in `packages/Bus/Tests/BusTests/` decodes each fixture (loaded as a bundle resource from a copied `fixtures/` directory — cheap copy in the Swift build phase) into `BusOutbound`, re-encodes, asserts byte equality modulo key ordering. This covers the *Swift* side of the round-trip; the TS side covers the *TS* side; the parity script asserts the constant matches. All three must pass for the pre-build phase to succeed.

**Hand-written `Codable` (the load-bearing pattern):**

```swift
// packages/Bus/Sources/Bus/Protocol.swift

public let BUS_PROTOCOL_VERSION: String = "2.0.0"

public enum BusOutbound: Equatable, Sendable {
    case hello(version: String)
    case hudState(HudState)
    case tokenDelta(text: String)
    case audioLevel(rms: Float)
    case toolCallStart(id: UUID, name: String, argsPreview: String)
    case toolCallEnd(id: UUID, ok: Bool, previewOrError: String)
    case turnStarted(id: UUID)
    case turnEnded(id: UUID, terminator: TurnTerminator)
}

extension BusOutbound: Codable {
    private enum Discriminator: String, Codable {
        case hello, hudState, tokenDelta, audioLevel
        case toolCallStart, toolCallEnd, turnStarted, turnEnded
    }
    private enum CodingKeys: String, CodingKey {
        case type, version, state, text, rms, id, name, argsPreview
        case ok, previewOrError, terminator
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Discriminator.self, forKey: .type)
        switch tag {
        case .hello:
            self = .hello(version: try c.decode(String.self, forKey: .version))
        case .hudState:
            self = .hudState(try c.decode(HudState.self, forKey: .state))
        case .tokenDelta:
            self = .tokenDelta(text: try c.decode(String.self, forKey: .text))
        case .audioLevel:
            self = .audioLevel(rms: try c.decode(Float.self, forKey: .rms))
        case .toolCallStart:
            self = .toolCallStart(
                id: try c.decode(UUID.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                argsPreview: try c.decode(String.self, forKey: .argsPreview)
            )
        case .toolCallEnd:
            self = .toolCallEnd(
                id: try c.decode(UUID.self, forKey: .id),
                ok: try c.decode(Bool.self, forKey: .ok),
                previewOrError: try c.decode(String.self, forKey: .previewOrError)
            )
        case .turnStarted:
            self = .turnStarted(id: try c.decode(UUID.self, forKey: .id))
        case .turnEnded:
            self = .turnEnded(
                id: try c.decode(UUID.self, forKey: .id),
                terminator: try c.decode(TurnTerminator.self, forKey: .terminator)
            )
        }
        // Exhaustive: compiler errors if any case is missed here.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v):
            try c.encode(Discriminator.hello, forKey: .type)
            try c.encode(v, forKey: .version)
        case .hudState(let s):
            try c.encode(Discriminator.hudState, forKey: .type)
            try c.encode(s, forKey: .state)
        // ... one arm per case ...
        }
        // Exhaustive at encode site, too.
    }
}
```

**TS mirror:**

```ts
// webview/packages/bus/src/protocol.ts
export const BUS_PROTOCOL_VERSION = "2.0.0";

export type HudState =
    | "idle" | "listening" | "thinking" | "speaking"
    | "awaitingConfirmation" | "reconfiguring" | "booting";

export type BusOutbound =
    | { type: "hello"; version: string }
    | { type: "hudState"; state: HudState }
    | { type: "tokenDelta"; text: string }
    | { type: "audioLevel"; rms: number }
    | { type: "toolCallStart"; id: string; name: string; argsPreview: string }
    | { type: "toolCallEnd"; id: string; ok: boolean; previewOrError: string }
    | { type: "turnStarted"; id: string }
    | { type: "turnEnded"; id: string; terminator: TurnTerminator };

export function decodeOutbound(s: string): { ok: true; value: BusOutbound } | { ok: false; error: string } {
    try {
        const parsed = JSON.parse(s);
        if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) {
            return { ok: false, error: "missing discriminator" };
        }
        // TS narrowing on parsed.type — exhaustive switch
        switch (parsed.type) {
            case "hello":     return { ok: true, value: { type: "hello", version: parsed.version }};
            case "hudState":  return { ok: true, value: { type: "hudState", state: parsed.state }};
            case "tokenDelta": return { ok: true, value: { type: "tokenDelta", text: parsed.text }};
            case "audioLevel": return { ok: true, value: { type: "audioLevel", rms: parsed.rms }};
            case "toolCallStart": return { ok: true, value: { /*…*/ } as any };
            case "toolCallEnd":   return { ok: true, value: { /*…*/ } as any };
            case "turnStarted":   return { ok: true, value: { /*…*/ } as any };
            case "turnEnded":     return { ok: true, value: { /*…*/ } as any };
            default:
                // Unreachable if types agree — tsc --strict catches drift at compile time
                const _exhaustive: never = parsed.type;
                return { ok: false, error: `unknown type: ${parsed.type}` };
        }
    } catch (e) {
        return { ok: false, error: String(e) };
    }
}
```

Note: TS is not truly exhaustive at runtime the way Swift is at compile time (a JS value can have any `type` string), but the `never` branch + `tsc --strict` compile-time check is the best TS offers and is enough because runtime mismatches surface as `ok: false` and route to the inbound error path.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Bi-directional bus transport | Websocket over localhost, custom IPC | `WKScriptMessageHandlerWithReply` + `callAsyncJavaScript` | Apple-supplied, content-world-isolated, process-sandboxed; a localhost socket adds a port + codesign exception + firewall surface |
| JSON serialization | Manual `String(data:)` construction | `JSONEncoder`/`JSONDecoder` with hand-written `Codable` | Foundation handles UTF-8, numeric formatting, escape sequences |
| Throttling | Manual `DispatchQueue.main.asyncAfter` chains | `actor` + `Task.sleep` | Swift 6 cancellation + structured concurrency; `DispatchWorkItem` cancellation is error-prone |
| Content-script injection | Global `window.xxx` assignment | `WKUserScript` at `.atDocumentStart` in dedicated content world | Isolates from page scripts; survives SPA navigation |
| Version check | Ad-hoc one-way probes | Two-way handshake with timeout + NSAlert | One-way checks give us `console.error` in the webview nobody sees |
| TS type generation | Sourcery / swift-openapi-generator for 10 types | Hand-write + parity script | Generators cost toolchain complexity; parity script + round-trip covers drift at our scale |
| JS-side error handling | `try/catch` sprinkled through page code | Every bridge.send returns a Promise; handlers are single-source in `bus/src/bridge.ts` | One error boundary, one place to log |

**Key insight:** the bus is the narrowest waist of the architecture. Every piece of UI truth flows through it. Hand-writing small, exhaustive, well-tested primitives here pays back more than in any other part of the codebase.

---

## Common Pitfalls

### Pitfall 1: Synthesized `Codable` produces wrong wire shape

**What goes wrong:** developer adds a new case to `BusOutbound`, forgets to extend the hand-written `Codable`, Xcode uses synthesized conformance silently. Encoded shape becomes `{"newCase": {...}}` instead of `{"type": "newCase", ...}`. TS parser falls into error path.
**Why it happens:** SE-0295 gives every Swift 5.5+ enum-with-associated-values free `Codable` synthesis; if you write your own extension but miss a case, Swift emits the synthesized version for the missing arm alongside yours — it doesn't "replace" anything, it fills gaps.
**How to avoid:** `public enum BusOutbound` has NO inline `: Codable` conformance. Conformance is added *only* in the extension, where exhaustive `switch self` forces errors. Double-guard with the round-trip fixture per case.
**Warning signs:** A JS console.error about "unknown type: <newCase>" that coincides with a recent Swift change.

### Pitfall 2: `WKScriptMessage.body` on wrong thread

**What goes wrong:** attempting to read `.body` from an `actor` method or a `Task.detached` hits a strict-concurrency warning (Swift 5.x) or error (Swift 6), or worse, crashes in some WebKit builds with an NSInternalInconsistencyException.
**Why it happens:** `WKScriptMessageHandlerWithReply` is not declared `@MainActor`; `WKScriptMessage` is not `Sendable`; `body` is documented as main-thread-only.
**How to avoid:** `MainActor.assumeIsolated { ... }` inside the `nonisolated` protocol method, read `.body` as `String` once, then hop to `Task { @MainActor }` for decode + dispatch. Pattern in § HUD-03 above.
**Warning signs:** Swift 6 compile errors referencing `Sendable` or `MainActor`; runtime crash with `NSInternalInconsistencyException: WKScriptMessage body accessed from a non-main thread`.

### Pitfall 3: Outbound before webview loaded

**What goes wrong:** Swift-side logic kicks off `.audioLevel` streaming (e.g., from voice pipeline during a race) before the webview has loaded the bundle; `callAsyncJavaScript` throws because `window.jarvisBus.receive` doesn't exist; error bubbles up; streams get torn down.
**Why it happens:** AppDelegate + WebviewBridge init sequence is naturally racy — nothing forces "bus armed" as a precondition.
**How to avoid:** gate all outbound on `handshakeState == .armed`. `OutboundBatcher` holds outbound messages pre-arm in a bounded buffer (drop-oldest `audioLevel`/`tokenDelta` if buffer exceeds 128; never drop state transitions). On arm, drain in-order. This matches the R3-A5 startup-barrier pattern from ARCHITECTURE.md.
**Warning signs:** "bus not mounted" errors in system log at first launch; first few seconds of voice activity don't render.

### Pitfall 4: Content-world leak

**What goes wrong:** we install `WKScriptMessageHandlerWithReply` in `.defaultClient`; the R3F bundle (or its hundreds of dependencies) happens to poke at `webkit.messageHandlers.jarvisBus`; messages get sent that we never intended; replies expose internals.
**Why it happens:** default content world is shared with all page scripts. Third-party JS can intercept.
**How to avoid:** install handler and `WKUserScript` bridge stub both in `WKContentWorld.world(name: "JarvisBusWorld")`. Page scripts cannot access this world directly.
**Warning signs:** replay log shows messages originating from WKFrameInfo other than our injected frame.

### Pitfall 5: NSAlert presentation during handshake mismatch deadlocks

**What goes wrong:** `NSAlert().runModal()` on main during `didFinishNavigation` parks the main actor; webview can't stop loading cleanly; hangs.
**Why it happens:** modal alerts spin a nested event loop; async Task wanting `@MainActor` is blocked.
**How to avoid:** reuse the P1 `TCCAlertService.presentHardBlock(...)` pattern which the planning docs already bless. If a blocking modal is the right UX, hop to a detached Task and `NSApp.terminate(nil)` after the alert returns — don't try to resume webview operations afterwards.
**Warning signs:** Xcode "Main thread checker" warnings; beachball on handshake-mismatch test.

### Pitfall 6: Swift `UUID` ↔ TS `string` silent coercion

**What goes wrong:** Swift encodes `UUID` as `"550E8400-E29B-41D4-A716-446655440000"` (uppercase by default); TS treats it as opaque string; fine… until someone compares two of them with `===`, one having been round-tripped through a regex or lowercased. Cross-language ID comparisons silently fail.
**Why it happens:** `JSONEncoder().dateEncodingStrategy` has attention, `.uuidEncodingStrategy` does too but isn't obvious.
**How to avoid:** explicit `JSONEncoder` config in `packages/Bus`: `encoder.outputFormatting = []`, UUIDs always lowercase via a custom `encode(to:)` that emits `.uuidString.lowercased()`. Document the convention. TS side: treat as opaque `type UUIDString = string & { __brand: "UUIDString" }` branded type so cross-use is surfaced at compile time.
**Warning signs:** tool-call replies mismatching their start events; flaky "why didn't my turn terminate" bugs.

### Pitfall 7: Forgetting to bump version

**What goes wrong:** developer adds `.toolCallProgress` case to `BusOutbound`, updates Swift + TS types, forgets to bump `BUS_PROTOCOL_VERSION`. Round-trip fixtures pass because they were added in the same change. Handshake passes because constants match. No drift detection.
**Why it happens:** version bump is a separate human judgement; not enforced by type system.
**How to avoid:** the round-trip fixture runner iterates over every case in the Swift enum (reflection via `Mirror` + CaseIterable-style pattern, or a code-generated `allCases` for non-associated-value enums; for associated values, the fixture file list MUST cover every case — the runner counts fixtures vs. a `Bus.caseCount` constant the Swift test exposes). A case without a fixture is a build-time failure. Bumping `BUS_PROTOCOL_VERSION` is then a convention + changelog discipline; P2 can't mechanically force it. (Acceptable — the parity script + round-trip covers the actual wire-shape risk; version is belt-and-suspenders for runtime.)
**Warning signs:** handshake mismatches in production after a rebuild; round-trip fixtures green but smoke tests fail.

---

## Recommended Package Decomposition

**Answer:** new top-level local SPM package `packages/Bus` + new paired TS workspace package `webview/packages/bus` + one shell script.

```
Jarvis/
├── packages/
│   ├── Bus/                                 ← NEW (P2)
│   │   ├── Package.swift                    Swift 6, macOS 13+, deps: Logging, Config
│   │   ├── Sources/Bus/
│   │   │   ├── Protocol.swift               BUS_PROTOCOL_VERSION + enums + Codable
│   │   │   ├── BusInbound.swift             Inbound enum + Codable
│   │   │   ├── BusOutbound.swift            Outbound enum + Codable
│   │   │   ├── WebviewBridge.swift          @MainActor; WKScriptMessageHandlerWithReply
│   │   │   ├── OutboundBatcher.swift        actor; ~30 Hz coalescer
│   │   │   ├── Handshake.swift              state machine + NSAlert
│   │   │   └── BusError.swift
│   │   └── Tests/BusTests/
│   │       ├── CodableRoundTripTests.swift  one test per case vs JSON fixture
│   │       ├── BatcherTests.swift           cadence + flush-bypass semantics
│   │       ├── HandshakeTests.swift         success + timeout + mismatch paths
│   │       └── Fixtures/                    copies webview/packages/bus/fixtures
│   ├── Keychain/        (P1, unchanged)
│   ├── Config/          (P1, unchanged)
│   ├── Logging/         (P1; consider adding "bus" channel)
│   └── Shell/           (P1, unchanged)
├── webview/                                 ← NEW DIRECTORY (P2 first content)
│   ├── package.json                         pnpm workspace root
│   ├── pnpm-workspace.yaml
│   ├── packages/
│   │   └── bus/
│   │       ├── package.json                 "@jarvis/bus"
│   │       ├── tsconfig.json                strict: true; target ES2022
│   │       ├── src/
│   │       │   ├── protocol.ts              mirror of Swift Protocol.swift
│   │       │   ├── bridge.ts                window.jarvisBus glue
│   │       │   └── index.ts                 re-exports
│   │       └── fixtures/
│   │           ├── hello.json ... (one per case)
│   │           └── round-trip.test.ts       vitest runner
│   └── bus-harness.html                     minimal HTML for Swift-side bridge tests
├── scripts/
│   ├── check-bus-protocol-version.sh        ← NEW; Xcode pre-build phase
│   └── check-no-evaluate-javascript.sh      ← NEW; lint guard for HUD-04
├── project.yml                              adds Bus package dep; adds pre-build phase
└── App/
    └── AppDelegate.swift                    Phase-2 wiring: create WebviewBridge,
                                             wire onInbound closure, gate HUD summon
                                             on handshakeArmed (P3 will replace this
                                             shim with HudStateCoordinator integration)
```

**Rationale:**
- `packages/Bus` is the natural home — peer to `Keychain/Config/Logging/Shell`, per D-01 "add only as phases land."
- `webview/` is new top-level — CLAUDE.md and source-material both describe this directory; P2 is its first content.
- pnpm workspace because R3F ecosystem in P3 needs it and we might as well use it from day one.
- Tests on both sides; fixtures as the shared contract committed to git (single source of truth for on-wire JSON).

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework (Swift) | XCTest (same as P1 `JarvisAppTests`) |
| Framework (TS) | Vitest 2.x (lighter than Vite's full test runner) |
| Swift config file | inherit from `packages/Bus/Package.swift` testTarget |
| TS config file | `webview/packages/bus/vitest.config.ts` |
| Quick run (Swift) | `xcodebuild test -project Jarvis.xcodeproj -scheme Jarvis -only-testing:BusTests` |
| Quick run (TS) | `pnpm --filter @jarvis/bus exec vitest run` |
| Full suite | `xcodebuild test` + `pnpm -r test` |

### Phase Requirements → Test Map

| Req | Behavior | Test Type | Command | Exists? |
|-----|----------|-----------|---------|---------|
| HUD-03 | Inbound handler decodes + replies with Result | unit (Swift) | `-only-testing:BusTests/WebviewBridgeTests/test_inboundReplyResultShape` | Wave 0 |
| HUD-03 | Decoder error surfaces as reply `failure(error)` | unit | `.../test_inboundDecodeFailureSurfacesAsFailureReply` | Wave 0 |
| HUD-04 | Outbound uses `callAsyncJavaScript`; zero `evaluateJavaScript` in codebase | lint/grep | `scripts/check-no-evaluate-javascript.sh` | Wave 0 |
| HUD-04 | JSON payload round-trips through primitive-string arg | unit | `.../test_outboundPayloadIsPrimitiveStringArg` | Wave 0 |
| HUD-05 | Matching versions → handshake armed | unit | `.../test_handshakeArmsOnMatchingVersions` | Wave 0 |
| HUD-05 | Mismatched version → NSAlert invoked + bridge never armed | unit (with mock alert) | `.../test_handshakeMismatchTriggersAlertAndBlocks` | Wave 0 |
| HUD-05 | Timeout → NSAlert invoked | unit | `.../test_handshakeTimeoutTriggersAlert` | Wave 0 |
| HUD-06 | Token stream coalesces to one send per ~33ms window | unit | `.../test_tokenStreamCoalesces` | Wave 0 |
| HUD-06 | State transition flushes pending tokens before sending state | unit | `.../test_stateTransitionFlushesPendingFirst` | Wave 0 |
| HUD-06 | `audioLevel` latest-wins | unit | `.../test_audioLevelLatestWins` | Wave 0 |
| SEC-09 | Script fails on constant mismatch | shell | `scripts/check-bus-protocol-version.sh` (run with intentionally mismatched files in CI test harness) | Wave 0 |
| SEC-09 | Round-trip fixture per case Swift | unit | `BusTests/CodableRoundTripTests` (one test method per case) | Wave 0 |
| SEC-09 | Round-trip fixture per case TS | vitest | `webview/packages/bus/fixtures/round-trip.test.ts` | Wave 0 |
| SEC-09 | Exhaustive switch compile error on added case | compile-time | test by deliberately adding a case in a feature branch — removed before merge | Manual smoke |

### Sampling Rate

- **Per task commit:** `xcodebuild -only-testing:BusTests` + `pnpm --filter @jarvis/bus exec vitest run`
- **Per wave merge:** above + `scripts/check-bus-protocol-version.sh` + `scripts/check-no-evaluate-javascript.sh`
- **Phase gate:** full suite green; parity script passes; manual Release-archive smoke (empty HUD loads, handshake handshakes, state transitions propagate)

### Wave 0 Gaps

- [ ] `packages/Bus/Tests/BusTests/CodableRoundTripTests.swift` — fixture-per-case Codable
- [ ] `packages/Bus/Tests/BusTests/WebviewBridgeTests.swift` — inbound + outbound
- [ ] `packages/Bus/Tests/BusTests/BatcherTests.swift` — cadence + flush
- [ ] `packages/Bus/Tests/BusTests/HandshakeTests.swift` — success/mismatch/timeout
- [ ] `webview/packages/bus/fixtures/round-trip.test.ts` — vitest fixture runner
- [ ] `webview/packages/bus/fixtures/*.json` — one per case
- [ ] `scripts/check-bus-protocol-version.sh` — pre-build script
- [ ] `scripts/check-no-evaluate-javascript.sh` — lint script
- [ ] `project.yml` updates — Bus package dep + pre-build phase registration
- [ ] Framework install: `pnpm init`, `pnpm add -Dw typescript vitest` (Wave 0)

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Not a network boundary |
| V3 Session Management | no | Single-process bridge |
| V4 Access Control | yes | Content-world isolation (`WKContentWorld.world(name:)`) prevents page-script interception |
| V5 Input Validation | yes | Every inbound JSON validated by strict `Codable` decode with exhaustive discriminator; failures return `BusError` not UB |
| V6 Cryptography | no | Bus carries no secrets; Keychain lives outside |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| JS injection via `evaluateJavaScript` interpolation | Tampering | `callAsyncJavaScript(arguments:)` with primitive string — never concatenate (HUD-04, CodeQL swift-unsafe-js-eval) |
| `</script>`, U+2028, U+2029 XSS | Tampering | Not possible with `callAsyncJavaScript` — values are parameters, not code (confirmed by pattern above) |
| Page-script bus hijack | Information Disclosure | Dedicated `WKContentWorld` isolates handler from page scripts |
| `turnNonce` leak to webview | Information Disclosure | P4 concern (nonce never enters Bus payloads); P2 discipline: no `nonce` field exists in any `BusOutbound` case (enforced by schema review) |
| API key in webview JS heap | Information Disclosure | P1-enforced (Keychain-only); P2 discipline: no `apiKey`-shaped field in any `BusInbound`/`BusOutbound` (schema review) |
| Schema drift producing UB on decode | Tampering (accidental) | Hand-written `Codable` + exhaustive switches + pre-build parity script (SEC-09) |
| Replay attack of inbound messages | Tampering | Not in threat model (single-user local); out of scope |

### Untrusted content:

**Tool results** and **user text** flow THROUGH the bus but are never evaluated as code thanks to primitive-string argument discipline. The P4 sanitize pipeline (SEC-07) runs before bus packing; P2 just ensures we don't undo it with interpolation. Schema shapes for untrusted content are plain `String` fields — the UI renders them as text nodes, never innerHTML.

---

## Sources

### Primary (HIGH confidence)

- [WKScriptMessageHandlerWithReply — Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply) — protocol signature, reply semantics
- [userContentController(_:didReceive:replyHandler:) — Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply/usercontentcontroller(_:didreceive:replyhandler:)) — `(Any?, String?) -> Void` reply shape
- [WKScriptMessageHandlerWithReply + Strict Concurrency — Apple Developer Forums 751086](https://developer.apple.com/forums/thread/751086) — `MainActor.assumeIsolated` workaround for Swift 6, `WKScriptMessage` not `Sendable`, filed FB13774556
- [callAsyncJavaScript — Apple Developer Documentation](https://developer.apple.com/documentation/webkit/wkwebview/3656441-callasyncjavascript) — primitive arguments dictionary, promise semantics
- [CodeQL swift-unsafe-js-eval — JavaScript Injection](https://codeql.github.com/codeql-query-help/swift/swift-unsafe-js-eval/) — security rationale for `callAsyncJavaScript` + `arguments:` over string interpolation
- [SE-0295: Codable synthesis for enums with associated values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0295-codable-synthesis-for-enums-with-associated-values.md) — why synthesized shape differs from `{type:…}` wire format
- [swift-async-algorithms Throttle.md](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Throttle.md) — alternative throttle primitive considered (and rejected for P2 in favor of hand-rolled actor)
- [.planning/research/ARCHITECTURE.md](/Users/james.maes/Git.Local/Kof22/Jarvis/.planning/research/ARCHITECTURE.md) — converged top-level decisions for the bus (two-way handshake, content world, hand-written Codable, OutboundBatcher)
- [.planning/research/PITFALLS.md §13, §15](/Users/james.maes/Git.Local/Kof22/Jarvis/.planning/research/PITFALLS.md) — schema drift as R4's dominant failure mode; lint-level `evaluateJavaScript` ban
- [CLAUDE.md "Architecture (settled)" + WKWebView+allow-jit discussion](/Users/james.maes/Git.Local/Kof22/Jarvis/CLAUDE.md) — Hardened Runtime JIT + architectural locked-in decisions

### Secondary (MEDIUM confidence)

- [Will Townsend — Codable Enums in Swift](https://will.townsend.io/2019/codable-enums-in-swift) — hand-written `Codable` pattern with discriminator (verified against SE-0295)
- [iOS 14: What is new for WKWebView — Filip Němeček](https://nemecek.be/blog/32/ios-14-what-is-new-for-wkwebview) — `callAsyncJavaScript` argument-as-variable binding behavior
- [Discover WKWebView enhancements — WWDC20 Session 10188](https://developer.apple.com/videos/play/wwdc2020/10188/) — original introduction of `WKScriptMessageHandlerWithReply` + `callAsyncJavaScript`
- [TauRPC — Rust ↔ TypeScript typed IPC](https://lib.rs/crates/taurpc) — alternative ecosystem reference (explicitly rejected for P2 scale)

### Tertiary (LOW confidence, flagged for validation)

- Exact Xcode "pre-build phase" invocation semantics — confirm at plan time whether `scripts/check-bus-protocol-version.sh` runs before OR after `Compile Sources` (we want before; verify it executes before `swiftc` picks up the constant so the constant check is meaningful; alternatively run as a plain "Run Script" as the first build phase which guarantees ordering)

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `callAsyncJavaScript` accepts a single `String` value under an `arguments` key and JS sees `payload` as a bare variable in the function body (not a property) | HUD-04 deep-dive | Low — WWDC20 session + multiple examples confirm; verify at plan time with a hello-world test |
| A2 | `WKScriptMessageHandlerWithReply` replies synchronously from the `replyHandler` callback (not via return) | HUD-03 deep-dive | Low — Apple docs explicitly describe callback + ergonomic async variant; verified |
| A3 | 33 ms (≈30 Hz) window is appropriate for R3F ring reactivity; user won't perceive delay in token stream | HUD-06 deep-dive | Medium — 30 Hz matches CLAUDE.md; actual perceptual validation deferred to P3; if 30 Hz feels laggy in P3, shift to 60 Hz with zero other changes |
| A4 | pnpm + vitest are the right TS toolchain pins for P2; Vite proper is a P3 concern | Package decomposition | Low — matches research/SUMMARY.md stack; vitest uses Vite internals so decision is compatible |
| A5 | The `WKContentWorld.world(name:)` pattern is stable as of macOS 26 Tahoe and not deprecated | System architecture + Pitfall 4 | Low — introduced iOS 14 / macOS 11, still current in 2026 docs; verify at plan |
| A6 | A `bus` log channel separate from `ui` is worth adding (OBS-06 said four channels, we want five) | Discretion — logging | Low — adding a channel is mechanical; if reviewed and rejected, fold into `ui` |
| A7 | Strict-equality version comparison (major.minor.patch) is right for a personal-project single-user codebase | HUD-05 deep-dive | Low — no backward-compat scenarios exist; relaxing later is trivial |
| A8 | Hand-rolled `actor + Task.sleep` batcher is more maintainable than `AsyncThrottleSequence` for our specific cancel-and-bypass needs | HUD-06 | Low — 40 LOC; if planner disagrees, swap is self-contained in one file |

**All A1-A8 are implementation-detail bets, not requirements bets.** If any is wrong, the fix is contained within `packages/Bus` and doesn't ripple.

---

## Open Questions for the Planner

1. **Is P2's webview content a static HTML stub, or does P2 deliver a real Vite-built bundle?**
   - What we know: P3 loads R3F (HUD-01); P2 requirements don't specify the webview contents
   - What's unclear: whether P2 should stand up a minimal Vite+TS project or just a single `bus-harness.html` that loads `bus/src/bridge.ts` via a `<script type="module">`
   - Recommendation: **static bus-harness.html + bus.ts compiled to single .js file** — minimal surface, exercises the handshake + a synthetic state transition, P3 replaces with the real React bundle. Avoids pulling Vite forward.

2. **Hot-reload for Dev builds — in scope or deferred?**
   - What we know: requirements don't mention it; P3 will need some dev-loop story (pnpm dev → watch)
   - What's unclear: whether P2 should wire `WKURLSchemeHandler` for `jarvis://` to serve from a local dev server, or rely on file:// loads + full rebuilds
   - Recommendation: **defer** — P2 uses `loadFileURL(_:allowingReadAccessTo:)` with the bundle copy of the compiled stub; P3 makes the dev-loop decision with full context

3. **Should `BUS_PROTOCOL_VERSION` mismatch terminate the app or disable the HUD?**
   - What we know: HUD-05 says refuse to load the webview; doesn't specify app lifecycle
   - What's unclear: a personal assistant has no menu-bar-only mode; if the HUD is dead, the app is mostly dead
   - Recommendation: **terminate** via `NSApp.terminate(nil)` after alert acknowledgement. Consistent with the P1 `TCCAlertService.presentHardBlock` pattern. Keeps state simple.

4. **Does `WebviewBridge` own the `WKWebView`, or does the existing `JarvisHUDPanel` expose it?**
   - What we know: `JarvisHUDPanel` currently keeps `webView` private
   - What's unclear: passing a `WKWebView` reference into `WebviewBridge(webView:)` is clean, but requires `JarvisHUDPanel` to expose it
   - Recommendation: **lift the webView to a `public` (or `internal` to App target) property on `JarvisHUDPanel`**, and construct `WebviewBridge` at AppDelegate bootstrap time passing `panel.webView`. Avoid giving `packages/Bus` knowledge of `JarvisHUDPanel` (which would invert the dep graph).

5. **Where does the webview actually get content loaded?**
   - What we know: P1 left `webView` with no content; HUD-05 says handshake runs at webview load
   - What's unclear: AppDelegate doesn't currently call `webView.loadFileURL` anywhere
   - Recommendation: **AppDelegate adds `panel.webView.loadFileURL(bundleStubURL, allowingReadAccessTo: bundleStubDir)` during `installHUDPanel()` AFTER the WebviewBridge is constructed**. The bus-harness HTML is vendored into `App/Resources/webview/` as part of the P2 scaffold (or, better, copied from `webview/dist/` via a post-build script when `pnpm build` runs).

6. **`WKScriptMessageHandlerWithReply` in macOS 13 baseline?**
   - What we know: `WKScriptMessageHandlerWithReply` is iOS 14+ / macOS 11+; project deployment target is macOS 13 (confirmed in `project.yml`)
   - What's unclear: nothing — macOS 13 is ≥ macOS 11, so the API is available
   - Recommendation: confirmed compatible; proceed

7. **Do we need a separate `bus` log channel, or fold into `ui`?**
   - What we know: OBS-06 lists four channels (agent/tools/ui/system); adding a fifth is mechanical
   - What's unclear: aesthetic preference + replay clarity
   - Recommendation: **add `bus` as a fifth channel** — it's OBS-06's letter, but the *spirit* is "structured logs for every major surface," and the bus is major enough. Document the addition in P2 SUMMARY so OBS-06 traceability notes the expansion.

---

## Metadata

**Confidence breakdown:**
- WebKit API surface (`WKScriptMessageHandlerWithReply`, `callAsyncJavaScript`) — HIGH, verified Apple Docs + WWDC
- Swift 6 `MainActor.assumeIsolated` pattern for the bridge — HIGH, verified Apple DevForums 751086 thread
- Hand-written `Codable` discriminator pattern — HIGH, verified SE-0295 + community examples
- `OutboundBatcher` primitive choice (`actor + Task.sleep` vs alternatives) — MEDIUM, defensible but three valid patterns exist
- Handshake protocol shape — HIGH, simple and symmetric; the hard part is discipline not novelty
- `check-bus-protocol-version.sh` script shape — HIGH, reading prior `scripts/` in repo (verify-entitlements.sh pattern is the template)
- TS-side tooling pins (pnpm + vitest + TS 5.5+) — MEDIUM, matches research/SUMMARY.md but P3 will re-verify with full stack

**Research date:** 2026-04-22
**Valid until:** 2026-05-22 (30 days — WebKit API is stable; Swift 6 strict-concurrency workaround may shift if Apple fixes FB13774556 before then, but the fallback is just "remove `MainActor.assumeIsolated` and let the compiler do the right thing")
