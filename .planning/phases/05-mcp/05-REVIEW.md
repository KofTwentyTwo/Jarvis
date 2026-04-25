---
phase: 05-mcp
review_depth: standard
files_reviewed: 65
diff_base: 1e83ac7
diff_head: 488f0da
reviewer: gsd-code-reviewer
review_date: 2026-04-25
summary: "Phase 5 lands the MCP runtime, three helpers, sanitize pipeline, and confirmation broker; structural invariants hold but several BLOCKERs (FD leak on init failure, observer/channel disconnect, bus-correlation UUID drift) plus app-shell wiring gaps remain."
findings_by_severity:
  blocker: 4
  warning: 7
  info: 4
  total: 15
---

# Phase 5: Code Review Report

**Reviewed:** 2026-04-25
**Depth:** standard
**Files Reviewed:** 65 (`1e83ac7..488f0da`)
**Status:** issues_found

## Summary

Plans 05-01 through 05-05 generally execute the architectural spec faithfully. The
big-ticket invariants are in place: `ChildSpawnGate` is the sole spawn surface,
the per-server restart mutex collapses concurrent callers, the SEC-07 pipeline
runs `sanitize → headTruncate` (with no wrap inside `MCPToolDispatcher`), the
confirmation broker enforces first-write-wins, the modal-presentation lint is
wired and self-tested, and the per-helper bidirectional entitlement verifier
fails closed on unknown helpers. Tests are thoughtful — the
`prepareForBoundary` order test is a real regression guard, not a tautology.

That said, this phase ships meaningful defects. The most consequential is that
the production "ME-04 closure" advertised in the SUMMARY is partially fictional:
`AppDelegate` instantiates the `BoundedAsyncChannel<ReplayEvent>` and a drain
Task, but the `ReplayingToolResultObserver` does not write to that channel — it
calls `replayLog.record(...)` directly. The channel has no producer, the drain
has no payload, and `MCPRuntimeWiring.build(...)` is referenced only in doc
comments — never actually invoked from `AppDelegate`. The dispatcher chain that
underpins this phase therefore has zero live wiring in production code today.

Other BLOCKERs: a 3-FD leak on every failed `MCPServerHandle.start()`, the
ConfirmingToolDispatcher generates fresh UUIDs that diverge from the
orchestrator-supplied tool-use IDs (breaking bus/replay/orchestrator
correlation), and the `mcp-clipboard` helper is configured `LSBackgroundOnly`
which has historically blocked pasteboard access on macOS Sonoma+ — needs an
empirical check against macOS 26.

## Critical Issues (BLOCKER)

### CR-01: `MCPServerHandle.start()` leaks 3 parent-side pipe FDs on every initialize-failure path

**File:** `packages/MCP/Sources/MCP/MCPServerHandle.swift:152-164`
**Severity:** BLOCKER
**Category:** Resource leak / security

**Issue:**
After `try process.run()` succeeds, the code creates three Pipes and retains
their parent ends. If `client.connect(transport:)` throws (line 153) or the
helper fails to advertise the `tools` capability (line 160), the handler runs:

```swift
try? terminateProcessImmediately(process)   // SIGKILLs child
throw JarvisMCPError.spawnFailed(...)       // OR helperMissingToolsCapability
```

`terminateProcessImmediately` only does `kill(pid, SIGKILL)` — it does NOT close
`stdinPipe.fileHandleForWriting`, `stdoutPipe.fileHandleForReading`, or
`stderrPipe.fileHandleForReading`. The Pipe objects go out of scope when the
function returns, but Foundation's `Pipe` does not close FDs in `deinit` when
the underlying `FileHandle` was created with `closeOnDealloc: false` (which is
the framework default for `Pipe()`). On a path that registers many helpers and
some fail, this leaks 3 FDs per failure.

The 100-cycle FD-leak test in `MCPRestartTests` does NOT cover this path —
every failure case in the test corpus uses a successful initial spawn. A
poisoned helper that crashes during `initialize` will trip the
`ChildSpawnGate.shared.prepare()` Debug `fatalError` on the NEXT spawn cycle
because the leaked FDs aren't `O_CLOEXEC`. (The CLOEXEC retrofit at lines
124–126 runs AFTER `client.connect(transport:)` succeeds.)

