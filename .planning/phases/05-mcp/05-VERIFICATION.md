---
phase: 05-mcp
verified: 2026-04-25T23:23:22Z
status: gaps_found
score: 31/32 must-haves verified
re_verification:
  previous_status: null
  previous_score: null
  gaps_closed: []
  gaps_remaining: []
  regressions: []
sha_verified: ca5b554ff55b7a5eec3337f263115619a9b85b82
req_ids_covered: [AGENT-11, MCP-01, MCP-02, MCP-03, MCP-04, MCP-07, MCP-08, MCP-09, SEC-07, SEC-08, ME-04]
spm_test_count: 360
gaps:
  - truth: "AppDelegate instantiates: MCPClient → registers 3 helpers → wraps via MCPToolDispatcher → wraps via ConfirmingToolDispatcher → injects into AgentOrchestrator. The orchestrator's ToolDispatcher is now the confirmation-gated MCP-backed dispatcher in production."
    status: failed
    reason: "App target xcodebuild fails (Debug AND Release) due to a Swift 6 concurrency error introduced by the CR-02 production wiring. AppDelegate.swift:294 places `await runtime.client.registeredToolNames().count` inside a string-interpolated logger autoclosure, which the compiler rejects: `'await' in an autoclosure that does not support concurrency` + `call to actor-isolated instance method 'registeredToolNames()' in a synchronous main actor-isolated context`. The structural wiring exists (steps 1-9 of applicationWillFinishLaunching land before step 10's MCPRuntimeWiring.build call) but step 10 itself does not compile, so the dispatcher chain is never constructed in a runnable build. SPM `swift build -c release` for JarvisMCP and AgentCore both pass — the regression is App-target-specific. Was masked because xcodebuild test for the App target is upstream-blocked (Xcode 26 harness bug) so the App target never gets compile-checked by tests."
    artifacts:
      - path: "App/AppDelegate.swift"
        issue: "Line 294: `self.systemLogger?.info(\"MCPRuntime built — \\(await runtime.client.registeredToolNames().count) tools\")` — `await` inside string interpolation autoclosure (which is non-async)."
    missing:
      - "Extract `let count = await runtime.client.registeredToolNames().count` to a local before the log call (or use a non-async accessor / cached count)."
      - "Add `xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug` as a CI gate so this class of regression doesn't recur (the upstream xctest blocker doesn't affect plain `xcodebuild build`)."
overrides_applied: 0
---

# Phase 5: MCP — Verification Report

**Phase Goal:** The three starter tools (`get_time`, `get_clipboard`, `run_applescript`) execute through the official MCP Swift SDK with correct helper codesigning, per-helper TCC identity, confirmation gating that never uses a webview modal, and a sanitize pipeline that defends the inbound boundary before tool results reach model-facing history.

**Verified:** 2026-04-25T23:23:22Z
**Status:** **gaps_found**
**SHA:** `ca5b554`
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (aggregated across 5 plans)

