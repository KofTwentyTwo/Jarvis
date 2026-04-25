---
phase: 05-mcp
plan: 03
type: execute
wave: 3
depends_on: [05-01]
files_modified:
  - mcp-servers/mcp-applescript/Package.swift
  - mcp-servers/mcp-applescript/Sources/mcp-applescript/main.swift
  - mcp-servers/mcp-applescript/Sources/mcp-applescript/AppleScriptRunner.swift
  - mcp-servers/mcp-applescript/Tests/AppleScriptRunnerTests/AppleScriptRunnerTests.swift
  - mcp-servers/mcp-applescript/Support/Info.plist
  - mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements
  - project.yml
  - scripts/verify-entitlements.sh
  - scripts/test-fixtures/helper-applescript-good.entitlements
  - scripts/test-fixtures/helper-applescript-missing.entitlements
  - scripts/test-fixtures/helper-time-with-apple-events.entitlements
autonomous: false
user_setup:
  - service: developer.apple.com App ID
    why: "Per-helper TCC identity for `mcp-applescript` requires an App ID with the Apple Events Automation capability enabled at developer.apple.com (RESEARCH Pitfall #6). Without this, AppleEvent error -1743 (errAEEventNotPermitted) returns on first execution with no TCC prompt. This is the same gating constraint as Phase 1 Task 4's speech-recognition-assets capability — Developer ID Application identity also required for live verification."
    env_vars: []
    dashboard_config:
      - task: "Register or extend App ID com.koftwentytwo.jarvis.mcp-applescript"
        location: "developer.apple.com → Certificates, Identifiers & Profiles → Identifiers"
      - task: "Enable Apple Events Sandbox Exception (Automation) capability on that App ID"
        location: "Same Identifiers screen, capabilities section"
requirements: [MCP-04]
tags: [mcp-helpers, mcp-applescript, automation-apple-events, tcc-identity, verify-entitlements-extension, nsapplescript]
assumptions:
  - This plan covers ONLY the helper bundle, its NSAppleScript execution path, and the build-time entitlement-grep extensions. The native AppKit confirmation sheet + ConfirmationBroker FSM lives in Plan 05-05; the helper executes scripts unconditionally because gating happens at the orchestrator boundary BEFORE the orchestrator dispatches into MCPClient.
  - `NSAppleScript(source:).executeAndReturnError(_:)` is synchronous and works without `NSApplication.run()` for v1's "execute and return stdout" contract (RESEARCH Assumption A4 + Open Question #3). A scaffold-time sanity probe is run during helper init that runs a trivial script (`tell application "System Events" to get the name of every process`) and logs the outcome to stderr; if the probe hangs or fails with -600, the executor flags this in the SUMMARY and a future plan wraps the helper in NSApplicationDelegate + NSApp.run().
  - The App ID capability gating is identical to P1-05 Task 4's speech-recognition-assets footgun — both require human action at developer.apple.com that is NOT scriptable. This plan declares `autonomous: false` with the user-setup gate for the same reason.
  - Anti-pattern callouts: DO NOT shell out to `/usr/bin/osascript` (RESEARCH Anti-Pattern: forks a child with mixed TCC identity). DO NOT add a regex-based "skip-allowlist" to bypass confirmation for "safe" scripts (SEC-08 forbids this; every AppleScript in v1 is privileged). DO NOT add `automation.apple-events` to mcp-time or mcp-clipboard entitlements (Plan 05-02 keeps them empty). DO NOT use `--deep` in any sign step (P1-05 verify-codesign-settings.sh would fail).