**Fix:**
Close the parent-retained Pipe ends in both error branches before throwing.
Factor a small `cleanupPipes()` helper and call it from both error paths.

```swift
do {
    initResult = try await client.connect(transport: transport)
} catch {
    try? terminateProcessImmediately(process)
    closeParentPipeEnds(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    throw JarvisMCPError.spawnFailed(name: name, underlying: String(describing: error))
}
guard initResult.capabilities.tools != nil else {
    try? terminateProcessImmediately(process)
    await client.disconnect()
    closeParentPipeEnds(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    throw JarvisMCPError.helperMissingToolsCapability(name: name)
}

private func closeParentPipeEnds(stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe) {
    try? stdinPipe.fileHandleForWriting.close()
    try? stdoutPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForReading.close()
    stderrPipe.fileHandleForReading.readabilityHandler = nil
}
```

Add a regression test: register a helper whose mock crashes mid-initialize,
loop 100 times, assert FD delta ≤ 16.

---

### CR-02: SEC-07 replay observer does NOT write to the orch→replay channel — ME-04 "closure" is two disconnected halves

**Files:**
- `App/MCP/ReplayingToolResultObserver.swift:75-82`
- `App/AppDelegate.swift:236-250`
- `.planning/phases/05-mcp/05-05-SUMMARY.md` (claims ME-04 closure complete)

**Severity:** BLOCKER
**Category:** Correctness / phase claim integrity

**Issue:**
The summary asserts `ME-04` is closed because `AppDelegate` instantiates a
`BoundedAsyncChannel<ReplayEvent>(capacity: 2048, policy: .dropOldest)` and a
drain Task. But:

1. `AppDelegate.applicationWillFinishLaunching` creates the channel + drain Task
   that simply throws away every event:
   ```swift
   orchToReplayDrainTask = Task.detached { [weak self] in
       for await _ in channel {
           _ = self  // silence unused-capture; future plan wires the real consumer.
       }
   }
   ```
2. The `ReplayingToolResultObserver.record(...)` does NOT send to the channel —
   it calls `replayLog.record(...)` directly:
   ```swift
   await replayLog.record(.toolResultFull(toolUseId: toolUseId, bytes: sanitizedBytes), for: turnId)
   await replayLog.record(.toolResultFull(toolUseId: "\(toolUseId):raw", bytes: rawBytes), for: turnId)
   ```
3. There is NO producer wired to `orchToReplayChannel`. The channel exists but
   carries zero traffic. The drain Task awaits forever on an empty queue.
4. `MCPRuntimeWiring.build(...)` is never called from `AppDelegate` — only
   referenced in a doc comment (line 121). The dispatcher chain has no
   instantiation in production.

So the AGENT-10 4th-seam contract (`orch→replay` 2048-cap `.dropOldest` channel
delivering ReplayEvents) is not actually proven by this code. The observer
bypasses the channel; the channel has no producer; AGENT-10 is unverified at
the production wiring layer.

**Fix:**
Either (a) honestly downgrade the claim from "ME-04 closed" to "ME-04 channel
primitive instantiated; producer-side wiring deferred", or (b) make the
observer the actual producer:

```swift
public func record(toolUseId: String, toolName: String, rawBytes: Data, sanitizedBytes: Data) async {
    guard let turnId = await turnIDResolver() else { return }
    await replayChannel?.send(.toolResultFull(toolUseId: toolUseId, bytes: sanitizedBytes))
    await replayChannel?.send(.toolResultFull(toolUseId: "\(toolUseId):raw", bytes: rawBytes))
}
```

…and have the drain Task actually call `replayLog.record(...)` per drained event.
Either choice is acceptable, but the current state advertises closure that
doesn't exist.

---

### CR-03: `ConfirmingToolDispatcher` synthesizes a fresh UUID when the tool-use id is not UUID-formatted, breaking correlation across bus/replay/orchestrator

**File:** `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:109`
**Severity:** BLOCKER
**Category:** Correctness / observability

**Issue:**
```swift
let toolUseUUID = UUID(uuidString: toolUse.id) ?? UUID()
```