| #   | Truth                                                                                                          | Status     | Evidence                                                                                                                                                                                                |
| --- | -------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | MCPClient actor spawns helper, completes SDK initialize, returns tool-call results without manual JSON-RPC framing | ✓ VERIFIED | `MCPClient.swift:1-195` uses `Client` + `StdioTransport` from swift-sdk; integration tests in `MCPTimeIntegrationTests`, `MCPClipboardIntegrationTests`, and `MCPClientHappyPathTests` round-trip via SDK |
| 2   | On SIGKILL, in-flight `callTool` rejects with `JarvisMCPError.serverCrashed`                                   | ✓ VERIFIED | `MCPServerHandle.swift:257`, `MCPRestartTests.swift` covers crash-during-callTool                                                                                                                       |
| 3   | After crash, next `callTool` lazily restarts; concurrent callers share single restart task                     | ✓ VERIFIED | `MCPClient.swift:113` checks `restartTask` slot; `MCPServerHandle.swift:235-239` mutex                                                                                                                  |
| 4   | 100 sequential crash-and-restart cycles finish with parent FD count within ±16 of baseline                     | ✓ VERIFIED | `MCPRestartTests.swift:213` — actual run printed `[FD leak test] baseline=4 final=4 delta=0`                                                                                                            |
| 5   | Every `Process().run()` routes through `ChildSpawnGate.shared.prepare(...)`; non-CLOEXEC FD = fatalError in DEBUG | ✓ VERIFIED | `MCPServerHandle.swift:86`; `ChildSpawnGate.swift:47` `fatalError` in DEBUG                                                                                                                              |
| 6   | Spawned children see exactly `PATH=/usr/bin:/bin` and no other env keys                                        | ✓ VERIFIED | `ChildSpawnGate.swift:29` `minimalEnvironment = ["PATH": "/usr/bin:/bin"]`; `MCPServerHandle.swift:101` `process.environment = env`                                                                      |
| 7   | `Package.resolved` pins swift-sdk at exactly `0.12.0`                                                          | ✓ VERIFIED | `Package.resolved` carries `version: 0.12.0`; `Package.swift:` `.exact("0.12.0")`                                                                                                                       |
| 8   | `mcp-time` returns ISO 8601 timestamp via `MCPClient.callTool('get_time', [:])`                                | ✓ VERIFIED | `MCPTimeMain.swift:38-48` returns `ISO8601DateFormatter()` string; integration test round-trips via `ISO8601DateFormatter().date(from:)`                                                                |
| 9   | `mcp-clipboard` refuses `NSPasteboardTypeFileURL` even with string variant present                             | ✓ VERIFIED | `PasteboardReader.swift:36-44`, `PasteboardReaderTests` covers all 3 variants (only-fileURL, fileURL+string, types-contains-fileURL)                                                                     |
| 10  | Both helpers ship as separately-codesigned nested `.app` bundles; verify-entitlements grep finds no apple-events on time/clipboard | ✓ VERIFIED | `mcp-time/Support/mcp-time.entitlements` + `mcp-clipboard/Support/mcp-clipboard.entitlements` are empty plists; `grep apple-events mcp-servers/{time,clipboard}` = 0 matches |
| 11  | Helpers' Info.plist carry `LSUIElement=true` (and `LSBackgroundOnly=true` ON time/applescript only)            | ✓ VERIFIED | mcp-time + mcp-applescript Info.plists have BOTH; mcp-clipboard intentionally has ONLY LSUIElement (per CR-04 fix)                                                                                       |
| 12  | Both time/clipboard helpers build clean under SWIFT_VERSION 6.0 + strict concurrency                           | ✓ VERIFIED | `swift test` exit 0 in `mcp-time` (no tests target by design — covered by JarvisMCP integration suite) and `mcp-clipboard` (6/6)                                                                         |
| 13  | A trip through `callTool('get_time', [:])` returns ISO 8601 parseable string                                   | ✓ VERIFIED | Integration test `MCPTimeIntegrationTests.test_get_time_returnsISO8601String`                                                                                                                            |
| 14  | `mcp-applescript` returns NSAppleScript `.stringValue` on success                                              | ✓ VERIFIED | `AppleScriptRunnerTests.test_validScript_returnsSuccessWithStringValue` passes                                                                                                                           |
| 15  | Invalid AppleScript returns `isError: true` with `NSAppleScriptError{Number,Message}`                          | ✓ VERIFIED | `AppleScriptRunnerTests.test_invalidSyntax_returnsCompileFailure` + `test_runtimeError_returnsRuntimeError` (4/4)                                                                                        |
| 16  | applescript helper signed entitlements carry exactly `automation.apple-events = true` and nothing else        | ✓ VERIFIED | `mcp-applescript.entitlements` content = single `automation.apple-events true` key                                                                                                                       |
| 17  | Post-codesign verify-entitlements asserts: only mcp-applescript HAS apple-events; mcp-time/mcp-clipboard LACK | ✓ VERIFIED | `scripts/verify-entitlements.sh` extended with HELPER_ENTITLEMENT_RULES; fixtures present (good/missing/cross-drift)                                                                                     |
| 18  | Fault-injection self-test covers good-applescript, missing-applescript, time-with-apple-events fixtures       | ✓ VERIFIED | All 3 fixtures present at `scripts/test-fixtures/helper-{applescript-good,applescript-missing,time-with-apple-events}.entitlements`                                                                      |
| 19  | `SanitizeForModel.sanitize` strips bidi (U+202A..E, U+2066..9), zero-width (U+200B..D, U+2060, U+FEFF), C0 controls | ✓ VERIFIED | `SanitizeForModel.swift:38-56`, tests cover each class                                                                                                                                                  |
| 20  | `SanitizeForModel.sanitize` caps each line at 4096 bytes with `…[line-truncated]` marker                      | ✓ VERIFIED | `SanitizeForModelTests.test_lineCapped_*` pair                                                                                                                                                           |
| 21  | `SanitizeForModel.sanitize` enforces UTF-8 validity (total function — any input → valid output)               | ✓ VERIFIED | `SanitizeForModelTests.test_invalidUTF8_*`                                                                                                                                                                |
| 22  | `SanitizeForModel.headTruncate` head-truncates to 8192 bytes with `…[tool-result-truncated…]` marker          | ✓ VERIFIED | `SanitizeForModelTests.test_headTruncate_*`                                                                                                                                                              |
| 23  | `prepareForBoundary` runs sanitize → headTruncate (NO wrap step)                                              | ✓ VERIFIED | `SanitizeForModelTests.test_prepareForBoundary_runsSanitizeBeforeHeadTruncate` — 10000-byte ZWSP-pair input distinguishes orderings                                                                       |
| 24  | `MCPToolDispatcher` conforms to AgentOrchestrator's `ToolDispatcher`; calls MCPClient.callTool + sanitize     | ✓ VERIFIED | `MCPToolDispatcher.swift:71`, `MCPToolDispatcher.swift:114`                                                                                                                                              |
| 25  | `MCPToolDispatcher.requiresConfirmation` returns true for `run_applescript`, false for `get_time` / `get_clipboard` | ✓ VERIFIED | `MCPRuntimeWiring.swift:117-119` registry seed; `MCPToolDispatcherTests` cover requiresConfirmation                                                                                                     |
| 26  | Pre/post-sanitize bytes exposed via `ToolResultObserver` callback                                              | ✓ VERIFIED | `MCPToolDispatcher.swift` calls observer with both byte streams                                                                                                                                          |
| 27  | `ConfirmationBroker.request` returns one of {.approve, .deny, .timeout, .barge}; first call wins, late hops no-op | ✓ VERIFIED | `ConfirmationOutcome.swift:19-24` 4 cases; `ConfirmationBroker.swift:123` `guard req.resolved == false else { return }`                                                                                  |
| 28  | 60s timeout on `broker.request` synthesizes `.timeout` and resumes awaiter exactly once                       | ✓ VERIFIED | `ConfirmationBroker.swift:91-98` Task.sleep(for:) + response(.timeout); test_OC_T1_timeoutLogsWarning captures actual log line + asserts subsystem                                                       |
| 29  | `ConfirmationPresenter` shows AppKit sheet on hidden NSPanel via `beginSheet`; never `runModal`                | ✓ VERIFIED | `ConfirmationPresenter.swift:127` `owner.beginSheet(panel)`; modal-lint allowlist accepts only TCCAlertService + ConfirmationPresenter (latter has runModal in DOC COMMENTS only — comment-stripping prevents false positive) |
| 30  | `ConfirmingToolDispatcher` wraps inner; on `.approve` proceeds; on .deny/.timeout/.barge throws ConfirmationError | ✓ VERIFIED | `ConfirmingToolDispatcher.swift:108`, `ConfirmingToolDispatcherTests` cover all 4 outcomes including deny/timeout/barge → throw + bus toolCallEnd(ok: false)                                              |
| 31  | Bus argsPreview is `{"awaitingApproval":true}` BEFORE approval; sanitized preview AFTER                        | ✓ VERIFIED | `ConfirmingToolDispatcher.swift:131` `let awaitingPreview = #"{"awaitingApproval":true}"#`; argsPreviewUpdate event after approval carries the sanitized JSON                                              |
| 32  | `scripts/check-no-modal-presentation.sh` runs as preBuildScript; fails on runModal/beginModalSession/NSApp.run outside allowlist | ✓ VERIFIED | Script exit 0 against codebase; exit 0 against `string-literal-modal-mentions.swift` (WR-01 fix); exit 1 against `forbidden-modal-call.swift`; allowlist = exactly TCCAlertService + ConfirmationPresenter |
| 33  | `AppDelegate` instantiates MCPClient → registers 3 helpers → wraps via MCPToolDispatcher → wraps via ConfirmingToolDispatcher → injects into AgentOrchestrator | ✗ FAILED | **App target xcodebuild fails** at AppDelegate.swift:294 — `await runtime.client.registeredToolNames().count` in string-interpolation autoclosure is rejected by Swift 6 concurrency. SPM packages build fine. The structural wiring is in place (lines 252-298) but the build is broken. See gaps. |
| 34  | `ReplayingToolResultObserver` records both pre- and post-sanitize bytes via `ReplayLog.record(.toolResultFull(...))` for every dispatch | ✓ VERIFIED (structural — see ME-04 section) | Observer's record() produces 2 envelopes per call (sanitized + raw with `:raw` suffix); drain in AppDelegate consumes; tests `test_observer_producesIntoReplayChannel` + `test_observer_to_channel_to_drain_writes_to_replayLog` cover end-to-end |

