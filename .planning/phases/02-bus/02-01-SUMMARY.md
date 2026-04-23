---
phase: 02-bus
plan: 01
subsystem: bus
tags: [swift, wkwebview, wkscriptmessagehandlerwithreply, codable, swift6, strict-concurrency, mainactor, handshake]

requires:
  - phase: 01-foundations
    provides: "JarvisLogging channel model + swift-log bootstrap; JarvisHUDPanel host; `packages/` SPM layout"
provides:
  - "`packages/Bus` SPM package — `BUS_PROTOCOL_VERSION` constant, `BusOutbound`/`BusInbound` discriminated-union enums with hand-written `Codable`, `BusReply`, `BusError`, `HandshakeState`, `WebviewBridge`"
  - "14 JSON fixtures defining the wire format (Plan 02 TS mirror reads identical bytes; Plan 04 parity script asserts the two dirs stay in sync)"
  - "`JarvisLogChannel.bus` case (OBS-06 expansion)"
  - "Injectable `AlertPresenter` closure pattern for NSAlert-free handshake tests"
  - "Internal `handleInboundString(_:replyHandler:)` seam for testing decode/dispatch without synthesizing `WKScriptMessage`"
affects: [02-02-typescript-bus-mirror, 02-03-outbound-batcher-appdelegate-integration, 02-04-parity-scripts, 03-hud-wave]

tech-stack:
  added:
    - "`packages/Bus` SPM peer package (Swift 6 strict concurrency; macOS 13+; WebKit-linked)"
  patterns:
    - "Hand-written `Codable` with `Discriminator` + `CodingKeys` private enums (SE-0295 synthesis forbidden — it produces the wrong wire shape)"
    - "`MainActor.assumeIsolated` inside `nonisolated` `WKScriptMessageHandlerWithReply` protocol method (Apple DevForums 751086 workaround)"
    - "Two-way version handshake state machine (`.idle` → `.sentHello` → `.armed`|`.mismatched`|`.timedOut`) with 2s `Task.sleep` timeout, cancelled on ack"
    - "Injectable `@MainActor` `alertPresenter` closure so hard-block alerts can be asserted without NSAlert under XCTest"
    - "Testable seam: `handleInboundString(_:replyHandler:)` lets XCTest exercise decode + dispatch without synthesizing `WKScriptMessage`"

key-files:
  created:
    - "packages/Bus/Package.swift"
    - "packages/Bus/Sources/Bus/Protocol.swift"
    - "packages/Bus/Sources/Bus/BusOutbound.swift"
    - "packages/Bus/Sources/Bus/BusInbound.swift"
    - "packages/Bus/Sources/Bus/BusReply.swift"
    - "packages/Bus/Sources/Bus/BusError.swift"
    - "packages/Bus/Sources/Bus/Handshake.swift"
    - "packages/Bus/Sources/Bus/WebviewBridge.swift"
    - "packages/Bus/Tests/BusTests/CodableRoundTripTests.swift"
    - "packages/Bus/Tests/BusTests/HandshakeTests.swift"
    - "packages/Bus/Tests/BusTests/WebviewBridgeTests.swift"
    - "packages/Bus/Tests/BusTests/Fixtures/*.json (14 files)"
  modified:
    - "packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift — added `case bus`"
    - "packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift — updated channel-count test to `test_fiveChannelsAreDefined`"

key-decisions:
  - "Hand-written `Codable` on `BusOutbound`/`BusInbound` in an extension (not on the enum declaration) — SE-0295 synthesis would produce `{\"hudState\": {\"_0\": \"idle\"}}` which does NOT match the required `{\"type\": \"hudState\", \"state\": \"idle\"}` shape. Exhaustive `switch tag` / `switch self` with zero `default:` makes adding a case a compile error."
  - "`MainActor.assumeIsolated` at the `WKScriptMessageHandlerWithReply.userContentController(_:didReceive:replyHandler:)` site — the protocol is not `@MainActor` but WebKit always invokes it on main; Apple DevForums 751086 documents this as the supported workaround under Swift 6 strict concurrency."
  - "Bus logging gets its own `JarvisLogChannel.bus` case rather than multiplexing into `ui` — the bus is busy enough in replay traces that mixing channels muddies debugging. 2-line non-breaking extension to the existing enum."
  - "`send(_:)` is intentionally a stub in P2-01 — it validates handshake state + round-trips through the encoder so any wire-shape breakage surfaces here, but does not yet call `callAsyncJavaScript`. Plan 02-03 replaces the stub body once the TS side exists and `AppDelegate` wires the navigation-delegate handshake kickoff."
  - "Test seam: `handleInboundString(_:replyHandler:)` is `internal` (not `fileprivate`) so `@testable import Bus` can drive it. `WKScriptMessage` is not user-constructible; without this seam, decode-path tests would require spinning up a real webview with navigation — too brittle for unit tests."
  - "UUID explicitly lowercased at each encode site (`id.uuidString.lowercased()`). `JSONEncoder` defaults to uppercase; the TS mirror (Plan 02-02) cannot easily uppercase without an extra `toUpperCase()` call on the wire. Pitfall 6 in RESEARCH."