must_haves:
  truths:
    - "An MCPClient consumer can register `mcp-applescript` from `Bundle.main.bundleURL/Contents/Helpers/mcp-applescript.app/Contents/MacOS/mcp-applescript` and call `run_applescript` with `{source: <script>}`; the helper executes via NSAppleScript and returns the script's `result.stringValue` as `.text` content."
    - "An invalid AppleScript source returns `isError: true` with content carrying the error number and message from `NSAppleScriptErrorNumber` / `NSAppleScriptErrorMessage`."
    - "The helper bundle's signed entitlements carry exactly `com.apple.security.automation.apple-events = true` and nothing else."
    - "Post-codesign verification (`scripts/verify-entitlements.sh --post-codesign`) explicitly checks: (a) `mcp-applescript` HAS `automation.apple-events`, (b) `mcp-time` and `mcp-clipboard` LACK `automation.apple-events`. Any drift fails the build."
    - "The fault-injection self-test (`scripts/test-verify-entitlements.sh`) covers each new fixture path: good-applescript-helper, applescript-helper-missing-grant, time-helper-with-apple-events (forbidden cross-helper drift)."
  artifacts:
    - path: "mcp-servers/mcp-applescript/Sources/mcp-applescript/main.swift"
      provides: "MCP server exposing `run_applescript` tool; routes through AppleScriptRunner."
      min_lines: 30
    - path: "mcp-servers/mcp-applescript/Sources/mcp-applescript/AppleScriptRunner.swift"
      provides: "Testable runner protocol + concrete NSAppleScript-backed implementation; exposes `run(source:) -> Result<String, AppleScriptError>`."
      min_lines: 40
    - path: "mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements"
      provides: "Plist carrying ONLY com.apple.security.automation.apple-events=true."
      contains: "<key>com.apple.security.automation.apple-events</key>"
    - path: "mcp-servers/mcp-applescript/Support/Info.plist"
      provides: "Helper Info.plist; CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-applescript; LSUIElement=YES; LSBackgroundOnly=YES; PLUS NSAppleEventsUsageDescription string."
      contains: "<key>NSAppleEventsUsageDescription</key>"
    - path: "scripts/verify-entitlements.sh"
      provides: "Extended HELPER_ENTITLEMENT_RULES section enforcing: only mcp-applescript carries apple-events; mcp-applescript MUST carry it (missing-grant is a build failure)."
      min_lines: 200
    - path: "scripts/test-fixtures/helper-applescript-good.entitlements"
      provides: "Fixture: helper-shape entitlements with apple-events present (positive case)."
    - path: "scripts/test-fixtures/helper-applescript-missing.entitlements"
      provides: "Fixture: helper-shape entitlements WITHOUT apple-events (negative case for mcp-applescript identity)."
    - path: "scripts/test-fixtures/helper-time-with-apple-events.entitlements"
      provides: "Fixture: mcp-time-shape entitlements WITH apple-events (negative case — forbidden cross-helper drift)."
  key_links:
    - from: "mcp-servers/mcp-applescript/Sources/mcp-applescript/main.swift"
      to: "AppleScriptRunner.run(source:)"
      via: "withMethodHandler(CallTool.self) -> runner.run(source: params.arguments[\"source\"]?.stringValue)"
      pattern: "AppleScriptRunner|runner\\.run"
    - from: "scripts/verify-entitlements.sh"
      to: "Helper-specific entitlement rules"
      via: "Walks Contents/Helpers/**/*.app and grep-checks per-helper bundle name; mcp-applescript REQUIRED apple-events; others FORBIDDEN apple-events"
      pattern: "mcp-applescript|HELPER_NAME"
    - from: "scripts/test-verify-entitlements.sh"
      to: "Three new fixture paths"
      via: "Self-test invocations of --verify-fixture mode covering good/missing/cross-drift"
      pattern: "helper-applescript|helper-time-with"
---

<objective>
Stand up the third and most security-sensitive MCP helper, `mcp-applescript`, plus the build-time entitlement enforcement that ensures `com.apple.security.automation.apple-events` lives EXCLUSIVELY on this helper.

This plan does NOT build the confirmation broker, NOT build the AppKit sheet, NOT touch the orchestrator. The helper executes whatever script is handed to it; the gate that asks the user "approve this script?" is Plan 05-05's job. This separation is intentional: the helper's TCC identity is independent of the gate, and we want the build-time sign-and-grep dance to land before the runtime FSM lands.

