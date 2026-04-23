---
phase: 04-agent-core
plan: 05
type: execute
wave: 4
depends_on: [01, 02, 03, 04]
files_modified:
  - packages/DevOverlay/Package.swift
  - packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift
  - packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift
  - packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift
  - packages/DevOverlay/Sources/DevOverlay/DevSnapshot.swift
  - packages/DevOverlay/Sources/DevOverlay/ToolCallRow.swift
  - packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift
  - packages/DevOverlay/Tests/DevOverlayTests/DevSnapshotTests.swift
  - packages/DevOverlay/Tests/DevOverlayTests/DevOverlayViewModelTests.swift
  - packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBridgeTests.swift
  - packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift
  - packages/AgentCore/Tests/AgentCoreTests/TextInputEndToEndTests.swift
  - packages/AgentCore/Tests/AgentCoreTests/ChannelTopologyTests.swift
autonomous: true
requirements: [OBS-01, AGENT-10, TEXT-01]
must_haves:
  truths:
    - "packages/DevOverlay exists as a new SPM package with a single library product (DevOverlay); depends on AgentCore + JarvisLogging"
    - "DevSnapshot struct carries: current TurnState, current provider+model, input/output/cache_creation/cache_read token counts, ttfb_ms + total_ms latency, last 5 ToolCallRow entries"
    - "DevOverlayView renders the full surface from research §9: state row, provider row, token counts row, cache row with hit percentage, latency row, last-5 tool calls table with [show] expansion"
    - "DevOverlayViewModel is @Observable @MainActor final class with a single write path: the DevSnapshot channel subscriber Task; UI never mutates state directly"
    - "DevSnapshot channel is a BoundedAsyncChannel with capacity 32, policy .dropOldest (DevOverlay is observational — stale snapshots are fine) — AGENT-10 compliance"
    - "DevSnapshotEmitter (in AgentCore) subscribes to OrchestratorEvent.events and produces DevSnapshot updates at each state change + turn boundary + usage event"
    - "DevOverlayWindow is an NSPanel with .floating level + .nonactivating + transparent background; hidden by default; toggled via a method call (menu-bar wiring is Plan 01-04's concern — Plan 04-05 just exposes the toggle)"
    - "Channel topology load test verifies the AGENT-10 four-seam invariant: provider→orch (unbounded via URLSession backpressure), orch→bus (256 suspend), orch→replay (2048 drop-oldest for tokenDelta only), orch→devoverlay (32 drop-oldest) — all bounded, correct drop policies"
    - "TEXT-01 text-input end-to-end: submit(TurnInput.text('what time is it')) → MockLLMProvider scripts a turn with one get_time tool_use → orchestrator dispatches via a mock ToolDispatcher that returns '22:57 UTC' → model scripts a final textDelta response → the full token sequence is captured in the test and matches expected"
    - "TEXT-01 proves: voice path and text path share the exact same orchestrator entry; the only difference is TurnInput.source (.text vs .voice) — headless text fixture runs the full loop with zero UI dependency"
  artifacts:
    - path: "packages/DevOverlay/Package.swift"
      provides: "SPM manifest for DevOverlay package; depends on AgentCore + JarvisLogging"
      contains: "DevOverlay"
    - path: "packages/DevOverlay/Sources/DevOverlay/DevSnapshot.swift"
      provides: "The @Observable state bag rendered by DevOverlayView (OBS-01)"
      contains: "DevSnapshot"
    - path: "packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift"
      provides: "SwiftUI view rendering the full OBS-01 surface per research §9"
      contains: "Last 5 tool calls"
    - path: "packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift"
      provides: "NSPanel wrapper with .floating level + .nonactivating + transparent background"
      contains: "NSPanel"
    - path: "packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift"
      provides: "Bridge between OrchestratorEvent stream and DevSnapshot channel; aggregates token/latency/tool-call state into snapshots"
      contains: "DevSnapshot"
    - path: "packages/AgentCore/Tests/AgentCoreTests/TextInputEndToEndTests.swift"
      provides: "TEXT-01 headless proof — text turn runs end-to-end via MockLLMProvider + MockToolDispatcher"
      contains: "text-input"
    - path: "packages/AgentCore/Tests/AgentCoreTests/ChannelTopologyTests.swift"
      provides: "AGENT-10 four-seam bounded-channel invariant verification under load"
      contains: "channel topology"
  key_links:
    - from: "packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift"
      to: "packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift"
      via: "Subscribes to BoundedAsyncChannel<OrchestratorEvent> from AgentOrchestrator.events; produces DevSnapshot"
      pattern: "OrchestratorEvent"
    - from: "packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift"
      to: "packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift"
      via: "Subscribes to BoundedAsyncChannel<DevSnapshot>; updates @Observable state"
      pattern: "DevSnapshot"
    - from: "packages/AgentCore/Tests/AgentCoreTests/TextInputEndToEndTests.swift"
      to: "packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift"
      via: "TurnInput.text(...) submitted to orchestrator; captures emitted OrchestratorEvents"
      pattern: "submit.*TurnInput.text"
---

<objective>
Close Phase 4 by delivering the observability layer (`packages/DevOverlay`, OBS-01), the channel-topology verification for AGENT-10, and the headless text-input end-to-end proof for TEXT-01. All three ride on the orchestrator from Plan 04-04.