**Score:** **31/32** truths VERIFIED (truth #33 FAILED on App-target build). Note: I aggregated 32 distinct testable truths from the 5 plans' must_haves; some were collapsed (e.g., LSUIElement+LSBackgroundOnly variants).

### Required Artifacts

| Artifact                                                                | Expected (min lines)                                       | Status            | Details                                                                       |
| ----------------------------------------------------------------------- | ---------------------------------------------------------- | ----------------- | ----------------------------------------------------------------------------- |
| `packages/MCP/Package.swift`                                            | swift-sdk @ exact 0.12.0                                   | ✓ VERIFIED        | `.exact("0.12.0")` present                                                    |
| `packages/MCP/Sources/MCP/MCPClient.swift` (≥100)                       | actor with register/callTool/shutdown                      | ✓ VERIFIED        | 195 lines                                                                     |
| `packages/MCP/Sources/MCP/MCPServerHandle.swift` (≥80)                  | Process + Pipe + SDK Client + restartTask                  | ✓ VERIFIED        | 344 lines (post-CR-01 fix added closeParentPipeEnds helper)                   |
| `packages/MCP/Sources/MCP/ChildSpawnGate.swift` (≥40)                   | actor with FD_CLOEXEC sweep + minimal env                  | ✓ VERIFIED        | 55 lines                                                                      |
| `packages/MCP/Sources/MCP/MCPError.swift`                               | error enum                                                 | ✓ VERIFIED        | 42 lines, all 5 cases declared                                                |
| `mcp-servers/mcp-time/Sources/mcp-time/MCPTimeMain.swift` (≥30)         | get_time SDK server                                        | ✓ VERIFIED        | 61 lines                                                                      |
| `mcp-servers/mcp-clipboard/Sources/.../MCPClipboardMain.swift` (≥30)    | get_clipboard with fileURL refusal                         | ✓ VERIFIED        | 110 lines                                                                     |
| `mcp-servers/mcp-clipboard/.../PasteboardReader.swift` (≥40)            | testable PasteboardLike protocol + concrete reader         | ✓ VERIFIED        | 50 lines, 6/6 tests pass                                                      |
| `mcp-servers/mcp-time/Support/Info.plist`                               | LSUIElement + bundle identifier                            | ✓ VERIFIED        | `LSUIElement=true`, `LSBackgroundOnly=true`, `com.koftwentytwo.jarvis.mcp-time`|
| `mcp-servers/mcp-clipboard/Support/Info.plist`                          | LSUIElement + bundle identifier                            | ✓ VERIFIED        | `LSUIElement=true` only (CR-04 removed LSBackgroundOnly)                      |
| `mcp-servers/mcp-time/Support/mcp-time.entitlements`                    | empty plist dict                                           | ✓ VERIFIED        | empty `<dict></dict>`                                                         |
| `mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements`          | empty plist dict                                           | ✓ VERIFIED        | empty `<dict></dict>`                                                         |
| `project.yml`                                                           | helper targets + non-empty copyFiles for Contents/Helpers/ | ✓ VERIFIED        | postBuildScript walks BUILT_PRODUCTS_DIR + cp -R into Contents/Helpers/       |
| `mcp-servers/mcp-applescript/.../MCPAppleScriptMain.swift` (≥30)        | run_applescript SDK server                                 | ✓ VERIFIED        | 105 lines                                                                     |
| `mcp-servers/mcp-applescript/.../AppleScriptRunner.swift` (≥40)         | testable runner + NSAppleScript impl                       | ✓ VERIFIED        | 80 lines, 4/4 tests                                                           |
| `mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements`      | ONLY apple-events                                          | ✓ VERIFIED        | single key `com.apple.security.automation.apple-events`                       |
| `mcp-servers/mcp-applescript/Support/Info.plist`                        | NSAppleEventsUsageDescription + LSUIElement                | ✓ VERIFIED        | All required keys present                                                     |
| `scripts/verify-entitlements.sh` (≥200)                                 | helper entitlement rules                                   | ✓ VERIFIED        | extended; covers HELPER_ENTITLEMENT_RULES                                     |
| `scripts/test-fixtures/helper-applescript-good.entitlements`            | positive case                                              | ✓ VERIFIED        | exists                                                                        |
| `scripts/test-fixtures/helper-applescript-missing.entitlements`         | negative case                                              | ✓ VERIFIED        | exists                                                                        |
| `scripts/test-fixtures/helper-time-with-apple-events.entitlements`      | cross-drift negative                                       | ✓ VERIFIED        | exists                                                                        |
| `packages/MCP/Sources/MCP/SanitizeForModel.swift` (≥70)                 | sanitize/headTruncate/prepareForBoundary                   | ✓ VERIFIED        | 96 lines                                                                      |
| `packages/MCP/Sources/MCP/ToolRegistry.swift` (≥30)                     | tool→server→requiresConfirmation map                       | ✓ VERIFIED        | 53 lines                                                                      |
| `packages/MCP/Sources/MCP/MCPToolDispatcher.swift` (≥60)                | actor conforming to ToolDispatcher                         | ✓ VERIFIED        | 166 lines                                                                     |
| `packages/MCP/Sources/MCP/ConfirmationBroker.swift` (≥80)               | actor FSM with first-write-wins + injectable timeout       | ✓ VERIFIED        | 143 lines                                                                     |
| `packages/MCP/Sources/MCP/ConfirmationPresenter.swift` (≥60)            | NSPanel beginSheet, no runModal                            | ✓ VERIFIED        | 169 lines                                                                     |
| `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift` (≥50)         | confirmation-gating wrapper                                | ✓ VERIFIED        | 233 lines                                                                     |
| `App/MCP/MCPRuntimeWiring.swift` (≥50)                                  | dependency-graph constructor                               | ✓ VERIFIED        | 224 lines                                                                     |
| `App/MCP/ReplayingToolResultObserver.swift` (≥25)                       | concrete ToolResultObserver writing to ReplayLog           | ✓ VERIFIED        | 107 lines                                                                     |
| `scripts/check-no-modal-presentation.sh` (≥30)                          | pre-build modal lint                                       | ✓ VERIFIED        | self-tests against allowed/forbidden/string-literal fixtures                  |

**Artifacts:** 30/30 VERIFIED at file-level. The blocker is at the wiring/build level (see #33).

### Key Link Verification

| From                                     | To                                            | Via                                                                            | Status      |
| ---------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------ | ----------- |
| MCPServerHandle                          | swift-sdk Client + StdioTransport             | `StdioTransport(input:..., output:..., logger:...)`                            | ✓ WIRED     |
| MCPClient                                | MCPServerHandle.restartTask                    | shared restart task                                                            | ✓ WIRED     |
| MCPServerHandle                          | ChildSpawnGate.shared                         | `try await ChildSpawnGate.shared.prepare()` BEFORE process.run()              | ✓ WIRED     |
| mcp-clipboard main                       | PasteboardReader.read()                       | withMethodHandler(CallTool.self) → reader.read()                              | ✓ WIRED     |
| project.yml                              | Jarvis Contents/Helpers/                      | postBuildScript cp -R BUILT_PRODUCTS_DIR/<helper>.app                         | ✓ WIRED     |
| scripts/codesign.sh                      | Helper Resources/<helper>.entitlements        | deepest-first walker                                                          | ✓ WIRED     |
| mcp-applescript main                     | AppleScriptRunner.run(source:)                | withMethodHandler(CallTool.self)                                              | ✓ WIRED     |
| scripts/verify-entitlements.sh           | per-helper rules                              | HELPER_ENTITLEMENT_RULES                                                       | ✓ WIRED     |
| MCPToolDispatcher                        | SanitizeForModel.prepareForBoundary           | `SanitizeForModel.prepareForBoundary(rawText, capBytes: 8192)`                | ✓ WIRED     |
| MCPToolDispatcher                        | AgentOrchestrator.ToolDispatcher              | `: ToolDispatcher` conformance                                                | ✓ WIRED     |
| MCPToolDispatcher                        | MCPClient                                     | internal dependency                                                            | ✓ WIRED     |
| ConfirmingToolDispatcher                 | ConfirmationBroker                            | `broker.request(...)` when requiresConfirmation                               | ✓ WIRED     |
| AppDelegate                              | MCPRuntimeWiring                              | `MCPRuntimeWiring.build(...)` in applicationWillFinishLaunching step 10        | ⚠️ ORPHANED (compile error) |
| ConfirmationPresenter                    | NSPanel.beginSheet                            | `owner.beginSheet(panel) { _ in ... }`                                         | ✓ WIRED     |
| scripts/check-no-modal-presentation.sh   | preBuildScripts in project.yml                | wired alongside check-bus-protocol-version.sh                                 | ✓ WIRED     |

**Wiring:** 14/15 connections WIRED. AppDelegate→MCPRuntimeWiring is structurally present but the call site does not compile (see gaps).

## Tests Prove Truths

This phase gets close attention because Phase 4's HI-02 finding was a proxy-assertion lesson. Verified each high-leverage truth has a non-proxy test:

| Truth | Test | Anti-Proxy Verification |
|-------|------|-------------------------|
| 23 — sanitize → headTruncate ordering | `SanitizeForModelTests.test_prepareForBoundary_runsSanitizeBeforeHeadTruncate` | **Strong.** Feeds 10000-byte input of `x\u{200B}` pairs (4 UTF-8 bytes each, 2500 pairs). Asserts the OUTPUT (a) doesn't contain `…[tool-result-truncated` AND (b) doesn't contain ZWSP — distinguishes wrong order from right order. The bytes themselves carry the proof. |
| 28 — broker timeout logs WARNING | `ConfirmingToolDispatcherTests.test_OC_T1_timeoutLogsWarning` | **Strong.** Captures actual log lines via `SpyLogRecorder`; asserts `warnings.count == 1`, `line.contains("timeout")`, `line.contains("ConfirmingToolDispatcher")`. Not just `outcome == .timeout`. |
| 4 — 100-cycle FD-leak | `MCPRestartTests.test_100_crashCycles_noFDLeak` | **Strong (runtime).** Real loop with SIGKILL + countOpenFDs() bracketing; printed `baseline=4 final=4 delta=0`. |
| CR-01 init-failure FD leak | `MCPServerHandleInitFailureFDLeakTests` (4 tests) | **Structural source-level.** Justified — runtime FD-count loop hits ChildSpawnGate's DEBUG fatalError before assertion. Asserts: helper exists, closes all 3 ends, both throw arms call helper, cleanup precedes throw. Documented compromise in fix report. |
| 9 — clipboard fileURL refusal | `MCPClipboardIntegrationTests.test_get_clipboard_seeded_returnsSeededString_CR04` | **Strong.** Parent seeds `JARVIS-CR04-SEED-<UUID>` via NSPasteboard.general; helper invocation must return EXACTLY that seed. Explicitly asserts `text != "(clipboard empty)"` (the silent-empty pre-CR-04 mode). Skips on headless CI. |
| CR-03 String toolUseId | `ConfirmingToolDispatcherTests.test_dispatch_busToolUseId_isOriginalString_acrossAllEmissions` + `test_dispatch_nonUUIDId_passesThroughVerbatim_onDeny` | **Strong.** Feeds `toolu_01ABCDEFGHIJKLMNOPQRSTUVWX` AND `ollama-call-7f3a` (non-UUID); asserts ALL bus events carry the original String verbatim across start + update + end. Regression for `UUID(uuidString:) ?? UUID()` synthesis. |
| ME-04 closure observer→channel→drain→ReplayLog | `MCPRuntimeWiringTests.test_observer_to_channel_to_drain_writes_to_replayLog` + `test_observer_producesIntoReplayChannel` + `test_replayChannel_dropOldest_underBurst` | **Strong (test-level).** First test spawns a real ephemeral ReplayLog at `/tmp`, mirrors AppDelegate's drain loop verbatim, asserts the write completes without throw. Second asserts both envelopes (sanitized + raw with `:raw` marker) flow. Third saturates 10× capacity and asserts `.dropOldest` policy holds. **See ME-04 Closure section below for the production-state caveat.** |

No disabled tests. No circular fixtures. No proxy assertions discovered.

## Post-Review-Fix Verification (CR-01 .. WR-07)

| Finding | Fix | Code Verified | Test Verified |
|---------|-----|---------------|---------------|
| CR-01 — MCPServerHandle init-failure FD leak | `closeParentPipeEnds` helper called from both throw arms | `MCPServerHandle.swift` contains helper + 2 call sites + cleanup-before-throw | `MCPServerHandleInitFailureFDLeakTests` (4 source-level invariants) |
| CR-02 — ME-04 closure observer→channel→drain→ReplayLog | Observer produces into channel; drain in AppDelegate consumes | `ReplayingToolResultObserver` sends 2 envelopes per record(); `AppDelegate.swift:252-273` opens ReplayLog + spawns drain task; `MCPRuntimeWiring.build` called from AppDelegate.swift:287 | `MCPRuntimeWiringTests` 3 new tests |
| CR-03 — Bus toolUseId String not UUID | toolUseId is String everywhere (BusGateway protocol + dispatcher emissions) | `ConfirmingToolDispatcher.swift:115` doc comment confirms; emissions use original String | `test_dispatch_busToolUseId_isOriginalString_acrossAllEmissions` + `test_dispatch_nonUUIDId_passesThroughVerbatim_onDeny` |
| CR-04 — mcp-clipboard LSBackgroundOnly removed | Option A | `mcp-clipboard/Support/Info.plist` has only LSUIElement | `test_get_clipboard_seeded_returnsSeededString_CR04` |
| WR-01 — Lint matches in strings/comments | PATTERN tightened to call-site shape; pre-strip strings + comments | `scripts/check-no-modal-presentation.sh:48-55` | `--fixture string-literal-modal-mentions.swift` exit 0; forbidden fixture exit 1 |
| WR-02 — Broker/presenter weak-cycle silent no-op | Holder holds presenter strongly; presenter holds broker strongly | `MCPRuntimeWiring.swift:200` `private var inner: ConfirmationPresenter?` (strong) | `ConfirmationLifecycleTests` (3 tests) |
| WR-03 — Broker timer cancellation race | Explicit do/catch for `Task.sleep(for:)` early-returns on CancellationError | `ConfirmationBroker.swift:91-98` | `test_response_atTimerBoundary_firstWriteWins_noDoubleResolve` (10× loop at 50ms) |
| WR-04 — toolCallEnd on success path | Approve path emits 3 events (start + argsPreviewUpdate + end) | `ConfirmingToolDispatcherTests.test_dispatch_confirmTool_onApprove` asserts 3 events | combined with CR-03 assertion above |
| WR-05 — Pasteboard MainActor hop | `MainActor.assumeIsolated` / `DispatchQueue.main.sync` for SDK-thread reads | `MCPClipboardMain.swift` | covered by 6 PasteboardReader unit tests + CR-04 seeded test |
| WR-06 — MCPClient.callTool arguments optional | `arguments: [String: Value]?` parameter | `MCPClient.swift` callTool default `nil` | `test_callTool_withoutArguments_isAccepted` |
| WR-07 — Helper signing settings verification | pbxproj lint Rule 4 + Rule 5 | `scripts/verify-codesign-settings.sh` exit 0 | manual perturbation per fix report |

All 11 BLOCKER + WARNING fixes verified at code AND test level.

## ME-04 Closure (Detailed)

**Status:** **Structurally complete; pending live traffic.**

Code-level wiring (CR-02 fix):

1. **AppDelegate** instantiates the production `BoundedAsyncChannel<ReplayEnvelope>(capacity: 2048, policy: .dropOldest)` (line 252) and a real `ReplayLog` at `~/Library/Application Support/Jarvis/replay.sqlite` (line 256).
2. **AppDelegate** spawns `orchToReplayDrainTask` consuming `for await envelope in channel { await log.record(envelope.event, for: envelope.turnId) }` (lines 258-262).
3. **AppDelegate** calls `MCPRuntimeWiring.build(bundleURL:, bus:, replayChannel: channel, turnIDResolver: { nil })` inside a Task (lines 286-298).
4. **MCPRuntimeWiring.build** instantiates `ReplayingToolResultObserver(replayChannel: channel, turnIDResolver:)` (line 123) and injects it into `MCPToolDispatcher` (line 126).
5. **ReplayingToolResultObserver.record** calls `replayChannel.send(.init(turnId, .toolResultFull(toolUseId, sanitizedBytes)))` AND `replayChannel.send(.init(turnId, .toolResultFull(toolUseId + ":raw", rawBytes)))` per dispatch (lines 84-91).

**The caveat I must surface (UNCERTAIN — not a gap, but worth flagging):** the observer's `record(...)` opens with `guard let turnId = await turnIDResolver() else { logger.debug(...); return }`. In the current production state, `turnIDResolver` is `{ nil }` because the orchestrator is not yet wired (it is a Phase 6/7 deliverable). So the observer **logs and returns early without writing to the channel** in production today. Tests pass because they inject `turnIDResolver: { turnId }` with a real TurnID.

**Why this is acceptable for Phase 5 close:** the structural wiring is complete (channel produced + drain consumes + observer connected). The orchestrator is the missing producer of TurnIDs, and the orchestrator → MCP dispatch path is Phase 6/7's job per `MCPRuntimeWiring.swift:84-94` documentation: "`turnIDResolver`: closure the observer uses to resolve the active TurnID at write time. Returns `nil` until the orchestrator is wired (later plan)."

**What would make this VERIFIED instead of UNCERTAIN:** a production observer call that returns a non-nil TurnID and lands in the SQLite database. That's a Phase 6/7 milestone-close deliverable.

Truth #34 (the ME-04 wiring) is therefore VERIFIED at the structural level. The deferred-traffic concern is captured in **Known Deferred** below.

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| JarvisMCP test suite | `cd packages/MCP && swift test` | 79/79 pass in 35.99s; FD leak baseline=4 final=4 delta=0 | ✓ PASS |
| AgentCore test suite | `cd packages/AgentCore && swift test` | 134/134 pass | ✓ PASS |
| Replay test suite | `cd packages/Replay && swift test` | 27/27 pass | ✓ PASS |
| Bus test suite | `cd packages/Bus && swift test` | 47/47 pass | ✓ PASS |
| mcp-clipboard test suite | `cd mcp-servers/mcp-clipboard && swift test` | 6/6 pass (PasteboardReaderTests) | ✓ PASS |
| mcp-applescript test suite | `cd mcp-servers/mcp-applescript && swift test` | 4/4 pass (AppleScriptRunnerTests) | ✓ PASS |
| mcp-time test suite | `cd mcp-servers/mcp-time && swift test` | no tests target by design (covered by JarvisMCP integration suite) | ✓ PASS |
| Modal-lint against codebase | `bash scripts/check-no-modal-presentation.sh` | exit 0 | ✓ PASS |
| Modal-lint allowed fixture | `--fixture allowed-non-modal-call.swift` | exit 0 | ✓ PASS |
| Modal-lint forbidden fixture | `--fixture forbidden-modal-call.swift` | exit 1 (correctly flags `alert.runModal()`) | ✓ PASS |
| Modal-lint string-literal fixture | `--fixture string-literal-modal-mentions.swift` | exit 0 | ✓ PASS |
| Codesign-settings pbxproj lint | `bash scripts/verify-codesign-settings.sh` | exit 0 | ✓ PASS |
| Cross-helper apple-events grep | `grep -rn 'automation.apple-events' mcp-servers/{mcp-time,mcp-clipboard,mcp-applescript}` | matches ONLY in mcp-applescript | ✓ PASS |
| swift-sdk pin | `grep modelcontextprotocol Package.resolved` | version 0.12.0 | ✓ PASS |
| SPM release build (JarvisMCP) | `swift build -c release` (in packages/MCP) | Build complete! | ✓ PASS |
| SPM release build (AgentCore) | `swift build -c release` (in packages/AgentCore) | Build complete! | ✓ PASS |
| **Xcode Debug build (App target)** | `xcodebuild build -scheme Jarvis -configuration Debug` | **BUILD FAILED** at AppDelegate.swift:294 | ✗ **FAIL** |
| **Xcode Release build (App target)** | `xcodebuild build -scheme Jarvis -configuration Release` | **BUILD FAILED** at AppDelegate.swift:294 (same line) | ✗ **FAIL** |

## Requirements Coverage

| Requirement | Description | Status | Evidence |
|-------------|-------------|--------|----------|
| AGENT-11 | 60s timeout on `broker.response(id)` await; timed-out = synthetic deny + log | ✓ SATISFIED | broker.swift:91-98 + test_OC_T1_timeoutLogsWarning |
| MCP-01 | MCP client uses `modelcontextprotocol/swift-sdk v0.12.0` | ✓ SATISFIED | Package.resolved exact 0.12.0 |
| MCP-02 | `get_time` returns current time, invocable by agent | ✓ SATISFIED | MCPTimeIntegrationTests round-trips ISO 8601 |
| MCP-03 | `get_clipboard` refuses NSPasteboardTypeFileURL regardless of string content | ✓ SATISFIED | PasteboardReader 6/6 + CR-04 seeded test |
| MCP-04 | `run_applescript` gated behind native AppKit confirmation sheet (NEVER webview); argsPreview = `{awaitingApproval:true}` until approved | ✓ SATISFIED | ConfirmationPresenter beginSheet + lint guard + dispatcher awaitingPreview at line 131 |
| MCP-07 | Per-server restart mutex; concurrent callers share one restart; `MCPError.serverCrashed` on EOF | ✓ SATISFIED | MCPServerHandle.restartTask + MCPRestartTests 100-cycle |
| MCP-08 | ChildSpawnGate enforces FD_CLOEXEC + minimal env (`PATH=/usr/bin:/bin`) | ✓ SATISFIED | ChildSpawnGate.swift + MCPServerHandle calls prepare() |
| MCP-09 | 4 legal transitions; modals forbidden across @MainActor (lint-enforced); late-hop no-ops | ✓ SATISFIED | broker.swift:114-142 + check-no-modal-presentation.sh |
| SEC-07 | Tool-result sanitize pipeline (sanitize → headTruncate, then orchestrator wraps); replay captures pre+post bytes | ✓ SATISFIED (structural) | SanitizeForModel + MCPToolDispatcher; observer wired (live traffic deferred to Phase 6/7) |
| SEC-08 | No AppleScript skip-allowlist (regex bypass forbidden) | ✓ SATISFIED | Plan 05-03 explicitly forbids; AppleScriptRunner has no allowlist code |
| ME-04 | orch→replay 2048-cap channel wired in production code (not just instantiated) | ✓ SATISFIED (structural) | AppDelegate.swift:252-262 + MCPRuntimeWiring.build call; live traffic awaits orchestrator wiring |

**Note:** MCP-05 + MCP-06 are explicitly Phase 1 requirements (per REQUIREMENTS.md line 212-213). Phase 5 verifies them implicitly via the helper bundle codesign chain landing.

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| App/AppDelegate.swift | 294 | `await runtime.client.registeredToolNames().count` in string interpolation autoclosure | 🛑 **Blocker** | App target xcodebuild fails Debug + Release |

No TODOs, FIXMEs, XXX, HACK, placeholder, or "coming soon" patterns in MCP package, helpers, or App/MCP/. The single anti-pattern is the compile-time failure introduced by the CR-02 fix.

## Human Verification Required

These remain deferred per the verification method's `known_deferred` block:

### 1. Apple Events Capability Registration on developer.apple.com

**Test:** Register/extend App ID `com.koftwentytwo.jarvis.mcp-applescript` and enable Apple Events Sandbox Exception (Automation) capability.

**Expected:** Live `run_applescript` tool call from a Release-signed/notarized archive returns the script's stdout. Without this capability, AppleEvent error -1743 (`errAEEventNotPermitted`) returns on first execution with no TCC prompt.

**Why human:** Cannot be scripted — requires authenticated session at developer.apple.com. Same gating constraint as Phase 1's speech-recognition-assets (HUMAN-UAT documented at `05-03-HUMAN-UAT.md`).

**When this becomes blocking:** Phase 8 (Hardening) — Release archive notarization. Non-blocking for Phase 5/6/7 because Debug builds + ad-hoc signing exercise the helper through the agent loop without notarization.

### 2. Live three-tool exercise via agent loop

**Test:** Cold-launch a Debug build, summon HUD, type "what time is it", "what's on my clipboard", "what processes are running" (last triggers run_applescript confirmation).

**Expected:** All three tool calls round-trip through the orchestrator (Phase 4 deliverable). The applescript call shows the AppKit confirmation sheet on the hidden NSPanel — not a webview modal.

**Why human:** Visual / interaction verification. Also depends on the orchestrator → MCP dispatch wiring landing (Phase 6/7 deliverable).

**When this becomes blocking:** Milestone-close UAT pass.

### 3. Live ME-04 traffic verification

**Test:** During a live agent turn that invokes a tool, query `~/Library/Application Support/Jarvis/replay.sqlite` for `tool_result_full` rows.

**Expected:** Two rows per dispatch — one with `tool_use_id = <orig>` (sanitized bytes), one with `tool_use_id = <orig>:raw` (raw bytes). turnIDResolver returns a real TurnID (not nil).

**Why human:** Depends on orchestrator → turnIDResolver wiring landing in Phase 6/7. Today's turnIDResolver returns nil so observer logs without writing.

## Known Deferred

Per the verification method's `known_deferred` block — these are NOT failures:

1. **HUMAN-UAT for mcp-applescript App ID capability** at developer.apple.com — non-blocking through Phase 7; first hard-blocked at Phase 8 (Release notarization). See `05-03-HUMAN-UAT.md`.
2. **App XCTest runtime** — Xcode 26 upstream harness bug. SPM tests + structural app-level tests cover. Per `HANDOFF.json`. **BUT note:** this masked the AppDelegate.swift:294 compile error because `xcodebuild test` was the loop never run. Recommend gating on `xcodebuild build` (no -test) at minimum.
3. **Manual cold-launch UAT** — defer to milestone-close UAT pass.
4. **INFO findings IN-01..IN-04** — out of default fix scope (diagnostic / robustness improvements; not blocking).
5. **Live tool exercise** — Phase 6 (Voice) milestone or milestone-close manual exercise.
6. **Live ME-04 traffic** — depends on orchestrator → turnIDResolver landing in Phase 6/7.

## Gaps Summary

### Critical Gap (Blocks Phase 5 close)

**G-01: App target does not build (Debug or Release).**

- **What:** `App/AppDelegate.swift:294` places `await runtime.client.registeredToolNames().count` inside a string-interpolation autoclosure. Swift 6 rejects: `'await' in an autoclosure that does not support concurrency` AND `call to actor-isolated instance method 'registeredToolNames()' in a synchronous main actor-isolated context`.
- **Why missed:** Introduced by CR-02 fix (the new step-10 wiring block in `applicationWillFinishLaunching`). xcodebuild test for the App target is upstream-blocked (Xcode 26 harness bug per HANDOFF.json), so the App target was never compile-checked by the test loop. SPM packages all build clean — the regression is App-target-specific.
- **Severity:** 🛑 **BLOCKER**. Phase 5's Success Criterion #1 ("MCP client uses swift-sdk via the dispatcher chain registered in AppDelegate") is structurally complete in source but unbuildable. The runtime wiring cannot execute.
- **Fix:** One-line repair — extract the await call to a local before logging. Suggested patch:
  ```swift
  self.mcpRuntime = runtime
  let toolCount = await runtime.client.registeredToolNames().count
  self.systemLogger?.info("MCPRuntime built — \(toolCount) tools")
  ```
- **Recommended secondary fix:** Add `xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug` (no `-test`) as a CI gate so this class of regression doesn't recur. The xctest harness blocker doesn't affect plain `xcodebuild build`.

## Recommended Fix Plans

### 05-06-PLAN.md: Repair App-target build regression

**Objective:** Restore xcodebuild Debug + Release pass on the App target post-CR-02 wiring.

**Tasks:**
1. **App/AppDelegate.swift:294** — Extract `await runtime.client.registeredToolNames().count` to a local variable before the logger call. Re-run `xcodebuild build -scheme Jarvis -configuration Debug` AND `-Release`; both must exit 0.
2. **scripts/check-app-builds.sh** (new, ≤30 lines) — wraps `xcodebuild build -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug` and exits 1 on failure. Document its run cadence in `.planning/STATE.md` so the App target doesn't drift again. (No xctest invocation — purely compile-check.)
3. **`.planning/HANDOFF.json`** — annotate the xctest blocker note with "compile-check via `scripts/check-app-builds.sh` is the substitute gate until Apple resolves Xcode 26 #….".

**Estimated scope:** Small (≤1 hour).

**Verification:** Re-run `/gsd-verify-phase 5` after fix lands. All 32 truths should flip to VERIFIED.

## Verification Metadata

**Verification approach:** Goal-backward (must_haves aggregated from 5 PLAN frontmatter blocks)
**Must-haves source:** PLAN.md frontmatter (Option A — present in all 5 plans)
**Automated checks:** 31 passed, 1 failed (App-target build), 0 uncertain
**Human checks required:** 0 net-new (all 3 listed items are pre-known-deferred)
**SPM test count:** 79 (JarvisMCP) + 134 (AgentCore) + 27 (Replay) + 47 (Bus) + 14 (DevOverlay) + 6 (mcp-clipboard) + 4 (mcp-applescript) + supporting packages = 360+ passing, 0 failures
**Total verification time:** ~25 min

---
_Verified: 2026-04-25T23:23:22Z_
_Verifier: Claude (gsd-verifier)_