Anthropic tool-use IDs are NEVER UUIDs — they are formatted like
`toolu_01ABCD…` (24+ alnum characters with prefix). Ollama IDs are similarly
free-form. Both will fail `UUID(uuidString:)` and produce a fresh, unrelated
UUID for every dispatch. Consequences:

- Bus emissions (`emitToolCallStart`, `updateArgsPreview`, `emitToolCallEnd`)
  use this fresh UUID as `toolUseId`.
- The broker pending-id uses this fresh UUID.
- The inner `MCPToolDispatcher` is passed `toolUse` verbatim (with the
  ORIGINAL string `toolUse.id`), which the observer records into ReplayLog
  as the correlation key.
- The HUD's `ToolCallCard` correlates `toolCallStart` and `toolCallEnd` events
  by id; with two random UUIDs per call, end events still align with their
  paired starts because both are emitted with `toolUseUUID`. So intra-bus
  correlation works.
- BUT the bus `toolUseId` and the replay-log `toolUseId` are now different
  values, breaking SEC-07 audit-trail-vs-bus correlation. Replay viewers
  cannot find the bus events for a given replay row.
- The orchestrator's tool-use record (in the LLM-history `tool_result` block)
  uses the original Anthropic/Ollama id. Bus events use the fresh UUID. The
  orchestrator cannot tell which `toolCallEnd` event corresponds to which
  tool-use it submitted.

**Fix:**
Don't synthesize. Either change `BusGateway.emitToolCallStart` to take
`toolUseId: String` (the original id), or compute a deterministic UUID by
hashing the original id. Production option:

```swift
// Either (preferred): change the bus surface to String ids
func emitToolCallStart(toolUseId: String, name: String, argsPreview: String) async

// Or: deterministic UUID from string id
let toolUseUUID = UUID(deterministicHashOf: toolUse.id)
```

The broker can keep using UUID internally; the dispatcher passes the same
deterministic UUID into both the bus and the broker. But the BUS event's
`toolUseId` should match what downstream consumers (orchestrator, ReplayLog)
already use as the correlation key.

Add a regression test: inject `toolUse.id = "toolu_01ABC"`, observe that the
bus `toolUseId` is derivable from `"toolu_01ABC"` and identical across
toolCallStart, argsPreviewUpdate, and toolCallEnd.

---

### CR-04: `mcp-clipboard` ships with `LSBackgroundOnly: true` — pasteboard access is silently denied to background-only daemons on macOS 26

**Files:**
- `mcp-servers/mcp-clipboard/Support/Info.plist:19-20`
- `mcp-servers/mcp-clipboard/Sources/mcp-clipboard/MCPClipboardMain.swift:27-32`

**Severity:** BLOCKER (gates MCP-03 acceptance at runtime)
**Category:** Permissions / functional regression

**Issue:**
The helper Info.plist sets `LSBackgroundOnly: true`. macOS Sonoma+ (and Tahoe,
the current host) treats LSBackgroundOnly daemons as non-foreground and has
historically denied or stripped `NSPasteboard.general` access for such
processes (see Apple feedback FB13402281 / radar lineage). The integration
test `test_get_clipboard_runs_and_returns_one_content_item` in
`MCPClipboardIntegrationTests.swift` accepts the empty/refusal path as valid,
so it cannot detect the silent-failure case.

The helper also has no `NSPasteboardAccessUsageDescription` Info.plist key.
Even if pasteboard access works empirically today, Apple has been tightening
TCC around clipboard reads (macOS 14.4+ now requires user consent for some
processes).

The 05-02 SUMMARY `Verification` table reports "PasteboardReader 6/6 pass" but
those are unit tests against `MockPasteboard`. The integration test does not
verify a non-empty clipboard string round-trips.

**Fix:**
1. Drop `LSBackgroundOnly` (keep `LSUIElement: true` — that suffices for a
   no-dock helper while still permitting pasteboard access).
2. Add a real round-trip integration test: write a known string to
   `NSPasteboard.general` from the test process, register the helper, call
   `get_clipboard`, assert the returned text equals the seeded string.
3. Document any TCC prompts that surface; if the helper now needs Privacy &
   Security → Accessibility or similar, capture in a HUMAN-UAT doc.