patterns-established:
  - "Discriminator + CodingKeys hand-written Codable pattern for discriminated unions — applies to every future `BusInbound`/`BusOutbound` case add (Phase 3+)."
  - "`alertPresenter: (String, String) -> Void` closure injection for hard-block NSAlert paths — lets XCTest assert alert content without actually presenting modal UI. Production wiring in Plan 03 passes `TCCAlertService.presentHardBlock` + `NSApp.terminate`."
  - "Internal testable seam: extract the body of a `nonisolated` protocol method into an `internal` method on the same class that XCTest can drive with `@testable import`. Keeps the protocol conformance thin and delegates to a testable core."
  - "2s `Task.sleep` + explicit `Task.cancel()` pattern for timeout state machines. `scheduleTimeout()` owns a `Task<Void, Never>?`; `handleHelloAck` / success paths cancel it; `handleTimeout` is idempotent via `guard case .sentHello` so a late-cancelled timer is a no-op."

requirements-completed: [HUD-03, HUD-05, SEC-09]

duration: ~30min
completed: 2026-04-23
---

# Phase 02 Plan 01: Swift Bus Package Summary

**Typed Swift-side JSON bus with `WKScriptMessageHandlerWithReply` + hand-written Codable discriminated unions + 2s handshake state machine; 36 XCTest green under Swift 6 strict concurrency.**

## Performance

- **Duration:** ~30 minutes
- **Started:** 2026-04-23T22:01Z (approx.)
- **Completed:** 2026-04-23T22:31:49Z
- **Tasks:** 2 of 2
- **Files created:** 25 (1 manifest, 7 sources, 3 test files, 14 fixtures)
- **Files modified:** 2 (Logging channel enum + its test)

## Accomplishments