Purpose: Plan 04-04 emits `OrchestratorEvent`s into a bounded channel but has no subscribers. This plan wires three subscribers:
1. **DevOverlay** (OBS-01) — SwiftUI overlay window driven by a `DevSnapshotEmitter` that aggregates orchestrator events into periodic snapshots.
2. **Channel-topology test** (AGENT-10) — verifies all four inter-subsystem seams are bounded with correct drop policies under load.
3. **Text-input E2E** (TEXT-01) — proves a full turn runs through the orchestrator headlessly via MockLLMProvider + MockToolDispatcher, demonstrating that voice and text share the same entry point (only TurnInput.source differs).

Phase 4's ROADMAP says observability lands WITH the orchestrator, not after. This plan makes that real: DevOverlay is shippable at the end of P4, not deferred to P8. The shipping gate (OBS-03 replay oracle, OBS-04 eval matrix) is still P8; this plan delivers the live-turn observability surface that developers use during P5-P7.

**Scope note:** ~13 files, within threshold. Three tasks: Task 1 = DevOverlay package + SwiftUI surface + ViewModel; Task 2 = DevSnapshotEmitter in AgentCore; Task 3 = TEXT-01 headless E2E + AGENT-10 channel-topology load test.

Wave 4 — depends on Plans 04-01 through 04-04. This is the final Phase-4 plan.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@CLAUDE.md
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/STATE.md
@.planning/phases/04-agent-core/04-RESEARCH.md
@.planning/phases/04-agent-core/04-01-SUMMARY.md
@.planning/phases/04-agent-core/04-02-SUMMARY.md
@.planning/phases/04-agent-core/04-03-SUMMARY.md
@.planning/phases/04-agent-core/04-04-SUMMARY.md

<interfaces>
From Plan 04-04:
```swift
public actor AgentOrchestrator {
    public let events: BoundedAsyncChannel<OrchestratorEvent>
    public func submit(_ input: TurnInput) async -> SubmitOutcome
    public func cancelAndSubmit(_ input: TurnInput) async -> SubmitOutcome
}
public enum OrchestratorEvent: Sendable {
    case stateChange(TurnState)
    case tokenDelta(turnId: TurnID, text: String)
    case thinkingDelta(turnId: TurnID, text: String)
    case toolCardUpdate(ToolCardUpdate)
    case turnEnd(turnId: TurnID, stopReason: StopReason)
    case error(turnId: TurnID, error: LLMProviderError)
}
public enum TurnState: Sendable, Equatable { case idle, booting, thinking, speaking, listening, awaitingConfirmation(ConfirmationID), reconfiguring }
public struct ToolCardUpdate: Sendable { /* phase, toolUseId, toolName, resultPreview, error */ }
```

From Plan 04-01:
- `BoundedAsyncChannel<Element>` (.suspend / .dropOldest / .dropNewest)
- `TurnID`, `TurnUsage` (usage includes cache_creation_input_tokens / cache_read_input_tokens)
- `MockLLMProvider` (now promoted: the test target from Plan 04-04 already has it; this plan extends its script vocabulary)

From Plan 04-03:
- `TokenDeltaDropOldestChannel`
- `ReplayLog` (consumed indirectly via orchestrator; this plan does not write to replay directly)

This plan ESTABLISHES (consumed in Phase 5+ and by the app shell):

- `DevSnapshot` struct — atomic state bag for the overlay.
- `DevOverlayViewModel` — `@Observable @MainActor final class`.
- `DevOverlayView` — SwiftUI view.
- `DevOverlayWindow` — NSPanel wrapper.
- `DevOverlayBridge` — connects the orchestrator's DevSnapshot channel to the viewmodel.
- `DevSnapshotEmitter` (in AgentCore) — aggregates OrchestratorEvent stream into periodic DevSnapshot updates.
- `MockToolDispatcher` test helper (internal to AgentCoreTests).
</interfaces>

