---
phase: 02-bus
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - packages/Bus/Package.swift
  - packages/Bus/Sources/Bus/Protocol.swift
  - packages/Bus/Sources/Bus/BusInbound.swift
  - packages/Bus/Sources/Bus/BusOutbound.swift
  - packages/Bus/Sources/Bus/BusReply.swift
  - packages/Bus/Sources/Bus/BusError.swift
  - packages/Bus/Sources/Bus/Handshake.swift
  - packages/Bus/Sources/Bus/WebviewBridge.swift
  - packages/Bus/Tests/BusTests/CodableRoundTripTests.swift
  - packages/Bus/Tests/BusTests/WebviewBridgeTests.swift
  - packages/Bus/Tests/BusTests/HandshakeTests.swift
  - packages/Bus/Tests/BusTests/Fixtures/hello.json
  - packages/Bus/Tests/BusTests/Fixtures/helloAck.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.idle.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.listening.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.thinking.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.speaking.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.awaitingConfirmation.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.reconfiguring.json
  - packages/Bus/Tests/BusTests/Fixtures/hudState.booting.json
  - packages/Bus/Tests/BusTests/Fixtures/tokenDelta.json
  - packages/Bus/Tests/BusTests/Fixtures/audioLevel.json
  - packages/Bus/Tests/BusTests/Fixtures/toolCallStart.json
  - packages/Bus/Tests/BusTests/Fixtures/toolCallEnd.json
  - packages/Bus/Tests/BusTests/Fixtures/turnStarted.json
  - packages/Bus/Tests/BusTests/Fixtures/turnEnded.json
  - packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift
autonomous: true
requirements: [HUD-03, HUD-05, SEC-09]

must_haves:
  truths:
    - "Swift `BUS_PROTOCOL_VERSION` constant exists at `packages/Bus/Sources/Bus/Protocol.swift` and equals \"2.0.0\""
    - "`BusOutbound` is a discriminated-union enum with hand-written `Codable` — every case encodes as `{\"type\": \"<case>\", ...}`, NOT SE-0295 synthesized `{\"<case>\": {...}}`"
    - "`BusInbound` is a discriminated-union enum with hand-written `Codable` using the same `type` discriminator pattern"
    - "Every `init(from:)` and `encode(to:)` is an exhaustive `switch self` / `switch tag` with NO `default:` branch — adding a case is a compile error"
    - "Inbound JSON arrives via `WKScriptMessageHandlerWithReply` (not the legacy `WKScriptMessageHandler` protocol); the `replyHandler` is called exactly once with either `(payload, nil)` for success or `(nil, error)` for failure"
    - "`WebviewBridge` is `@MainActor final class`; protocol conformance uses `MainActor.assumeIsolated` to read `WKScriptMessage.body` under Swift 6 strict concurrency"
    - "`WebviewBridge.send(_:)` serializes via hand-written `Codable` — there is zero `evaluateJavaScript` call anywhere in the module (Plan 03 adds the actual `callAsyncJavaScript` wiring; this plan keeps `send` as a stubbed sender for testing)"
    - "Two-way handshake: on webview nav complete the bridge records `.sentHello(deadline: now+2s)`; receipt of `BusInbound.helloAck(version:)` with matching version flips state to `.armed`; mismatch → `.mismatched`, timeout → `.timedOut`"
    - "Handshake mismatch and timeout both invoke an injectable `alertPresenter` closure (so tests don't actually show NSAlert); production wiring in Plan 03 passes `TCCAlertService.presentHardBlock` + `NSApp.terminate`"
    - "`JarvisLogChannel` gains a 5th case `bus` (OBS-06 extension per RESEARCH open question #7)"
  artifacts:
    - path: "packages/Bus/Package.swift"
      provides: "SPM manifest; Swift 6 strict-concurrency; deps on Logging + Config; links WebKit framework"
      contains: "SWIFT_STRICT_CONCURRENCY or .swiftLanguageMode(.v6)"
    - path: "packages/Bus/Sources/Bus/Protocol.swift"
      provides: "`BUS_PROTOCOL_VERSION` constant + shared `HudState`, `TurnTerminator` enums"
      contains: "BUS_PROTOCOL_VERSION = \"2.0.0\""
    - path: "packages/Bus/Sources/Bus/BusOutbound.swift"
      provides: "`BusOutbound` enum (8 cases) + hand-written Codable with exhaustive switches"
      contains: "enum Discriminator"
    - path: "packages/Bus/Sources/Bus/BusInbound.swift"
      provides: "`BusInbound` enum (helloAck + uiReady) + hand-written Codable"
    - path: "packages/Bus/Sources/Bus/BusReply.swift"
      provides: "`BusReply` struct → plist-serializable dictionary for WKScriptMessageHandlerWithReply"
    - path: "packages/Bus/Sources/Bus/BusError.swift"
      provides: "`BusError` enum: .decodeFailed, .bridgeNotReady, .handshakeMismatch, .handshakeTimeout"
    - path: "packages/Bus/Sources/Bus/Handshake.swift"
      provides: "`HandshakeState` enum + state-machine transitions + 2s timeout Task"
      contains: "case sentHello"
    - path: "packages/Bus/Sources/Bus/WebviewBridge.swift"
      provides: "`@MainActor final class WebviewBridge: NSObject, WKScriptMessageHandlerWithReply`"
      contains: "MainActor.assumeIsolated"
    - path: "packages/Bus/Tests/BusTests/CodableRoundTripTests.swift"
      provides: "One XCTest per `BusOutbound` case: decode-fixture → re-encode → byte-equal modulo key order"
    - path: "packages/Bus/Tests/BusTests/WebviewBridgeTests.swift"
      provides: "Tests for inbound decode success, decode failure → reply(_, error), content-world registration"
    - path: "packages/Bus/Tests/BusTests/HandshakeTests.swift"
      provides: "Tests for armed-on-match, mismatch-invokes-alert, timeout-invokes-alert"
    - path: "packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift"
      provides: "Adds `case bus` to existing `JarvisLogChannel` enum (OBS-06 extension)"
  key_links:
    - from: "packages/Bus/Sources/Bus/WebviewBridge.swift"
      to: "WKScriptMessageHandlerWithReply"
      via: "NSObject + protocol conformance in extension"
      pattern: "WKScriptMessageHandlerWithReply"
    - from: "packages/Bus/Sources/Bus/WebviewBridge.swift"
      to: "MainActor"
      via: "`MainActor.assumeIsolated` inside `nonisolated` protocol method"
      pattern: "MainActor\\.assumeIsolated"
    - from: "packages/Bus/Sources/Bus/BusOutbound.swift"
      to: "Discriminator"
      via: "private nested enum + forKey: .type"
      pattern: "Discriminator\\."
    - from: "packages/Bus/Sources/Bus/Handshake.swift"
      to: "alertPresenter closure"
      via: "injectable `(String, String) -> Void` so tests don't call NSAlert"
      pattern: "alertPresenter"
