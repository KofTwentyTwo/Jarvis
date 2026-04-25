---
phase: 05-mcp
plan: 02
type: execute
wave: 2
depends_on: [05-01]
files_modified:
  - mcp-servers/mcp-time/Package.swift
  - mcp-servers/mcp-time/Sources/mcp-time/main.swift
  - mcp-servers/mcp-time/Support/Info.plist
  - mcp-servers/mcp-time/Support/mcp-time.entitlements
  - mcp-servers/mcp-clipboard/Package.swift
  - mcp-servers/mcp-clipboard/Sources/mcp-clipboard/main.swift
  - mcp-servers/mcp-clipboard/Sources/mcp-clipboard/PasteboardReader.swift
  - mcp-servers/mcp-clipboard/Tests/PasteboardReaderTests/PasteboardReaderTests.swift
  - mcp-servers/mcp-clipboard/Support/Info.plist
  - mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements
  - project.yml
  - packages/MCP/Tests/MCPTests/MCPTimeIntegrationTests.swift
  - packages/MCP/Tests/MCPTests/MCPClipboardIntegrationTests.swift
autonomous: true
requirements: [MCP-02, MCP-03]
tags: [mcp-helpers, mcp-time, mcp-clipboard, nspasteboard, fileURL-refusal, xcodegen, copy-helpers]
assumptions:
  - `mcp-time` and `mcp-clipboard` carry NO entitlements beyond Hardened Runtime baseline (RESEARCH §Helper entitlement file). Only `mcp-applescript` (Plan 05-03) holds `automation.apple-events`.
  - The `Contents/Helpers/` directory exists in the built bundle (Phase 1's `Create Contents/Helpers directory` postBuildScript materializes it; the empty `copyFiles` placeholder for `wrapper/Contents/Helpers` exists in `project.yml`).
  - xcodegen drops empty `copyFiles` phases on regeneration (P1-05 SUMMARY Deferred Item #2). This plan adds NON-empty `copyFiles` entries pointing at each helper `.app` BUILT_PRODUCTS_DIR product so xcodegen preserves the phase.
  - `mcp-clipboard` uses `NSPasteboard.general` from AppKit (RESEARCH Pattern 7) — it is an AppKit-linking helper but does NOT need `NSApplication.run()` for synchronous pasteboard reads (RESEARCH Open Question #3 inverse — pasteboard reads are synchronous on the calling thread).
  - The unit test for PasteboardReader uses dependency injection (a `PasteboardLike` protocol) so we never touch `NSPasteboard.general` in tests — tests run headless without GUI session attachment.
  - Anti-pattern callouts: DO NOT add `automation.apple-events` to mcp-time or mcp-clipboard entitlements (cross-helper drift). DO NOT log to stdout in either helper (Pitfall #4 corrupts JSON-RPC). DO NOT use `Code Sign On Copy` for the copyFiles phase that ships these helpers (P1-05 verify-codesign-settings.sh would fail). DO NOT call `osascript` from mcp-clipboard (RESEARCH Anti-Patterns).
must_haves:
  truths:
    - "An MCPClient consumer can register `mcp-time` from `Bundle.main.bundleURL/Contents/Helpers/mcp-time.app/Contents/MacOS/mcp-time` and call `get_time` to receive an ISO 8601 timestamp string."
    - "An MCPClient consumer can register `mcp-clipboard` and call `get_clipboard`; if the system pasteboard contains `NSPasteboardTypeFileURL`, the helper returns `isError: true` with a refusal message — even if a string variant is also present."
    - "Both helpers ship as separately-codesigned nested `.app` bundles under `Contents/Helpers/<name>.app/`; the post-build entitlement grep (verify-entitlements.sh) finds no `automation.apple-events` in either helper."
    - "Helpers' Info.plist carries `LSUIElement=true` AND `LSBackgroundOnly=true` (Pitfall #3 — neither helper appears in Dock or Cmd-Tab)."
    - "Both helpers run with `swift build` cleanly under SWIFT_VERSION 6.0 + strict concurrency."
    - "A trip through `MCPClient.callTool('get_time', [:])` returns a string parseable by `ISO8601DateFormatter()` (round-trip integration test)."
  artifacts:
    - path: "mcp-servers/mcp-time/Sources/mcp-time/main.swift"
      provides: "MCP server exposing single tool `get_time` returning ISO 8601 current time."
      min_lines: 30
    - path: "mcp-servers/mcp-clipboard/Sources/mcp-clipboard/main.swift"
      provides: "MCP server exposing `get_clipboard`; refuses fileURL pasteboards via PasteboardReader."
      min_lines: 30
    - path: "mcp-servers/mcp-clipboard/Sources/mcp-clipboard/PasteboardReader.swift"
      provides: "Testable `PasteboardLike` protocol + concrete `SystemPasteboardReader`; refusal logic isolated for unit testing."
      min_lines: 40
    - path: "mcp-servers/mcp-time/Support/Info.plist"
      provides: "Helper Info.plist: LSUIElement=YES, LSBackgroundOnly=YES, CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-time."
      contains: "<key>LSUIElement</key>"
    - path: "mcp-servers/mcp-clipboard/Support/Info.plist"
      provides: "Helper Info.plist: LSUIElement=YES, LSBackgroundOnly=YES, CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-clipboard."
      contains: "<key>LSBackgroundOnly</key>"
    - path: "mcp-servers/mcp-time/Support/mcp-time.entitlements"
      provides: "Empty plist dict — no special grants beyond Hardened Runtime."
    - path: "mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements"
      provides: "Empty plist dict — no special grants beyond Hardened Runtime."
    - path: "project.yml"
      provides: "Two new xcodegen targets (mcp-time, mcp-clipboard) that produce .app bundles + a non-empty copyFiles entry on Jarvis target shipping each helper into Contents/Helpers/."
  key_links:
    - from: "mcp-servers/mcp-clipboard/Sources/mcp-clipboard/main.swift"
      to: "PasteboardReader.read()"
      via: "withMethodHandler(CallTool.self) calls reader.read(); reader.read() returns .refusedFileURL OR .text(String) OR .empty"
      pattern: "PasteboardReader|reader\\.read"
    - from: "project.yml"
      to: "Jarvis target Contents/Helpers/"
      via: "copyFiles destination=wrapper, subpath=Contents/Helpers, files=[mcp-time.app, mcp-clipboard.app]"
      pattern: "subpath: Contents/Helpers"
    - from: "scripts/codesign.sh"
      to: "Contents/Helpers/mcp-time.app/Contents/Resources/mcp-time.entitlements"
      via: "deepest-first walker (already exists from P1-05); helpers ship per-helper .entitlements at this path"
      pattern: "find.*\\-depth.*\\.app"
---

<objective>
Build and ship the two non-confirmation MCP helpers — `mcp-time` and `mcp-clipboard` — as separately-codesigned nested `.app` bundles under `Contents/Helpers/`, exposing the tools `get_time` and `get_clipboard` through the MCPClient infrastructure landed in 05-01.

Why these two together: they have **disjoint file scope**, **identical packaging shape** (both empty entitlements + identical Info.plist template + same xcodegen target shape), and **no confirmation surface** (those land in 05-03/05-05 with `mcp-applescript`). Bundling them in one plan keeps the cross-cutting xcodegen + project.yml work in a single edit while leaving each helper's Swift source independently buildable.

Why NOT touch `automation.apple-events`: only `mcp-applescript` (Plan 05-03) gets that entitlement. P1-05's `verify-entitlements.sh --post-codesign` enforces "any helper other than `mcp-applescript` carrying `apple-events` is a build failure" — this plan validates that gate stays green by adding two helpers with empty entitlements.

Output:
- 2 helper SPM packages under `mcp-servers/` (peer to `packages/`).
- 2 sets of Info.plist + .entitlements + main.swift + (clipboard only) PasteboardReader.swift.
- `project.yml` modifications: 2 new xcodegen targets producing `.app` products + a single non-empty `copyFiles` entry on the Jarvis target.
- 2 integration tests in `packages/MCP/Tests/MCPTests/` exercising round-trip calls through MCPClient against the built helpers (Bundle.main.bundleURL based path resolution).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/phases/05-mcp/05-RESEARCH.md
@.planning/phases/05-mcp/05-01-mcp-client-stdio-transport-PLAN.md
@.planning/phases/01-foundations/01-05-SUMMARY.md
@CLAUDE.md
@scripts/codesign.sh
@scripts/verify-entitlements.sh
@project.yml
@App/Jarvis.Release.entitlements
@App/Info.plist

<interfaces>
<!--
  Helper-side surface — these are the tools the orchestrator (Plan 05-04) will register
  through `MCPClient.register(...)` and call by name.
-->

```swift
// mcp-time exposes:
Tool(
    name: "get_time",
    description: "Returns the current local date and time as ISO 8601.",
    inputSchema: .object(["type": .string("object"), "properties": .object([:]), "required": .array([])])
)
// CallTool result: .text(text: ISO8601DateFormatter().string(from: Date()), annotations: nil, _meta: nil)

// mcp-clipboard exposes:
Tool(
    name: "get_clipboard",
    description: "Returns the current text content of the system clipboard. Refuses file URLs for security.",
    inputSchema: .object(["type": .string("object"), "properties": .object([:]), "required": .array([])])
)
// CallTool result possibilities:
//   .text(text: <clipboard string>, ..., isError: false) — happy path
//   .text(text: "Clipboard contains a file URL; refusing...", ..., isError: true) — MCP-03 refusal
//   .text(text: "(clipboard empty)", ..., isError: false) — empty pasteboard
```

PasteboardReader contract (mcp-clipboard internal, testable):

```swift
// mcp-servers/mcp-clipboard/Sources/mcp-clipboard/PasteboardReader.swift

public protocol PasteboardLike: Sendable {
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType: NSPasteboard.PasteboardType) -> String?
}

public enum ClipboardReadResult: Sendable, Equatable {
    case text(String)
    case empty
    case refusedFileURL
}

public struct PasteboardReader: Sendable {
    public let pasteboard: any PasteboardLike

    public init(pasteboard: any PasteboardLike)

    public func read() -> ClipboardReadResult
}
```

This plan does NOT modify the AppKit `NSPasteboard` extension to conform to `PasteboardLike` in production — production code wraps the real `NSPasteboard.general` via a tiny adapter struct in main.swift. Tests inject a `MockPasteboard` conforming to `PasteboardLike`.

Helper bundle layout produced by xcodegen + codesign.sh chain:

```
Jarvis.app/
└── Contents/
    └── Helpers/
        ├── mcp-time.app/
        │   └── Contents/
        │       ├── Info.plist          (CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-time, LSUIElement=YES, LSBackgroundOnly=YES)
        │       ├── MacOS/mcp-time      (executable)
        │       └── Resources/mcp-time.entitlements   (empty plist; codesign.sh reads from here per P1-05)
        └── mcp-clipboard.app/
            └── Contents/
                ├── Info.plist          (CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-clipboard, ...)
                ├── MacOS/mcp-clipboard
                └── Resources/mcp-clipboard.entitlements
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: mcp-time helper — package, source, plist, entitlements</name>
  <files>
    mcp-servers/mcp-time/Package.swift,
    mcp-servers/mcp-time/Sources/mcp-time/main.swift,
    mcp-servers/mcp-time/Support/Info.plist,
    mcp-servers/mcp-time/Support/mcp-time.entitlements
  </files>
  <behavior>
    - The helper builds standalone via `swift build --package-path mcp-servers/mcp-time -c release` and produces an executable at `.build/release/mcp-time`.
    - Running the executable with stdin/stdout connected to a parent MCPClient and calling `get_time` returns a single `.text` content whose body parses cleanly via `ISO8601DateFormatter()` into a `Date` within ±5 seconds of `Date()`.
    - Calling any other tool name returns `isError: true` with text "Unknown tool".
    - Info.plist has `LSUIElement=true`, `LSBackgroundOnly=true`, `CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-time`, `CFBundleExecutable=mcp-time`, `CFBundlePackageType=APPL`, `CFBundleVersion=1`, `LSMinimumSystemVersion=13.0`.
    - The .entitlements file is a plist with empty `<dict/>` — NO `automation.apple-events`, NO `device.audio-input`, NO `cs.allow-jit`. Hardened Runtime is inherited via codesign flags from the chain.
  </behavior>
  <action>
    1. Create `mcp-servers/mcp-time/Package.swift`:
       ```swift
       // swift-tools-version:6.0
       import PackageDescription

       let package = Package(
           name: "mcp-time",
           platforms: [.macOS(.v13)],
           dependencies: [
               .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
           ],
           targets: [
               .executableTarget(
                   name: "mcp-time",
                   dependencies: [.product(name: "MCP", package: "swift-sdk")],
                   swiftSettings: [.swiftLanguageMode(.v6)]
               )
           ]
       )
       ```

    2. Create `mcp-servers/mcp-time/Sources/mcp-time/main.swift` per RESEARCH Pattern 6:
       ```swift
       import MCP
       import Foundation

       @main
       struct MCPTime {
           static func main() async throws {
               let server = Server(
                   name: "mcp-time",
                   version: "1.0.0",
                   capabilities: .init(tools: .init(listChanged: false))
               )

               await server.withMethodHandler(ListTools.self) { _ in
                   .init(tools: [
                       Tool(
                           name: "get_time",
                           description: "Returns the current local date and time as ISO 8601.",
                           inputSchema: .object([
                               "type": .string("object"),
                               "properties": .object([:]),
                               "required": .array([])
                           ])
                       )
                   ])
               }

               await server.withMethodHandler(CallTool.self) { params in
                   guard params.name == "get_time" else {
                       return .init(
                           content: [.text(text: "Unknown tool", annotations: nil, _meta: nil)],
                           isError: true
                       )
                   }
                   let formatter = ISO8601DateFormatter()
                   formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                   let iso = formatter.string(from: Date())
                   return .init(
                       content: [.text(text: iso, annotations: nil, _meta: nil)],
                       isError: false
                   )
               }

               // StdioTransport() default no-arg init is correct for HELPER side
               // (it reads our own stdin / writes our own stdout). Pitfall #1 is
               // about the PARENT side, which uses explicit FDs — not relevant here.
               let transport = StdioTransport()
               try await server.start(transport: transport)
               await server.waitUntilCompleted()
           }
       }
       ```
       Anti-pattern: DO NOT use `Logger(label:)` writing to stdout — let the SDK's default Logger which targets stderr handle helper logs (Pitfall #4). Don't `print(...)` either; that hits stdout.

    3. Create `mcp-servers/mcp-time/Support/Info.plist`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <key>CFBundleIdentifier</key><string>com.koftwentytwo.jarvis.mcp-time</string>
           <key>CFBundleName</key><string>mcp-time</string>
           <key>CFBundleExecutable</key><string>mcp-time</string>
           <key>CFBundleShortVersionString</key><string>1.0.0</string>
           <key>CFBundleVersion</key><string>1</string>
           <key>CFBundlePackageType</key><string>APPL</string>
           <key>LSUIElement</key><true/>
           <key>LSBackgroundOnly</key><true/>
           <key>LSMinimumSystemVersion</key><string>13.0</string>
       </dict>
       </plist>
       ```

    4. Create `mcp-servers/mcp-time/Support/mcp-time.entitlements`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <!-- Empty. mcp-time needs no special grants beyond Hardened Runtime. -->
       </dict>
       </plist>
       ```
  </action>
  <verify>
    <automated>swift build --package-path mcp-servers/mcp-time -c release 2>&amp;1 | tail -3 &amp;&amp; test -x mcp-servers/mcp-time/.build/release/mcp-time &amp;&amp; plutil -lint mcp-servers/mcp-time/Support/Info.plist &amp;&amp; plutil -lint mcp-servers/mcp-time/Support/mcp-time.entitlements &amp;&amp; plutil -extract LSUIElement raw mcp-servers/mcp-time/Support/Info.plist &amp;&amp; plutil -extract LSBackgroundOnly raw mcp-servers/mcp-time/Support/Info.plist &amp;&amp; ! grep -q 'automation.apple-events' mcp-servers/mcp-time/Support/mcp-time.entitlements</automated>
  </verify>
  <done>
    - `swift build --package-path mcp-servers/mcp-time -c release` produces a runnable executable.
    - `plutil -lint` passes on both plists.
    - `LSUIElement` and `LSBackgroundOnly` are both `true` in Info.plist.
    - `mcp-time.entitlements` is grep-clean of `automation.apple-events` (regression for P1-05's per-helper enforcement).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: mcp-clipboard helper — PasteboardReader (testable) + main.swift + plist + entitlements</name>
  <files>
    mcp-servers/mcp-clipboard/Package.swift,
    mcp-servers/mcp-clipboard/Sources/mcp-clipboard/main.swift,
    mcp-servers/mcp-clipboard/Sources/mcp-clipboard/PasteboardReader.swift,
    mcp-servers/mcp-clipboard/Tests/PasteboardReaderTests/PasteboardReaderTests.swift,
    mcp-servers/mcp-clipboard/Support/Info.plist,
    mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements
  </files>
  <behavior>
    - Test (RED first): `PasteboardReaderTests.test_returnsRefusedFileURL_whenTypesContainsFileURL` — `MockPasteboard(types: [.fileURL, .string], string: "innocent string")` → `.read()` returns `.refusedFileURL`. **Critical: refusal triggers regardless of whether `.string` is also present.**
    - Test: `test_returnsRefusedFileURL_whenOnlyFileURL` — `MockPasteboard(types: [.fileURL], string: nil)` → `.refusedFileURL`.
    - Test: `test_returnsText_whenStringPresent_andNoFileURL` — `MockPasteboard(types: [.string], string: "hello")` → `.text("hello")`.
    - Test: `test_returnsEmpty_whenStringIsEmpty` — `MockPasteboard(types: [.string], string: "")` → `.empty`.
    - Test: `test_returnsEmpty_whenStringIsNil_andNoFileURL` — `MockPasteboard(types: [.html], string: nil)` → `.empty` (no string, no fileURL — defensive default).
    - Test: `test_returnsEmpty_whenTypesIsNil` — `MockPasteboard(types: nil, string: nil)` → `.empty`.
  </behavior>
  <action>
    1. Create `mcp-servers/mcp-clipboard/Package.swift`:
       ```swift
       // swift-tools-version:6.0
       import PackageDescription

       let package = Package(
           name: "mcp-clipboard",
           platforms: [.macOS(.v13)],
           dependencies: [
               .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
           ],
           targets: [
               .executableTarget(
                   name: "mcp-clipboard",
                   dependencies: [.product(name: "MCP", package: "swift-sdk")],
                   swiftSettings: [.swiftLanguageMode(.v6)]
               ),
               .testTarget(
                   name: "PasteboardReaderTests",
                   dependencies: ["mcp-clipboard"],
                   swiftSettings: [.swiftLanguageMode(.v6)]
               )
           ]
       )
       ```

    2. Create `mcp-servers/mcp-clipboard/Sources/mcp-clipboard/PasteboardReader.swift`:
       ```swift
       import AppKit
       import Foundation

       public protocol PasteboardLike: Sendable {
           var types: [NSPasteboard.PasteboardType]? { get }
           func string(forType type: NSPasteboard.PasteboardType) -> String?
       }

       public enum ClipboardReadResult: Sendable, Equatable {
           case text(String)
           case empty
           case refusedFileURL
       }

       public struct PasteboardReader: Sendable {
           public let pasteboard: any PasteboardLike

           public init(pasteboard: any PasteboardLike) {
               self.pasteboard = pasteboard
           }

           public func read() -> ClipboardReadResult {
               // MCP-03: Refuse pasteboards carrying NSPasteboardTypeFileURL regardless
               // of string content. Even if a friendly-looking string is also present,
               // a fileURL hint may correlate with a model trying to coerce a path-read.
               // Refusal precedes string extraction to avoid information disclosure.
               if let types = pasteboard.types, types.contains(.fileURL) {
                   return .refusedFileURL
               }
               guard let s = pasteboard.string(forType: .string), !s.isEmpty else {
                   return .empty
               }
               return .text(s)
           }
       }
       ```

    3. Create `mcp-servers/mcp-clipboard/Tests/PasteboardReaderTests/PasteboardReaderTests.swift`:
       ```swift
       import XCTest
       import AppKit
       @testable import mcp_clipboard  // Note SPM module-name munging: `mcp-clipboard` → `mcp_clipboard`

       struct MockPasteboard: PasteboardLike {
           let types: [NSPasteboard.PasteboardType]?
           let storedString: String?
           func string(forType type: NSPasteboard.PasteboardType) -> String? {
               type == .string ? storedString : nil
           }
       }

       final class PasteboardReaderTests: XCTestCase {
           func test_returnsRefusedFileURL_whenTypesContainsFileURL() {
               let reader = PasteboardReader(pasteboard: MockPasteboard(types: [.fileURL, .string], storedString: "innocent string"))
               XCTAssertEqual(reader.read(), .refusedFileURL)
           }
           func test_returnsRefusedFileURL_whenOnlyFileURL() {
               let reader = PasteboardReader(pasteboard: MockPasteboard(types: [.fileURL], storedString: nil))
               XCTAssertEqual(reader.read(), .refusedFileURL)
           }
           func test_returnsText_whenStringPresent_andNoFileURL() {
               let reader = PasteboardReader(pasteboard: MockPasteboard(types: [.string], storedString: "hello"))
               XCTAssertEqual(reader.read(), .text("hello"))
           }
           func test_returnsEmpty_whenStringIsEmpty() {
               let reader = PasteboardReader(pasteboard: MockPasteboard(types: [.string], storedString: ""))
               XCTAssertEqual(reader.read(), .empty)
           }
           func test_returnsEmpty_whenStringIsNil_andNoFileURL() {
               let reader = PasteboardReader(pasteboard: MockPasteboard(types: [.html], storedString: nil))
               XCTAssertEqual(reader.read(), .empty)
           }
           func test_returnsEmpty_whenTypesIsNil() {
               let reader = PasteboardReader(pasteboard: MockPasteboard(types: nil, storedString: nil))
               XCTAssertEqual(reader.read(), .empty)
           }
       }
       ```

    4. Create `mcp-servers/mcp-clipboard/Sources/mcp-clipboard/main.swift`:
       ```swift
       import MCP
       import AppKit
       import Foundation

       struct SystemPasteboard: PasteboardLike {
           let pasteboard: NSPasteboard
           var types: [NSPasteboard.PasteboardType]? { pasteboard.types }
           func string(forType type: NSPasteboard.PasteboardType) -> String? {
               pasteboard.string(forType: type)
           }
       }

       @main
       struct MCPClipboard {
           static func main() async throws {
               let server = Server(
                   name: "mcp-clipboard",
                   version: "1.0.0",
                   capabilities: .init(tools: .init(listChanged: false))
               )

               await server.withMethodHandler(ListTools.self) { _ in
                   .init(tools: [
                       Tool(
                           name: "get_clipboard",
                           description: "Returns the current text content of the system clipboard. Refuses file URLs for security.",
                           inputSchema: .object([
                               "type": .string("object"),
                               "properties": .object([:]),
                               "required": .array([])
                           ])
                       )
                   ])
               }

               await server.withMethodHandler(CallTool.self) { params in
                   guard params.name == "get_clipboard" else {
                       return .init(
                           content: [.text(text: "Unknown tool", annotations: nil, _meta: nil)],
                           isError: true
                       )
                   }
                   let reader = PasteboardReader(pasteboard: SystemPasteboard(pasteboard: .general))
                   switch reader.read() {
                   case .refusedFileURL:
                       return .init(
                           content: [.text(text: "Clipboard contains a file URL; refusing to expose to model (MCP-03).", annotations: nil, _meta: nil)],
                           isError: true
                       )
                   case .empty:
                       return .init(
                           content: [.text(text: "(clipboard empty)", annotations: nil, _meta: nil)],
                           isError: false
                       )
                   case .text(let s):
                       return .init(
                           content: [.text(text: s, annotations: nil, _meta: nil)],
                           isError: false
                       )
                   }
               }

               let transport = StdioTransport()
               try await server.start(transport: transport)
               await server.waitUntilCompleted()
           }
       }
       ```

    5. Create `mcp-servers/mcp-clipboard/Support/Info.plist` mirroring mcp-time but with `CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-clipboard` and `CFBundleName=mcp-clipboard`, `CFBundleExecutable=mcp-clipboard`.

    6. Create `mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements` as empty `<dict/>` — same shape as mcp-time.entitlements.

    Anti-patterns to enforce:
    - DO NOT add `pasteboard.changeCount` polling or any "watch the clipboard" logic — the helper is a one-shot synchronous read on tool call, not a daemon.
    - DO NOT inspect `.fileContents`, `.html`, `.rtf`, `.pdf` types — only `.string` reads are permitted, and only after the fileURL precondition passes.
    - DO NOT add any entitlement to `mcp-clipboard.entitlements`. Pasteboard read is unrestricted on macOS for processes the user launched.
  </action>
  <verify>
    <automated>swift test --package-path mcp-servers/mcp-clipboard --filter PasteboardReaderTests 2>&amp;1 | tail -10 &amp;&amp; swift build --package-path mcp-servers/mcp-clipboard -c release 2>&amp;1 | tail -3 &amp;&amp; test -x mcp-servers/mcp-clipboard/.build/release/mcp-clipboard &amp;&amp; plutil -lint mcp-servers/mcp-clipboard/Support/Info.plist &amp;&amp; plutil -lint mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements &amp;&amp; ! grep -q 'automation.apple-events' mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements</automated>
  </verify>
  <done>
    - All 6 PasteboardReaderTests pass.
    - mcp-clipboard executable builds clean.
    - Info.plist + entitlements lint clean.
    - The .entitlements file is grep-clean of `automation.apple-events`.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: xcodegen target wiring + Copy Helpers phase + integration tests</name>
  <files>
    project.yml,
    packages/MCP/Tests/MCPTests/MCPTimeIntegrationTests.swift,
    packages/MCP/Tests/MCPTests/MCPClipboardIntegrationTests.swift
  </files>
  <behavior>
    - After running `xcodegen generate` and a Debug build, `Jarvis.app/Contents/Helpers/mcp-time.app/Contents/MacOS/mcp-time` exists and is executable.
    - Same for `mcp-clipboard.app/Contents/MacOS/mcp-clipboard`.
    - Each helper's `Contents/Resources/<name>.entitlements` is present (so `scripts/codesign.sh`'s deepest-first walker finds it per P1-05 contract).
    - The post-codesign verification phase (`scripts/verify-entitlements.sh --post-codesign`) passes — i.e., neither helper carries `automation.apple-events`, the directory `Contents/Helpers/` is non-empty, and the main app still meets MAIN_REQUIRED.
    - `MCPTimeIntegrationTests.test_get_time_returns_iso8601` resolves the helper path via `Bundle.main.url(forAuxiliaryExecutable:)` OR a manual walk of `Contents/Helpers/` (whichever resolves), launches it via MCPClient, calls `get_time`, asserts the returned string parses through `ISO8601DateFormatter()`.
    - `MCPClipboardIntegrationTests.test_get_clipboard_runs_and_returns_text_or_refusal` launches mcp-clipboard via MCPClient and asserts the call completes with EITHER `.text` OR an `isError: true` refusal — both are valid outcomes depending on the test runner's pasteboard state.
    - These integration tests run against the **MCP package's** test target (SPM `swift test --package-path packages/MCP`), but they require the host bundle exists. The tests probe `Bundle(for: <test-class>).bundleURL` to find the test runner's bundle, then walk up to find `Contents/Helpers/`. If `Contents/Helpers/<name>.app` is absent, the test marks itself as `XCTSkip("Helper bundle not present in test runner; run via xcodebuild test")`.
  </behavior>
  <action>
    1. Modify `project.yml` to add two new targets at the same indentation level as `Jarvis:` and `JarvisAppTests:`:

       ```yaml
       targets:
         # ... existing Jarvis, JarvisAppTests, JarvisEntitlementProbeTests ...

         mcp-time:
           type: application
           platform: macOS
           sources:
             - path: mcp-servers/mcp-time/Sources/mcp-time
           settings:
             base:
               PRODUCT_BUNDLE_IDENTIFIER: com.koftwentytwo.jarvis.mcp-time
               PRODUCT_NAME: mcp-time
               INFOPLIST_FILE: mcp-servers/mcp-time/Support/Info.plist
               GENERATE_INFOPLIST_FILE: NO
               CODE_SIGN_ENTITLEMENTS: mcp-servers/mcp-time/Support/mcp-time.entitlements
               ENABLE_HARDENED_RUNTIME: YES
               CODE_SIGN_STYLE: Manual
               CODE_SIGN_IDENTITY: "-"
               OTHER_CODE_SIGN_FLAGS: "--options=runtime --timestamp"
               SWIFT_STRICT_CONCURRENCY: complete
               SWIFT_VERSION: "6.0"
               MACOSX_DEPLOYMENT_TARGET: "13.0"
             configs:
               Debug:
                 CODE_SIGNING_ALLOWED: NO
                 CODE_SIGNING_REQUIRED: NO
                 ENABLE_HARDENED_RUNTIME: NO
                 OTHER_CODE_SIGN_FLAGS: ""
               Release:
                 DEVELOPMENT_TEAM: 7UC2HETAN9
                 CODE_SIGNING_ALLOWED: NO
                 CODE_SIGNING_REQUIRED: NO
           # NOTE: We pull the MCP swift-sdk product through SPM; xcodegen needs a package
           # entry to resolve it. Add `mcp-time` to the project-level `packages:` list
           # below (a top-level edit), pointing at the local mcp-servers/mcp-time path.
           dependencies:
             - package: mcp-time-pkg
               product: MCP

         mcp-clipboard:
           type: application
           platform: macOS
           sources:
             - path: mcp-servers/mcp-clipboard/Sources/mcp-clipboard
           settings:
             # ... same shape as mcp-time, with PRODUCT_BUNDLE_IDENTIFIER=com.koftwentytwo.jarvis.mcp-clipboard,
             # PRODUCT_NAME=mcp-clipboard, INFOPLIST_FILE/CODE_SIGN_ENTITLEMENTS pointing under mcp-servers/mcp-clipboard/Support/
           dependencies:
             - package: mcp-clipboard-pkg
               product: MCP
       ```

       Add at top level under `packages:`:
       ```yaml
       packages:
         # ... existing entries ...
         mcp-time-pkg:
           path: mcp-servers/mcp-time
         mcp-clipboard-pkg:
           path: mcp-servers/mcp-clipboard
       ```

    2. Modify the `Jarvis` target's existing `copyFiles:` block to ship the helpers:

       ```yaml
       targets:
         Jarvis:
           # ... existing config ...
           copyFiles:
             - destination: wrapper
               subpath: Contents/Helpers
               files:
                 - mcp-time.app
                 - mcp-clipboard.app
           dependencies:
             # ... existing deps ...
             - target: mcp-time
             - target: mcp-clipboard
       ```

       The `target:` dependencies ensure xcodegen orders the helper builds BEFORE the Jarvis copy. The `files:` list is non-empty so xcodegen will preserve the copyFiles phase (P1-05 Deferred Item #2 — empty lists get dropped).

    3. After modifying project.yml, run `xcodegen generate` and verify the new `mcp-time` and `mcp-clipboard` targets appear in `xcodebuild -list`. (xcodegen failure surfaces as a non-zero exit code from the verify command.)

    4. Place per-helper `.entitlements` files where `scripts/codesign.sh` reads them. P1-05 reads from `<helper>.app/Contents/Resources/<helper>.entitlements`. The xcodegen `CODE_SIGN_ENTITLEMENTS` setting points at the SOURCE path; the app-bundle COPY must land in `Contents/Resources/`. Add a postBuildScript on each helper target that copies the source entitlements into the bundle's `Contents/Resources/`:
       ```yaml
       mcp-time:
         postBuildScripts:
           - name: Copy per-helper entitlements into bundle Resources
             script: |
               cp "${SRCROOT}/mcp-servers/mcp-time/Support/mcp-time.entitlements" \
                  "${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Resources/mcp-time.entitlements"
             runOnlyWhenInstalling: false
             basedOnDependencyAnalysis: false
       ```
       Same shape for mcp-clipboard.

    5. Create `packages/MCP/Tests/MCPTests/MCPTimeIntegrationTests.swift`:
       - Discover the helper binary via probing in priority order:
         1. `Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent().appendingPathComponent("Contents/Helpers/mcp-time.app/Contents/MacOS/mcp-time")` (when running inside Jarvis.app's PlugIns).
         2. Search up from the test bundle's URL for any `.app/Contents/Helpers/mcp-time.app/Contents/MacOS/mcp-time`.
         3. Fall back to `XCTSkip("Helper bundle not present; run via xcodebuild test scheme=Jarvis")`.
       - When found, register via MCPClient, call `get_time`, parse the result through `ISO8601DateFormatter()`, assert it's within ±10 seconds of `Date()`.

    6. Create `packages/MCP/Tests/MCPTests/MCPClipboardIntegrationTests.swift` mirroring the time test pattern:
       - Find mcp-clipboard binary or `XCTSkip`.
       - Register via MCPClient, call `get_clipboard`.
       - Assert: result has exactly 1 content item; `isError` is either false (text/empty) or true (refusal); content text is non-nil. (We don't assert specific text because the test environment's pasteboard state is unknown.)

    Anti-patterns:
    - DO NOT add `Code Sign On Copy = YES` to either helper's xcodegen target settings, and DO NOT add it on the copyFiles phase. P1-05's `verify-codesign-settings.sh` would reject it. The deepest-first `scripts/codesign.sh` walker is the authoritative signer.
    - DO NOT use `--deep` anywhere in the codesign path. Already verified by `verify-codesign-settings.sh`.
    - DO NOT add `Bundle.main.url(forAuxiliaryExecutable:)` as the SOLE path-resolution strategy in tests — RESEARCH Open Question #2 documents that it expects flat layouts and may not resolve into nested `.app/Contents/Helpers/<name>.app/Contents/MacOS/<name>`. Use the manual `Contents/Helpers/` walk shown above.
    - DO NOT mark the integration tests as `requires_app_bundle: true` in any custom way — XCTSkip when the bundle is absent is sufficient and keeps `swift test --package-path packages/MCP` from spuriously failing in package-only mode.
  </action>
  <verify>
    <automated>xcodegen generate 2>&amp;1 | tail -5 &amp;&amp; xcodebuild -project Jarvis.xcodeproj -list 2>&amp;1 | grep -E 'mcp-time|mcp-clipboard' &amp;&amp; xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build 2>&amp;1 | tail -10 &amp;&amp; test -x build/Build/Products/Debug/Jarvis.app/Contents/Helpers/mcp-time.app/Contents/MacOS/mcp-time &amp;&amp; test -x build/Build/Products/Debug/Jarvis.app/Contents/Helpers/mcp-clipboard.app/Contents/MacOS/mcp-clipboard &amp;&amp; test -f build/Build/Products/Debug/Jarvis.app/Contents/Helpers/mcp-time.app/Contents/Resources/mcp-time.entitlements &amp;&amp; test -f build/Build/Products/Debug/Jarvis.app/Contents/Helpers/mcp-clipboard.app/Contents/Resources/mcp-clipboard.entitlements &amp;&amp; ./scripts/verify-entitlements.sh --post-codesign 2>&amp;1 | tail -5</automated>
  </verify>
  <done>
    - `xcodegen generate` exits 0 with the two new targets visible in `xcodebuild -list`.
    - Debug build of the `Jarvis` scheme produces both helper executables nested under `Contents/Helpers/`.
    - Each helper's bundle has a `Contents/Resources/<helper>.entitlements` file present (so codesign.sh finds it).
    - `scripts/verify-entitlements.sh --post-codesign` passes — confirming neither helper carries `automation.apple-events`, both bundles are signed, and the main app still meets MAIN_REQUIRED.
    - The integration tests (when run via `xcodebuild test -scheme Jarvis`) produce green for `MCPTimeIntegrationTests` and `MCPClipboardIntegrationTests`. (When run via `swift test --package-path packages/MCP` standalone, they `XCTSkip` cleanly — also acceptable.)
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| LLM-provided tool args → helper subprocess | Args land via JSON-RPC stdio. Helpers must validate input shape; SDK schema validation handles that automatically per `inputSchema`. |
| System pasteboard → mcp-clipboard helper | The pasteboard's CONTENT is untrusted (any app on the user's machine can post any data). MCP-03 enforces type-level refusal of fileURL pasteboards regardless of string payload — even a "clean" string variant with a fileURL hint is refused. |
| Helper bundle entitlements at sign time | Per-helper `.entitlements` files must NOT carry `automation.apple-events` (only mcp-applescript may). P1-05's post-codesign grep enforces; this plan validates the gate stays green. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-02-01 | Information Disclosure | mcp-clipboard exposing file paths to model | mitigate | `PasteboardReader.read()` returns `.refusedFileURL` whenever `pasteboard.types` contains `.fileURL`, BEFORE attempting any string read. Six unit tests cover the refusal matrix including the "fileURL + string both present" case (the most likely model-coercion vector). |
| T-05-02-02 | Elevation of Privilege | Cross-helper entitlement drift (e.g., automation.apple-events accidentally landing on mcp-time) | mitigate | P1-05's `scripts/verify-entitlements.sh --post-codesign` greps each helper's signed entitlements; rejects any helper other than `mcp-applescript` carrying `automation.apple-events`. This plan's helpers ship with EMPTY entitlements; build-time grep regression-guards. |
| T-05-02-03 | Tampering | Code Sign On Copy stripping per-helper entitlements at link time | mitigate | P1-05's `scripts/verify-codesign-settings.sh` lints the pbxproj for `CodeSignOnCopy = YES`. This plan's xcodegen settings explicitly DO NOT enable that flag; helpers are signed by `scripts/codesign.sh`'s deepest-first walker. |
| T-05-02-04 | Information Disclosure | Helper logging tool args/results to stdout | mitigate | Both helpers use SDK's default `Logger(label:)` which routes to stderr; no `print(...)` calls in either main.swift. Pitfall #4 regression. The parent's `startStderrPump` (Plan 05-01) drains stderr to the main app log channel. |
| T-05-02-05 | Repudiation | Helper appearing in Dock / Cmd-Tab masking its activity | mitigate | Both Info.plist files set `LSUIElement=YES` AND `LSBackgroundOnly=YES` (Pitfall #3). The build-time grep adds `plutil -extract` checks in the `<verify>` block. |
| T-05-02-06 | Information Disclosure | mcp-clipboard reading `.html`, `.rtf`, `.pdf`, `.fileContents` types and exposing to model | accept | v1 scope is `.string` only with `.fileURL` refusal. Wider type coverage is deferred to v2 / a future plan. The current code path returns `.empty` for any non-string non-fileURL pasteboard, which is conservative. |
</threat_model>

<verification>
1. `swift build --package-path mcp-servers/mcp-time -c release` exits 0.
2. `swift build --package-path mcp-servers/mcp-clipboard -c release` exits 0.
3. `swift test --package-path mcp-servers/mcp-clipboard --filter PasteboardReaderTests` reports 6/6 green.
4. `xcodegen generate` produces a regenerated pbxproj listing `mcp-time` and `mcp-clipboard` targets.
5. `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` succeeds end-to-end including:
   - Helper builds (mcp-time, mcp-clipboard targets)
   - Copy Helpers phase placing both `.app` bundles under `Contents/Helpers/`
   - codesign.sh deepest-first signs each helper with its `.entitlements`
   - verify-entitlements.sh --post-codesign passes (`automation.apple-events` absent from non-applescript helpers)
   - verify-codesign-settings.sh passes (no `CodeSignOnCopy = YES`, no `--deep`)
6. `xcodebuild test -scheme Jarvis -only-testing:JarvisAppTests` continues to pass (no regression in Phase 1 tests).
7. `plutil -extract LSUIElement raw mcp-servers/mcp-time/Support/Info.plist` returns `true`; same for mcp-clipboard.
8. `! grep -q 'automation.apple-events' mcp-servers/mcp-time/Support/mcp-time.entitlements` and similar for mcp-clipboard.
9. `! grep -q 'automation.apple-events' mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements`.
10. `! grep -q 'CodeSignOnCopy = YES' Jarvis.xcodeproj/project.pbxproj` (regression for P1-05 invariant).
</verification>

<success_criteria>
- Two helper bundles ship inside `Jarvis.app/Contents/Helpers/` after a Debug build.
- The MCP-03 refusal logic is unit-tested at the PasteboardReader level (no GUI session needed).
- An MCPClient consumer can register and round-trip both helpers (integration tests verify this when run via `xcodebuild test`).
- Phase 1's codesign + entitlement chain accepts both helpers without modification (no script changes needed for empty-entitlement helpers).
- The xcodegen `copyFiles:` phase is preserved across regeneration because its `files:` list is non-empty.
</success_criteria>

<output>
Write `.planning/phases/05-mcp/05-02-SUMMARY.md`. Highlights:
- Two new top-level packages (`mcp-servers/mcp-time/`, `mcp-servers/mcp-clipboard/`) with peer-of-`packages/` placement (per RESEARCH §Recommended Project Structure rationale).
- Two new xcodegen application targets producing nested `.app` bundles.
- The Copy Helpers phase pivots from empty (P1-05 carried forward) to non-empty here — flag this clearly so future plans understand xcodegen will now preserve it.
- Document the post-build entitlement-copy script for each helper (the entitlement file ships at SOURCE under `Support/` but must land in `Contents/Resources/` of the built bundle for `codesign.sh` to find).
- Any deviation from the plan's literal copyFiles approach (e.g., if xcodegen rejects the destination shape and the executor migrated to a `postBuildScript` `cp -R` instead).
- The exact `xcodebuild` command that produces a clean build with both helpers landed.
</output>