<codebase_patterns>
- Swift 6 strict concurrency + `.swiftLanguageMode(.v6)`.
- @Observable for SwiftUI view models (macOS 14+ / iOS 17+ Observation framework). Macros live on the class declaration.
- NSPanel-based overlay window on macOS: .floating level, .nonactivating style mask, `isOpaque = false`, `hasShadow = false` (or true — developer preference; docs §9 doesn't specify, default to true for visual depth).
- MainActor isolation: the ViewModel is @MainActor; the DevSnapshot channel subscriber lives in a `Task { @MainActor in for await snap in channel { self.snap = snap } }`.
- Test doubles: MockToolDispatcher is a small actor implementing `ToolDispatcher` with a scripted response map.
- macOS 13 platform floor from Phase 1; DevOverlay can use macOS 14 features via `@available(macOS 14.0, *)` wrapped calls if needed — but `@Observable` is macOS 14 / Swift 5.9+. Verify deployment target; if Phase 1 is macOS 13, `DevOverlay` can raise its floor to macOS 14 since it's purely optional (menu-bar toggle; developer-facing).
</codebase_patterns>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: packages/DevOverlay — SwiftUI overlay window + view model + DevSnapshot</name>
  <files>
    packages/DevOverlay/Package.swift,
    packages/DevOverlay/Sources/DevOverlay/DevSnapshot.swift,
    packages/DevOverlay/Sources/DevOverlay/ToolCallRow.swift,
    packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift,
    packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift,
    packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift,
    packages/DevOverlay/Sources/DevOverlay/DevOverlayBridge.swift,
    packages/DevOverlay/Tests/DevOverlayTests/DevSnapshotTests.swift,
    packages/DevOverlay/Tests/DevOverlayTests/DevOverlayViewModelTests.swift,
    packages/DevOverlay/Tests/DevOverlayTests/DevOverlayBridgeTests.swift
  </files>
  <behavior>
    - Test DS1 (DevSnapshotTests): `DevSnapshot.initial` returns a snapshot with `state == .idle`, turnId == nil, all token counts 0, ttfbMs 0, totalMs 0, toolCalls empty.
    - Test DS2 (DevSnapshotTests): `DevSnapshot.cacheHitPercentage` returns 0 when cacheReadInputTokens == 0 AND cacheCreationInputTokens == 0; returns cacheReadInputTokens / (cacheReadInputTokens + cacheCreationInputTokens) × 100 otherwise.
    - Test DS3 (DevSnapshotTests): `ToolCallRow` carries toolUseId, toolName, durationMs, status (pending/running/completed/failed/awaitingApproval), preview (String?).
    - Test DS4 (DevSnapshotTests): `DevSnapshot` is Sendable + Equatable (synthesized); two snapshots with identical fields compare equal.
    - Test VM1 (DevOverlayViewModelTests): ViewModel initializes with `snapshot == DevSnapshot.initial`.
    - Test VM2 (DevOverlayViewModelTests): Applying a `DevSnapshot` with 2 tool calls updates viewModel.snapshot; a subsequent apply with 3 DIFFERENT tool calls updates to show the most recent 5 (circular buffer behavior); a 6th apply with an additional call drops the oldest one.
    - Test VM3 (DevOverlayViewModelTests): `.apply(newSnapshot)` runs on @MainActor; test uses `MainActor.run` + XCTestExpectation.
    - Test VM4 (DevOverlayViewModelTests): ViewModel subscribes to a `BoundedAsyncChannel<DevSnapshot>`; when channel yields 5 snapshots, viewModel's `snapshot` property ends up equal to the 5th.
    - Test BR1 (DevOverlayBridgeTests): `DevOverlayBridge.attach(channel:viewModel:)` spawns a subscriber task; cancelling the task stops updates (no stale snapshot after cancel).
    - Test BR2 (DevOverlayBridgeTests): Bridge does not leak tasks — after `detach()`, the subscriber task is cancelled and a new channel-send does not reach the viewModel.
  </behavior>
  <action>
Create `packages/DevOverlay/Package.swift`:
- swift-tools-version:6.0
- macOS 14 platform floor (Observation framework). Document in a comment: "macOS 14+ for @Observable — raises the floor vs Phase 1's macOS 13 but this package is dev-only; the app target stays at macOS 13."
- One library product `DevOverlay`.
- Dependencies: `../AgentCore` (for TurnState, TurnID, ToolCardUpdate, BoundedAsyncChannel, OrchestratorEvent), `../Logging` (JarvisLogging).
- Target name `DevOverlay` + test target `DevOverlayTests`.
- Swift language mode v6 on every target.

**`DevSnapshot.swift`**:

```swift
import Foundation
import AgentCore

public struct DevSnapshot: Sendable, Equatable {
    public let state: TurnState
    public let turnId: TurnID?
    public let provider: String        // e.g., "anthropic" or "ollama"
    public let modelId: String         // e.g., "claude-opus-4-7"
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
    public let ttfbMs: Int
    public let totalMs: Int
    public let toolCalls: [ToolCallRow]   // last 5

    public var cacheHitPercentage: Double {
        let total = cacheReadInputTokens + cacheCreationInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total) * 100.0
    }

    public static let initial = DevSnapshot(
        state: .idle, turnId: nil, provider: "", modelId: "",
        inputTokens: 0, outputTokens: 0,
        cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
        ttfbMs: 0, totalMs: 0,
        toolCalls: []
    )

    public init(...) { /* memberwise */ }
}
```

**`ToolCallRow.swift`**:

```swift
import Foundation

public struct ToolCallRow: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable { case pending, running, completed, failed, awaitingApproval }
    public let id: String           // toolUseId
    public let name: String
    public let status: Status
    public let durationMs: Int
    public let preview: String?
}
```

**`DevOverlayViewModel.swift`**:

```swift
import Foundation
import Observation
import AgentCore

@MainActor
@Observable
public final class DevOverlayViewModel {
    public var snapshot: DevSnapshot

    public init(snapshot: DevSnapshot = .initial) {
        self.snapshot = snapshot
    }

    public func apply(_ newSnapshot: DevSnapshot) {
        // Maintain last-5 circular buffer behavior: the snapshot already carries
        // only the last 5 tool calls (DevSnapshotEmitter is responsible for the
        // windowing). ViewModel just overwrites.
        self.snapshot = newSnapshot
    }

    public func reset() {
        self.snapshot = .initial
    }
}
```

**`DevOverlayView.swift`** — SwiftUI surface per research §9:

```swift
import SwiftUI
import AgentCore

public struct DevOverlayView: View {
    @State public var viewModel: DevOverlayViewModel

    public init(viewModel: DevOverlayViewModel) {
        self._viewModel = State(wrappedValue: viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("State:"); Text(String(describing: viewModel.snapshot.state)).bold(); Spacer(); Text("Turn:"); Text(viewModel.snapshot.turnId?.rawValue.prefix(6) ?? "—").monospaced() }
            HStack { Text("Provider:"); Text("\(viewModel.snapshot.provider) / \(viewModel.snapshot.modelId)").monospaced() }
            HStack { Text("Input:"); Text("\(viewModel.snapshot.inputTokens) tok").monospaced(); Text("Output:"); Text("\(viewModel.snapshot.outputTokens) tok").monospaced() }
            HStack { Text("Cache creation:"); Text("\(viewModel.snapshot.cacheCreationInputTokens) tok").monospaced() }
            HStack { Text("Cache read:"); Text("\(viewModel.snapshot.cacheReadInputTokens) tok").monospaced(); Text(String(format: "(%.0f%% hit)", viewModel.snapshot.cacheHitPercentage)).monospaced() }
            HStack { Text("Latency:"); Text("ttfb=\(viewModel.snapshot.ttfbMs)ms").monospaced(); Text("total=\(viewModel.snapshot.totalMs)ms").monospaced() }
            Divider()
            Text("Last 5 tool calls:").bold()
            ForEach(viewModel.snapshot.toolCalls) { row in
                HStack {
                    Text(row.name).monospaced()
                    Text("\(row.durationMs)ms").monospaced()
                    Text(symbolForStatus(row.status))
                    Spacer()
                    Text(row.preview.map { String($0.prefix(30)) } ?? "—").foregroundColor(.secondary).monospaced()
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 460, alignment: .leading)
        .background(.regularMaterial)
    }

    private func symbolForStatus(_ s: ToolCallRow.Status) -> String {
        switch s {
        case .pending: return "⏸"
        case .running: return "…"
        case .completed: return "✓"
        case .failed: return "✗"
        case .awaitingApproval: return "?"
        }
    }
}
```

**`DevOverlayWindow.swift`** — NSPanel wrapper:

```swift
#if canImport(AppKit)
import AppKit
import SwiftUI

@MainActor
public final class DevOverlayWindow {
    private let panel: NSPanel
    public let viewModel: DevOverlayViewModel

    public init() {
        self.viewModel = DevOverlayViewModel()
        let contentRect = NSRect(x: 0, y: 0, width: 460, height: 320)
        let styleMask: NSWindow.StyleMask = [.titled, .utilityWindow, .nonactivatingPanel, .closable]
        let p = NSPanel(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.title = "Jarvis DevOverlay"
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: DevOverlayView(viewModel: viewModel))
        p.orderOut(nil)   // hidden by default
        self.panel = p
    }

    public func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }

    public func toggle() {
        if isVisible { hide() } else { show() }
    }
}
#endif
```

**`DevOverlayBridge.swift`** — connects the orchestrator's DevSnapshot channel to the ViewModel:

```swift
import Foundation
import AgentCore

@MainActor
public final class DevOverlayBridge {
    private var subscriberTask: Task<Void, Never>?
    private weak var viewModel: DevOverlayViewModel?

    public init(viewModel: DevOverlayViewModel) {
        self.viewModel = viewModel
    }

    public func attach(channel: BoundedAsyncChannel<DevSnapshot>) {
        let task = Task { [weak viewModel, channel] in
            for await snap in channel {
                guard !Task.isCancelled else { break }
                await MainActor.run { viewModel?.apply(snap) }
            }
        }
        self.subscriberTask = task
    }

    public func detach() {
        subscriberTask?.cancel()
        subscriberTask = nil
    }

    deinit {
        subscriberTask?.cancel()
    }
}
```

Note: `BoundedAsyncChannel<DevSnapshot>` requires DevSnapshot to be Sendable (it is). The capacity for this channel is 32 with `.dropOldest` — configured at the call site (Plan 04-04 orchestrator provides it to consumers via a getter OR the emitter in Task 2 creates it).

Tests per `<behavior>` DS1-DS4 + VM1-VM4 + BR1-BR2.

Commit: `feat(04-05): DevOverlay package — NSPanel + SwiftUI view + @Observable view model (OBS-01)`.
  </action>
  <verify>
    <automated>cd packages/DevOverlay && swift build 2>&1 | tee /tmp/build-04-05-t1.log && swift test 2>&1 | tee /tmp/test-04-05-t1.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-05-t1.log</automated>
  </verify>
  <done>
    - `cd packages/DevOverlay && swift build` exits 0.
    - `cd packages/DevOverlay && swift test` exits 0 with 10 tests passing.
    - `grep -c 'NSPanel' packages/DevOverlay/Sources/DevOverlay/DevOverlayWindow.swift` at least 1.
    - `grep -c '@Observable' packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift` at least 1.
    - `grep -c '@MainActor' packages/DevOverlay/Sources/DevOverlay/DevOverlayViewModel.swift` at least 1.
    - `grep -c 'Last 5 tool calls' packages/DevOverlay/Sources/DevOverlay/DevOverlayView.swift` at least 1.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: DevSnapshotEmitter — aggregates OrchestratorEvent stream into DevSnapshot updates</name>
  <files>
    packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift,
    packages/AgentCore/Tests/AgentCoreTests/DevSnapshotEmitterTests.swift
  </files>
  <behavior>
    - Test DE1 (DevSnapshotEmitterTests): Emitter starts with `DevSnapshot.initial` state. After receiving one `.stateChange(.thinking)` OrchestratorEvent, emits a DevSnapshot with `state == .thinking`.
    - Test DE2 (DevSnapshotEmitterTests): After receiving 3 `.tokenDelta` events with a `.usage(TurnUsage(inputTokens: 100, outputTokens: 42, cacheCreationInputTokens: 0, cacheReadInputTokens: 0))` synthesized from orchestrator (the usage flows from LLMEvent.usage via orchestrator event forwarding), the emitted DevSnapshot carries outputTokens: 42.
    - Test DE3 (DevSnapshotEmitterTests): Cache hit ratio — a snapshot carrying inputTokens: 100, cacheReadInputTokens: 60, cacheCreationInputTokens: 40 has cacheHitPercentage = 60.0.
    - Test DE4 (DevSnapshotEmitterTests): Last-5 circular buffer — after 7 .toolCardUpdate events (each with distinct toolUseId), the emitted DevSnapshot's toolCalls array contains the last 5 (by ID, in order of most-recent-appended).
    - Test DE5 (DevSnapshotEmitterTests): Latency — emitter records ttfbMs as the time between .stateChange(.thinking) and the first .tokenDelta (within ±20ms tolerance using a test clock); totalMs is the time between .stateChange(.thinking) and .turnEnd.
    - Test DE6 (DevSnapshotEmitterTests): `.turnEnd` causes a final DevSnapshot with the terminal state (idle) and recorded totals; the emitter does NOT crash on multiple .turnEnd events (idempotent).
  </behavior>
  <action>
Since this file lives inside `packages/AgentCore/Sources/AgentCore/` but references `DevSnapshot` + `ToolCallRow` which are defined in `packages/DevOverlay/Sources/DevOverlay/`, we face a dep-direction problem: AgentCore → DevOverlay creates a cycle because DevOverlay already depends on AgentCore.

**Resolution:** Define `DevSnapshot` and `ToolCallRow` in **AgentCore**, not DevOverlay. DevOverlay just re-exports them via the view layer. Adjust Task 1: move `DevSnapshot.swift` and `ToolCallRow.swift` from `packages/DevOverlay/Sources/DevOverlay/` to `packages/AgentCore/Sources/AgentCore/`. DevOverlay imports AgentCore to get them.

Add this to the plan's `files_modified` adjustment: during execution, the agent should recognize the dep-cycle and move those two files. The plan's file paths above are updated in the frontmatter on re-read.

**`DevSnapshotEmitter.swift`**:

```swift
import Foundation

public actor DevSnapshotEmitter {
    public let output: BoundedAsyncChannel<DevSnapshot>   // capacity 32, .dropOldest

    private var current: DevSnapshot = .initial
    private var thinkingStartedAt: ContinuousClock.Instant?
    private var firstTokenAt: ContinuousClock.Instant?
    private let clock: ContinuousClock
    private var toolCallsRing: [ToolCallRow] = []   // maintains max 5 entries
    private var subscriberTask: Task<Void, Never>?

    public init(clock: ContinuousClock = .continuous) {
        self.output = BoundedAsyncChannel<DevSnapshot>(capacity: 32, policy: .dropOldest)
        self.clock = clock
    }

    /// Drives the emitter from a BoundedAsyncChannel<OrchestratorEvent>.
    public func subscribe(to events: BoundedAsyncChannel<OrchestratorEvent>) {
        let task = Task { [weak self] in
            for await event in events {
                guard let self = self else { break }
                await self.apply(event)
            }
        }
        subscriberTask = task
    }

    public func apply(_ event: OrchestratorEvent) async {
        switch event {
        case .stateChange(let state):
            if case .thinking = state, thinkingStartedAt == nil {
                thinkingStartedAt = clock.now
            }
            current = current.with(state: state)

        case .tokenDelta(let turnId, _):
            if firstTokenAt == nil, let start = thinkingStartedAt {
                firstTokenAt = clock.now
                let ttfb = Int((clock.now - start).components.seconds * 1000 + (clock.now - start).components.attoseconds / 1_000_000_000_000_000)
                current = current.with(turnId: turnId, ttfbMs: ttfb)
            } else {
                current = current.with(turnId: turnId)
            }

        case .thinkingDelta: break    // covered by provider-level thinking; not surfaced in DevOverlay in P4

        case .toolCardUpdate(let upd):
            let row = ToolCallRow(
                id: upd.toolUseId, name: upd.toolName,
                status: mapStatus(upd.phase),
                durationMs: 0,   // TODO: track per-tool duration in Task 3 polish
                preview: upd.resultPreview
            )
            // Circular buffer behavior: keep only last 5, dedupe by id (latest wins).
            if let idx = toolCallsRing.firstIndex(where: { $0.id == row.id }) {
                toolCallsRing[idx] = row
            } else {
                toolCallsRing.append(row)
            }
            while toolCallsRing.count > 5 { toolCallsRing.removeFirst() }
            current = current.with(toolCalls: toolCallsRing)

        case .turnEnd(let turnId, let reason):
            if let start = thinkingStartedAt {
                let total = Int((clock.now - start).components.seconds * 1000)
                current = current.with(turnId: turnId, totalMs: total, state: .idle)
            } else {
                current = current.with(turnId: turnId, state: .idle)
            }
            thinkingStartedAt = nil
            firstTokenAt = nil

        case .error(let turnId, _):
            current = current.with(turnId: turnId, state: .idle)
        }
        await output.send(current)
    }

    private func mapStatus(_ phase: ToolCardUpdate.Phase) -> ToolCallRow.Status {
        switch phase {
        case .pending: return .pending
        case .running: return .running
        case .awaitingApproval: return .awaitingApproval
        case .completed: return .completed
        case .failed: return .failed
        }
    }
}

extension DevSnapshot {
    func with(state: TurnState? = nil, turnId: TurnID? = nil, ttfbMs: Int? = nil, totalMs: Int? = nil, toolCalls: [ToolCallRow]? = nil) -> DevSnapshot {
        DevSnapshot(
            state: state ?? self.state,
            turnId: turnId ?? self.turnId,
            provider: self.provider, modelId: self.modelId,
            inputTokens: self.inputTokens, outputTokens: self.outputTokens,
            cacheCreationInputTokens: self.cacheCreationInputTokens,
            cacheReadInputTokens: self.cacheReadInputTokens,
            ttfbMs: ttfbMs ?? self.ttfbMs, totalMs: totalMs ?? self.totalMs,
            toolCalls: toolCalls ?? self.toolCalls
        )
    }
}
```

Note on usage tokens: `OrchestratorEvent` currently doesn't carry `.usage(TurnUsage)` — the orchestrator absorbs the LLMEvent.usage internally. To surface token counts in DevOverlay, we need to **add a new OrchestratorEvent case**: `.usage(turnId: TurnID, usage: TurnUsage)`. Add this to `OrchestratorEvent.swift` (Plan 04-04's file) in this task as a minor additive change. Update AgentOrchestrator's runTurnLoop to emit it when processing LLMEvent.usage.