- New `packages/Bus` SPM package: Swift 6 strict concurrency, macOS 13+, WebKit-linked, depends only on `../Logging`.
- `BUS_PROTOCOL_VERSION = "2.0.0"` + `HudState` (7 cases) + `TurnTerminator` (4 cases) in `Protocol.swift`.
- `BusOutbound` (8 cases — `hello`, `hudState`, `tokenDelta`, `audioLevel`, `toolCallStart`, `toolCallEnd`, `turnStarted`, `turnEnded`) and `BusInbound` (2 cases — `helloAck`, `uiReady`) with hand-written `Codable` using a `type` discriminator and exhaustive switches.
- `BusReply` plist-serializable reply type; `BusError` error surface (`.decodeFailed`, `.bridgeNotReady`, `.handshakeMismatch`, `.handshakeTimeout`).
- `WebviewBridge` (`@MainActor final class`) conforming to `WKScriptMessageHandlerWithReply` with the `MainActor.assumeIsolated` Swift 6 workaround; handler installed in `WKContentWorld.world(name: "JarvisBusWorld")` so page scripts cannot observe the bus.
- `HandshakeState` state machine (`.idle` → `.sentHello` → `.armed`/`.mismatched`/`.timedOut`) with 2s `Task.sleep` timeout, cancelled on successful ack.
- 14 JSON fixtures defining the wire format byte-exactly — Plan 02 (TS mirror) reads the same files; Plan 04 parity script asserts they stay in sync.
- 36 XCTest methods all green: 24 `CodableRoundTripTests` (round-trip per case, UUID lowercasing, shape invariants, negative-path decode failures), 5 `HandshakeTests` (arm/mismatch/timeout/cancel-on-arm/state-transition), 7 `WebviewBridgeTests` (decode-success dispatch, decode-failure reply, non-string body reply, onInbound-throws reply, nil-return implicit success, helloAck-inline-handled, handler registration).
- `JarvisLogChannel.bus` added (OBS-06 extension per RESEARCH open question #7); existing `LoggingTests` updated to cover the new 5-channel set.

## Task Commits

Each task committed atomically on branch `worktree-agent-a7a9e225` (base `37619d0c`):

1. **Task 1: Protocol types + hand-written Codable + 14 fixtures + `JarvisLogChannel.bus`** — `cf61b6b` (feat)
2. **Task 2: `WebviewBridge` + `HandshakeState` + XCTest coverage** — `a555093` (feat)

_Task 1 bundled the RED→GREEN→fixture-first TDD flow into a single atomic commit because the type layer and round-trip tests landed together; Task 2 followed the same structure with Handshake + WebviewBridge + their tests._

Plan metadata commit will be made below after this SUMMARY lands.

## Files Created/Modified

**Package manifest:**
- `packages/Bus/Package.swift` — Swift 6 strict-concurrency, macOS 13+, depends on `../Logging`, links `WebKit.framework`, test target processes `Fixtures/` resources.

**Sources (`packages/Bus/Sources/Bus/`):**
- `Protocol.swift` — `BUS_PROTOCOL_VERSION = "2.0.0"`, `HudState`, `TurnTerminator`, `BusCoder` (shared `makeEncoder`/`makeDecoder`).
- `BusOutbound.swift` — 8-case enum + hand-written `Codable` via `Discriminator` + `CodingKeys`; UUIDs encoded lowercase.
- `BusInbound.swift` — 2-case enum (`helloAck`, `uiReady`) + hand-written `Codable`.
- `BusReply.swift` — `ok`/`value`/`error` struct with `asPlist()` → `[String: Any]` for `replyHandler`.
- `BusError.swift` — 4-case error enum.
- `Handshake.swift` — `HandshakeState` enum + `HandshakeTiming.timeout = .seconds(2)`.
- `WebviewBridge.swift` — `@MainActor final class` conforming to `WKScriptMessageHandlerWithReply`; `MainActor.assumeIsolated` at the protocol site; stubbed `send(_:)`; internal `handleInboundString` seam; inline `helloAck` handling.

**Tests (`packages/Bus/Tests/BusTests/`):**
- `CodableRoundTripTests.swift` — 24 tests covering all 8 `BusOutbound` shapes (× 7 HudState variants), `helloAck` round-trip, shape invariants (`{"type":"…"}` not `{"case":{…}}`), UUID lowercasing, negative-path decode failures, `HudState.allCases` fixture coverage guard.
- `HandshakeTests.swift` — 5 tests covering match/mismatch/timeout/cancel-on-arm/initial-transition; uses `AlertCollector` helper (main-actor-isolated, records title+body, offers optional `onRecord` callback).
- `WebviewBridgeTests.swift` — 7 tests covering decode-success dispatch, decode-failure reply, non-string body reply, onInbound-throws reply, nil-return implicit success, helloAck-handled-inline, handler registration; uses `ReplyCollector` helper (main-actor-isolated, captures `Any?` reply + error + expectation fulfillment without tripping Swift 6 `Sendable` checks).

**Fixtures (`packages/Bus/Tests/BusTests/Fixtures/` — 14 files):**
- `hello.json`, `helloAck.json`, 7 × `hudState.<case>.json`, `tokenDelta.json`, `audioLevel.json`, `toolCallStart.json`, `toolCallEnd.json`, `turnStarted.json`, `turnEnded.json` — all bytes exactly per plan spec (UUID in `550e8400-…` or `6ba7b810-…` test-vector form).

**Modified (`packages/Logging/`):**
- `Sources/JarvisLogging/JarvisLogChannel.swift` — added `case bus` (5th case).
- `Tests/JarvisLoggingTests/LoggingTests.swift` — renamed `test_fourChannelsAreDefined` → `test_fiveChannelsAreDefined`, expanded expected set to include `"bus"`.

## Decisions Made

See `key-decisions` in frontmatter for the full list with rationale. Headline items:

1. **Hand-written `Codable` in extensions** — the whole point of Plan 02-01. Exhaustive switches with zero `default:` turn drift into a compile error.
2. **`MainActor.assumeIsolated` workaround** — Apple DevForums 751086; `WKScriptMessageHandlerWithReply` is not `@MainActor` but WebKit always calls on main.
3. **`JarvisLogChannel.bus` 5th case** — bus traces are busy enough to deserve their own channel; non-breaking enum extension.
4. **`send(_:)` stub in P2-01** — validates handshake-state guard + encoder round-trip, but Plan 03 wires the real `callAsyncJavaScript` body.
5. **UUID lowercased at encode time** — `JSONEncoder` defaults to uppercase; lowercasing at the Swift side keeps the TS mirror from needing a workaround.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Updated `WKScriptMessageHandlerWithReply` `replyHandler` signature for Swift 6**
- **Found during:** Task 2 (initial build after writing `WebviewBridge.swift`)
- **Issue:** The WebKit SDK's `WKScriptMessageHandlerWithReply.userContentController(_:didReceive:replyHandler:)` protocol requires the `replyHandler` parameter typed as `@escaping @MainActor @Sendable (Any?, String?) -> Void`. My first draft used `@escaping (Any?, String?) -> Void` (matching the plan's pattern sketch verbatim, but the actual SDK-declared shape is stricter under Swift 6). Compile failed with "type 'WebviewBridge' does not conform to protocol".
- **Fix:** Added `@MainActor @Sendable` attributes to the `replyHandler` parameter type in both the `nonisolated` extension method and the `handleInboundString` signature (so the reply handler can be propagated without re-wrapping). The `ReplyCollector` test helper was rewritten to expose a `@MainActor @Sendable` closure that the tests can pass directly.
- **Files modified:** `packages/Bus/Sources/Bus/WebviewBridge.swift`, `packages/Bus/Tests/BusTests/WebviewBridgeTests.swift`.
- **Verification:** `swift build` + `swift test --filter WebviewBridgeTests` green.
- **Committed in:** `a555093` (Task 2 commit).