---

## Warnings (WARNING)

### WR-01: `check-no-modal-presentation.sh` regex matches inside string literals and block comments

**File:** `scripts/check-no-modal-presentation.sh:41,62`
**Severity:** WARNING
**Category:** Lint correctness

**Issue:**
The pre-grep filter `grep -vE '^[[:space:]]*//'` strips only LEADING `//`
comment lines. It does NOT strip:

- Trailing `//` comments on a line of code: `let x = 1 // NSApp.run example` →
  not stripped → grep flags it.
- Block comments `/* ... NSApp.run() ... */` → not stripped.
- String literals: `let docs = "Use NSApp.run() to start the app loop"` →
  not stripped, the entire line is forwarded to grep, which matches.

I verified the false-positive empirically: the line
`let docs = "Use NSApp.run() to start the app loop"` survives the comment
strip and matches the pattern. Today the codebase happens not to contain such
lines, so the lint is green. Adding any documentation that uses
`NSApp.run` in a string (e.g., a deprecation message, an error description)
will fail the build with no fix path other than the allowlist.

**Fix:**
- Document the limitation explicitly in the script header, OR
- Use a stricter parser (e.g., consume the file via a small Swift parser, or
  use SwiftFormat / SwiftLint with a custom rule), OR
- Detect the pattern only at "looks like a function-call site" (e.g.,
  `\.runModal\s*\(` rather than just `runModal\b`), reducing false-positive
  exposure.

The minimum acceptable fix is the second: tighten the patterns to require an
opening parenthesis or method-call dot prefix:

```sh
PATTERN='\.runModal\s*\(|beginModalSession\s*\(|NSApp\.run\s*\(|NSApplication\.shared\.run\s*\('
```

Today the broader pattern catches identifiers, doc-comment mentions, and
string literals.

---

### WR-02: `ConfirmationBroker` weak-presenter cycle plus weak `broker` capture in presenter — both can deinit during pending request

**Files:**
- `packages/MCP/Sources/MCP/ConfirmationPresenter.swift:33`
- `App/MCP/MCPRuntimeWiring.swift:111-113,173-174`

**Severity:** WARNING
**Category:** Lifecycle / correctness

**Issue:**
`ConfirmationPresenter.broker` is `weak`. The Approve/Deny button handlers
guard `[weak self]` and then `self?.broker`:

```swift
onApprove: { [weak self] in
    guard let broker = self?.broker else { return }
    Task { await broker.response(id: id, outcome: .approve) }
}
```

If the `ConfirmationBroker` deinits between the panel being shown and the user
pressing Approve, the broker `nil`s out and the button silently does nothing.
The user sees "Approve" succeed (panel closes) but the orchestrator hangs on
the awaiter until the 60s timeout fires. There is no log line, no UI feedback.

The cycle-breaking `ConfirmationPresenterHolder.inner` is also `weak`. If the
presenter deinits (held only by `MCPRuntime`), the holder's `show` becomes a
silent no-op, the broker's `Task { await presenter.show(...) }` does nothing,
and the user never sees a panel — they wait for the 60s timeout.