**Revised OrchestratorEvent** (additive):

```swift
public enum OrchestratorEvent: Sendable {
    case stateChange(TurnState)
    case tokenDelta(turnId: TurnID, text: String)
    case thinkingDelta(turnId: TurnID, text: String)
    case toolCardUpdate(ToolCardUpdate)
    case usage(turnId: TurnID, usage: TurnUsage)   // NEW
    case turnEnd(turnId: TurnID, stopReason: StopReason)
    case error(turnId: TurnID, error: LLMProviderError)
}
```

Update the grep-gate verification for SEC-06: `grep -v '^//' packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift | grep -c 'nonce'` still equals 0 (the added `.usage` case carries `TurnUsage`, which has no nonce field).

Write `DevSnapshotEmitterTests.swift` per `<behavior>` DE1-DE6.

Commit: `feat(04-05): DevSnapshotEmitter aggregates OrchestratorEvent stream into OBS-01 snapshots`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift build 2>&1 | tee /tmp/build-04-05-t2.log && swift test --filter DevSnapshotEmitterTests 2>&1 | tee /tmp/test-04-05-t2.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-05-t2.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter DevSnapshotEmitterTests` exits 0 with 6 tests passing.
    - `cd packages/AgentCore && swift test` exits 0 overall (no regression to Plans 04-01/04-02/04-04 tests — the new `.usage` OrchestratorEvent case is additive).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift | grep -c 'toolCallsRing'` at least 2.
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift | grep -c 'case usage'` at least 1 (new case present).
    - `grep -v '^//' packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift | grep -c 'nonce'` equals 0 (SEC-06 invariant preserved).
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: TEXT-01 headless text-input E2E + AGENT-10 channel-topology load test</name>
  <files>
    packages/AgentCore/Tests/AgentCoreTests/TextInputEndToEndTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/ChannelTopologyTests.swift,
    packages/AgentCore/Tests/AgentCoreTests/MockToolDispatcher.swift
  </files>
  <behavior>
    - Test TE1 (TextInputEndToEndTests, **critical TEXT-01 proof**): Create AgentOrchestrator with MockLLMProvider scripted to yield: [.messageStart, .textDelta("Let me check. "), .toolUseRequested(id:"t1", name:"get_time", argsJSON:"{}"), .stopReason(.toolUse), .messageStop]. Then on the second provider.stream call (after tool_result): [.messageStart, .textDelta("It's "), .textDelta("22:57 "), .textDelta("UTC"), .stopReason(.endTurn), .usage(input:120, output:4, cache:{}), .messageStop]. MockToolDispatcher returns "22:57 UTC" for get_time. Submit(TurnInput.text("what time is it")). Collect all emitted OrchestratorEvents into an array. Assertions: array contains exactly 4 `.tokenDelta` events in order ("Let me check. ", "It's ", "22:57 ", "UTC"), exactly 1 `.toolCardUpdate(phase:.completed)` for get_time, exactly 1 `.turnEnd` with stopReason .endTurn, exactly 1 `.usage` event at the end.
    - Test TE2 (TextInputEndToEndTests): The replay log receives: one `turn_end` event for the single turnId (NOT two — the tool-use→tool-result loop iteration is a single turn, not two), ten events of kind `text_delta` + `tool_call_requested` + `tool_result_full` + `usage` + `stop_reason` + `turn_end`.
    - Test TE3 (TextInputEndToEndTests): `TurnInput.text("...")` and `TurnInput.voice("...")` produce IDENTICAL event sequences when the MockLLMProvider script is the same — proving the orchestrator entry is unified (TEXT-01 acceptance).
    - Test TE4 (TextInputEndToEndTests): The tool-result that reaches the model-facing LLMMessage for the second stream call is wrapped with the turnNonce — verify by inspecting `MockLLMProvider.recordedCalls[1].messages` and finding the `<UNTRUSTED_CONTENT id="..."> 22:57 UTC </UNTRUSTED_CONTENT id="...">` pattern. The nonce in the wrapper matches the nonce recorded in the replay log (via a read-back from the mock replay log).
    - Test CT1 (ChannelTopologyTests): Orchestrator's public `events: BoundedAsyncChannel<OrchestratorEvent>` has capacity 256 and policy .suspend — verify via test-hook that reads the channel's capacity/policy properties (may need to expose internal readers on BoundedAsyncChannel for this).
    - Test CT2 (ChannelTopologyTests): The replay channel inside the orchestrator is a `TokenDeltaDropOldestChannel<ReplayEventTag>` with capacity 2048 and dropTag `.tokenDelta` — verified by spinning up an orchestrator with a mock ReplayLog that counts events; firing 10000 scripted `.tokenDelta` events AND 1000 scripted `.toolUseRequested` events via MockLLMProvider; asserting the replay log received at most 2048 text_delta events and exactly 1000 tool_call_requested events (zero drops for non-tokenDelta tag).
    - Test CT3 (ChannelTopologyTests): The DevSnapshot channel has capacity 32 and policy .dropOldest — verified by firing 100 rapid OrchestratorEvents at the DevSnapshotEmitter with a stalled consumer; after resume, consumer sees at most 32 snapshots.
    - Test CT4 (ChannelTopologyTests): tool_call / turn_end / reconfiguring / confirmation events are NEVER dropped — run a stress scenario with many tokenDeltas interspersed with 5 tool_calls, 3 turn_ends, 2 reconfigure state changes, 1 confirmation (synthesized); assert all 11 non-tokenDelta events are delivered.
  </behavior>
  <action>
**`MockToolDispatcher.swift`** (test helper, internal):

```swift
@testable import AgentCore
import Foundation

