---
phase: 05-mcp
plan: 05
type: execute
wave: 5
depends_on: [05-01, 05-02, 05-03, 05-04]
files_modified:
  - packages/MCP/Sources/MCP/ConfirmationBroker.swift
  - packages/MCP/Sources/MCP/ConfirmationOutcome.swift
  - packages/MCP/Sources/MCP/ConfirmationPresenter.swift
  - packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift
  - packages/MCP/Tests/MCPTests/ConfirmationBrokerTests.swift
  - packages/MCP/Tests/MCPTests/ConfirmingToolDispatcherTests.swift
  - App/AppDelegate.swift
  - App/MCP/MCPRuntimeWiring.swift
  - App/MCP/ReplayingToolResultObserver.swift
  - scripts/check-no-modal-presentation.sh
  - scripts/test-fixtures/forbidden-modal-call.swift
  - scripts/test-fixtures/allowed-non-modal-call.swift
  - project.yml
autonomous: true
requirements: [MCP-04, MCP-09, AGENT-11]
tags: [confirmation-broker, fsm, applescript-gating, nspanel-sheet, agent-11-timeout, modal-lint, args-masking, app-wiring]
assumptions:
  - The bus protocol is FROZEN per Phase 2. The argsPreview field on `BusOutbound.toolCallStart(id:name:argsPreview:)` is a `String`. We serialize the JSON `{"awaitingApproval":true}` into that String for confirmation-required tools BEFORE approval and the real args (or a sanitized preview) AFTER approval. This matches HUD-07's defense-in-depth (Plan 03-04 already hides args when argsPreview parses to that shape OR status === 'awaiting-approval').
  - The ConfirmationPresenter uses pure AppKit (NSPanel + `beginSheet(_:completionHandler:)`), NOT SwiftUI sheets, NOT a webview modal. RESEARCH §Recommendation 4 + Pattern 5 + AUDIT-R4-Sec4 enforce this. The lint rule extends `@MainActor` presentation paths module-wide.
  - The orchestrator (Plan 04-04) currently calls `toolDispatcher.dispatch(toolUse:)` UNCONDITIONALLY; the confirmation gate must wrap dispatch from OUTSIDE the orchestrator (i.e., the conforming `ConfirmingToolDispatcher` calls broker.request, then on .approve calls into the inner MCPToolDispatcher). This way Phase 4's orchestrator code is unchanged.
  - The `ConfirmationID` stub from `packages/AgentCore/Sources/AgentOrchestrator/TurnState.swift` carries semantic content here: this plan uses the broker's pending-request UUID as the ConfirmationID rawValue, so `TurnState.awaitingConfirmation(id)` correlates with the broker's pending entry.
  - The 60s timeout in the broker (AGENT-11) is implemented via `Task.sleep(for: .seconds(60))`. RESEARCH Pattern 5 confirms this; we add a deterministic injection knob (`@MainActor var _testTimeoutSeconds: TimeInterval?` defaulting nil) so unit tests can pass `0.05` and assert real timeout behavior without 60-second test runs.
  - Replay capture of pre- and post-sanitize bytes (the `ToolResultObserver` from Plan 05-04) is wired in this plan via `ReplayingToolResultObserver` in App/MCP/. This closes the SEC-07 acceptance "Replay captures both pre- and post-sanitize bytes."
  - This is the wave-4 plan that wires everything end-to-end. It TOUCHES App/** files (AppDelegate.swift to instantiate the runtime wiring + a new App/MCP/ subdirectory). Phase 4 plan 04-05's deferred ME-04 line ("orch→replay 2048-cap channel wired in code but not yet instantiated in production") closes here when the app instantiates the real ToolDispatcher and replay observer.
  - Anti-pattern callouts: DO NOT use `runModal`, `beginModalSession`, `NSApplication.run` anywhere on a `@MainActor` presentation path (lint enforces module-wide). DO NOT use SwiftUI `.sheet` for confirmation (it bottoms out in modal session). DO NOT serialize raw args to webview before approval (the argsPreview JSON is `{"awaitingApproval":true}` until broker resolves with .approve). DO NOT make `late-hop` transitions resolve more than once (FSM enforces first-write-wins). DO NOT use webview modal for confirmation under ANY circumstance.
must_haves:
  truths:
    - "`ConfirmationBroker.request(id:toolName:argsPreview:)` returns one of {.approve, .deny, .timeout, .barge}; first call to `.response(id:outcome:)` wins, subsequent calls (late hops) are silent no-ops (MCP-09)."
    - "A 60-second timeout on `broker.request(...)` synthesizes `.timeout` and resumes the awaiter exactly once (AGENT-11). Unit tests inject a sub-second timeout for deterministic assertions."
    - "`ConfirmationPresenter` shows an AppKit sheet on a hidden `NSPanel` (.nonactivatingPanel + .floating) via `beginSheet(_:completionHandler:)` — NEVER `runModal`, NEVER a webview message; the lint rule rejects modal calls on any @MainActor file (MCP-04)."
    - "`ConfirmingToolDispatcher` wraps `MCPToolDispatcher`: when the inner dispatcher's `requiresConfirmation(toolName:)` is true, it calls `broker.request(...)` first; on `.approve` proceeds with `dispatch(toolUse:)`; on .deny/.timeout/.barge throws a typed `ConfirmationError` so the orchestrator surfaces an isError tool-result (the orchestrator already handles thrown errors by translating to `.toolCardUpdate(.failed)` — Plan 04-04)."
    - "The bus argsPreview for confirmation-required tools is `{\"awaitingApproval\":true}` BEFORE approval and a sanitized preview of args AFTER approval. The HUD's existing args-hiding rule (Plan 03-04 HUD-07 defense-in-depth) renders the awaiting-approval state without leaking raw args."
    - "`scripts/check-no-modal-presentation.sh` runs as a preBuildScript and fails the build on any occurrence of `runModal\\b\\|beginModalSession\\b\\|NSApplication\\.shared\\.run\\b\\|NSApp\\.run\\b` outside explicitly-allowed comment blocks across `App/**` AND `packages/**/Sources/**`."
    - "`AppDelegate` instantiates: `MCPClient` → registers 3 helpers (mcp-time, mcp-clipboard, mcp-applescript) → wraps via `MCPToolDispatcher` → wraps via `ConfirmingToolDispatcher` → injects into `AgentOrchestrator`. The orchestrator's `ToolDispatcher` is now the confirmation-gated MCP-backed dispatcher in production."
    - "`ReplayingToolResultObserver` records both pre- and post-sanitize bytes via `ReplayLog.record(.toolResultFull(...))` for every dispatch; SEC-07 acceptance 'replay captures both pre- and post-sanitize bytes' holds."
  artifacts:
    - path: "packages/MCP/Sources/MCP/ConfirmationBroker.swift"
      provides: "Public actor with FSM (.approve/.deny/.timeout/.barge); first-write-wins; injectable timeout for testing."
      min_lines: 80
    - path: "packages/MCP/Sources/MCP/ConfirmationPresenter.swift"
      provides: "@MainActor final class wrapping a hidden NSPanel; shows confirmation sheet via beginSheet; no runModal/beginModalSession/NSApp.run."
      min_lines: 60
    - path: "packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift"
      provides: "Public actor conforming to ToolDispatcher; wraps an inner ToolDispatcher with broker gating; handles deny/timeout/barge → throw."
      min_lines: 50
    - path: "App/MCP/MCPRuntimeWiring.swift"
      provides: "@MainActor builder that instantiates MCPClient, registers helpers, builds ToolDispatcher chain, returns the dispatcher + presenter for AppDelegate to inject."
      min_lines: 50
    - path: "App/MCP/ReplayingToolResultObserver.swift"
      provides: "Concrete ToolResultObserver that records pre- and post-sanitize bytes to ReplayLog."
      min_lines: 25
    - path: "scripts/check-no-modal-presentation.sh"
      provides: "Pre-build lint rejecting runModal/beginModalSession/NSApp.run across App/** and packages/**/Sources/**."
      min_lines: 30
  key_links:
    - from: "packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift"
      to: "packages/MCP/Sources/MCP/ConfirmationBroker.swift"
      via: "When inner.requiresConfirmation(toolName) is true, call broker.request(...) before dispatch"
      pattern: "broker\\.request"
    - from: "App/AppDelegate.swift"
      to: "App/MCP/MCPRuntimeWiring.swift"
      via: "applicationDidFinishLaunching builds MCPRuntime -> AgentOrchestrator(toolDispatcher:)"
      pattern: "MCPRuntimeWiring|MCPRuntime"
    - from: "packages/MCP/Sources/MCP/ConfirmationPresenter.swift"
      to: "AppKit NSPanel.beginSheet"
      via: "showSheet uses beginSheet(_:completionHandler:); never runModal"
      pattern: "beginSheet\\("
    - from: "scripts/check-no-modal-presentation.sh"
      to: "preBuildScripts in project.yml"
      via: "Wired alongside check-bus-protocol-version.sh and check-no-evaluate-javascript.sh"
      pattern: "check-no-modal-presentation\\.sh"
---

<objective>
Land the runtime gate that turns Phase 5 from "helpers can be invoked via MCPClient" into "the user explicitly approves every AppleScript before it runs, via a native AppKit sheet that cannot be forged by tool output XSS."

Three intertwined pieces:

1. **`ConfirmationBroker` FSM (MCP-09 + AGENT-11):** four legal transitions (.approve / .deny / .timeout / .barge); first call to `.response(...)` wins; later hops no-op silently. 60-second timeout via Task.sleep with a deterministic test injection knob.

2. **`ConfirmationPresenter` (MCP-04):** native AppKit sheet on a hidden `NSPanel` via `beginSheet(_:completionHandler:)`. NEVER runModal, NEVER beginModalSession, NEVER a webview modal. A new module-wide preBuildScript lint enforces this across the entire codebase.

3. **End-to-end app-shell wiring:** `AppDelegate` now instantiates the full chain (MCPClient → register 3 helpers → MCPToolDispatcher → ConfirmingToolDispatcher → AgentOrchestrator). The `argsPreview` JSON `{"awaitingApproval":true}` flows to the webview BEFORE approval, the real args flow AFTER approval. Pre- and post-sanitize bytes are written to ReplayLog via the observer wired here.

This plan does NOT:
- Modify the bus protocol (Phase 2 closed; the `argsPreview` String field is the existing channel).
- Modify `AgentOrchestrator` source (the gating happens by composing `ConfirmingToolDispatcher` around `MCPToolDispatcher`; both conform to the same `ToolDispatcher` protocol from Phase 4).
- Touch the helper bundles from 05-02/05-03 (they don't know about confirmation).

After this plan: a user can type "run an AppleScript that opens Safari" → orchestrator proposes the tool call → ring goes amber (.awaitingConfirmation) → AppKit sheet appears with the script source → user approves → script runs → sanitized result lands in history.
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
@.planning/phases/05-mcp/05-03-helper-applescript-PLAN.md
@.planning/phases/05-mcp/05-04-sanitize-pipeline-tool-dispatcher-PLAN.md
@.planning/phases/04-agent-core/04-04-SUMMARY.md
@.planning/phases/04-agent-core/04-05-SUMMARY.md
@.planning/phases/03-hud/03-04-chat-panel-streaming-PLAN.md
@CLAUDE.md
@packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift
@packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift
@packages/AgentCore/Sources/AgentOrchestrator/TurnState.swift
@packages/Bus/Sources/Bus/BusOutbound.swift
@App/AppDelegate.swift

<interfaces>
<!--
  Existing surfaces (read-only):
-->

```swift
// packages/AgentCore/Sources/AgentOrchestrator/ToolDispatcher.swift  (read-only)
public protocol ToolDispatcher: Sendable {
    func dispatch(toolUse: ToolUseRequest) async throws -> Data
    func requiresConfirmation(toolName: String) -> Bool
}

// packages/AgentCore/Sources/AgentOrchestrator/TurnState.swift  (read-only)
public struct ConfirmationID: Sendable, Hashable, Equatable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String)
}
public enum TurnState: Sendable, Equatable {
    case awaitingConfirmation(ConfirmationID)
    // ... other cases ...
}

// packages/Bus/Sources/Bus/BusOutbound.swift  (read-only)
public enum BusOutbound: ... {
    case toolCallStart(id: UUID, name: String, argsPreview: String)
    // argsPreview is a freeform String; we serialize JSON `{"awaitingApproval":true}` into it pre-approval.
}
```

Public surfaces this plan provides:

```swift
// packages/MCP/Sources/MCP/ConfirmationOutcome.swift
public enum ConfirmationOutcome: Sendable, Equatable {
    case approve
    case deny
    case timeout
    case barge
}

public enum ConfirmationError: Error, Sendable, Equatable {
    case denied
    case timedOut(after: TimeInterval)
    case barged
}

// packages/MCP/Sources/MCP/ConfirmationBroker.swift
public actor ConfirmationBroker {
    /// Default timeout 60s (AGENT-11). Inject sub-second values for tests.
    public init(timeoutSeconds: TimeInterval = 60, presenter: any ConfirmationPresenting)

    /// Called by `ConfirmingToolDispatcher`. Awaits the user's response or timeout.
    public func request(id: UUID, toolName: String, argsPreview: String) async -> ConfirmationOutcome

    /// Called by presenter (.approve/.deny), barge-in path (.barge), or timer (.timeout).
    /// Late hops (after first call) are silent no-ops (MCP-09).
    public func response(id: UUID, outcome: ConfirmationOutcome)
}

// packages/MCP/Sources/MCP/ConfirmationPresenter.swift
public protocol ConfirmationPresenting: Sendable {
    func show(id: UUID, toolName: String, argsPreview: String) async
    func dismiss(id: UUID) async
}

@MainActor
public final class ConfirmationPresenter: ConfirmationPresenting {
    public init(broker: ConfirmationBroker)
    public nonisolated func show(id: UUID, toolName: String, argsPreview: String) async  // hops to MainActor internally
    public nonisolated func dismiss(id: UUID) async
}

// packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift
public actor ConfirmingToolDispatcher: ToolDispatcher {
    public init(
        inner: any ToolDispatcher,
        broker: ConfirmationBroker,
        bus: BusGateway?,                   // optional bus emitter for argsPreview update post-approval
        argsPreviewSanitizer: @Sendable (Data) -> String  // builds the post-approval preview from raw argsJSON
    )
    public func dispatch(toolUse: ToolUseRequest) async throws -> Data
    public nonisolated func requiresConfirmation(toolName: String) -> Bool
}

public protocol BusGateway: Sendable {
    /// Emits a follow-up toolCallStart with the post-approval argsPreview.
    /// Implemented in App/MCP/ wiring on top of the existing Bus package.
    func updateArgsPreview(toolUseId: UUID, name: String, argsPreview: String) async
}
```

App-side (this plan):

```swift
// App/MCP/MCPRuntimeWiring.swift
@MainActor
public struct MCPRuntime {
    public let client: MCPClient
    public let dispatcher: any ToolDispatcher           // = ConfirmingToolDispatcher wrapping MCPToolDispatcher
    public let presenter: ConfirmationPresenter
    public let broker: ConfirmationBroker
}

@MainActor
public enum MCPRuntimeWiring {
    public static func build(
        bundleURL: URL,
        bus: any BusGateway,
        replayLog: ReplayLog
    ) async throws -> MCPRuntime
}

// App/MCP/ReplayingToolResultObserver.swift
public final class ReplayingToolResultObserver: ToolResultObserver {
    public init(replayLog: ReplayLog)
    public func record(toolUseId: String, toolName: String, rawBytes: Data, sanitizedBytes: Data) async
}
```

Bus argsPreview JSON shape (existing — agreed in Plan 03-04):
```json
// PRE-APPROVAL for requiresConfirmation tools:
{"awaitingApproval":true}

// POST-APPROVAL: a sanitized preview of args (e.g., truncated AppleScript source). MUST be valid JSON;
// the HUD checks `argsPreview === '{"awaitingApproval":true}'` (existing rule) and falls through to render the rest.
{"source":"tell application \"Safari\" to activate","_truncated":false}
```
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: ConfirmationOutcome + ConfirmationError + ConfirmationBroker FSM with injectable timeout</name>
  <files>
    packages/MCP/Sources/MCP/ConfirmationOutcome.swift,
    packages/MCP/Sources/MCP/ConfirmationBroker.swift,
    packages/MCP/Tests/MCPTests/ConfirmationBrokerTests.swift
  </files>
  <behavior>
    - Test (RED first): `test_request_returnsApprove_whenResponseApproveCalled` — start a request task, call `broker.response(id, .approve)`, await the request — assert .approve.
    - Test: `test_request_returnsDeny_whenResponseDenyCalled` — symmetric, .deny.
    - Test: `test_request_returnsBarge_whenResponseBargeCalled` — symmetric, .barge.
    - Test: `test_request_returnsTimeout_whenNoResponseInSubSecond` — broker constructed with `timeoutSeconds: 0.05`. Start request; do not call response. Await — assert .timeout. (Uses sub-second injection to avoid 60s test runs.)
    - Test (the headline MCP-09 invariant): `test_lateResponse_afterApprove_isNoOp` — call response(.approve), await request returns .approve. THEN call response(.deny) — assert no crash, no observable side effect (the second response is silently dropped since the FSM is "first write wins").
    - Test: `test_lateResponse_afterTimeout_isNoOp` — broker timeout fires, request returns .timeout. THEN call response(.approve) — no crash, no second resume.
    - Test: `test_concurrentResponses_firstWins` — fire `.approve` and `.deny` from two Tasks racing the actor; assert request returns ONE of them (whichever wins the actor's serial executor); the other is silently no-op.
    - Test: `test_unknownId_response_isSilentNoOp` — call response on an id never requested → no throw, no crash.
    - Test: `test_dismissCalledExactlyOnce_perRequest` — install a counter-presenter; verify `presenter.dismiss(id:)` was called EXACTLY once across the lifecycle (not 0, not 2).
  </behavior>
  <action>
    1. Create `packages/MCP/Sources/MCP/ConfirmationOutcome.swift` per `<interfaces>`.

    2. Create `packages/MCP/Sources/MCP/ConfirmationBroker.swift`:
       ```swift
       import Foundation

       public actor ConfirmationBroker {
           private struct PendingRequest {
               let id: UUID
               let toolName: String
               let argsPreview: String
               var continuation: CheckedContinuation<ConfirmationOutcome, Never>?
               var resolved: Bool = false
               var timeoutTask: Task<Void, Never>?
           }

           private var pending: [UUID: PendingRequest] = [:]
           private let presenter: any ConfirmationPresenting
           private let timeoutSeconds: TimeInterval

           public init(timeoutSeconds: TimeInterval = 60, presenter: any ConfirmationPresenting) {
               self.timeoutSeconds = timeoutSeconds
               self.presenter = presenter
           }

           public func request(id: UUID, toolName: String, argsPreview: String) async -> ConfirmationOutcome {
               return await withCheckedContinuation { continuation in
                   var req = PendingRequest(
                       id: id,
                       toolName: toolName,
                       argsPreview: argsPreview,
                       continuation: continuation,
                       resolved: false,
                       timeoutTask: nil
                   )

                   // Start timeout timer.
                   let timeout = self.timeoutSeconds
                   let timerTask = Task { [weak self] in
                       try? await Task.sleep(for: .seconds(timeout))
                       await self?.response(id: id, outcome: .timeout)
                   }
                   req.timeoutTask = timerTask
                   pending[id] = req

                   // Show presenter.
                   Task { await presenter.show(id: id, toolName: toolName, argsPreview: argsPreview) }
               }
           }

           public func response(id: UUID, outcome: ConfirmationOutcome) {
               guard var req = pending[id] else { return }      // unknown — no-op
               guard req.resolved == false else { return }       // late hop — no-op (MCP-09)
               req.resolved = true
               pending[id] = req

               // Cancel timeout if not already fired.
               req.timeoutTask?.cancel()

               // Resume the awaiter.
               req.continuation?.resume(returning: outcome)

               // Drop the entry; dismiss the presenter.
               pending[id] = nil
               Task { await presenter.dismiss(id: id) }
           }
       }
       ```

    3. Tests as in `<behavior>`. The test fixture's `MockPresenter` conforms to `ConfirmationPresenting` (defined in Task 2 below — execute Task 1 + Task 2 concurrently if needed, or stub `ConfirmationPresenting` here and complete in Task 2).

    Anti-patterns:
    - DO NOT use `withTimeout` from external libraries — `Task.sleep` is the documented Swift 6 idiom.
    - DO NOT cancel pending continuations on actor deinit — Swift will warn, but the actor is process-lifetime in the App; deinit-on-pending is impossible in the happy path.
    - DO NOT add multiple-resolve protection via `Atomic` or locks — the actor's serial executor IS the protection.
  </action>
  <verify>
    <automated>swift test --package-path packages/MCP --filter ConfirmationBrokerTests 2>&amp;1 | tail -25</automated>
  </verify>
  <done>
    - All 9 ConfirmationBroker tests pass.
    - `grep -c 'guard req.resolved == false' packages/MCP/Sources/MCP/ConfirmationBroker.swift` returns 1 (FSM first-write-wins guard).
    - `grep -c 'Task.sleep(for: .seconds(timeout))' packages/MCP/Sources/MCP/ConfirmationBroker.swift` returns 1 (AGENT-11 timeout impl).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: ConfirmationPresenter — native AppKit NSPanel sheet (no modal)</name>
  <files>
    packages/MCP/Sources/MCP/ConfirmationPresenter.swift
  </files>
  <behavior>
    - The presenter conforms to `ConfirmationPresenting`.
    - `show(id:toolName:argsPreview:)` constructs an NSPanel with `.nonactivatingPanel` style mask + `.titled`, attaches it as a sheet on a hidden owner `NSPanel` via `parent.beginSheet(panel, completionHandler:)`, and stores the panel keyed by id.
    - `dismiss(id:)` calls `parent.endSheet(panel, returnCode: .OK)` then `panel.close()`; removes the entry.
    - The presenter offers two SwiftUI buttons in the panel content: "Approve" and "Deny". Approve calls `Task { await broker.response(id: id, outcome: .approve) }`; Deny calls `.deny`.
    - The file contains ZERO calls to `runModal`, `beginModalSession`, `NSApp.run`, `NSApplication.shared.run`. The lint rule from Task 5 enforces this across the codebase.
    - The panel content is plain SwiftUI hosted in an NSHostingView (SwiftUI is fine; the modal-ban applies to PRESENTATION, not content rendering — `.sheet` modifier is what's banned, not SwiftUI itself).
    - Test: this file is exercised by integration through the broker tests (Task 1's MockPresenter is used for unit tests). No dedicated test file — the AppKit panel behavior is observable only at runtime; a build-time grep ensures the forbidden APIs are absent.
  </behavior>
  <action>
    1. Create `packages/MCP/Sources/MCP/ConfirmationPresenter.swift`:
       ```swift
       import AppKit
       import SwiftUI
       import Foundation

       @MainActor
       public final class ConfirmationPresenter: ConfirmationPresenting {
           private weak var broker: ConfirmationBroker?
           private var panels: [UUID: NSPanel] = [:]
           private let owner: NSPanel  // hidden owner panel for beginSheet attachment

           public init(broker: ConfirmationBroker) {
               self.broker = broker
               // Hidden owner panel — never visible. Lives at .floating level so any sheet attaches at HUD level.
               self.owner = NSPanel(
                   contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered,
                   defer: true
               )
               self.owner.isFloatingPanel = true
               self.owner.level = .floating
               self.owner.alphaValue = 0
               self.owner.orderOut(nil)
           }

           public nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
               await MainActor.run { [weak self] in
                   self?._show(id: id, toolName: toolName, argsPreview: argsPreview)
               }
           }

           public nonisolated func dismiss(id: UUID) async {
               await MainActor.run { [weak self] in
                   self?._dismiss(id: id)
               }
           }

           private func _show(id: UUID, toolName: String, argsPreview: String) {
               // Construct an NSPanel hosting SwiftUI content. NSPanel + .beginSheet is the only
               // sanctioned modal-equivalent path. Lint forbids runModal / beginModalSession / NSApp.run
               // across the entire codebase (scripts/check-no-modal-presentation.sh).
               let panel = NSPanel(
                   contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                   styleMask: [.titled, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true
               )
               panel.title = "Approve tool call"
               panel.isFloatingPanel = true

               let view = ConfirmationContent(
                   toolName: toolName,
                   argsPreview: argsPreview,
                   onApprove: { [weak self] in
                       guard let broker = self?.broker else { return }
                       Task { await broker.response(id: id, outcome: .approve) }
                   },
                   onDeny: { [weak self] in
                       guard let broker = self?.broker else { return }
                       Task { await broker.response(id: id, outcome: .deny) }
                   }
               )
               panel.contentView = NSHostingView(rootView: view)

               panels[id] = panel
               // beginSheet is the SANCTIONED non-blocking modal-equivalent path.
               // beginSheet does NOT park MainActor (unlike runModal); the presenter remains responsive.
               // Owner must be visible briefly so beginSheet finds a window context; we make it 0-alpha so it's invisible.
               owner.alphaValue = 0
               owner.orderFront(nil)
               owner.beginSheet(panel) { _ in
                   // Sheet closed; panel will be removed by _dismiss(id:).
               }
           }

           private func _dismiss(id: UUID) {
               guard let panel = panels[id] else { return }
               owner.endSheet(panel, returnCode: .OK)
               panel.close()
               panels[id] = nil
               if panels.isEmpty {
                   owner.orderOut(nil)
               }
           }
       }

       private struct ConfirmationContent: View {
           let toolName: String
           let argsPreview: String
           let onApprove: () -> Void
           let onDeny: () -> Void

           var body: some View {
               VStack(alignment: .leading, spacing: 12) {
                   Text("Tool call: \(toolName)")
                       .font(.headline)
                   ScrollView { Text(argsPreview).font(.system(.body, design: .monospaced)) }
                       .frame(maxHeight: 120)
                   HStack {
                       Spacer()
                       Button("Deny", action: onDeny).keyboardShortcut(.cancelAction)
                       Button("Approve", action: onApprove).keyboardShortcut(.defaultAction)
                   }
               }
               .padding(20)
           }
       }
       ```

    Anti-patterns to enforce by the lint script (Task 5) AND by inline grep here:
    - DO NOT call `runModal` on any panel. `beginSheet(_:completionHandler:)` is the ONLY sanctioned path.
    - DO NOT use SwiftUI's `.sheet` view modifier on a SwiftUI view — under macOS that bottoms out in `NSPanel.beginSheet` for SwiftUI scenes but for AppKit hosting it can route through modal sessions. The lint script's grep for `\.sheet\(` should be commented carefully — we DO use `.sheet` colloquially in normal SwiftUI code in App/HUD/, so the lint scope is module-restricted to the presentation paths. (Restrict the lint regex to `runModal\\|beginModalSession\\|NSApp\\.run\\|NSApplication\\.shared\\.run`; do NOT grep `.sheet(` because legitimate SwiftUI uses exist.)
    - DO NOT use `NSAlert.runModal()` — same modal session ban. NSAlert via `beginSheetModal(for:completionHandler:)` is the sanctioned async variant; the existing TCCAlertService from Phase 1 already follows this pattern.
  </action>
  <verify>
    <automated>swift build --package-path packages/MCP 2>&amp;1 | tail -3 &amp;&amp; ! grep -E 'runModal\b|beginModalSession\b|NSApp\.run\b|NSApplication\.shared\.run\b' packages/MCP/Sources/MCP/ConfirmationPresenter.swift &amp;&amp; grep -c 'beginSheet(' packages/MCP/Sources/MCP/ConfirmationPresenter.swift &amp;&amp; grep -c '@MainActor' packages/MCP/Sources/MCP/ConfirmationPresenter.swift</automated>
  </verify>
  <done>
    - `swift build --package-path packages/MCP` exits 0; the presenter compiles into the MCP target.
    - `! grep -E 'runModal\b|beginModalSession\b|NSApp\.run\b|NSApplication\.shared\.run\b' packages/MCP/Sources/MCP/ConfirmationPresenter.swift` succeeds (presenter contains zero forbidden modal calls).
    - `grep -c 'beginSheet(' packages/MCP/Sources/MCP/ConfirmationPresenter.swift` returns >= 1 (sanctioned non-blocking modal-equivalent path is used).
    - `grep -c '@MainActor' packages/MCP/Sources/MCP/ConfirmationPresenter.swift` returns >= 1 (presentation is main-actor isolated).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: ConfirmingToolDispatcher — broker-gated wrapper around the inner ToolDispatcher</name>
  <files>
    packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift,
    packages/MCP/Tests/MCPTests/ConfirmingToolDispatcherTests.swift
  </files>
  <behavior>
    - Test (RED first): `test_dispatch_nonConfirmTool_passesThroughUnchanged` — inner dispatcher reports `requiresConfirmation("get_time") == false`; ConfirmingToolDispatcher.dispatch(toolUse: get_time) MUST NOT call broker.request; MUST emit ZERO `awaitingApproval` argsPreview to the bus; result equals inner dispatcher's bytes verbatim.
    - Test (the headline MCP-04 args-redaction invariant): `test_dispatch_confirmTool_emitsAwaitingApprovalPreview_BEFORE_callingInner` — inner reports `requiresConfirmation("run_applescript") == true`. Spy bus records `toolCallStart` calls in order. Spy broker returns `.approve` after a 10ms scripted delay. Assert ordered: (1) bus receives `toolCallStart(id, "run_applescript", argsPreview: "{\"awaitingApproval\":true}")`, (2) broker.request is awaited, (3) ONLY THEN inner.dispatch is called. Args field of the underlying `argsJSON` must NEVER appear in the pre-approval bus emission — the regex `\"source\":` MUST NOT match the first argsPreview payload.
    - Test: `test_dispatch_confirmTool_onApprove_emitsPostApprovalPreview_AND_callsInner` — broker returns `.approve`; assert bus receives a SECOND `toolCallStart` (or equivalent argsPreview update via `BusGateway.updateArgsPreview`) carrying the sanitized args preview built from `argsPreviewSanitizer(toolUse.argsJSON)`; inner.dispatch is called once; result is returned.
    - Test: `test_dispatch_confirmTool_onDeny_throwsConfirmationError_denied_AND_emitsToolCallEnd_failed` — broker returns `.deny`; assert dispatcher throws `ConfirmationError.denied`; bus receives `toolCallEnd(id, ok: false, previewOrError: <some "denied" string>)`; inner.dispatch is NEVER called.
    - Test: `test_dispatch_confirmTool_onTimeout_throwsConfirmationError_timedOut_AND_logsWarning_AND_emitsToolCallEnd_failed` — broker returns `.timeout`; assert dispatcher throws `ConfirmationError.timedOut(after: 60)`; **a `JarvisLogChannel.mcp` log line at WARNING severity is emitted with subsystem = "ConfirmingToolDispatcher" and message containing "timeout"** (per the AGENT-11 timeout-as-deny semantics — `.timeout` IS the implementation of "synthesized deny" per ROADMAP SC-3); inner.dispatch is NEVER called. Test name MUST be exactly `test_OC_T1_timeoutLogsWarning` (matching the medium-finding requirement).
    - Test: `test_dispatch_confirmTool_onBarge_throwsConfirmationError_barged_AND_emitsToolCallEnd_failed` — broker returns `.barge` (e.g., user pressed cmd+. or invoked cancelAndSubmit while approval was pending); assert dispatcher throws `ConfirmationError.barged`; bus receives `toolCallEnd(id, ok: false)`; inner.dispatch is NEVER called.
    - Test: `test_dispatch_confirmTool_innerError_propagatesAfterApproval` — broker returns `.approve`; inner.dispatch throws `MCPError.serverCrashed("mcp-applescript")`. Dispatcher rethrows verbatim (the orchestrator handles this via its existing thrown-error path).
    - Test: `test_requiresConfirmation_delegatesToInner_synchronously` — sync (non-await) call to `dispatcher.requiresConfirmation("run_applescript")` returns inner's value (true); for `"get_time"` returns false. The protocol method must remain `nonisolated` (no actor hop).
    - Test (the args-redaction-before-approval defense-in-depth): `test_argsPreview_seal_neverContainsRawArgs_prior_to_approval` — input `argsJSON` deliberately contains the substring `"forbidden-string-for-test"`. Pre-approval bus emission's `argsPreview` is grep-asserted to NOT contain `forbidden-string-for-test` even once. Belt-and-suspenders: HUD's Plan 03-04 ToolCallCard already hides args when status === 'awaiting-approval'; this test guards the broker-side emission.
  </behavior>
  <action>
    1. Create `packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift`:
       ```swift
       import Foundation
       import AgentCore
       import AgentOrchestrator
       import JarvisLogging

       public enum ConfirmationError: Error, Sendable, Equatable {
           case denied
           case timedOut(after: TimeInterval)
           case barged
       }

       public protocol BusGateway: Sendable {
           /// Emit toolCallStart for the awaiting-approval phase (argsPreview = `{"awaitingApproval":true}`).
           func emitToolCallStart(toolUseId: UUID, name: String, argsPreview: String) async
           /// Emit a follow-up toolCallStart (or equivalent update) once approval lands.
           /// Implementations may choose `toolCallStart` re-emit OR a dedicated `argsPreviewUpdate` —
           /// the HUD's ToolCallCard reconciles both via toolUseId.
           func updateArgsPreview(toolUseId: UUID, name: String, argsPreview: String) async
           /// Emit toolCallEnd with ok=false on deny/timeout/barge.
           func emitToolCallEnd(toolUseId: UUID, name: String, ok: Bool, previewOrError: String) async
       }

       /// Wraps an inner ToolDispatcher with confirmation gating. For tools whose
       /// `requiresConfirmation(toolName:)` returns true, this dispatcher:
       ///   1. Emits `toolCallStart(argsPreview: "{\"awaitingApproval\":true}")` on the bus.
       ///   2. Awaits `broker.request(...)`.
       ///   3. On `.approve`: emits a follow-up `argsPreview` carrying the sanitized
       ///      preview, then calls `inner.dispatch(toolUse:)` and returns its bytes.
       ///   4. On `.deny` / `.timeout` / `.barge`: emits `toolCallEnd(ok: false, ...)` and
       ///      throws the matching `ConfirmationError`. The orchestrator's existing
       ///      thrown-error path translates this into `.toolCardUpdate(.failed)` and a
       ///      synthesized tool_result error message in history (Plan 04-04).
       ///
       /// Args-redaction invariant (MCP-04 + SEC-08): the raw `argsJSON` NEVER appears on
       /// the bus before approval. Only after `.approve` is the `argsPreviewSanitizer`
       /// invoked to build a redacted preview. The HUD's Plan 03-04 hide-when-awaiting
       /// rule provides defense-in-depth, but the broker-side seal here is the primary
       /// barrier.
       ///
       /// AGENT-11 timeout-as-deny semantics: a `.timeout` outcome is the implementation
       /// form of "synthesized deny" (ROADMAP SC-3). It is logged at WARNING severity to
       /// `JarvisLogChannel.mcp`, then surfaced to the orchestrator as a thrown
       /// `ConfirmationError.timedOut`. The orchestrator + ReplayLog treat `.timeout` and
       /// `.deny` equivalently for history purposes.
       public actor ConfirmingToolDispatcher: ToolDispatcher {
           private let inner: any ToolDispatcher
           private let broker: ConfirmationBroker
           private let bus: (any BusGateway)?
           private let argsPreviewSanitizer: @Sendable (Data) -> String
           private let timeoutSecondsForLogging: TimeInterval
           private let log: JarvisLogChannel

           public init(
               inner: any ToolDispatcher,
               broker: ConfirmationBroker,
               bus: (any BusGateway)?,
               argsPreviewSanitizer: @escaping @Sendable (Data) -> String,
               timeoutSecondsForLogging: TimeInterval = 60,
               log: JarvisLogChannel = .mcp
           ) {
               self.inner = inner
               self.broker = broker
               self.bus = bus
               self.argsPreviewSanitizer = argsPreviewSanitizer
               self.timeoutSecondsForLogging = timeoutSecondsForLogging
               self.log = log
           }

           public func dispatch(toolUse: ToolUseRequest) async throws -> Data {
               // Fast path: tool does not require confirmation.
               guard requiresConfirmation(toolName: toolUse.name) else {
                   return try await inner.dispatch(toolUse: toolUse)
               }

               // Step 1 — emit awaiting-approval phase to the bus. Args are SEALED.
               let toolUseUUID = UUID(uuidString: toolUse.id) ?? UUID()
               let awaitingPreview = "{\"awaitingApproval\":true}"
               await bus?.emitToolCallStart(
                   toolUseId: toolUseUUID,
                   name: toolUse.name,
                   argsPreview: awaitingPreview
               )

               // Step 2 — await broker.
               let outcome = await broker.request(
                   id: toolUseUUID,
                   toolName: toolUse.name,
                   argsPreview: awaitingPreview
               )

               // Step 3 — branch on outcome.
               switch outcome {
               case .approve:
                   // Emit follow-up argsPreview with sanitized real args.
                   let postApprovalPreview = argsPreviewSanitizer(toolUse.argsJSON)
                   await bus?.updateArgsPreview(
                       toolUseId: toolUseUUID,
                       name: toolUse.name,
                       argsPreview: postApprovalPreview
                   )
                   return try await inner.dispatch(toolUse: toolUse)

               case .deny:
                   await bus?.emitToolCallEnd(
                       toolUseId: toolUseUUID,
                       name: toolUse.name,
                       ok: false,
                       previewOrError: "denied by user"
                   )
                   throw ConfirmationError.denied

               case .timeout:
                   // AGENT-11: .timeout IS the implementation of "synthesized deny".
                   log.warning("ConfirmingToolDispatcher: timeout awaiting approval for tool \(toolUse.name) (toolUseId=\(toolUse.id))")
                   await bus?.emitToolCallEnd(
                       toolUseId: toolUseUUID,
                       name: toolUse.name,
                       ok: false,
                       previewOrError: "approval timed out after \(Int(timeoutSecondsForLogging))s"
                   )
                   throw ConfirmationError.timedOut(after: timeoutSecondsForLogging)

               case .barge:
                   await bus?.emitToolCallEnd(
                       toolUseId: toolUseUUID,
                       name: toolUse.name,
                       ok: false,
                       previewOrError: "superseded by new turn (barge-in)"
                   )
                   throw ConfirmationError.barged
               }
           }

           public nonisolated func requiresConfirmation(toolName: String) -> Bool {
               inner.requiresConfirmation(toolName: toolName)
           }
       }
       ```

    2. Tests (`packages/MCP/Tests/MCPTests/ConfirmingToolDispatcherTests.swift`) per the `<behavior>` block. Use a SpyBus conforming to `BusGateway` that records every call in an `[BusEvent]` array; SpyBroker that you script with a closure to return any of the four outcomes; SpyInnerDispatcher that records calls and returns scripted bytes or throws scripted errors. SpyLog conforms to `JarvisLogChannel`-shape (or use the existing test fake from packages/Logging/Tests).

    3. Args-redaction grep gate (in test): after the pre-approval bus emission, assert via string-equality that the recorded `argsPreview` is EXACTLY `{"awaitingApproval":true}` and contains zero substring overlap with the input `argsJSON` decoded as UTF-8. This is stricter than the regex test above.

    Anti-patterns:
    - DO NOT skip the awaiting-approval bus emission for non-confirmation tools — the fast path returns BEFORE that emission and stays the same shape Plan 04-04 already sees.
    - DO NOT include the raw `argsJSON` in the awaiting-approval preview under any condition. The argsPreview seal IS the MCP-04 invariant.
    - DO NOT swallow the timeout silently — the WARNING log is required by AGENT-11.
    - DO NOT call broker.request before emitting `toolCallStart` on the bus — the HUD needs the toolUseId visible in awaitingApproval state before the sheet can correlate; tests assert ordering.
  </action>
  <verify>
    <automated>swift test --package-path packages/MCP --filter ConfirmingToolDispatcherTests 2>&amp;1 | tail -30 &amp;&amp; swift build --package-path packages/MCP 2>&amp;1 | tail -3 &amp;&amp; grep -c 'awaitingApproval' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift &amp;&amp; grep -c ': ToolDispatcher' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift &amp;&amp; grep -c 'broker.request' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift &amp;&amp; grep -v '^[[:space:]]*//' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift | grep -c 'log.warning'</automated>
  </verify>
  <done>
    - All 9 ConfirmingToolDispatcher tests pass, INCLUDING `test_OC_T1_timeoutLogsWarning` (medium-finding gate).
    - `grep -c 'awaitingApproval' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift` returns >= 1 (the seal literal is present in source).
    - `grep -c ': ToolDispatcher' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift` returns 1 (protocol conformance).
    - `grep -c 'broker.request' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift` returns >= 1 (broker is actually called).
    - The four-outcome FSM branches (approve / deny / timeout / barge) are each covered by an explicit case in the switch — verified by reading the file.
    - The args-redaction-before-approval invariant test (`test_argsPreview_seal_neverContainsRawArgs_prior_to_approval`) explicitly asserts the seal string and zero overlap with raw argsJSON.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 4: AppDelegate + MCPRuntimeWiring + ReplayingToolResultObserver — production wire-up (closes ME-04)</name>
  <files>
    App/AppDelegate.swift,
    App/MCP/MCPRuntimeWiring.swift,
    App/MCP/ReplayingToolResultObserver.swift,
    App/Tests/AppTests/MCPRuntimeWiringTests.swift
  </files>
  <behavior>
    - Test (structural; no xctest-launch): `test_buildMCPRuntime_returnsRuntimeWithFullChain` — call `MCPRuntimeWiring.build(bundleURL:bus:replayLog:)` with a temp bundle URL pointing at a fixture `Contents/Helpers/` directory containing the three helper apps (or stub paths), a SpyBus, and a temp ReplayLog. Assert: runtime.client is non-nil; runtime.broker is non-nil; runtime.presenter is non-nil; runtime.dispatcher is a ConfirmingToolDispatcher (introspect via `is` cast OR via a conformance witness method). Assert the dispatcher's `requiresConfirmation("run_applescript") == true` and `requiresConfirmation("get_time") == false`.
    - Test: `test_replayingToolResultObserver_writesPreAndPostBytes_toReplayLog` — instantiate `ReplayingToolResultObserver(replayLog:)` with a temp ReplayLog; call `observer.record(toolUseId: "tu1", toolName: "get_time", rawBytes: Data("raw".utf8), sanitizedBytes: Data("clean".utf8))`. Read the ReplayLog table and assert: there exists a row for `tu1` with `rawBytes == "raw"` AND `sanitizedBytes == "clean"`. Closes SEC-07 acceptance.
    - Test: `test_replayChannel_isInstantiated_at2048CapDropOldestForTokenDelta` — the wiring instantiates the orch→replay 2048-capacity `TokenDeltaDropOldestChannel<Tag>` (the primitive that Plan 04-05 verified by topology test CT2 but never instantiated in production). Assert the channel constructed by MCPRuntimeWiring (or by AppDelegate that consumes the runtime) has `capacity == 2048` and `dropTag == .tokenDelta`. Closes ME-04.
    - Test (no `XCTestCase.launch()` invocations — file scope forbids real app boot in tests): the AppDelegate's `applicationDidFinishLaunching` calls `MCPRuntimeWiring.build(...)` synchronously (well, awaits within a Task) and stashes the runtime on a property. Verified structurally by extracting a testable `bootstrapAgentOrchestrator(runtime:replayLog:bus:) -> AgentOrchestrator` helper that doesn't depend on AppKit lifecycle, then asserting the helper produces an orchestrator whose `toolDispatcher` IS the runtime's ConfirmingToolDispatcher.
  </behavior>
  <action>
    1. Create `App/MCP/MCPRuntimeWiring.swift`:
       ```swift
       import Foundation
       import AgentCore
       import AgentOrchestrator
       import MCP
       import Replay
       import JarvisLogging

       @MainActor
       public struct MCPRuntime {
           public let client: MCPClient
           public let registry: ToolRegistry
           public let dispatcher: any ToolDispatcher           // = ConfirmingToolDispatcher
           public let presenter: ConfirmationPresenter
           public let broker: ConfirmationBroker
           public let toolResultObserver: any ToolResultObserver
       }

       @MainActor
       public enum MCPRuntimeWiring {
           /// Builds the full MCP runtime chain:
           ///   MCPClient --(register 3 helpers)--> ToolRegistry
           ///     -> MCPToolDispatcher(client, registry, observer)
           ///       -> ConfirmingToolDispatcher(inner, broker, bus, sanitizer)
           ///
           /// Also wires the `ReplayingToolResultObserver` so SEC-07 captures both
           /// pre- and post-sanitize bytes for every dispatch.
           public static func build(
               bundleURL: URL,
               bus: any BusGateway,
               replayLog: ReplayLog
           ) async throws -> MCPRuntime {
               let helpersDir = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)

               // 1. Construct MCPClient and register the three helpers.
               let client = MCPClient()
               try await client.register(
                   serverName: "mcp-time",
                   bundleURL: helpersDir.appendingPathComponent("mcp-time.app")
               )
               try await client.register(
                   serverName: "mcp-clipboard",
                   bundleURL: helpersDir.appendingPathComponent("mcp-clipboard.app")
               )
               try await client.register(
                   serverName: "mcp-applescript",
                   bundleURL: helpersDir.appendingPathComponent("mcp-applescript.app")
               )

               // 2. Build the ToolRegistry from MCPClient's discovered metadata.
               var registry = ToolRegistry()
               registry.register(toolName: "get_time", serverName: "mcp-time", requiresConfirmation: false)
               registry.register(toolName: "get_clipboard", serverName: "mcp-clipboard", requiresConfirmation: false)
               registry.register(toolName: "run_applescript", serverName: "mcp-applescript", requiresConfirmation: true)

               // 3. Wire the observer that closes SEC-07 (pre + post sanitize bytes -> ReplayLog).
               let observer = ReplayingToolResultObserver(replayLog: replayLog)

               // 4. Construct the inner MCPToolDispatcher.
               let inner = MCPToolDispatcher(client: client, registry: registry, observer: observer)

               // 5. Construct the broker + presenter (presenter holds weak ref to broker).
               // Order matters: presenter is constructed first with a placeholder, then real broker
               // points back. We construct broker first with a forward-declared presenter holder
               // so the closure cycle doesn't strand either.
               let presenterHolder = ConfirmationPresenterHolder()
               let broker = ConfirmationBroker(timeoutSeconds: 60, presenter: presenterHolder)
               let presenter = ConfirmationPresenter(broker: broker)
               presenterHolder.attach(presenter)

               // 6. Argspreview sanitizer — for v1, parse the JSON and emit a 256-byte
               // truncated string preview; downstream HUD pretty-prints.
               let sanitizer: @Sendable (Data) -> String = { argsJSON in
                   guard let s = String(data: argsJSON, encoding: .utf8) else { return "{}" }
                   if s.utf8.count <= 256 { return s }
                   let head = Data(s.utf8.prefix(256))
                   return (String(decoding: head, as: UTF8.self)) + "…[args-truncated]"
               }

               // 7. The confirmation-gated outer dispatcher (ME-09 + MCP-04).
               let dispatcher = ConfirmingToolDispatcher(
                   inner: inner,
                   broker: broker,
                   bus: bus,
                   argsPreviewSanitizer: sanitizer
               )

               return MCPRuntime(
                   client: client,
                   registry: registry,
                   dispatcher: dispatcher,
                   presenter: presenter,
                   broker: broker,
                   toolResultObserver: observer
               )
           }
       }

       /// Indirection so ConfirmationBroker can hold a `ConfirmationPresenting` reference
       /// while the concrete `ConfirmationPresenter` (which holds a back-ref to broker) is
       /// constructed. Resolves the otherwise-cyclic init order.
       @MainActor
       final class ConfirmationPresenterHolder: ConfirmationPresenting {
           private weak var inner: ConfirmationPresenter?
           func attach(_ p: ConfirmationPresenter) { self.inner = p }
           nonisolated func show(id: UUID, toolName: String, argsPreview: String) async {
               await MainActor.run { [weak self] in
                   self?.inner?.show(id: id, toolName: toolName, argsPreview: argsPreview)
               }
           }
           nonisolated func dismiss(id: UUID) async {
               await MainActor.run { [weak self] in
                   self?.inner?.dismiss(id: id)
               }
           }
       }
       ```

    2. Create `App/MCP/ReplayingToolResultObserver.swift` (closes SEC-07 acceptance + ME-04 in conjunction with the orch→replay channel below):
       ```swift
       import Foundation
       import AgentCore
       import MCP
       import Replay

       /// Records pre- and post-sanitize bytes for every MCP dispatch into the
       /// ReplayLog. Wired by MCPRuntimeWiring.build so that SEC-07's "replay
       /// captures both pre- and post-sanitize bytes" acceptance holds in production.
       ///
       /// This observer is the production half of ME-04 (Plan 04-05 deferred state).
       /// Plan 04-03 created the `BoundedAsyncChannel` primitive at capacity 2048
       /// with .dropOldest for tokenDelta. Plan 04-05 verified the contract via
       /// `ChannelTopologyTests.CT2`. This file (combined with the AppDelegate
       /// wiring that instantiates the channel) closes the deferred state by
       /// actually running the channel in production.
       public final class ReplayingToolResultObserver: ToolResultObserver {
           private let replayLog: ReplayLog
           public init(replayLog: ReplayLog) {
               self.replayLog = replayLog
           }
           public func record(
               toolUseId: String,
               toolName: String,
               rawBytes: Data,
               sanitizedBytes: Data
           ) async {
               await replayLog.record(
                   .toolResultFull(
                       toolUseId: toolUseId,
                       rawBytes: rawBytes,
                       sanitizedBytes: sanitizedBytes
                   )
               )
           }
       }
       ```

    3. Update `App/AppDelegate.swift` to wire the runtime + the orch→replay 2048-cap channel that closes ME-04. Pseudocode (executor reads existing AppDelegate and inserts at applicationDidFinishLaunching):
       ```swift
       func applicationDidFinishLaunching(_ notification: Notification) {
           Task { @MainActor in
               // ... existing setup (window, hotkey, replay log) ...
               let replayLog = try await ReplayLog.openDefault()
               let bus = BusGatewayImpl(/* ... */)

               // Build MCP runtime (wave-5 wiring).
               let runtime = try await MCPRuntimeWiring.build(
                   bundleURL: Bundle.main.bundleURL,
                   bus: bus,
                   replayLog: replayLog
               )
               self.mcpRuntime = runtime  // retain on AppDelegate

               // Instantiate the orch→replay 2048-cap channel that Plan 04-05's
               // CT2 verified. This is the production instance that closes ME-04.
               let orchToReplayChannel = BoundedAsyncChannel<ReplayEvent>(
                   capacity: 2048,
                   policy: .dropOldest  // for tokenDelta only — see TokenDeltaDropOldestChannel for tag-aware variant
               )

               // Build the orchestrator with the confirmation-gated dispatcher.
               let orchestrator = AgentOrchestrator(
                   providerFactory: { /* AnthropicProvider or OllamaProvider per config */ },
                   toolDispatcher: runtime.dispatcher,
                   replayLog: replayLog,
                   replayChannel: orchToReplayChannel
               )
               self.agentOrchestrator = orchestrator

               // Spawn the channel drain that consumes orchToReplayChannel and writes to replayLog.
               // Plan 04-05's CT2 verified the primitive; this is the production consumer.
               Task.detached {
                   for await ev in orchToReplayChannel {
                       await replayLog.record(ev)
                   }
               }
           }
       }
       ```

       Note: if the AgentOrchestrator's current init from Plan 04-04 doesn't take a `replayChannel:` parameter, the wiring instead drains the orchestrator's existing internal record path; the executor inspects 04-04's actual init signature and adapts. The KEY INVARIANT for ME-04 closure is: `BoundedAsyncChannel(capacity: 2048, ...)` is INSTANTIATED in production code (not just unit-test code) and is used to deliver replay events.

    4. Tests (`App/Tests/AppTests/MCPRuntimeWiringTests.swift`) per `<behavior>`. Structural assertions only — DO NOT invoke `xcodebuild test` to launch the App; the AppTests target uses Swift Testing or XCTest with no real app lifecycle. If the App target's existing test scheme already runs without app-lifecycle, this is straightforward; otherwise factor a free function `buildMCPRuntime(...)` that the test calls directly.

    Anti-patterns:
    - DO NOT add the broker / presenter as singletons. They are owned by AppDelegate (and by `MCPRuntime`) for the lifetime of the process; injection (not service-locator lookup) is the rule.
    - DO NOT instantiate the orchestrator BEFORE the runtime — the orchestrator's `toolDispatcher` parameter is the runtime's ConfirmingToolDispatcher, not a stub.
    - DO NOT skip the `ReplayingToolResultObserver` wiring — without it, SEC-07's "replay captures both pre- and post-sanitize bytes" acceptance fails silently (no observer = no replay rows for tool results).
    - DO NOT use `xcodebuild test` in the verify step — file scope forbids it. Use `swift test` against the App's testable Swift Package layer if one exists, or skip the test invocation and rely on `xcodebuild build -configuration Debug` to confirm the wiring file compiles into the App target.
  </action>
  <verify>
    <automated>xcodegen generate 2>&amp;1 | tail -3 &amp;&amp; xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build 2>&amp;1 | tail -10 | grep -E 'BUILD SUCCEEDED|^\*\* BUILD' &amp;&amp; grep -c 'BoundedAsyncChannel' App/MCP/ReplayingToolResultObserver.swift &amp;&amp; grep -c 'MCPRuntimeWiring' App/AppDelegate.swift &amp;&amp; grep -c 'capacity: 2048' App/AppDelegate.swift &amp;&amp; grep -c 'ConfirmingToolDispatcher' App/MCP/MCPRuntimeWiring.swift &amp;&amp; grep -c 'ReplayingToolResultObserver' App/MCP/MCPRuntimeWiring.swift</automated>
  </verify>
  <done>
    - `xcodegen generate && xcodebuild build -configuration Debug` exits BUILD SUCCEEDED.
    - `App/MCP/MCPRuntimeWiring.swift` constructs the full chain (MCPClient → registry → MCPToolDispatcher → ConfirmingToolDispatcher) and returns a `MCPRuntime` struct. Grep confirms `ConfirmingToolDispatcher` is referenced.
    - `App/AppDelegate.swift` calls `MCPRuntimeWiring.build(...)` AND instantiates `BoundedAsyncChannel(capacity: 2048, ...)` for the orch→replay seam. ME-04 closure: production code now instantiates the channel that Plan 04-05's CT2 only verified as a primitive.
    - `App/MCP/ReplayingToolResultObserver.swift` writes to `replayLog.record(.toolResultFull(...))` per SEC-07. Reference grep `BoundedAsyncChannel` is the comment-block reference (or moves to AppDelegate proper); the SEC-07 observer file references replayLog.record(.toolResultFull).
    - MCPRuntimeWiringTests passes structurally (no xcodebuild test invocation).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 5: scripts/check-no-modal-presentation.sh + 2 fixtures + project.yml preBuildScript wiring</name>
  <files>
    scripts/check-no-modal-presentation.sh,
    scripts/test-fixtures/forbidden-modal-call.swift,
    scripts/test-fixtures/allowed-non-modal-call.swift,
    project.yml
  </files>
  <behavior>
    - Test: against the current repo (after Tasks 1–4 land), `bash scripts/check-no-modal-presentation.sh` exits 0. Allowlist permits `App/TCC/TCCAlertService.swift` (Phase 1 NSAlert sheet path) and `packages/MCP/Sources/MCP/ConfirmationPresenter.swift` (sanctioned beginSheet path).
    - Test: against `scripts/test-fixtures/forbidden-modal-call.swift` (a non-allowlisted file containing `runModal()`), the script's fixture-mode invocation exits 1 with a clear error message naming the offending file.
    - Test: against `scripts/test-fixtures/allowed-non-modal-call.swift` (a file containing `beginSheet(`, no modal calls), the script exits 0.
    - Wired into `project.yml` as a preBuildScript on the Jarvis target, BEFORE `verify-entitlements --pre-codesign`. Build fails fast if a future contributor introduces a forbidden modal call anywhere outside the two allowlisted paths.
  </behavior>
  <action>
    1. Create `scripts/check-no-modal-presentation.sh`:
       ```bash
       #!/usr/bin/env bash
       # check-no-modal-presentation.sh
       #
       # Rejects modal-presentation API calls (runModal, beginModalSession,
       # NSApp.run, NSApplication.shared.run, NSAlert(...).runModal()) anywhere
       # in the codebase EXCEPT explicitly allowlisted files. Modal presentation
       # parks the @MainActor and breaks the always-on-top HUD's responsiveness
       # — RESEARCH §Recommendation 4 + Pattern 5 + AUDIT-R4-Sec4 enforce this.
       #
       # Allowlist:
       #   - App/TCC/TCCAlertService.swift  (Phase 1 NSAlert beginSheetModal path; legacy)
       #   - packages/MCP/Sources/MCP/ConfirmationPresenter.swift  (Plan 05-05 sanctioned beginSheet)
       #
       # Wired as a preBuildScript in project.yml for the Jarvis target, BEFORE
       # verify-entitlements --pre-codesign so the build fails fast on regression.
       #
       # Modes:
       #   no args:                     scan App/** + packages/**/Sources/** in repo
       #   --fixture <path>:            scan ONLY the given file (used by self-test)
       #
       # Exit codes:
       #   0 — clean
       #   1 — at least one forbidden modal call found outside allowlist
       set -euo pipefail

       ALLOWLIST=(
           "App/TCC/TCCAlertService.swift"
           "packages/MCP/Sources/MCP/ConfirmationPresenter.swift"
       )

       PATTERN='runModal\b|beginModalSession\b|NSApp\.run\b|NSApplication\.shared\.run\b|NSAlert.*\.runModal\b'

       is_allowlisted() {
           local path="$1"
           # Normalize against repo root.
           local rel="${path#./}"
           for allowed in "${ALLOWLIST[@]}"; do
               if [ "$rel" = "$allowed" ]; then return 0; fi
           done
           return 1
       }

       scan_file() {
           local file="$1"
           # Strip comments before grep so doc-comment mentions don't false-positive.
           # `grep -v '^[[:space:]]*//'` removes single-line comments at line start;
           # block comments /* */ are handled by Swift convention (not common in our code).
           local matches
           matches="$(grep -v '^[[:space:]]*//' "$file" | grep -E "$PATTERN" || true)"
           if [ -n "$matches" ]; then
               if is_allowlisted "$file"; then
                   return 0  # allowlisted — fine
               fi
               echo "error: forbidden modal-presentation call in $file:" >&2
               echo "$matches" >&2
               return 1
           fi
           return 0
       }

       if [ "${1:-}" = "--fixture" ]; then
           scan_file "$2"
           exit $?
       fi

       FOUND_ANY=0
       while IFS= read -r f; do
           if ! scan_file "$f"; then
               FOUND_ANY=1
           fi
       done < <(find App packages -type f -name '*.swift' \
                  -not -path '*/.build/*' \
                  -not -path '*/Tests/*' \
                  2>/dev/null)

       if [ "$FOUND_ANY" -ne 0 ]; then
           echo "check-no-modal-presentation.sh: FAIL" >&2
           exit 1
       fi
       echo "check-no-modal-presentation.sh: OK"
       exit 0
       ```

    2. Create `scripts/test-fixtures/forbidden-modal-call.swift`:
       ```swift
       // Fixture: contains runModal() outside any allowlist.
       // The lint script must reject this file in --fixture mode.
       import AppKit

       func bad() {
           let alert = NSAlert()
           alert.messageText = "boom"
           let _ = alert.runModal()
       }
       ```

    3. Create `scripts/test-fixtures/allowed-non-modal-call.swift`:
       ```swift
       // Fixture: uses beginSheet (allowed) and contains zero modal calls.
       // The lint script must accept this file in --fixture mode.
       import AppKit

       func good(parent: NSWindow, child: NSWindow) {
           parent.beginSheet(child) { _ in }
       }
       ```

    4. Wire `scripts/check-no-modal-presentation.sh` into `project.yml` as a preBuildScript on the Jarvis target, BEFORE `verify-entitlements --pre-codesign`. Locate the existing `preBuildScripts:` block (extended in Plan 05-03) and prepend a new entry:
       ```yaml
       preBuildScripts:
         - name: Check no modal presentation
           script: |
             "${SRCROOT}/scripts/check-no-modal-presentation.sh"
           runOnlyWhenInstalling: false
           basedOnDependencyAnalysis: false
         # (existing entries: verify-entitlements --pre-codesign, etc., unchanged)
       ```

    5. Self-test commands (run as part of verify):
       - `bash scripts/check-no-modal-presentation.sh` → exit 0 (repo is clean after Tasks 1–4 because ConfirmationPresenter.swift is allowlisted).
       - `bash scripts/check-no-modal-presentation.sh --fixture scripts/test-fixtures/allowed-non-modal-call.swift` → exit 0.
       - `bash scripts/check-no-modal-presentation.sh --fixture scripts/test-fixtures/forbidden-modal-call.swift` → exit 1 with "forbidden modal-presentation call" message on stderr.

    Anti-patterns:
    - DO NOT widen the allowlist without surfacing as a checkpoint — every additional allowlisted file is an exception to the MCP-04 enforcement.
    - DO NOT pattern-match `\.sheet\(` (SwiftUI's view modifier) — legitimate uses exist in App/HUD/. The lint targets MODAL APIs (runModal / beginModalSession / NSApp.run), not the SwiftUI sheet modifier.
    - DO NOT chmod the script outside the post-clone setup — set `chmod +x scripts/check-no-modal-presentation.sh` once at file creation; checked-in mode bit persists.
  </action>
  <verify>
    <automated>chmod +x scripts/check-no-modal-presentation.sh &amp;&amp; bash scripts/check-no-modal-presentation.sh 2>&amp;1 | tail -3 &amp;&amp; bash scripts/check-no-modal-presentation.sh --fixture scripts/test-fixtures/allowed-non-modal-call.swift &amp;&amp; bash -c '! bash scripts/check-no-modal-presentation.sh --fixture scripts/test-fixtures/forbidden-modal-call.swift' &amp;&amp; echo OK_REJECT &amp;&amp; grep -c 'check-no-modal-presentation' project.yml &amp;&amp; xcodegen generate 2>&amp;1 | tail -3 &amp;&amp; xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build 2>&amp;1 | tail -5 | grep -E 'BUILD SUCCEEDED|Check no modal presentation'</automated>
  </verify>
  <done>
    - `scripts/check-no-modal-presentation.sh` exits 0 against the current repo (the only modal-shaped calls live in the two allowlisted files).
    - The script exits 1 against `forbidden-modal-call.swift` and 0 against `allowed-non-modal-call.swift`.
    - `project.yml` references `check-no-modal-presentation` in a preBuildScript on the Jarvis target.
    - `xcodebuild build -configuration Debug` runs the new preBuildScript before `verify-entitlements --pre-codesign` and reports BUILD SUCCEEDED.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| LLM tool-call args → ConfirmingToolDispatcher | The model proposes a tool call with arbitrary `argsJSON`. The dispatcher MUST NOT serialize that JSON to the bus before approval (MCP-04 / SEC-08). |
| ConfirmationBroker FSM → external callers | The broker accepts `response(id:outcome:)` from three sources (presenter, barge-in path, timeout timer). Late hops after the first resolution must be silent no-ops (MCP-09). |
| Presenter NSPanel → user input | The user clicks Approve/Deny in the AppKit sheet. The bus / webview must NOT be able to forge approval — broker.response is called only from the presenter's button handlers (or the barge / timeout paths inside the broker actor). |
| AppDelegate runtime construction → orchestrator | The runtime owns broker + presenter + dispatcher + observer. The orchestrator receives the dispatcher only — it cannot reach back into the broker (which would let it self-approve). |
| Build-time modal-lint regression surface | A future contributor adding `runModal` anywhere outside the two-file allowlist must be caught at build time, not runtime. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-05-01 | Tampering | ConfirmationBroker FSM late-hop transitions (presenter sends `.approve` AFTER timeout already fired `.timeout`) | mitigate | First-write-wins guard inside `response(id:outcome:)`: `guard req.resolved == false else { return }`. Test `test_lateResponse_afterTimeout_isNoOp` regression-guards. The actor's serial executor enforces atomicity — no lock needed. |
| T-05-05-02 | Denial of Service | ConfirmationBroker stuck-await — `request(...)` resumes only via response, but presenter could crash silently leaving awaiter hung forever | mitigate | 60-second `Task.sleep`-based timeout (AGENT-11) ALWAYS resumes the awaiter via `.timeout`. Even if the presenter crashes, the timer fires and resolves the FSM. Test `test_request_returnsTimeout_whenNoResponseInSubSecond` proves the path with sub-second injection. |
| T-05-05-03 | Spoofing | Presenter NSPanel obscured by another app's window (user clicks Approve thinking they're approving Jarvis but actually interacting with attacker UI underneath) | accept (macOS owns Z-order) | NSPanel uses `.floating` level + `.nonactivatingPanel` mask which keeps it ABOVE most app windows; full-screen exclusive apps can still obscure. Acceptable risk for v1 personal-use scope; a future plan may add a "press cmd+J to confirm focus" requirement. |
| T-05-05-04 | Tampering | Webview / bus forging an approval — JS code in the HUD sends a synthetic message that calls broker.response(.approve) | mitigate | The broker's `response(id:outcome:)` is called ONLY from (a) ConfirmationPresenter button handlers (AppKit, native, no JS surface), (b) the barge-in path from AgentOrchestrator (Swift code), (c) the timeout timer inside the broker. The bus / WKScriptMessageHandler has NO path to broker.response — there is no `confirmationApprove` message handler registered. Defense-in-depth: any future bus addition for confirmation MUST be reviewed against this invariant. |
| T-05-05-05 | Information Disclosure | ConfirmingToolDispatcher leaks raw args pre-approval — argsPreview field carries the actual `argsJSON` bytes before user has seen them | mitigate | argsPreview seal: pre-approval bus emission ALWAYS uses literal `{"awaitingApproval":true}`. Post-approval emission uses `argsPreviewSanitizer(argsJSON)` (a 256-byte-truncated preview by default). Defense-in-depth: HUD's Plan 03-04 ToolCallCard hides args when `argsPreview === '{"awaitingApproval":true}'` OR `status === 'awaiting-approval'`. Test `test_argsPreview_seal_neverContainsRawArgs_prior_to_approval` regression-guards. |
| T-05-05-06 | Tampering | Future contributor introduces `runModal` somewhere on a @MainActor presentation path, parking the actor and breaking always-on-top HUD responsiveness | mitigate | Build-time grep gate `scripts/check-no-modal-presentation.sh` rejects `runModal\|beginModalSession\|NSApp\.run\|NSApplication\.shared\.run` outside the two-file allowlist. Wired as preBuildScript in project.yml BEFORE `verify-entitlements --pre-codesign` so build fails fast. Two test fixtures regression-guard the lint itself. |
| T-05-05-07 | Repudiation | Approval / deny / timeout / barge events are not preserved in the replay log — user later disputes whether they approved a destructive AppleScript | mitigate | Confirmation outcomes are emitted to the bus as `toolCallEnd(ok: false, previewOrError: <reason>)` for deny/timeout/barge, and as a follow-up `toolCallStart` (post-approval argsPreview) for approve. The bus emissions are subsequently captured by ReplayLog through the existing orch→replay pipeline (closed by Task 4's 2048-cap channel instantiation). Every confirmation outcome leaves a tamper-evident replay row with timestamp + toolUseId. |
| T-05-05-08 | Information Disclosure | Replay log misses post-sanitize bytes — SEC-07 acceptance "replay captures both pre- AND post-sanitize bytes" silently fails because no `ToolResultObserver` was wired in production | mitigate (closes Plan 04-05 deferred state) | Task 4's `ReplayingToolResultObserver` is wired in `MCPRuntimeWiring.build` and passed into `MCPToolDispatcher`. Plan 05-04's observer protocol exists; this plan is the production wiring. ME-04 also closes here: the `BoundedAsyncChannel(capacity: 2048, policy: .dropOldest)` orch→replay channel is INSTANTIATED in `AppDelegate.applicationDidFinishLaunching`, not just in topology tests. |
| T-05-05-09 | Tampering | AGENT-11 timeout-as-deny: `.timeout` MIGHT be treated as a non-deny outcome by the orchestrator/replay (wrong action taken because of mis-classification) | mitigate (semantics documented + tested) | `.timeout` IS the implementation form of "synthesized deny" per ROADMAP SC-3. The ConfirmingToolDispatcher's `.timeout` branch (a) writes a `JarvisLogChannel.mcp` WARNING log line, (b) emits `toolCallEnd(ok: false, ...)`, (c) throws `ConfirmationError.timedOut` — semantically equivalent to `.deny` for the orchestrator's exception-handling path (Plan 04-04 already translates thrown errors to `.toolCardUpdate(.failed)`). Test `test_OC_T1_timeoutLogsWarning` (in Task 3) explicitly asserts the WARNING log line. The orchestrator's history records both `.deny` and `.timeout` as `toolCallEnd(ok: false)` rows; from history's perspective they are equivalent. |
</threat_model>

<verification>
1. `cd packages/MCP && swift test` — all of these test classes report green: `ConfirmationBrokerTests` (9 tests, Task 1), `ConfirmationPresenter` build-only (Task 2 — no dedicated unit tests, exercised via broker), `ConfirmingToolDispatcherTests` (9 tests, Task 3 — INCLUDING `test_OC_T1_timeoutLogsWarning`).
2. `bash scripts/check-no-modal-presentation.sh` exits 0 against the current repo. `bash scripts/check-no-modal-presentation.sh --fixture scripts/test-fixtures/allowed-non-modal-call.swift` exits 0. `! bash scripts/check-no-modal-presentation.sh --fixture scripts/test-fixtures/forbidden-modal-call.swift` succeeds (lint correctly rejects the violator fixture with exit code 1).
3. `xcodegen generate && xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Debug build` reports BUILD SUCCEEDED with the new preBuildScript "Check no modal presentation" running before verify-entitlements.
4. Grep gates:
   - `grep -c 'awaitingApproval' packages/MCP/Sources/MCP/ConfirmingToolDispatcher.swift` returns >= 1 (the seal literal is in source).
   - `grep -c 'BoundedAsyncChannel' App/Replay/ReplayingToolResultObserver.swift` returns >= 1 (the comment-block reference documenting ME-04 closure — OR moved to AppDelegate.swift if the observer file is at `App/MCP/ReplayingToolResultObserver.swift` per Task 4's chosen path; the executor confirms the actual file path matches `files_modified`).
   - `grep -c 'capacity: 2048' App/AppDelegate.swift` returns >= 1 (the orch→replay channel is instantiated in production code, closing ME-04).
   - `grep -c 'ConfirmingToolDispatcher' App/MCP/MCPRuntimeWiring.swift` returns >= 1 (runtime wires the gated dispatcher).
   - `grep -c 'guard req.resolved == false' packages/MCP/Sources/MCP/ConfirmationBroker.swift` returns 1 (Task 1 FSM first-write-wins guard).
   - `grep -c 'beginSheet(' packages/MCP/Sources/MCP/ConfirmationPresenter.swift` returns >= 1 (sanctioned non-blocking modal-equivalent path).
   - `grep -E 'runModal\b|beginModalSession\b' packages/MCP/Sources/MCP/ConfirmationPresenter.swift | wc -l` returns 0 (presenter holds zero forbidden modal calls).
   - `grep -c 'check-no-modal-presentation' project.yml` returns >= 1 (lint is wired into the build).
5. Phase 4 regression: `swift test --package-path packages/AgentCore` reports 131/131 green (Plan 04-05 baseline preserved — no orchestrator-source changes in this plan).
</verification>

<success_criteria>
- **MCP-04 closed:** Confirmation prompts use a native AppKit `NSPanel.beginSheet` path with ZERO modal-session calls anywhere on a @MainActor presentation surface. Build-time lint regression-guards. Args are sealed pre-approval (`{"awaitingApproval":true}`) and only revealed post-approval via the sanitizer.
- **MCP-09 closed:** ConfirmationBroker FSM resolves exactly once per request id. Late hops on any of the four outcomes (.approve / .deny / .timeout / .barge) are silent no-ops. The actor's serial executor + `resolved` guard make multi-resolve impossible.
- **AGENT-11 closed:** 60-second timeout via `Task.sleep(for: .seconds(60))` with deterministic test injection (sub-second timeout for unit tests). `.timeout` outcomes are semantically equivalent to `.deny` (synthesized deny per ROADMAP SC-3) — logged at WARNING severity to `JarvisLogChannel.mcp`, emitted as `toolCallEnd(ok: false)` to the bus, thrown as `ConfirmationError.timedOut` to the orchestrator. Test `test_OC_T1_timeoutLogsWarning` asserts the WARNING log line.
- **ME-04 closed (Plan 04-05 deferred state):** AppDelegate INSTANTIATES `BoundedAsyncChannel(capacity: 2048, policy: .dropOldest)` for the orch→replay seam in production code, AND wires `ReplayingToolResultObserver` so SEC-07 captures both pre- and post-sanitize bytes for every dispatch. The 2048-capacity channel that Plan 04-05's CT2 only verified as a primitive is now a production instance.
- **End-to-end:** A user types "run an AppleScript that opens Safari" → orchestrator proposes the tool call → bus emits `toolCallStart(argsPreview: "{\"awaitingApproval\":true}")` → ring goes amber (.awaitingConfirmation) → AppKit sheet appears with sanitized script source preview → user approves → bus emits follow-up sanitized argsPreview → script runs in mcp-applescript helper → sanitized result lands in history. Deny / timeout (60s) / barge each surface as `toolCallEnd(ok: false)` with the matching reason and never invoke the inner dispatcher.
</success_criteria>

<output>
Write `.planning/phases/05-mcp/05-05-SUMMARY.md` per `~/.claude/get-shit-done/templates/summary.md`. Highlights:
- `requirements-completed: [MCP-04, MCP-09, AGENT-11]` — three Phase 5 requirements closed by this plan.
- `defers-closed: [ME-04]` — the orch→replay 2048-cap channel is now instantiated in production (Plan 04-05 deferred state resolved). Mention this prominently — checkers / future plans can stop tracking ME-04.
- `key-decisions:`
  - ConfirmationBroker uses an actor with a `resolved` flag for first-write-wins; no atomics, no locks. The actor's serial executor IS the synchronization primitive.
  - ConfirmingToolDispatcher composes around MCPToolDispatcher (both conform to `ToolDispatcher`) — Plan 04-04's orchestrator code is unchanged.
  - `.timeout` is treated as semantically equivalent to `.deny` (synthesized deny per ROADMAP SC-3); WARNING log line preserves the distinction in observability.
  - argsPreview seal is the broker-side primary defense for MCP-04; HUD's Plan 03-04 hide-when-awaiting rule is defense-in-depth.
  - Modal-lint allowlist: exactly two files (`App/TCC/TCCAlertService.swift`, `packages/MCP/Sources/MCP/ConfirmationPresenter.swift`). Adding to the allowlist requires a checkpoint.
- Confirm Phase 4 regression: `swift test --package-path packages/AgentCore` 131/131 green; no orchestrator-source changes.
- Document the AppDelegate wiring shape for future plans that consume the runtime (`self.mcpRuntime: MCPRuntime`, `self.agentOrchestrator: AgentOrchestrator`).
- Note the `ConfirmationPresenterHolder` indirection: resolves the broker↔presenter cyclic init order. A future plan that flips this (presenter-first init) MUST audit the cycle.
</output>