`MCPRuntime` holds strong refs to broker + presenter so as long as the
runtime stays alive both stay alive. But the runtime's lifetime is tied to
AppDelegate retention (`mcpRuntime` field, which doesn't exist yet because
`MCPRuntimeWiring.build` isn't called). Today the structure is moot, but as
soon as wiring lands, the strong/weak balance needs an audit.

**Fix:**
- Document the lifecycle invariant on `MCPRuntime` ("must be held strongly by
  AppDelegate for the lifetime of the process; orchestrator must not outlive
  the runtime").
- Consider holding `broker` strongly inside the presenter (the broker is a
  Sendable actor, no cycle danger) AND keeping the holder reference strong.
  The cycle that motivates `weak` is broker → presenter → broker, but the
  holder layer already broke that — the broker only knows about
  `ConfirmationPresenterHolder`, which can hold the presenter strongly with
  no cycle.

---

### WR-03: `ConfirmationBroker` timer task will fire `.timeout` after `.deny` at sub-second timeouts — passes today only because of wall-clock luck

**File:** `packages/MCP/Sources/MCP/ConfirmationBroker.swift:79-83,113`
**Severity:** WARNING
**Category:** Race / correctness

**Issue:**
On `response(id:outcome:)`, the broker cancels the timer task:
```swift
req.timeoutTask?.cancel()
```
But the timer task body is:
```swift
try? await Task.sleep(for: .seconds(timeout))
if Task.isCancelled { return }
await self?.response(id: id, outcome: .timeout)
```

`Task.sleep` returns from cancellation with `try?` swallowing the
`CancellationError`. Then `if Task.isCancelled` checks but — between
`Task.sleep` returning and `Task.isCancelled` being read — there is a window
where `cancel()` has not yet propagated. With sub-second timeouts (the test
uses 0.05s; production uses 60s), a race is possible where the timer body
already passed the `Task.isCancelled` check before the cancellation call
arrives, and the late `.timeout` lands. The first-write-wins guard in
`response` saves us — `req.resolved == false` is the second-line defense —
but if a future contributor removes that guard or inverts the order, the
broker double-resolves.

In the test corpus, `test_lateResponse_afterApprove_isNoOp` actually depends
on the first-write-wins guard, not on cancellation. The cancellation is
defensive but not load-bearing.

**Fix:**
The current code is correct because of the resolved guard, but make the
intent clear:

```swift
let timerTask = Task { [weak self] in
    do {
        try await Task.sleep(for: .seconds(timeout))
    } catch {
        return  // canceled — no-op
    }
    await self?.response(id: id, outcome: .timeout)
}
```

The `try?` + `Task.isCancelled` check is double-coverage that obscures intent.
Also: `try? Task.sleep` swallows ALL errors, not just cancellation. Today
`Task.sleep(for:)` only throws `CancellationError`, but it's still a code
smell.

---

### WR-04: `ConfirmingToolDispatcher` does not emit `toolCallEnd` on the success path — bus consumers cannot tell a tool call completed

**File:** `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift:128-136`
**Severity:** WARNING
**Category:** Bus protocol completeness

**Issue:**
On `.approve`, the dispatcher:
1. emits `updateArgsPreview` with sanitized args, then
2. calls `inner.dispatch(toolUse:)`, then
3. returns the bytes.

It does NOT emit `emitToolCallEnd(ok: true, ...)`. The dispatcher's
`BusGateway` has the `emitToolCallEnd` hook, but it's only invoked on
`.deny`, `.timeout`, `.barge`. So bus consumers (HUD, DevOverlay) see a
tool-call start, an args update, and then…nothing. The tool-call-end signal
must come from somewhere else — presumably the orchestrator — but that's
unwired (CR-02) and the contract isn't documented.

Compare to Plan 04-04's orchestrator behavior: orchestrator emits
`toolCardUpdate` events (running → completed). The bus consumer side
(WR-09) actually handles its own toolCallEnd from the orchestrator's tool
result, separate from the dispatcher's bus events. Worth documenting.

**Fix:**
Either emit `toolCallEnd(ok: true, previewOrError: <result preview>)` after
inner.dispatch returns, OR add an explicit doc comment explaining that
`toolCallEnd` is the orchestrator's emission for the success path and this
dispatcher only emits failure ends. The current state where the bus surface
has a method that's only fired on failures is asymmetric and surprising.

---

### WR-05: Anthropic Pasteboard read is not @MainActor — silent failure on macOS Sequoia+ with the new pasteboard threading rules

**File:** `mcp-servers/mcp-clipboard/Sources/mcp-clipboard/MCPClipboardMain.swift:26-32`
**Severity:** WARNING
**Category:** Threading / platform behavior

**Issue:**
`SystemPasteboard` is `@unchecked Sendable` and reads `NSPasteboard.general`
from the SDK's CallTool handler executor (no @MainActor isolation). macOS
Sequoia/Sonoma have been progressively requiring main-thread access for
NSPasteboard reads in some configurations; doing it from a background queue
can return stale or empty data with no error. There is no observable test
that exercises a non-empty pasteboard round-trip from the helper subprocess
context.

This compounds with CR-04 (LSBackgroundOnly).

**Fix:**
Hop the pasteboard read onto MainActor explicitly, or add a real round-trip
integration test that proves background-thread pasteboard reads work under
this configuration. If they don't, route through `DispatchQueue.main.sync` or
`MainActor.run`.

---

### WR-06: `MCPClient.callTool` arguments parameter is non-optional — diverges from SDK signature

**File:** `packages/MCP/Sources/MCP/MCPClient.swift:97`
**Severity:** WARNING
**Category:** API surface

**Issue:**
```swift
public func callTool(name: String, arguments: [String: Value]) async throws -> CallTool.Result
```

The SDK's `Client.callTool(name:arguments:)` accepts `[String: Value]?` (note
the optional). Tools registered with `inputSchema.required = []` (like
`get_time` and `get_clipboard`) accept `null` arguments per the JSON-RPC
spec. Forcing callers to pass `[:]` is a small impedance — but the bigger
issue is `MCPToolDispatcher.decodeArguments` returns `[:]` for empty/missing
input, which goes onto the wire as `arguments: {}`. Some MCP servers
distinguish between `arguments: null` (no args provided) and `arguments: {}`
(empty arg dict). The current helpers happen not to care, but a future
helper might.

**Fix:**
Either match the SDK signature (`arguments: [String: Value]? = nil`) or
document the intentional flattening of null → `{}` in `decodeArguments`. The
SDK signature is preferable because it preserves protocol-level fidelity.

---

### WR-07: Helpers ship with `CODE_SIGNING_ALLOWED: NO` even on Release — relies entirely on `codesign.sh` running on parent

**File:** `project.yml:367-370,407-410,464-467`
**Severity:** WARNING
**Category:** Build / signing

**Issue:**
All three helper targets set `CODE_SIGNING_ALLOWED: NO` and
`CODE_SIGNING_REQUIRED: NO` in BOTH Debug and Release configs:

```yaml
configs:
  Debug:
    CODE_SIGNING_ALLOWED: NO
    CODE_SIGNING_REQUIRED: NO
    ENABLE_HARDENED_RUNTIME: NO
  Release:
    DEVELOPMENT_TEAM: 7UC2HETAN9
    CODE_SIGNING_ALLOWED: NO
    CODE_SIGNING_REQUIRED: NO
```

The Release config has a DEVELOPMENT_TEAM but signing disabled, so the helper
ships unsigned out of `xcodebuild` and is signed only via `codesign.sh` from
the parent target's postBuildScript (deepest-first walker). The deepest-first
walker re-signs every helper in `Contents/Helpers/*.app` — fine in principle,
but:

1. If a developer runs `xcodebuild -target mcp-applescript` standalone (e.g.,
   for incremental builds), the resulting binary is unsigned and won't load
   under hardened runtime in Release.
2. The Release config's `ENABLE_HARDENED_RUNTIME: YES` (inherited from base)
   is incompatible with `CODE_SIGNING_ALLOWED: NO` — hardened runtime
   requires signing. This will produce confusing build-time warnings on
   Release.
3. There is no explicit gate that fails the build if `codesign.sh` was NOT
   run; if a developer disables postBuildScripts (or the parent target build
   is canceled mid-flight), the bundle ships with unsigned helpers.

**Fix:**
Either enable signing on the helper targets (Release: signing identity
`-` ad-hoc for Debug, full identity for Release) OR add a verification step
in `verify-codesign-settings.sh` that asserts every helper bundle is signed.
The verifier today checks pbxproj for `--deep` absence; extend it to assert
each helper has a `_CodeSignature/` directory.

---

## Info

### IN-01: `ChildSpawnGate.prepare()` Debug fatalError makes test harness fragile across packages

**File:** `packages/MCP/Sources/MCP/ChildSpawnGate.swift:46-47`
**Severity:** INFO
**Category:** Testability

**Issue:**
The Debug `fatalError` is intentionally aggressive (the contract is "every
long-lived FD must be CLOEXEC at open time"). But this means a single
unrelated test in any package that opens an FD without CLOEXEC and leaves it
open across a test boundary will crash subsequent JarvisMCP tests. The
in-suite `MCPRestartTests` is sensitive enough that the SUMMARY documents the
discovery (Plan 05-01 Deviation D4).

The crash is the right behavior in the long run, but the diagnostic could be
better. Today it logs the FD number; that's not enough to identify origin.
Capturing `fcntl(fd, F_GETPATH, ...)` to print the FD's filesystem path on
the fatalError would dramatically reduce debugging time when this fires.

**Fix:**
Before fatalErroring, attempt `F_GETPATH` and include the path:

```swift
var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
let pathStr = fcntl(fd, F_GETPATH, &pathBuf) >= 0
    ? String(cString: pathBuf)
    : "<unknown>"
fatalError("FD \(fd) (path: \(pathStr)) is not FD_CLOEXEC; …")
```

---

### IN-02: `ConfirmationPresenter` panel cleanup is silent on dismiss-of-unknown-id

**File:** `packages/MCP/Sources/MCP/ConfirmationPresenter.swift:113-121`
**Severity:** INFO
**Category:** Diagnostics

**Issue:**
```swift
private func _dismiss(id: UUID) {
    guard let panel = panels[id] else { return }
    ...
}
```

If `dismiss(id:)` is called for an id the presenter never showed (broker bug,
duplicate dismiss, etc.), the call silently no-ops. This is the right
production behavior, but the absence of a log makes debugging hard. Add a
debug-level log line so tests/replay can detect the case.

**Fix:**
```swift
guard let panel = panels[id] else {
    Logger(label: JarvisLogChannel.mcp.rawValue).debug("dismiss(id: \(id)) for unknown panel id")
    return
}
```

---

### IN-03: `mcp-applescript` scaffold-time probe writes to stderr unconditionally — pollutes ReplayLog with timeout error on every cold start

**File:** `mcp-servers/mcp-applescript/Sources/mcp-applescript/MCPAppleScriptMain.swift:36-42`
**Severity:** INFO
**Category:** Operational hygiene

**Issue:**
Every helper spawn runs:
```swift
let probeOutcome = runner.run(source: "tell application \"System Events\" to get the name of every process")
FileHandle.standardError.write(Data("mcp-applescript probe outcome: \(probeOutcome)\n".utf8))
```

When TCC isn't granted (which is the common case before user approves), the
probe times out at ~30 seconds (per the SUMMARY). That's a 30-second startup
delay on every cold start of the helper. Worse: the parent `MCPClient.start()`
has no startup timeout (despite `JarvisMCPError.startupTimeout` existing in
the error enum), so the SDK's `client.connect(transport:)` will pump the
initialize handshake handshake-traffic through the same stdio that the probe
is blocked on, possibly delaying it.

This is a design choice (research OQ#3 verification), but it has real
operational impact and should be flagged behind a feature flag or removed
once OQ#3 is empirically resolved.

**Fix:**
Gate the probe behind an env var (`JARVIS_MCP_APPLESCRIPT_PROBE=1`) so it's
opt-in for diagnostics. Alternatively, remove the probe entirely in favor of
the live first-call path that Plan 05-05 already exercises.

---

### IN-04: `MCPClient` has no startup timeout — helpers can hang the registration call indefinitely

**File:** `packages/MCP/Sources/MCP/MCPClient.swift:71` and `MCPServerHandle.swift:79-153`
**Severity:** INFO
**Category:** Robustness

**Issue:**
`JarvisMCPError.startupTimeout(name:seconds:)` is defined but never thrown
anywhere. `MCPServerHandle.start()` does `try await client.connect(transport:)`
without a `withTimeout(...)` wrapper. A wedged helper (e.g., an
`mcp-applescript` whose probe hangs because TCC is denied — see IN-03) blocks
the registration call until SIGKILL.

The 05-RESEARCH document mentions a "30s startupTimeout" expectation but the
implementation doesn't enforce it.

**Fix:**
Wrap the `connect` call in a TaskGroup with a timeout race:

```swift
let initResult = try await withThrowingTaskGroup(of: Initialize.Result.self) { group in
    group.addTask {
        try await client.connect(transport: transport)
    }
    group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw JarvisMCPError.startupTimeout(name: name, seconds: 30)
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
}
```

Add a regression test that registers a helper-fixture which sleeps forever in
its initialize handler; assert `JarvisMCPError.startupTimeout` after 30s
(with a sub-second injection knob like the broker uses for AGENT-11).

---

## By-File Annotations

| File | Findings |
|------|----------|
| `packages/MCP/Sources/MCP/MCPServerHandle.swift` | CR-01 (FD leak) |
| `packages/MCP/Sources/MCP/MCPClient.swift` | WR-06, IN-04 |
| `packages/MCP/Sources/MCP/ChildSpawnGate.swift` | IN-01 |
| `packages/MCP/Sources/MCP/SanitizeForModel.swift` | clean — order test is real, scalar ranges correct |
| `packages/MCP/Sources/MCP/MCPToolDispatcher.swift` | clean — no wrap, observer fires on success only |
| `packages/MCP/Sources/MCP/ToolRegistry.swift` | clean — value-type snapshot is sound |
| `packages/MCP/Sources/MCP/ConfirmationBroker.swift` | WR-03 |
| `packages/MCP/Sources/MCP/ConfirmationPresenter.swift` | WR-02, IN-02 |
| `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift` | CR-03, WR-04 |
| `packages/MCP/Sources/MCP/ConfirmationOutcome.swift` | clean |
| `packages/MCP/Sources/MCP/MCPError.swift` | clean |
| `packages/MCP/Sources/MCP/MCPLogChannel.swift` | clean |
| `packages/MCP/Package.swift` | clean — asymmetric MCP→AgentCore dep is intentional |
| `App/MCP/MCPRuntimeWiring.swift` | CR-02 (build never called) |
| `App/MCP/ReplayingToolResultObserver.swift` | CR-02 (channel not wired) |
| `App/AppDelegate.swift` | CR-02 (drain Task drains nothing) |
| `mcp-servers/mcp-time/**` | clean (helper is minimal) |
| `mcp-servers/mcp-clipboard/**` | CR-04, WR-05 |
| `mcp-servers/mcp-applescript/**` | IN-03 |
| `scripts/check-no-modal-presentation.sh` | WR-01 |
| `scripts/verify-entitlements.sh` | clean — bidirectional rules + fail-closed on unknown helper |
| `scripts/codesign.sh` | clean — deepest-first walker, no `--deep` |
| `scripts/test-verify-entitlements.sh` | clean |
| `project.yml` | WR-07 |
| `packages/Logging/Sources/JarvisLogging/JarvisLogChannel.swift` | clean — additive `.mcp` case, tests updated |
| `packages/{Bus,Replay,AgentCore}/Package.swift` | clean — explicit swift-log dep added per linker requirement |
| `App/Tests/AppTests/MCPRuntimeWiringTests.swift` | structural-only by design (Xcode 26 xctest blocked); clean |
| Tests across MCP package | mostly clean; broker tests + dispatcher tests are thorough; restart tests have honest "either error or success" tolerance |

## Recommended Next Steps

**Verdict:** `issues_found` — Phase 5 should NOT advance to verify until at
least the four BLOCKERs are addressed. The CR-02 wiring gap and CR-03
correlation drift in particular invalidate downstream Phase 6/7 plans that
will assume MCP runtime works end-to-end.

**Required for fix-pass:**
- CR-01 (FD leak on initialize-failure path)
- CR-02 (either downgrade ME-04 claim to "primitive instantiated" OR wire the
  observer to the channel and make the drain Task the actual ReplayLog
  consumer)
- CR-03 (toolUseId UUID drift)
- CR-04 (LSBackgroundOnly + integration test)

**Recommended for fix-pass:**
- WR-01 (lint regex tightening)
- WR-04 (toolCallEnd success-path documentation or emission)
- WR-07 (helper signing strategy)

**Out of fix-pass scope (but document):**
- WR-02, WR-03, WR-05, WR-06 — useful but lower-impact; can ship to next phase
- IN-01..IN-04 — diagnostics improvements

**Routing:** Recommend `/gsd-code-review-fix 5` BEFORE `/gsd-verify-phase 5`.
The four BLOCKERs are correctness gaps that the verify pass should not be
asked to rationalize.

---

_Reviewed: 2026-04-25_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