actor MockToolDispatcher: ToolDispatcher {
    private var scripts: [String: Data] = [:]
    private(set) var dispatchCalls: [(tool: String, args: Data)] = []

    func setResult(for toolName: String, result: Data) {
        scripts[toolName] = result
    }

    func dispatch(toolUse: ToolUseRequest) async throws -> Data {
        dispatchCalls.append((toolUse.name, toolUse.argsJSON))
        guard let r = scripts[toolUse.name] else {
            throw MockToolError.noScript(toolUse.name)
        }
        return r
    }

    nonisolated func requiresConfirmation(toolName: String) -> Bool { false }
}

enum MockToolError: Error { case noScript(String) }
```

**`TextInputEndToEndTests.swift`** — implements TE1-TE4 per `<behavior>`:

- `setUp()` creates a temp DB for ReplayLog, an in-memory ConfigStore with default PerTurnSnapshot, a MockLLMProvider with a scripted two-call sequence, a MockToolDispatcher with "22:57 UTC" registered for "get_time".
- Instantiates AgentOrchestrator with these doubles.
- Collects OrchestratorEvents from `orchestrator.events` into an array (via a spawned Task that drains the channel until it sees .turnEnd).
- Submits via `await orchestrator.submit(TurnInput.text("what time is it"))`.
- After turnEnd, asserts the event sequence, the replay log contents, and the nonce-wrapping.

TE3 re-runs the same scenario with `TurnInput.voice(...)` and asserts byte-identical OrchestratorEvent sequence (modulo turnId which is fresh per turn — use a field-by-field comparator that excludes turnId).

TE4 uses `mockLLM.getRecordedCalls()` to inspect the second `provider.stream` call's messages. Finds the .tool role message with .toolResult content. Regex-checks for `<UNTRUSTED_CONTENT id="[A-Za-z0-9_-]+">...22:57 UTC...</UNTRUSTED_CONTENT id="[A-Za-z0-9_-]+">`. Extracts the nonce string from the regex. Queries the mock replay log for the turn's turn_nonce column. Asserts they match.

**`ChannelTopologyTests.swift`** — implements CT1-CT4:

- CT1: Access `orchestrator.events` property; assert its capacity + policy via exposed `BoundedAsyncChannel.capacity` (add a public `let capacity: Int` + `let policy: Policy` getter to BoundedAsyncChannel if not already present — minor additive change to Plan 04-01's file).
- CT2: Spin up orchestrator + mock ReplayLog counter; script MockLLMProvider to yield 10000 tokenDeltas interspersed with 1000 tool_uses (use throttle=0 for max throughput); submit one turn; after completion, assert replay counter shows ≤ 2048 `text_delta` events + exactly 1000 `tool_call_requested` events.
- CT3: Separate test against DevSnapshotEmitter — construct emitter + a consumer Task that sleeps 50ms between each `for await`; fire 100 OrchestratorEvents at the emitter; sleep 200ms; resume consumer; assert ≤ 32 snapshots seen.
- CT4: Single stress scenario with mixed event types; asserts non-tokenDelta events are never lossy.

**Minor additive change to Plan 04-01's `BoundedAsyncChannel.swift`**: expose `public let capacity: Int` + `public nonisolated let policy: Policy` for topology introspection. This is a clean additive change.

Write up the test files with comprehensive fixture setup. Each test cleans up its DB path in `tearDown`.

Commit: `test(04-05): TEXT-01 headless E2E proof + AGENT-10 channel-topology load test (final P4 gates)`.
  </action>
  <verify>
    <automated>cd packages/AgentCore && swift test --filter TextInputEndToEndTests --filter ChannelTopologyTests 2>&1 | tee /tmp/test-04-05-t3.log && cd /Users/james.maes/Git.Local/Kof22/Jarvis/packages/AgentCore && swift test 2>&1 | tee /tmp/test-04-05-t3-full.log && cd /Users/james.maes/Git.Local/Kof22/Jarvis/packages/DevOverlay && swift test 2>&1 | tee /tmp/test-04-05-t3-devoverlay.log && cd /Users/james.maes/Git.Local/Kof22/Jarvis/packages/Replay && swift test 2>&1 | tee /tmp/test-04-05-t3-replay.log && grep -c "Test Suite 'All tests' passed" /tmp/test-04-05-t3-full.log</automated>
  </verify>
  <done>
    - `cd packages/AgentCore && swift test --filter TextInputEndToEndTests --filter ChannelTopologyTests` exits 0 with 8 tests passing.
    - `cd packages/AgentCore && swift test` exits 0 with ALL tests across AgentCoreTests + AnthropicProviderTests + OllamaProviderTests passing (full P4 regression suite green).
    - `cd packages/DevOverlay && swift test` exits 0 (Task 1 tests still pass after Task 2 moved DevSnapshot/ToolCallRow to AgentCore).
    - `cd packages/Replay && swift test` exits 0 (no regression).
    - End-to-end scenario proves TEXT-01: `grep -c 'TurnInput.text' packages/AgentCore/Tests/AgentCoreTests/TextInputEndToEndTests.swift` at least 1; `grep -c 'TurnInput.voice' packages/AgentCore/Tests/AgentCoreTests/TextInputEndToEndTests.swift` at least 1 (parity proof).
    - AGENT-10 load test: channels/policies verified via `grep -c 'capacity: 256' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift` at least 1; `grep -c 'capacity: 2048' packages/AgentCore/Sources/AgentCore/AgentOrchestrator.swift` at least 1; `grep -c 'capacity: 32' packages/AgentCore/Sources/AgentCore/DevSnapshotEmitter.swift` at least 1.
    - SEC-06 nonce-never-in-events invariant preserved: `grep -v '^//' packages/AgentCore/Sources/AgentCore/OrchestratorEvent.swift | grep -c 'nonce'` equals 0.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| OrchestratorEvent → DevSnapshotEmitter → DevOverlay | Dev-only surface; not bound for the webview. DevOverlay runs in the main app process as NSPanel; receives data directly. |
| DevOverlay → visual display | The DevOverlay renders tool call previews + token counts — no secrets cross this boundary because `resultPreview` is already capped at 200 chars upstream in Plan 04-04's ToolCardUpdate. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-04-05-01 | Information Disclosure | DevOverlay displays tool result previews that could contain secrets | mitigate | `resultPreview` is capped at 200 chars upstream (Plan 04-04). `Redact.apply` from JarvisLogging runs on the preview string before surfacing to DevOverlayView. Tests verify: a tool result containing "sk-ant-FAKE" is redacted to "REDACTED" in the DevOverlayView rendering (via a Redact.apply call in DevOverlayView.preview-text code path). |
| T-04-05-02 | Tampering | DevSnapshot dropped under load erases audit trail | accept | DevOverlay is observational by design (OBS-01 — "shows current state"). Stale snapshots are fine; the replay log (OBS-02) is the authoritative record. Policy is `.dropOldest` capacity 32 — tested under CT3. |
| T-04-05-03 | Denial of Service | Infinite tool-card-update loop floods DevOverlay | mitigate | DevSnapshotEmitter's tool-call buffer is capped at 5 rows; extra updates overwrite existing rows by id (dedupe-on-id). A single turn with 100 tool calls produces at most 5 rows in the final snapshot. |
| T-04-05-04 | Information Disclosure | TEXT-01 E2E test prints turn_nonce to XCTest console | mitigate | Tests use `XCTAssert*` against internal state; no nonce is logged via `print()` or `Logger.info()`. Test code review gate: grep for `print.*nonce` in TextInputEndToEndTests.swift returns 0. |
</threat_model>

<verification>
- `cd packages/DevOverlay && swift test` — 10 tests pass.
- `cd packages/AgentCore && swift test` — FULL regression suite from all four preceding plans passes (AgentCoreTests + AnthropicProviderTests + OllamaProviderTests + orchestrator tests + TEXT-01 E2E + AGENT-10 topology).
- `cd packages/Replay && swift test` — no regression.
- `cd packages/Logging && swift test` — no regression.
- `gsd-sdk query frontmatter.validate .planning/phases/04-agent-core/04-05-devoverlay-text-e2e-PLAN.md --schema plan` returns valid.
- All 14 Phase 4 requirements (AGENT-01..04, 06..10, TEXT-01, OBS-01, OBS-02, OBS-07, SEC-06) covered by tests in some file across the five plans.
</verification>

<success_criteria>
- `packages/DevOverlay` exists; SwiftUI surface renders the full OBS-01 table from research §9.
- `DevSnapshotEmitter` aggregates OrchestratorEvents into DevSnapshot updates; last-5 tool-call ring maintained.
- OrchestratorEvent gets an additive `.usage(turnId:usage:)` case (needed for DevOverlay token counts).
- TEXT-01 end-to-end proof: text and voice turns produce identical event sequences through the orchestrator (only source field differs).
- AGENT-10 channel topology verified under load: 256 suspend / 2048 drop-oldest-for-tokenDelta-only / 32 drop-oldest; tool_call / turn_end / reconfiguring / confirmation NEVER dropped.
- All Phase 4 package tests pass together in a full regression run.
</success_criteria>

<output>
After completion, create `.planning/phases/04-agent-core/04-05-SUMMARY.md` per the GSD summary template.
</output>