Why this is autonomous=false: per-helper TCC identity for `mcp-applescript` requires the user to enable the Apple Events capability on the `com.koftwentytwo.jarvis.mcp-applescript` App ID at developer.apple.com (RESEARCH Pitfall #6). The same constraint that left P1-05 Task 4 BLOCKED applies here. The plan can complete its build-time work autonomously; live AppleScript execution against a real macOS TCC prompt requires the human action.

Output:
- 1 helper SPM package + xcodegen target.
- 1 helper Info.plist + per-helper entitlements file (ONE entitlement: apple-events).
- 1 testable `AppleScriptRunner` with unit tests covering valid script / invalid source / runtime error paths (mocked NSAppleScript).
- Extension to `scripts/verify-entitlements.sh` that enforces helper-specific rules (mcp-applescript MUST carry apple-events; all other helpers MUST NOT).
- 3 new fixtures + extension to `scripts/test-verify-entitlements.sh` covering positive/negative/cross-drift cases.
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
@.planning/phases/05-mcp/05-02-helpers-time-clipboard-PLAN.md
@.planning/phases/01-foundations/01-05-SUMMARY.md
@CLAUDE.md
@scripts/codesign.sh
@scripts/verify-entitlements.sh
@scripts/test-verify-entitlements.sh

<interfaces>
<!--
  Helper-side surface and the runner protocol.
-->

```swift
// mcp-applescript exposes (after Plan 05-05 wraps it in confirmation gating):
Tool(
    name: "run_applescript",
    description: "Executes AppleScript source. Requires user confirmation (gated by host).",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "source": .object(["type": .string("string"), "description": .string("AppleScript source code to execute.")])
        ]),
        "required": .array([.string("source")])
    ])
)
// CallTool result possibilities:
//   .text(text: <NSAppleScriptResult.stringValue>, isError: false)         — success
//   .text(text: "AppleScript error <num>: <msg>", isError: true)            — runtime error
//   .text(text: "AppleScript source failed to compile.", isError: true)     — compile error
//   .text(text: "Missing 'source' argument.", isError: true)                — bad input
```

AppleScriptRunner contract (mcp-applescript internal, testable):

```swift
// mcp-servers/mcp-applescript/Sources/mcp-applescript/AppleScriptRunner.swift

public protocol AppleScriptRunning: Sendable {
    func run(source: String) -> AppleScriptOutcome
}

public enum AppleScriptOutcome: Sendable, Equatable {
    case success(String)
    case runtimeError(number: Int, message: String)
    case compileFailure
}

public struct NSAppleScriptRunner: AppleScriptRunning {
    public init()
    public func run(source: String) -> AppleScriptOutcome
}
```

`scripts/verify-entitlements.sh` extension contract (this plan adds these enforcement rules):

```bash
# After signing, walk Contents/Helpers/*.app and apply per-helper rules:
#
# For each helper bundle name (basename of $HELPER .app):
#   - mcp-applescript:  MUST carry com.apple.security.automation.apple-events
#                       MUST NOT carry com.apple.security.cs.allow-jit
#   - mcp-time:         MUST NOT carry com.apple.security.automation.apple-events
#                       MUST NOT carry com.apple.developer.speech-recognition-assets (forbidden propagation)
#   - mcp-clipboard:    same forbidden list as mcp-time
#
# Existing P1-05 logic already greps for "any helper other than mcp-applescript carrying apple-events";
# this plan ADDS the positive assertion: mcp-applescript MUST carry it (catches the inverse footgun).
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: AppleScriptRunner + helper sources + Info.plist + entitlements</name>
  <files>
    mcp-servers/mcp-applescript/Package.swift,
    mcp-servers/mcp-applescript/Sources/mcp-applescript/main.swift,
    mcp-servers/mcp-applescript/Sources/mcp-applescript/AppleScriptRunner.swift,
    mcp-servers/mcp-applescript/Tests/AppleScriptRunnerTests/AppleScriptRunnerTests.swift,
    mcp-servers/mcp-applescript/Support/Info.plist,
    mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements
  </files>
  <behavior>
    - Test (RED first): `AppleScriptRunnerTests.test_validScript_returnsSuccessWithStringValue` — uses real `NSAppleScriptRunner` on a script that returns a literal string (`"return \"hello\""`). Asserts `.success("hello")`. Skipped if running in headless CI where AppleScript is unavailable (XCTSkipIf).
    - Test: `test_invalidSyntax_returnsCompileFailure` — runs source `"this is not applescript"`. Asserts `.compileFailure`.
    - Test: `test_runtimeError_returnsRuntimeError` — runs `"error \"bad things\" number 42"`. Asserts `.runtimeError(number: 42, message: <containing "bad things">)`.
    - Test: `test_emptySource_returnsCompileFailure` — empty string source.
    - The helper builds standalone via `swift build -c release`, executable lands at `.build/release/mcp-applescript`.
    - Info.plist has `LSUIElement=true`, `LSBackgroundOnly=true`, `CFBundleIdentifier=com.koftwentytwo.jarvis.mcp-applescript`, AND `NSAppleEventsUsageDescription` with a human-readable string ("Jarvis runs AppleScript snippets you approve in the confirmation sheet to control other apps.").
    - Entitlements file carries EXACTLY `com.apple.security.automation.apple-events = true` and NO other keys.
  </behavior>
  <action>
    1. Create `mcp-servers/mcp-applescript/Package.swift`:
       ```swift
       // swift-tools-version:6.0
       import PackageDescription

       let package = Package(
           name: "mcp-applescript",
           platforms: [.macOS(.v13)],
           dependencies: [
               .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
           ],
           targets: [
               .executableTarget(
                   name: "mcp-applescript",
                   dependencies: [.product(name: "MCP", package: "swift-sdk")],
                   swiftSettings: [.swiftLanguageMode(.v6)]
               ),
               .testTarget(
                   name: "AppleScriptRunnerTests",
                   dependencies: ["mcp-applescript"],
                   swiftSettings: [.swiftLanguageMode(.v6)]
               )
           ]
       )
       ```

    2. Create `mcp-servers/mcp-applescript/Sources/mcp-applescript/AppleScriptRunner.swift`:
       ```swift
       import Foundation

       public protocol AppleScriptRunning: Sendable {
           func run(source: String) -> AppleScriptOutcome
       }

       public enum AppleScriptOutcome: Sendable, Equatable {
           case success(String)
           case runtimeError(number: Int, message: String)
           case compileFailure
       }

       public struct NSAppleScriptRunner: AppleScriptRunning {
           public init() {}

           public func run(source: String) -> AppleScriptOutcome {
               guard let script = NSAppleScript(source: source) else {
                   return .compileFailure
               }
               var errorInfo: NSDictionary?
               let result = script.executeAndReturnError(&errorInfo)
               if let err = errorInfo {
                   let num = err["NSAppleScriptErrorNumber"] as? Int ?? 0
                   let msg = err["NSAppleScriptErrorMessage"] as? String ?? "unknown error"
                   return .runtimeError(number: num, message: msg)
               }
               return .success(result.stringValue ?? "(no return value)")
           }
       }
       ```

    3. Create `mcp-servers/mcp-applescript/Sources/mcp-applescript/main.swift` per RESEARCH Pattern 8:
       ```swift
       import MCP
       import Foundation

       @main
       struct MCPAppleScript {
           static func main() async throws {
               let runner: any AppleScriptRunning = NSAppleScriptRunner()

               let server = Server(
                   name: "mcp-applescript",
                   version: "1.0.0",
                   capabilities: .init(tools: .init(listChanged: false))
               )

               // RESEARCH Open Question #3: scaffold-time probe to confirm NSAppleScript works
               // without NSApplication.run(). Run a trivial script during init and log the outcome
               // to stderr (Pitfall #4 — never stdout). If this hangs or returns -600, a future
               // plan wraps the helper in NSApplicationDelegate + NSApp.run().
               let probe = runner.run(source: "tell application \"System Events\" to get the name of every process")
               FileHandle.standardError.write(Data("mcp-applescript probe outcome: \(probe)\n".utf8))

               await server.withMethodHandler(ListTools.self) { _ in
                   .init(tools: [
                       Tool(
                           name: "run_applescript",
                           description: "Executes AppleScript source. Requires user confirmation (gated by host).",
                           inputSchema: .object([
                               "type": .string("object"),
                               "properties": .object([
                                   "source": .object([
                                       "type": .string("string"),
                                       "description": .string("AppleScript source code to execute.")
                                   ])
                               ]),
                               "required": .array([.string("source")])
                           ])
                       )
                   ])
               }

               await server.withMethodHandler(CallTool.self) { params in
                   guard params.name == "run_applescript" else {
                       return .init(content: [.text(text: "Unknown tool", annotations: nil, _meta: nil)], isError: true)
                   }
                   guard let source = params.arguments?["source"]?.stringValue else {
                       return .init(content: [.text(text: "Missing 'source' argument.", annotations: nil, _meta: nil)], isError: true)
                   }
                   switch runner.run(source: source) {
                   case .success(let text):
                       return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
                   case .runtimeError(let num, let msg):
                       return .init(content: [.text(text: "AppleScript error \(num): \(msg)", annotations: nil, _meta: nil)], isError: true)
                   case .compileFailure:
                       return .init(content: [.text(text: "AppleScript source failed to compile.", annotations: nil, _meta: nil)], isError: true)
                   }
               }

               let transport = StdioTransport()
               try await server.start(transport: transport)
               await server.waitUntilCompleted()
           }
       }
       ```

    4. Create `mcp-servers/mcp-applescript/Tests/AppleScriptRunnerTests/AppleScriptRunnerTests.swift` with the four tests in `<behavior>`.

       Use `XCTSkipIf(ProcessInfo.processInfo.environment["JARVIS_SKIP_NSAPPLESCRIPT"] != nil, "Skipping under headless test runner")` so CI can opt-out via env if needed; locally these tests run real NSAppleScript.

    5. Create `mcp-servers/mcp-applescript/Support/Info.plist`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <key>CFBundleIdentifier</key><string>com.koftwentytwo.jarvis.mcp-applescript</string>
           <key>CFBundleName</key><string>mcp-applescript</string>
           <key>CFBundleExecutable</key><string>mcp-applescript</string>
           <key>CFBundleShortVersionString</key><string>1.0.0</string>
           <key>CFBundleVersion</key><string>1</string>
           <key>CFBundlePackageType</key><string>APPL</string>
           <key>LSUIElement</key><true/>
           <key>LSBackgroundOnly</key><true/>
           <key>LSMinimumSystemVersion</key><string>13.0</string>
           <key>NSAppleEventsUsageDescription</key>
           <string>Jarvis runs AppleScript snippets you approve in the confirmation sheet to control other apps.</string>
       </dict>
       </plist>
       ```

    6. Create `mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <!-- ONLY mcp-applescript may hold this entitlement.
                scripts/verify-entitlements.sh --post-codesign enforces this both ways:
                this helper MUST carry it; no other helper may. -->
           <key>com.apple.security.automation.apple-events</key>
           <true/>
       </dict>
       </plist>
       ```

    Anti-patterns to enforce:
    - DO NOT add a regex/allowlist for "safe" script patterns — SEC-08 forbids this. Every script gets routed through the confirmation broker (Plan 05-05).
    - DO NOT use `Process()` to spawn `osascript` — RESEARCH Anti-Pattern: forks a separate `/usr/bin/osascript` child with mixed TCC identity. NSAppleScript stays in-process under this helper's per-helper TCC identity.
    - DO NOT add `com.apple.security.cs.allow-jit` to the helper entitlements; only the main app needs it (Phase 1). The helper has no WKWebView.
  </action>
  <verify>
    <automated>swift test --package-path mcp-servers/mcp-applescript --filter AppleScriptRunnerTests 2>&amp;1 | tail -10 &amp;&amp; swift build --package-path mcp-servers/mcp-applescript -c release 2>&amp;1 | tail -3 &amp;&amp; test -x mcp-servers/mcp-applescript/.build/release/mcp-applescript &amp;&amp; plutil -lint mcp-servers/mcp-applescript/Support/Info.plist &amp;&amp; plutil -lint mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements &amp;&amp; grep -c 'com.apple.security.automation.apple-events' mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements &amp;&amp; ! grep -q 'com.apple.security.cs.allow-jit' mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements &amp;&amp; plutil -extract NSAppleEventsUsageDescription raw mcp-servers/mcp-applescript/Support/Info.plist</automated>
  </verify>
  <done>
    - All AppleScriptRunner tests pass (locally; XCTSkip is acceptable in headless mode).
    - mcp-applescript executable builds and is executable.
    - Entitlement file carries `com.apple.security.automation.apple-events` and only that key (grep -c == 1, `cs.allow-jit` absent).
    - Info.plist carries `NSAppleEventsUsageDescription`.
    - `swift test` for the helper package returns 4/4 green (or 4 skipped under JARVIS_SKIP_NSAPPLESCRIPT).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: xcodegen helper target + add to Jarvis copyFiles + Resources entitlement copy</name>
  <files>
    project.yml
  </files>
  <behavior>
    - After regenerating the pbxproj, `xcodebuild -list` shows a new `mcp-applescript` target.
    - A Debug build of the `Jarvis` scheme produces `Jarvis.app/Contents/Helpers/mcp-applescript.app/Contents/MacOS/mcp-applescript`.
    - The helper's source `.entitlements` lands at `Contents/Resources/mcp-applescript.entitlements` so `scripts/codesign.sh`'s deepest-first walker signs the bundle with that file.
    - The Jarvis target's `copyFiles:` block (extended in Plan 05-02) now lists THREE helpers: mcp-time, mcp-clipboard, mcp-applescript.
  </behavior>
  <action>
    1. Modify `project.yml`:
       a. Add to top-level `packages:` list:
          ```yaml
          mcp-applescript-pkg:
            path: mcp-servers/mcp-applescript
          ```
       b. Add `mcp-applescript` target alongside `mcp-time` and `mcp-clipboard` (mirror their shape):
          ```yaml
          mcp-applescript:
            type: application
            platform: macOS
            sources:
              - path: mcp-servers/mcp-applescript/Sources/mcp-applescript
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: com.koftwentytwo.jarvis.mcp-applescript
                PRODUCT_NAME: mcp-applescript
                INFOPLIST_FILE: mcp-servers/mcp-applescript/Support/Info.plist
                GENERATE_INFOPLIST_FILE: NO
                CODE_SIGN_ENTITLEMENTS: mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements
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
            dependencies:
              - package: mcp-applescript-pkg
                product: MCP
            postBuildScripts:
              - name: Copy per-helper entitlements into bundle Resources
                script: |
                  cp "${SRCROOT}/mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements" \
                     "${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Resources/mcp-applescript.entitlements"
                runOnlyWhenInstalling: false
                basedOnDependencyAnalysis: false
          ```
       c. Append `mcp-applescript.app` to the Jarvis target's `copyFiles.files:` list (already extended in Plan 05-02 to carry mcp-time.app + mcp-clipboard.app). Final list: `[mcp-time.app, mcp-clipboard.app, mcp-applescript.app]`.
       d. Append `target: mcp-applescript` to the Jarvis target's `dependencies:` list.

    2. Run `xcodegen generate` to regenerate the pbxproj.

    Anti-patterns:
    - DO NOT enable `CodeSignOnCopy` on the copyFiles entry — Phase 1's lint refuses. The deepest-first walker handles signing.
    - DO NOT add `com.apple.security.automation.apple-events` to the Jarvis target's main entitlements — it lives ONLY on the helper. P1-05 verify-entitlements.sh already enforces "main MUST NOT carry apple-events" via MAIN_FORBIDDEN.
  </action>
  <verify>
    <automated>xcodegen generate 2>&amp;1 | tail -3 &amp;&amp; xcodebuild -project Jarvis.xcodeproj -list 2>&amp;1 | grep -E 'mcp-applescript' &amp;&amp; grep -c 'mcp-applescript' project.yml &amp;&amp; ! grep -q 'CodeSignOnCopy = YES' Jarvis.xcodeproj/project.pbxproj</automated>
  </verify>
  <done>
    - xcodegen succeeds; mcp-applescript appears in `xcodebuild -list`.
    - project.yml lists three helpers in the Jarvis copyFiles.files entries.
    - No `CodeSignOnCopy = YES` introduced.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: verify-entitlements.sh per-helper extension + 3 new fixtures + test-verify-entitlements.sh extension</name>
  <files>
    scripts/verify-entitlements.sh,
    scripts/test-fixtures/helper-applescript-good.entitlements,
    scripts/test-fixtures/helper-applescript-missing.entitlements,
    scripts/test-fixtures/helper-time-with-apple-events.entitlements,
    scripts/test-verify-entitlements.sh
  </files>
  <behavior>
    - The fault-injection self-test passes ALL fixtures with exit 0 from the harness (PASS=N FAIL=0). New fixtures join the existing good/broken/forbidden corpus.
    - `scripts/verify-entitlements.sh --post-codesign` against a properly-signed bundle with three helpers (mcp-time, mcp-clipboard, mcp-applescript) passes.
    - The same script against a corrupted bundle (mcp-applescript missing apple-events, or mcp-time carrying apple-events) FAILS with a clear error message naming the offending helper.
    - The new fixture mode `--verify-helper-fixture <fixture> <expected-helper-name>` allows the harness to fault-inject by giving the script a fixture file AND telling it "treat this as if it were the entitlements signed onto helper named X" — drives the per-helper rule branches without needing a real signed bundle.
  </behavior>
  <action>
    1. Extend `scripts/verify-entitlements.sh` with a per-helper entitlement enforcement section in `--post-codesign` mode. Pseudocode (read existing script first to fit the style):

       ```bash
       # New section in --post-codesign mode, AFTER the existing main-app verification:
       check_helper_entitlements() {
           local helper_app="$1"          # path to helper .app
           local helper_name="$2"          # basename without .app
           local signed_xml
           signed_xml="$(/usr/bin/codesign -d --entitlements - --xml "$helper_app" 2>/dev/null \
                          | /usr/bin/grep -v '^<!--')"  # comment-strip defense

           # Per-helper required + forbidden lists.
           local required=()
           local forbidden=()
           case "$helper_name" in
               mcp-applescript)
                   required=("com.apple.security.automation.apple-events")
                   forbidden=(
                       "com.apple.security.cs.allow-jit"
                       "com.apple.developer.speech-recognition-assets"
                       "com.apple.security.device.audio-input"
                   )
                   ;;
               mcp-time|mcp-clipboard)
                   required=()  # No special grants beyond Hardened Runtime.
                   forbidden=(
                       "com.apple.security.automation.apple-events"
                       "com.apple.developer.speech-recognition-assets"
                       "com.apple.security.cs.allow-jit"
                   )
                   ;;
               *)
                   echo "error: unknown helper '$helper_name' — extend HELPER_ENTITLEMENT_RULES in verify-entitlements.sh" >&2
                   return 1
                   ;;
           esac

           for key in "${required[@]}"; do
               if ! echo "$signed_xml" | /usr/bin/grep -q "<key>$key</key>"; then
                   echo "error: helper '$helper_name' MISSING required entitlement: $key" >&2
                   return 1
               fi
           done
           for key in "${forbidden[@]}"; do
               if echo "$signed_xml" | /usr/bin/grep -q "<key>$key</key>"; then
                   echo "error: helper '$helper_name' carries FORBIDDEN entitlement: $key" >&2
                   return 1
               fi
           done
           return 0
       }

       # Add a new walk in --post-codesign:
       HELPERS_DIR="$APP/Contents/Helpers"
       if [ -d "$HELPERS_DIR" ]; then
           while IFS= read -r helper; do
               helper_name="$(basename "$helper" .app)"
               check_helper_entitlements "$helper" "$helper_name" || exit 1
               echo "post-codesign: helper '$helper_name' entitlements OK"
           done < <(find "$HELPERS_DIR" -depth -name "*.app" -type d)
       fi
       ```

       Add a new `--verify-helper-fixture <fixture-path> <helper-name>` mode that takes a plist file and a helper name, treats the file as if it were the result of `codesign -d --entitlements - --xml`, and runs the per-helper rule. Used by the fault-injection harness without needing a real signed bundle.

    2. Create the three fixture files:

       `scripts/test-fixtures/helper-applescript-good.entitlements`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <key>com.apple.security.automation.apple-events</key><true/>
       </dict>
       </plist>
       ```

       `scripts/test-fixtures/helper-applescript-missing.entitlements`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <!-- mcp-applescript helper missing the apple-events grant; should fail check. -->
       </dict>
       </plist>
       ```

       `scripts/test-fixtures/helper-time-with-apple-events.entitlements`:
       ```xml
       <?xml version="1.0" encoding="UTF-8"?>
       <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
       <plist version="1.0">
       <dict>
           <!-- mcp-time helper carrying apple-events (forbidden cross-helper drift); should fail check. -->
           <key>com.apple.security.automation.apple-events</key><true/>
       </dict>
       </plist>
       ```

    3. Extend `scripts/test-verify-entitlements.sh` (the fault-injection harness) to call:
       - `verify-entitlements.sh --verify-helper-fixture helper-applescript-good.entitlements mcp-applescript` → expect exit 0.
       - `verify-entitlements.sh --verify-helper-fixture helper-applescript-missing.entitlements mcp-applescript` → expect exit 1.
       - `verify-entitlements.sh --verify-helper-fixture helper-time-with-apple-events.entitlements mcp-time` → expect exit 1.
       - Track PASS/FAIL counters and report at the end.

    Anti-patterns:
    - DO NOT regex-match the entitlement key (e.g., `grep '\bapple-events\b'`) — pbxproj/plists may have comments mentioning the key. Always strip comments first (`grep -v '^<!--'`) per P1-05 self-invalidating-grep defense.
    - DO NOT remove the existing P1-05 main-app `MAIN_FORBIDDEN` checks — those still apply. This plan ADDS to the script, doesn't replace.
    - DO NOT hardcode helper-name allowlist anywhere except `case "$helper_name" in` — future helpers need a single edit point.
  </action>
  <verify>
    <automated>./scripts/test-verify-entitlements.sh 2>&amp;1 | tail -10 &amp;&amp; ./scripts/test-verify-entitlements.sh 2>&amp;1 | grep -E '^PASS=|^FAIL=' &amp;&amp; bash -c './scripts/verify-entitlements.sh --verify-helper-fixture scripts/test-fixtures/helper-applescript-good.entitlements mcp-applescript &amp;&amp; echo OK_GOOD' &amp;&amp; bash -c '! ./scripts/verify-entitlements.sh --verify-helper-fixture scripts/test-fixtures/helper-applescript-missing.entitlements mcp-applescript' &amp;&amp; echo OK_MISSING_REJECTED &amp;&amp; bash -c '! ./scripts/verify-entitlements.sh --verify-helper-fixture scripts/test-fixtures/helper-time-with-apple-events.entitlements mcp-time' &amp;&amp; echo OK_DRIFT_REJECTED</automated>
  </verify>
  <done>
    - `scripts/test-verify-entitlements.sh` reports `FAIL=0` after extension.
    - The three fixtures produce the expected exit codes when fed through `--verify-helper-fixture`.
    - `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` succeeds with all three helpers signed and the post-codesign verifier reporting "helper '...' entitlements OK" for each.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| LLM tool args → `mcp-applescript` source field | The model can put arbitrary AppleScript in the `source` argument. The helper executes it unconditionally; the gate is the orchestrator's confirmation broker (Plan 05-05) which BLOCKS dispatch until the user clicks Approve in the native AppKit sheet. This plan's helper is intentionally trusting — it has no way to know if user approved; the orchestrator decides. |
| `mcp-applescript` helper → other apps via Apple Events | The helper holds `com.apple.security.automation.apple-events`; macOS TCC will prompt the user on first attempt to control any specific target app (e.g., "mcp-applescript wants to control Mail"). |
| Build-time entitlement signing → runtime TCC behavior | If `automation.apple-events` lands on the wrong helper (cross-helper drift), the wrong process gets the TCC prompt and the right one fails silently. The post-codesign grep is the structural defense. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-03-01 | Elevation of Privilege | Cross-helper drift of `automation.apple-events` (e.g., a future build accidentally adds it to mcp-time or mcp-clipboard) | mitigate | Per-helper rules in `verify-entitlements.sh --post-codesign` reject any non-mcp-applescript helper carrying the key. Three new fault-injection fixtures (helper-time-with-apple-events) regression-guard. |
| T-05-03-02 | Elevation of Privilege | mcp-applescript MISSING `automation.apple-events` (silent permission gap — script attempts return -1743 with no TCC prompt, looking like denial) | mitigate | New required-key check in the post-codesign verifier; mcp-applescript MUST carry the key. Fault-injection fixture `helper-applescript-missing.entitlements` regression-guards. |
| T-05-03-03 | Tampering | AppleScript execution via `osascript` subprocess (mixed TCC identity, cross-helper escape) | mitigate | Helper uses in-process `NSAppleScript(source:)` only; lint guard via `! grep -q 'osascript' Sources/mcp-applescript/main.swift` (verified inline). RESEARCH Anti-Pattern documents the rejection rationale. |
| T-05-03-04 | Tampering | Regex-based "skip-allowlist" bypassing confirmation (SEC-08) | accept (architectural) | The helper has no allowlist code path. Every call is gated by the orchestrator's confirmation broker (Plan 05-05). SEC-08 is a project invariant; this plan must NOT introduce any allowlist now or in v1. |
| T-05-03-05 | Information Disclosure | NSAppleScript hangs without `NSApplication.run()` event loop | mitigate | Scaffold-time stderr probe in helper init runs a trivial script and logs the outcome. If hang/-600 observed during execution, the SUMMARY flags it for a future plan to wrap the helper in `NSApplicationDelegate`. RESEARCH Open Question #3. |
| T-05-03-06 | Tampering | App ID capability gap on developer.apple.com (silent failure: -1743 with no TCC prompt) | accept (autonomous=false gates) | Plan declares `autonomous: false` with `user_setup` instruction. Same pattern as Phase 1 Task 4's speech-recognition-assets. Live AppleScript verification is a manual step the user runs after enabling the App ID capability. |
| T-05-03-07 | Repudiation | Helper executing unapproved scripts because confirmation gating happens at orchestrator, not at helper | accept (separation of concerns) | The helper is intentionally trusting — gating at the orchestrator boundary lets us reuse the helper for non-confirmation use cases later (e.g., a curated read-only AppleScript catalog) without retrofitting. SEC-08 enforces "every script v1" through orchestrator policy in Plan 05-05; the helper neither knows nor cares. |
</threat_model>

<verification>
1. `swift test --package-path mcp-servers/mcp-applescript` reports green (or XCTSkip-passing locally).
2. `swift build --package-path mcp-servers/mcp-applescript -c release` exits 0.
3. `xcodegen generate` produces a regenerated pbxproj with the new target.
4. Full `xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` succeeds, including the post-codesign per-helper grep.
5. `scripts/test-verify-entitlements.sh` reports `FAIL=0` (now covering 6 fixtures total: 3 from P1-05 + 3 from this plan).
6. Grep gates:
   - `grep -c 'com.apple.security.automation.apple-events' mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements` returns 1.
   - `grep -c 'com.apple.security.automation.apple-events' mcp-servers/mcp-time/Support/mcp-time.entitlements` returns 0.
   - `grep -c 'com.apple.security.automation.apple-events' mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements` returns 0.
   - `! grep -q 'osascript' mcp-servers/mcp-applescript/Sources/mcp-applescript/main.swift`.
   - `grep -c 'verify-helper-fixture' scripts/verify-entitlements.sh` returns >= 1 (new mode landed).
   - `grep -c 'NSAppleEventsUsageDescription' mcp-servers/mcp-applescript/Support/Info.plist` returns 1.
7. Build-bundle layout: `Jarvis.app/Contents/Helpers/mcp-applescript.app/Contents/MacOS/mcp-applescript` is executable; `Contents/Resources/mcp-applescript.entitlements` is present.
</verification>

<success_criteria>
- The third helper ships in the bundle alongside mcp-time and mcp-clipboard.
- Build-time entitlement enforcement is now bidirectional: the build fails if mcp-applescript LACKS `automation.apple-events` AND if any other helper CARRIES it.
- A future plan (05-04 ToolDispatcher, 05-05 ConfirmationBroker) can register `mcp-applescript` via MCPClient and dispatch `run_applescript` with the confirmation gating layered on top.
- The plan completes its build-time work autonomously; live AppleScript-with-TCC verification is documented as a user-action gate matching Phase 1 Task 4's pattern.
</success_criteria>

<output>
Write `.planning/phases/05-mcp/05-03-SUMMARY.md`. Highlights:
- Third helper (mcp-applescript) added; only this helper carries `automation.apple-events`.
- `verify-entitlements.sh` extended with bidirectional per-helper enforcement (required AND forbidden lists per helper name).
- Three new fault-injection fixtures cover the positive (good), negative-required-missing (applescript-missing-grant), and negative-cross-drift (time-with-apple-events) cases.
- Document the result of the scaffold-time stderr probe that runs at helper init (RESEARCH Open Question #3 — does NSAppleScript work without NSApp.run()?). If the probe returns success on the executor's machine, leave the assumption as confirmed; if it hangs or returns -600, surface as a deferred item for a future plan to wrap the helper in NSApplicationDelegate.
- Note the autonomous=false gate clearly: live AppleScript execution against a real macOS TCC prompt requires (a) Developer ID Application identity (same gap as P1-05 Task 4) and (b) Apple Events capability on the App ID at developer.apple.com. Both blockers gate the SAME human-action checkpoint.
- Confirm the build still passes for non-AppleScript paths (mcp-time, mcp-clipboard round-trips from Plan 05-02 still green).
</output>