**2. [Rule 3 - Blocking] Added missing `import JarvisLogging` to `WebviewBridge.swift`**
- **Found during:** Task 2 (second build attempt).
- **Issue:** `JarvisLogChannel.bus.rawValue` referenced on the `Logger(label:)` line failed to resolve — `import Logging` pulls in swift-log's `Logger` but `JarvisLogChannel` lives in the `JarvisLogging` module.
- **Fix:** Added `import JarvisLogging` alongside `import Logging`.
- **Files modified:** `packages/Bus/Sources/Bus/WebviewBridge.swift`.
- **Verification:** `swift build` clean on next iteration.
- **Committed in:** `a555093` (Task 2 commit).

**3. [Rule 3 - Blocking] Updated `LoggingTests.test_fourChannelsAreDefined` after adding `case bus`**
- **Found during:** Task 1 (pre-build sanity sweep for side-effects).
- **Issue:** Plan 02-01 calls for adding `case bus` to `JarvisLogChannel`. The existing `LoggingTests.test_fourChannelsAreDefined` enumerates `Set(JarvisLogChannel.allCases.map(\.rawValue))` and asserts it equals `["agent", "tools", "ui", "system"]`. Adding `case bus` would have turned that test red on the next `swift test` in the Logging package.
- **Fix:** Renamed the test to `test_fiveChannelsAreDefined` and added `"bus"` to the expected set, with a comment pointing at the Phase 2 / RESEARCH §OBS-06 extension.
- **Files modified:** `packages/Logging/Tests/JarvisLoggingTests/LoggingTests.swift`.
- **Verification:** `swift test` inside `packages/Logging/` remained green (14/14).
- **Committed in:** `cf61b6b` (Task 1 commit).

---