---

<objective>
Build `packages/Bus` — the Swift side of the typed JSON bus — with the load-bearing
primitives that foreclose the R4 dominant failure mode ("schema drift across the
Swift/JS boundary"). This plan delivers:

1. The `BUS_PROTOCOL_VERSION` constant and discriminated-union message enums
   (`BusOutbound`, `BusInbound`, `BusReply`, `BusError`) with HAND-WRITTEN
   `Codable` — synthesized `Codable` (SE-0295) produces the wrong wire shape
   (`{"hudState": {...}}` vs the required `{"type": "hudState", ...}`).
2. `WebviewBridge` — `@MainActor final class` that conforms to
   `WKScriptMessageHandlerWithReply` (HUD-03), decodes inbound JSON with the
   `MainActor.assumeIsolated` Swift 6 workaround (Apple DevForums 751086), and
   exposes a stubbed `send(_:)` sender for testing. Plan 03 replaces the stub
   with the real `callAsyncJavaScript` wiring once the TS side exists.
3. The two-way version handshake state machine (HUD-05) with 2s timeout,
   mismatched-version detection, and an injectable `alertPresenter` closure so
   tests can verify the alert path without actually presenting NSAlert.
4. A full Codable round-trip fixture suite — one `.json` file per `BusOutbound`
   case, each asserted in XCTest to decode + re-encode to byte-equal form.
   Plan 04 reads the same fixtures from the TS side so the wire format is
   unified across the parity boundary (SEC-09).
5. A fifth `JarvisLogChannel` case `bus` — OBS-06 extension per RESEARCH-07.

Purpose: Pin the wire format. Plan 02 (TS mirror) reads these fixtures. Plan 03
(OutboundBatcher + real callAsyncJavaScript wiring in AppDelegate) consumes
this bridge's `send(_:)` API. Plan 04 (scripts) enforces cross-language parity
at build time.

Output: New `packages/Bus` SPM package, 8 source files + 3 test files + 14
JSON fixture files. `JarvisLogChannel` gains `case bus`. No changes to
`project.yml` yet (Plan 03 wires the package into the Jarvis target).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/REQUIREMENTS.md
@.planning/phases/02-bus/02-RESEARCH.md

<!-- Peer packages for pattern parity -->
@packages/Config/Package.swift
@packages/Shell/Package.swift
@packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift

<interfaces>
<!-- From packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift (existing) -->
```swift
public enum JarvisLogChannel: String, Sendable, CaseIterable {
    case agent
    case tools
    case ui
    case system
    // This plan ADDS: case bus
}
```

<!-- From packages/Logging (existing, consumed by this plan) -->
```swift
// Usage:
import Logging   // swift-log
let logger = Logger(label: JarvisLogChannel.bus.rawValue)
logger.debug("inbound decode failed: \(error)")
```

<!-- Swift 6 strict-concurrency pattern from existing codebase -->
```swift
// From App/HUD/JarvisHUDPanel.swift — @MainActor discipline
@MainActor
public final class JarvisHUDPanel: NSPanel { ... }
```

<!-- Bus public API this plan creates -->
```swift
// packages/Bus/Sources/Bus/Protocol.swift
public let BUS_PROTOCOL_VERSION: String = "2.0.0"

public enum HudState: String, Codable, Sendable, CaseIterable {
    case idle, listening, thinking, speaking
    case awaitingConfirmation, reconfiguring, booting
}

public enum TurnTerminator: String, Codable, Sendable, CaseIterable {
    case completed, cancelled, errored, superseded
}

// packages/Bus/Sources/Bus/BusOutbound.swift
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
extension BusOutbound: Codable { /* hand-written */ }

// packages/Bus/Sources/Bus/BusInbound.swift
public enum BusInbound: Equatable, Sendable {
    case helloAck(version: String)
    case uiReady
}
extension BusInbound: Codable { /* hand-written */ }

// packages/Bus/Sources/Bus/BusReply.swift
public struct BusReply: Sendable {
    public let ok: Bool
    public let value: String?    // JSON-encoded payload or nil
    public let error: String?
}

// packages/Bus/Sources/Bus/BusError.swift
public enum BusError: Error, Sendable {
    case decodeFailed(String)
    case bridgeNotReady
    case handshakeMismatch(swift: String, js: String)
    case handshakeTimeout
}

// packages/Bus/Sources/Bus/Handshake.swift
public enum HandshakeState: Equatable, Sendable {
    case idle
    case sentHello(deadline: Date)
    case armed
    case mismatched(swift: String, js: String)
    case timedOut
}

// packages/Bus/Sources/Bus/WebviewBridge.swift
@MainActor
public final class WebviewBridge: NSObject {
    public init(
        webView: WKWebView,
        messageHandlerName: String = "jarvisBus",
        contentWorldName: String = "JarvisBusWorld",
        alertPresenter: @escaping @MainActor (_ title: String, _ body: String) -> Void
    )
    public var onInbound: (@MainActor (BusInbound) async throws -> BusReply?)?
    public var onHandshakeArmed: (@MainActor () -> Void)?
    public private(set) var handshakeState: HandshakeState
    public func startHandshake() async   // Plan 03 calls after nav complete
    public func send(_ msg: BusOutbound) async throws  // stub in P2-01; wired in P2-03
}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Protocol types + hand-written Codable + fixture JSONs</name>
  <files>
    packages/Bus/Package.swift,
    packages/Bus/Sources/Bus/Protocol.swift,
    packages/Bus/Sources/Bus/BusOutbound.swift,
    packages/Bus/Sources/Bus/BusInbound.swift,
    packages/Bus/Sources/Bus/BusReply.swift,
    packages/Bus/Sources/Bus/BusError.swift,
    packages/Bus/Tests/BusTests/CodableRoundTripTests.swift,
    packages/Bus/Tests/BusTests/Fixtures/*.json (14 files),
    packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift
  </files>
  <behavior>
    - Test 1: Each fixture file decodes to the expected `BusOutbound` / `BusInbound` case
    - Test 2: Round-trip (decode → encode → JSON-normalize → compare) is byte-equal modulo key order
    - Test 3: `BusOutbound.hudState(.idle)` encodes to `{"type":"hudState","state":"idle"}` (NOT `{"hudState":{"state":"idle"}}` — proves hand-written Codable is load-bearing)
    - Test 4: `BusOutbound.tokenDelta(text:"hi")` encodes to `{"type":"tokenDelta","text":"hi"}`
    - Test 5: Decoding `{"type":"unknown"}` throws `DecodingError` (exhaustive switch catches drift)
    - Test 6: `BusInbound.helloAck(version:"2.0.0")` round-trips to `{"type":"helloAck","version":"2.0.0"}`
    - Test 7: `UUID` encodes as lowercase string (Pitfall 6 defense)
    - Test 8: All 7 `HudState` cases covered by dedicated fixtures
  </behavior>
  <action>
    **Decisions honored:** All locked. `BUS_PROTOCOL_VERSION = "2.0.0"` per RESEARCH §HUD-05.
    Hand-written Codable per RESEARCH §SEC-09 deep-dive (SE-0295 produces wrong shape).
    Exhaustive switches with zero `default:` per HUD-03 / RESEARCH §pitfall 1.

    **1. `packages/Bus/Package.swift`** — Swift 6, macOS 13+, Swift-language-mode v6.
    Dependencies: `../Logging` (for `JarvisLogging` product). Do NOT depend on
    `../Config` — the bus has no config knobs in P2. Targets: `Bus` library +
    `BusTests` test target. Link `WebKit.framework` in `linkerSettings`.
    Resources: `.process("Fixtures")` on the test target so the JSON files are
    copied into the test bundle — `Bundle.module` reads them in
    `CodableRoundTripTests`.

    **2. `packages/Bus/Sources/Bus/Protocol.swift`** — Declare:
    ```swift
    public let BUS_PROTOCOL_VERSION: String = "2.0.0"

    public enum HudState: String, Codable, Sendable, CaseIterable {
        case idle, listening, thinking, speaking
        case awaitingConfirmation, reconfiguring, booting
    }

    public enum TurnTerminator: String, Codable, Sendable, CaseIterable {
        case completed, cancelled, errored, superseded
    }

    /// Shared JSON coder configuration. UUID output is lowercased per Pitfall 6.
    /// This is a single source of truth so WebviewBridge + tests agree.
    public enum BusCoder {
        public static func makeEncoder() -> JSONEncoder {
            let e = JSONEncoder()
            e.outputFormatting = []       // no pretty / sorted — wire form is minimal
            e.dateEncodingStrategy = .iso8601
            return e
        }
        public static func makeDecoder() -> JSONDecoder {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }
    }
    ```
    Note: The custom `UUID → lowercased` handling is done at each encode site
    in `BusOutbound.encode(to:)` (explicit `try c.encode(id.uuidString.lowercased(), forKey: .id)`)
    — Foundation's JSONEncoder encodes UUID as uppercase by default.

    **3. `packages/Bus/Sources/Bus/BusOutbound.swift`** — Follow RESEARCH §SEC-09
    pattern exactly:
    ```swift
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
            case type, version, state, text, rms
            case id, name, argsPreview, ok, previewOrError, terminator
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
                let idStr = try c.decode(String.self, forKey: .id)
                guard let id = UUID(uuidString: idStr) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .id, in: c,
                        debugDescription: "invalid UUID: \(idStr)")
                }
                self = .toolCallStart(
                    id: id,
                    name: try c.decode(String.self, forKey: .name),
                    argsPreview: try c.decode(String.self, forKey: .argsPreview))
            case .toolCallEnd:
                let idStr = try c.decode(String.self, forKey: .id)
                guard let id = UUID(uuidString: idStr) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .id, in: c,
                        debugDescription: "invalid UUID: \(idStr)")
                }
                self = .toolCallEnd(
                    id: id,
                    ok: try c.decode(Bool.self, forKey: .ok),
                    previewOrError: try c.decode(String.self, forKey: .previewOrError))
            case .turnStarted:
                let idStr = try c.decode(String.self, forKey: .id)
                guard let id = UUID(uuidString: idStr) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .id, in: c,
                        debugDescription: "invalid UUID: \(idStr)")
                }
                self = .turnStarted(id: id)
            case .turnEnded:
                let idStr = try c.decode(String.self, forKey: .id)
                guard let id = UUID(uuidString: idStr) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .id, in: c,
                        debugDescription: "invalid UUID: \(idStr)")
                }
                self = .turnEnded(
                    id: id,
                    terminator: try c.decode(TurnTerminator.self, forKey: .terminator))
            }
            // NO default — adding a Discriminator case without a switch arm
            // is a compile error. This is the load-bearing drift preventer.
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
            case .tokenDelta(let t):
                try c.encode(Discriminator.tokenDelta, forKey: .type)
                try c.encode(t, forKey: .text)
            case .audioLevel(let rms):
                try c.encode(Discriminator.audioLevel, forKey: .type)
                try c.encode(rms, forKey: .rms)
            case .toolCallStart(let id, let name, let argsPreview):
                try c.encode(Discriminator.toolCallStart, forKey: .type)
                try c.encode(id.uuidString.lowercased(), forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(argsPreview, forKey: .argsPreview)
            case .toolCallEnd(let id, let ok, let previewOrError):
                try c.encode(Discriminator.toolCallEnd, forKey: .type)
                try c.encode(id.uuidString.lowercased(), forKey: .id)
                try c.encode(ok, forKey: .ok)
                try c.encode(previewOrError, forKey: .previewOrError)
            case .turnStarted(let id):
                try c.encode(Discriminator.turnStarted, forKey: .type)
                try c.encode(id.uuidString.lowercased(), forKey: .id)
            case .turnEnded(let id, let terminator):
                try c.encode(Discriminator.turnEnded, forKey: .type)
                try c.encode(id.uuidString.lowercased(), forKey: .id)
                try c.encode(terminator, forKey: .terminator)
            }
            // Exhaustive at encode site — adding a case without encode is a compile error.
        }
    }
    ```

    **4. `packages/Bus/Sources/Bus/BusInbound.swift`** — Same pattern. Minimal
    P2 scope per RESEARCH §Deferred Ideas: only `helloAck(version:)` and
    `uiReady`. P3+ adds more inbound cases.
    ```swift
    public enum BusInbound: Equatable, Sendable {
        case helloAck(version: String)
        case uiReady
    }
    extension BusInbound: Codable {
        private enum Discriminator: String, Codable { case helloAck, uiReady }
        private enum CodingKeys: String, CodingKey { case type, version }
        // exhaustive init(from:) and encode(to:) per the pattern above
    }
    ```

    **5. `packages/Bus/Sources/Bus/BusReply.swift`** — Plist-serializable reply:
    ```swift
    public struct BusReply: Sendable {
        public let ok: Bool
        public let value: String?   // JSON-encoded payload or nil
        public let error: String?

        public init(ok: Bool, value: String? = nil, error: String? = nil) {
            self.ok = ok; self.value = value; self.error = error
        }

        public static let success = BusReply(ok: true)
        public static func failure(_ message: String) -> BusReply {
            BusReply(ok: false, error: message)
        }

        /// Converts to a plist-serializable dictionary that `WKScriptMessageHandlerWithReply.replyHandler`
        /// accepts. WebKit rejects arbitrary `Codable` — only NSNumber/NSString/NSArray/NSDictionary/NSNull.
        public func asPlist() -> [String: Any] {
            if ok {
                return ["ok": true, "value": (value as Any?) ?? NSNull()]
            } else {
                return ["ok": false, "error": error ?? "unknown"]
            }
        }
    }
    ```

    **6. `packages/Bus/Sources/Bus/BusError.swift`**:
    ```swift
    public enum BusError: Error, Sendable, Equatable {
        case decodeFailed(String)
        case bridgeNotReady
        case handshakeMismatch(swift: String, js: String)
        case handshakeTimeout
    }
    ```

    **7. `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift`** —
    Add `case bus` to the existing enum (OBS-06 extension per RESEARCH-07).
    This is a ONE-LINE change — preserve all existing cases verbatim:
    ```swift
    public enum JarvisLogChannel: String, Sendable, CaseIterable {
        case agent
        case tools
        case ui
        case system
        case bus     // Phase 2 addition — P2 SUMMARY documents the OBS-06 expansion
    }
    ```
    Rationale (RESEARCH open question #7): bus is busy enough in replay traces
    that mixing into `ui` muddies debugging. Adding a 5th channel is
    2-line and non-breaking (existing callers still compile).

    **8. JSON Fixtures (14 files under `packages/Bus/Tests/BusTests/Fixtures/`):**
    Exact verbatim contents (single line each, no trailing newline needed — tests
    parse via JSONDecoder):
    - `hello.json`: `{"type":"hello","version":"2.0.0"}`
    - `helloAck.json`: `{"type":"helloAck","version":"2.0.0"}`
    - `hudState.idle.json`: `{"type":"hudState","state":"idle"}`
    - `hudState.listening.json`: `{"type":"hudState","state":"listening"}`
    - `hudState.thinking.json`: `{"type":"hudState","state":"thinking"}`
    - `hudState.speaking.json`: `{"type":"hudState","state":"speaking"}`
    - `hudState.awaitingConfirmation.json`: `{"type":"hudState","state":"awaitingConfirmation"}`
    - `hudState.reconfiguring.json`: `{"type":"hudState","state":"reconfiguring"}`
    - `hudState.booting.json`: `{"type":"hudState","state":"booting"}`
    - `tokenDelta.json`: `{"type":"tokenDelta","text":"Hello, world!"}`
    - `audioLevel.json`: `{"type":"audioLevel","rms":0.42}`
    - `toolCallStart.json`: `{"type":"toolCallStart","id":"550e8400-e29b-41d4-a716-446655440000","name":"get_time","argsPreview":"{}"}`
    - `toolCallEnd.json`: `{"type":"toolCallEnd","id":"550e8400-e29b-41d4-a716-446655440000","ok":true,"previewOrError":"\"2026-04-23T16:00:00Z\""}`
    - `turnStarted.json`: `{"type":"turnStarted","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8"}`
    - `turnEnded.json`: `{"type":"turnEnded","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","terminator":"completed"}`

    Plan 02 (TS mirror) mirrors these exact files under `webview/packages/bus/fixtures/`
    so both languages parse identical bytes. Plan 04's parity script asserts the
    directories stay in sync.

    **9. `packages/Bus/Tests/BusTests/CodableRoundTripTests.swift`** — XCTest
    cases, one `test_<case>` per fixture. Use `Bundle.module.url(forResource:)`
    to load JSON, decode via `BusCoder.makeDecoder()`, re-encode via
    `BusCoder.makeEncoder()`, normalize via `JSONSerialization.jsonObject`
    → compare as `NSDictionary`/`NSArray` (handles key-order differences).
    Include negative tests: `test_decodeUnknownTypeFails` (`{"type":"unknown"}`
    → expect `DecodingError`), `test_decodeMissingTypeFails`
    (`{"version":"2.0.0"}` → expect `DecodingError`).
  </action>
  <verify>
    <automated>cd packages/Bus && swift test --filter CodableRoundTripTests</automated>
  </verify>
  <done>
    All 14 fixtures decode + re-encode to byte-equal (modulo key order) form.
    Negative tests reject unknown discriminator.
    `grep -rn '\.hudState\b' packages/Bus/Sources/Bus/BusOutbound.swift` shows
    exhaustive switch with zero `default:` branches (in this file, after
    stripping comments: `grep -v '^[[:space:]]*//' packages/Bus/Sources/Bus/BusOutbound.swift | grep -c 'default:'` == 0).
    `grep -c 'case bus$' packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift` == 1.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: WebviewBridge with WKScriptMessageHandlerWithReply + Handshake state machine</name>
  <files>
    packages/Bus/Sources/Bus/Handshake.swift,
    packages/Bus/Sources/Bus/WebviewBridge.swift,
    packages/Bus/Tests/BusTests/WebviewBridgeTests.swift,
    packages/Bus/Tests/BusTests/HandshakeTests.swift
  </files>
  <behavior>
    - Test 1: Inbound `{"type":"helloAck","version":"2.0.0"}` on a fresh bridge (state=.sentHello) flips state to `.armed` and invokes `onHandshakeArmed`
    - Test 2: Inbound `{"type":"helloAck","version":"1.9.0"}` when Swift is at `"2.0.0"` flips state to `.mismatched(swift: "2.0.0", js: "1.9.0")` AND calls `alertPresenter` exactly once
    - Test 3: If 2s elapses after `startHandshake()` without a helloAck, state flips to `.timedOut` AND calls `alertPresenter` exactly once
    - Test 4: Inbound decode failure (malformed JSON, non-String body) calls `replyHandler` with `(nil, error)` — never `(value, _)`
    - Test 5: Inbound decode success routes the decoded `BusInbound` to `onInbound`, which returns a `BusReply`; replyHandler sees `(reply.asPlist() as NSDictionary, nil)`
    - Test 6: `onInbound` returning nil results in `replyHandler(["ok": true], nil)` (implicit success)
    - Test 7: `onInbound` throwing an error results in `replyHandler(nil, errorMessage)`
    - Test 8: Handshake helloAck branch is handled INSIDE the bridge — `onInbound` is not called for that case (so P3's `HudStateCoordinator` doesn't need to know about handshake)
  </behavior>
  <action>
    **Decisions honored:** WKScriptMessageHandlerWithReply per HUD-03 + RESEARCH §HUD-03 deep-dive.
    `MainActor.assumeIsolated` per Apple DevForums 751086.
    Handshake 2s timeout per RESEARCH §HUD-05.
    Content world `"JarvisBusWorld"` per RESEARCH §pitfall 4.
    Injectable `alertPresenter` so tests verify the alert path without NSAlert.

    **1. `packages/Bus/Sources/Bus/Handshake.swift`:**
    ```swift
    import Foundation

    public enum HandshakeState: Equatable, Sendable {
        case idle
        case sentHello(deadline: Date)
        case armed
        case mismatched(swift: String, js: String)
        case timedOut
    }

    /// 2s handshake timeout per RESEARCH §HUD-05. The deadline is wall-clock
    /// `Date` (not monotonic) because `Date.now` inside `Task.sleep` is what
    /// the compiler hands us on Swift 6; off-by-microseconds doesn't matter.
    public enum HandshakeTiming {
        public static let timeout: Duration = .seconds(2)
    }
    ```

    **2. `packages/Bus/Sources/Bus/WebviewBridge.swift`:**
    Follow RESEARCH §HUD-03 pattern sketch verbatim with the fixes noted below.
    ```swift
    import Foundation
    import WebKit
    import Logging

    @MainActor
    public final class WebviewBridge: NSObject {
        public typealias AlertPresenter = @MainActor (_ title: String, _ body: String) -> Void

        private let webView: WKWebView
        private let messageHandlerName: String
        private let contentWorld: WKContentWorld
        private let encoder = BusCoder.makeEncoder()
        private let decoder = BusCoder.makeDecoder()
        private let logger = Logger(label: JarvisLogChannel.bus.rawValue)
        private let alertPresenter: AlertPresenter

        /// Set by AppDelegate (P3) to receive decoded inbound messages.
        /// Throwing here surfaces as `(nil, errorMessage)` to the JS Promise
        /// reject path.
        public var onInbound: (@MainActor (BusInbound) async throws -> BusReply?)?

        /// Called exactly once when handshake succeeds. AppDelegate wires this
        /// to "unblock outbound sends" / "kick off P3 consumers."
        public var onHandshakeArmed: (@MainActor () -> Void)?

        public private(set) var handshakeState: HandshakeState = .idle
        private var timeoutTask: Task<Void, Never>?

        public init(
            webView: WKWebView,
            messageHandlerName: String = "jarvisBus",
            contentWorldName: String = "JarvisBusWorld",
            alertPresenter: @escaping AlertPresenter
        ) {
            self.webView = webView
            self.messageHandlerName = messageHandlerName
            self.contentWorld = WKContentWorld.world(name: contentWorldName)
            self.alertPresenter = alertPresenter
            super.init()

            webView.configuration.userContentController.addScriptMessageHandler(
                self,
                contentWorld: self.contentWorld,
                name: self.messageHandlerName
            )
        }

        deinit {
            // Note: removeScriptMessageHandler is @MainActor; deinit may be
            // non-isolated. Plan 03 handles explicit teardown; deinit left
            // as best-effort cleanup via MainActor.assumeIsolated if needed.
        }

        /// Plan 03 calls after `WKNavigationDelegate.webView(_:didFinish:)`.
        /// P2-01 scope: state machine only — the actual `callAsyncJavaScript`
        /// hello send is a P2-03 concern. For test visibility, the state flip
        /// and timeout Task are the testable observable.
        public func startHandshake() {
            let deadline = Date().addingTimeInterval(2.0)
            handshakeState = .sentHello(deadline: deadline)
            scheduleTimeout()
        }

        /// Stubbed outbound API — Plan 03 replaces the body with the real
        /// `callAsyncJavaScript` call. P2-01 scope is contract surface only so
        /// tests can reference the signature.
        public func send(_ msg: BusOutbound) async throws {
            guard handshakeState == .armed else {
                throw BusError.bridgeNotReady
            }
            // P2-01 stub: serialize to prove Codable works, but don't call JS.
            _ = try encoder.encode(msg)
            // P2-03 replaces this with the callAsyncJavaScript body.
        }

        // MARK: - Private

        private func scheduleTimeout() {
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: HandshakeTiming.timeout)
                guard !Task.isCancelled, let self else { return }
                self.handleTimeout()
            }
        }

        private func handleTimeout() {
            // Idempotent: if already armed/mismatched, do nothing.
            guard case .sentHello = handshakeState else { return }
            logger.critical("bus handshake timeout after 2s")
            handshakeState = .timedOut
            alertPresenter(
                "Jarvis HUD couldn't start",
                "The HUD bundle did not respond to the bus handshake within 2 seconds. Rebuild Jarvis from source."
            )
        }

        fileprivate func handleHelloAck(_ jsVersion: String) {
            timeoutTask?.cancel()
            timeoutTask = nil
            if jsVersion == BUS_PROTOCOL_VERSION {
                handshakeState = .armed
                logger.info("bus handshake armed at v\(jsVersion)")
                onHandshakeArmed?()
            } else {
                handshakeState = .mismatched(swift: BUS_PROTOCOL_VERSION, js: jsVersion)
                logger.critical("bus handshake mismatch: swift=\(BUS_PROTOCOL_VERSION) js=\(jsVersion)")
                alertPresenter(
                    "Jarvis HUD couldn't start",
                    "The HUD bundle was built against bus protocol v\(jsVersion); the app expects v\(BUS_PROTOCOL_VERSION). Rebuild Jarvis from source."
                )
            }
        }
    }

    // MARK: - WKScriptMessageHandlerWithReply

    extension WebviewBridge: WKScriptMessageHandlerWithReply {
        public nonisolated func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            // Apple DevForums 751086 workaround. `WKScriptMessage.body` is
            // documented as main-thread-only but the protocol is not
            // @MainActor, so Swift 6 requires us to assert the isolation we
            // already have (WebKit always calls this on main).
            MainActor.assumeIsolated {
                guard let raw = message.body as? String else {
                    self.logger.error("bus: inbound body was not a String")
                    replyHandler(nil, "bus: expected string payload")
                    return
                }
                let data = Data(raw.utf8)
                let inbound: BusInbound
                do {
                    inbound = try self.decoder.decode(BusInbound.self, from: data)
                } catch {
                    self.logger.error("bus: inbound decode failed: \(error)")
                    replyHandler(nil, "bus: decode error: \(error)")
                    return
                }

                // Handshake ack is handled inline — onInbound consumers
                // never see it (per RESEARCH §HUD-03 "Handshake ack is
                // handled inline to avoid callout to consumer").
                if case .helloAck(let version) = inbound {
                    self.handleHelloAck(version)
                    replyHandler(BusReply.success.asPlist(), nil)
                    return
                }

                // Non-handshake inbound: dispatch to consumer.
                Task { @MainActor [weak self] in
                    guard let self else {
                        replyHandler(nil, "bus: bridge deallocated")
                        return
                    }
                    do {
                        let reply = try await self.onInbound?(inbound)
                        replyHandler((reply ?? .success).asPlist(), nil)
                    } catch {
                        replyHandler(nil, "bus: handler error: \(error)")
                    }
                }
            }
        }
    }
    ```

    **3. `packages/Bus/Tests/BusTests/HandshakeTests.swift`** — Three primary tests
    + supporting infrastructure:
    ```swift
    // Each test creates a WKWebView, a WebviewBridge with an injected
    // alertPresenter that writes into an @MainActor counter, and drives the
    // state machine via synthesized inbound messages (can't easily call the
    // protocol method directly — instead, test via a `testOnlyHandleInbound`
    // seam added to WebviewBridge OR via direct state inspection after
    // calling handleHelloAck through @testable import).
    ```
    Add `@testable import Bus` and mark `handleHelloAck(_:)` as `internal`
    (not fileprivate) so tests can drive it directly — this is the cleanest
    Swift-idiomatic test seam for an actor-ish class. Tests:
    - `test_handshakeArmsOnMatchingVersion` — call `startHandshake()`, then
      `bridge.handleHelloAck("2.0.0")`, assert `state == .armed` and
      `onHandshakeArmed` fired once and `alertCount == 0`.
    - `test_handshakeMismatchTriggersAlertAndBlocks` — call `startHandshake()`,
      then `bridge.handleHelloAck("1.9.0")`, assert state is `.mismatched(swift: "2.0.0", js: "1.9.0")`
      and `alertCount == 1` (captured title contains "couldn't start").
    - `test_handshakeTimeoutTriggersAlert` — call `startHandshake()`, wait
      >2s via `XCTestExpectation.fulfill()` in `alertPresenter`, assert
      state is `.timedOut` and `alertCount == 1`. Use
      `await fulfillment(of: [exp], timeout: 3.0)`.
    - `test_handshakeTimeoutCancelledByArm` — call `startHandshake()`, after
      100ms call `handleHelloAck("2.0.0")`, wait 2.5s total, assert state
      stayed `.armed` and `alertCount == 0` (timeout Task was cancelled).

    **4. `packages/Bus/Tests/BusTests/WebviewBridgeTests.swift`** — Tests for
    the inbound decoder path. Use `WKWebView` + a real `WKUserContentController`
    + inject synthesized `WKScriptMessage` bodies. Simplest approach: extract
    the decode-and-dispatch logic into a `handleInboundString(_:replyHandler:)`
    internal method on `WebviewBridge`, and have the `WKScriptMessageHandlerWithReply`
    protocol method just call it. Then tests drive `handleInboundString`
    directly. Tests:
    - `test_inboundDecodeSuccessCallsOnInbound` — set `onInbound` to record
      calls + return `BusReply.success`. Call `handleInboundString("{\"type\":\"uiReady\"}", …)`.
      Assert recorded call count == 1, replyHandler saw `(success plist, nil)`.
    - `test_inboundDecodeFailureSurfacesAsFailureReply` — call
      `handleInboundString("{not json", …)`. Assert replyHandler saw
      `(nil, error)` where error contains "decode".
    - `test_inboundNonStringBodyIsFailureReply` — call
      `handleInboundString(nil-ish, …)` via the protocol path with a
      `WKScriptMessage` whose body is a number. (If hard to synthesize
      WKScriptMessage, cover this by a dedicated `handleInboundBody(_ body: Any?, …)`
      seam.)
    - `test_helloAckHandledInlineDoesNotCallOnInbound` — set `onInbound` to
      increment a counter. Call `startHandshake()` + `handleInboundString("{\"type\":\"helloAck\",\"version\":\"2.0.0\"}", …)`.
      Assert counter == 0, state == `.armed`.
    - `test_onInboundThrowingErrorSurfacesAsFailureReply` — set
      `onInbound` to throw `BusError.bridgeNotReady`. Call
      `handleInboundString("{\"type\":\"uiReady\"}", …)`. Assert replyHandler saw `(nil, error)`.
    - `test_contentWorldIsRegisteredUnderCustomName` — assert
      `webView.configuration.userContentController` holds a handler under
      `"jarvisBus"` in `WKContentWorld.world(name:"JarvisBusWorld")` — probe
      via the handler count or by sending a scripted message. (If hard to
      introspect, assert via side-effect: script in non-Jarvis world doesn't
      reach the handler — optional if too brittle; may omit this one test
      with comment "content-world isolation is integration-tested in P3".)

    **TDD flow:** Start by writing `HandshakeTests` with the public surface
    (mutating `handshakeState`, `onHandshakeArmed`, `alertPresenter` capture),
    watch them fail against a skeleton `Handshake.swift` / `WebviewBridge.swift`,
    then fill in `handleHelloAck` + `scheduleTimeout` + `handleTimeout` until
    green. Do the inbound tests second. Commit RED → GREEN atomically per task.
  </action>
  <verify>
    <automated>cd packages/Bus && swift test --filter WebviewBridgeTests && swift test --filter HandshakeTests</automated>
  </verify>
  <done>
    All handshake state-machine paths tested (match, mismatch, timeout, timeout-cancelled-by-arm).
    Inbound decode success/failure/error-throwing paths all surface through `replyHandler` correctly.
    helloAck handled inline — `onInbound` never sees it.
    `grep -n 'MainActor.assumeIsolated' packages/Bus/Sources/Bus/WebviewBridge.swift` shows the Apple DevForums 751086 workaround at the protocol-method site.
    `grep -c 'evaluateJavaScript' packages/Bus/Sources/Bus/` == 0 (HUD-04 invariant; `send(_:)` stub does not call the forbidden API).
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| JS → Swift inbound | Untrusted JSON from the webview process (could contain crafted `type` strings, UTF-8 edge cases, oversized payloads) |
| Swift → JS outbound | Trusted within Jarvis.app process; still must not produce code-as-string to avoid XSS regressions in future edits |
| Content world | `JarvisBusWorld` isolates handler/stub from page scripts — page-script world cannot access `webkit.messageHandlers.jarvisBus` |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-02-01 | Tampering | `BusOutbound` / `BusInbound` Codable | mitigate | Hand-written `init(from:)` with exhaustive `switch tag` on `Discriminator`; no `default:`; unknown discriminator throws `DecodingError`. Schema drift produces a decode failure, not UB. |
| T-02-02 | Tampering | Inbound `message.body` parse | mitigate | `message.body as? String` guard; non-string body → `replyHandler(nil, "bus: expected string payload")`. No unchecked cast propagation. |
| T-02-03 | Information Disclosure | Page-script bus hijack | mitigate | Handler installed in `WKContentWorld.world(name: "JarvisBusWorld")` — page scripts cannot observe or post to it. |
| T-02-04 | Denial of Service | Unbounded inbound flood from webview | accept | Single-user personal project; JS side is in-process and trusted. P3 may add rate limiting if realtime events grow. |
| T-02-05 | Tampering | SE-0295 synthesized Codable fills missing case | mitigate | `public enum BusOutbound: Equatable, Sendable` WITHOUT inline `Codable` conformance; `Codable` added ONLY in extension where exhaustive switches force errors (per RESEARCH §pitfall 1). |
| T-02-06 | Spoofing | Handshake JS version claim | accept | Single-process, trusted JS bundle. Strict-equality check on `BUS_PROTOCOL_VERSION` is sufficient; mismatch is a build-time bug, not an attack. |
| T-02-07 | Information Disclosure | `turnNonce` or secrets in bus payloads | mitigate | P2 schema review: no `nonce`, `apiKey`, `token`-shaped fields in any `BusInbound`/`BusOutbound` case. Enforced by visual review of `Protocol.swift` + TS mirror at review time. |
</threat_model>

<verification>
**Unit tests (Swift, XCTest):**
- `cd packages/Bus && swift test` — all `CodableRoundTripTests` + `WebviewBridgeTests` + `HandshakeTests` green.
- 14 fixtures, each with its own test method name (e.g. `test_roundTrip_hudState_idle`).

**Exhaustive-switch compile-error invariant (manual smoke):**
- Temporarily add a 9th case to `BusOutbound` without extending the Codable
  extension → `swift build` must fail on missing switch arm in both
  `init(from:)` and `encode(to:)`. Revert. This proves the language-level
  drift preventer works.

**Wire-shape invariant (proven by round-trip tests):**
- `{"type":"hudState","state":"idle"}` → `BusOutbound.hudState(.idle)` → same JSON
- If SE-0295 synthesis leaked, encoding would yield `{"hudState":{"state":"idle"}}` — round-trip tests catch this.
</verification>

<success_criteria>
1. `packages/Bus/Package.swift` exists; `swift build` inside `packages/Bus/` succeeds under Swift 6 strict concurrency.
2. `BUS_PROTOCOL_VERSION = "2.0.0"` exists at `packages/Bus/Sources/Bus/Protocol.swift` — grep-verifiable.
3. `BusOutbound.hudState(.idle)` round-trips through `{"type":"hudState","state":"idle"}` (byte-equal modulo key order), not `{"hudState":{"state":"idle"}}`.
4. 14 XCTest methods pass, one per `BusOutbound` case + `helloAck` + `uiReady`.
5. `WebviewBridge` conforms to `WKScriptMessageHandlerWithReply` (NOT the legacy protocol) and uses `MainActor.assumeIsolated` at the protocol method.
6. Handshake state machine: matching version → `.armed` + `onHandshakeArmed` fires + no alert; mismatch → `.mismatched` + alert fires; 2s without ack → `.timedOut` + alert fires; ack before timeout cancels the timeout Task.
7. `send(_:)` stub refuses to send when not armed (throws `BusError.bridgeNotReady`).
8. Zero `evaluateJavaScript` calls in the package — `grep -c 'evaluateJavaScript' packages/Bus/Sources/` == 0.
9. Zero `default:` branches in Codable switch statements — `grep -v '^[[:space:]]*//' packages/Bus/Sources/Bus/BusOutbound.swift | grep -c 'default:'` == 0 (same for `BusInbound.swift`).
10. `JarvisLogChannel.bus` case exists — `grep -c 'case bus$' packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift` == 1.
</success_criteria>

<output>
After completion, create `.planning/phases/02-bus/02-01-SUMMARY.md` covering:
- Files created (package manifest, 7 sources, 3 test files, 14 fixtures, 1 modified Logging file)
- Key decisions: hand-written Codable rationale, `MainActor.assumeIsolated` use, `JarvisLogChannel.bus` expansion
- Tech-stack adds: WebKit framework, first-class `packages/Bus` SPM peer
- Patterns established: Discriminator + CodingKeys hand-written Codable pattern (applies to future bus schema adds in P3+), `alertPresenter` closure-injection for NSAlert-avoiding tests, `handleInboundString` internal seam for protocol testing
- Requirements completed: HUD-03 (inbound path), HUD-05 (handshake state machine), SEC-09 (hand-written Codable + exhaustive switches + per-case fixtures)
- Handoff to Plan 02 (TS mirror must cite these exact fixture bytes) and Plan 03 (consumes `send(_:)` via real `callAsyncJavaScript`; calls `startHandshake()` from `WKNavigationDelegate`)
</output>