**Total deviations:** 3 auto-fixed (all Rule 3 — blocking issues immediately adjacent to the task's changes).
**Impact on plan:** No scope creep. All three fixes were small, mechanical adaptations needed to make Plan 02-01 compile and avoid leaving the sibling Logging package's tests red.

## Issues Encountered

None that required problem-solving outside of the blocking-issue fixes documented under Deviations.

## Known Stubs

**1. `WebviewBridge.send(_:)` (`packages/Bus/Sources/Bus/WebviewBridge.swift:104-116`)**
- **What:** Serializes the outbound message through `BusCoder.makeEncoder()` to prove the hand-written `Codable` path works end-to-end, but does NOT call `callAsyncJavaScript` yet.
- **Why:** Plan 02-01 scope is the contract surface; Plan 02-03 adds the real `callAsyncJavaScript` wiring once the TS side exists (Plan 02-02) and `AppDelegate` knows how to kick off `startHandshake()` from `WKNavigationDelegate.webView(_:didFinish:)`.
- **Intentional:** Yes. Documented inline with the replacement body as a comment; `send(_:)` still enforces the `handshakeState == .armed` guard so consumers can't accidentally depend on a silently-dropped send.
- **Resolved by:** Plan 02-03 (OutboundBatcher + AppDelegate integration).

## Threat Flags

None — all security-relevant surface (inbound JSON decode, non-string body guard, content-world isolation, page-script hijack defense, handshake spoof defense) maps 1:1 to the plan's `<threat_model>` register entries T-02-01 through T-02-07. No net-new attack surface introduced.

## Next Phase Readiness

**Ready to consume from Plan 02-02 (TypeScript mirror):**
- 14 JSON fixtures at `packages/Bus/Tests/BusTests/Fixtures/` are the canonical wire format. Copy identical bytes into `webview/packages/bus/fixtures/`. Plan 02-04's parity script enforces this.
- `BUS_PROTOCOL_VERSION = "2.0.0"` string is the reference value for the TS constant.

**Ready to consume from Plan 02-03 (OutboundBatcher + AppDelegate):**
- `WebviewBridge.send(_:)` signature is locked: `public func send(_ message: BusOutbound) async throws`.
- `WebviewBridge.startHandshake()` is called from `WKNavigationDelegate.webView(_:didFinish:)`; the injected `alertPresenter` should wrap `TCCAlertService.presentHardBlock` + `NSApp.terminate` in production wiring.
- `WebviewBridge.onInbound` and `onHandshakeArmed` are the closure hooks AppDelegate sets.
- Plan 03 must replace the body of `send(_:)` with a `callAsyncJavaScript` call targeting the `JarvisBusWorld` content world — the hand-written `encoder` is already constructed and the encoded JSON string is ready to pass as an `arguments:` value.

**Open items explicitly punted to later plans:**
- The `deinit` on `WebviewBridge` does NOT currently call `removeScriptMessageHandler` — the remove API is `@MainActor` and `deinit` may be non-isolated. Plan 03 adds an explicit `tearDown()` / `stop()` method invoked at window-close and handles the lifecycle there.
- The `scriptMessageHandlerIsRegisteredUnderConfiguredName` test is a soft assertion (remove-doesn't-throw). A stronger integration test (page script posts to the bus → Swift sees it vs. page script in non-Jarvis world doesn't reach the handler) is Plan 03's responsibility, since it requires a real loaded webview.

## Self-Check: PASSED

**Files verified present:**
- `packages/Bus/Package.swift` — FOUND
- `packages/Bus/Sources/Bus/Protocol.swift` — FOUND (contains `BUS_PROTOCOL_VERSION = "2.0.0"`)
- `packages/Bus/Sources/Bus/BusOutbound.swift` — FOUND (0 `default:` branches, exhaustive switches)
- `packages/Bus/Sources/Bus/BusInbound.swift` — FOUND (0 `default:` branches)
- `packages/Bus/Sources/Bus/BusReply.swift` — FOUND
- `packages/Bus/Sources/Bus/BusError.swift` — FOUND
- `packages/Bus/Sources/Bus/Handshake.swift` — FOUND
- `packages/Bus/Sources/Bus/WebviewBridge.swift` — FOUND (`MainActor.assumeIsolated` at line 226; `WKScriptMessageHandlerWithReply` conformance at line 216; 0 `evaluateJavaScript` calls)
- `packages/Bus/Tests/BusTests/CodableRoundTripTests.swift` — FOUND
- `packages/Bus/Tests/BusTests/HandshakeTests.swift` — FOUND
- `packages/Bus/Tests/BusTests/WebviewBridgeTests.swift` — FOUND
- All 14 `packages/Bus/Tests/BusTests/Fixtures/*.json` — FOUND
- `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift` — FOUND (5 cases including `case bus`)

**Commits verified present:**
- `cf61b6b` (Task 1) — FOUND via `git log --oneline`
- `a555093` (Task 2) — FOUND via `git log --oneline`

**Tests verified green:**
- `cd packages/Bus && swift test` → 36 passed, 0 failed (CodableRoundTripTests 24, HandshakeTests 5, WebviewBridgeTests 7).
- `cd packages/Logging && swift test` → 14 passed, 0 failed.

---
*Phase: 02-bus*
*Plan: 01*
*Completed: 2026-04-23*
