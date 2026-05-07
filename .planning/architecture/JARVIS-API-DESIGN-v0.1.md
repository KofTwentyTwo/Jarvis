# Jarvis API Design — v0.1

**Status:** DRAFT for critic review (Phase 2 → Phase 3a/b/c)
**Date:** 2026-05-07
**Author:** Architect agent (swarm phase 2)
**Feeds:** REVIEW-API-CORRECTNESS.md, REVIEW-MIGRATION-RISK.md, REVIEW-TEST-CONTRACT.md

---

## 1. Goals & Non-Goals

### Goals

- Represent 100% of Jarvis behavior at a typed, transport-agnostic boundary between the Swift host and any client (webview, test harness, CLI, replay runner, eval harness).
- Every operation has an explicit success type and an explicit error type. No silent `void` returns. No `Bool` returns that hide the reason for failure.
- The schema must be expressible as JSON over `WKScriptMessageHandler` today, and as JSON-RPC / HTTP / IPC tomorrow, without changing the semantic shape.
- Every B-02..B-08 bug class is dissolved by a named API contract that would have made the failure observable at the boundary.
- CQRS-flavored: Commands mutate state and return a typed outcome; Events are server-push; Queries are read-only probes.

### Non-Goals

- Does not redesign the Swift host internals (LLM provider, voice stack, MCP runtime, SQLite schema). Those are settled.
- Does not redesign transport mechanics (WKScriptMessageHandler framing, handshake state machine). Those are settled.
- Does not define the webview rendering layer. The API defines what the webview receives, not how it renders it.
- Does not define eval harness internals. The harness uses this API as its client interface.

---

## 2. API Surfaces — Overview Table

| Surface | Concept | Commands | Events | Queries |
|---------|---------|----------|--------|---------|
| **Turn** | A single user→assistant exchange including all tool-call rounds | `submitTurn`, `cancelTurn`, `bargeIn`, `respondToConfirmation` | `turnStarted`, `tokenStreamed`, `thinkingStreamed`, `toolCallStarted`, `toolCallUpdated`, `toolCallEnded`, `confirmationRequested`, `confirmationResolved`, `turnEnded`, `turnError` | `getActiveTurn`, `listTurns` |
| **Voice** | Wake-word detection, VAD, STT, TTS, PTT, mute | `startVoice`, `shutdownVoice`, `muteWakeWord`, `unmuteWakeWord`, `pttDown`, `pttUp`, `cancelTTS`, `setTTSTier` | `voiceStateChanged`, `audioLevelChanged`, `wakeWordDetected`, `sttTranscriptPartial`, `sttTranscriptFinal`, `ttsStarted`, `ttsEnded`, `voiceDegraded` | `getVoiceState` |
| **Memory** | Persistent facts, hybrid search, session history | `forgetFact` | `factMutated`, `factsRetrieved` | `listRecentFacts`, `searchFacts`, `listTurns` |
| **Vision** | Frame attachment, camera TCC, presence | `requestFrameAttach`, `cancelFrameAttach` | `framePending`, `frameSent`, `frameExpired`, `cameraDegraded` | `getFrameAttachState` |
| **Settings** | Provider, TTS tier, STT backend, feature flags, per-turn config, API key, hotkey | `setProvider`, `setTTSTier`, `setSTTBackend`, `setFeatureFlag`, `storeAPIKey`, `setHotkey`, `setWakeWordMuted` | `settingsChanged` | `getSettings` |
| **Diagnostics** | DevSnapshot, replay log, structured log stream, state dump | `toggleDevOverlay`, `copyStateDump` | `devSnapshotUpdated`, `systemBannerEnqueued`, `systemBannerDismissed` | `getDevSnapshot`, `getStateDump` |
| **Self** | System identity, hardware enumeration, boot/TCC state | _(none)_ | `selfStateChanged`, `tccStatusChanged` | `getSelfState`, `listAudioDevices`, `listCameraDevices`, `getActiveAudioRoute` |

---

## 3. Lifecycle & Sessions

### Connection

A "session" in this API equals the process lifetime of the Swift host. There is at most one logical session active at any time, identified by a `SessionID` (UUID, created at app launch via `ReplayLog.beginSession`).

A client (webview, harness, CLI) connects by completing the handshake protocol:
1. Swift host emits `hello(version:)` immediately after webview load.
2. Client replies with `helloAck(version:)`.
3. On version match: Swift host emits `selfStateChanged` (boot state), then `settingsChanged` (current config), then the client may issue commands.
4. On version mismatch: Swift host presents a hard-block alert and terminates. This is unchanged from current behavior.

The handshake timeout is 2 seconds (unchanged). This is a transport-layer detail, not an API-level concern; the API design simply requires that a client is considered "connected" only after the handshake completes.

### Client identity & multiplexing

There is a single logical client at any given time (the WKWebView). The test harness substitutes a different transport (direct Swift actor call or IPC) but does not run simultaneously with the webview. The API does NOT need per-client fan-out, per-client subscriptions, or session tokens. Global state is global. If future multi-client use is needed, that is a v2 concern.

### State persistence across client disconnect

When the webview is hidden/dismissed but the Swift host continues running:
- The agent orchestrator continues any in-flight turn.
- Voice pipeline continues (wake-word stays active).
- Memory extraction continues.
- When the webview reconnects (next `uiReady`), the client must call `listTurns` (Query) to hydrate chat history, and query `getActiveTurn` to catch any in-flight turn. Swift does NOT re-push missed events.

This resolves the DEAD `sessionHistory` push gap (INVENTORY §2 — no production emit site for `BusOutbound.sessionHistory`). The client is responsible for fetching on connect. The server does not push a catch-up burst.

### Turn boundaries

A turn has a strict lifecycle:
1. `submitTurn` or `bargeIn` → `turnStarted` event (with `turnId`)
2. Zero or more rounds of: `tokenStreamed` | `thinkingStreamed` | `toolCallStarted` / `toolCallUpdated` / `toolCallEnded` | `confirmationRequested` / `confirmationResolved`
3. Exactly one `turnEnded` or `turnError` event.

A turn is identified by a `TurnID` (UUID string). Every event emitted during a turn carries the same `turnId`. A new `submitTurn` while a turn is in-flight returns `TurnRejected.turnInFlight` unless `bargeIn` is used.

### Turn ordering guarantees

Events for a given turn are delivered in-order. Events across concurrent turns (impossible in this design — only one turn runs at a time) are not a concern. The `OutboundBatcher` coalesces sends within a 16ms window; ordering within a turn is preserved by the Swift actor's serial executor.

---

## 4. State Ownership

| State domain | Single writer | Readers |
|---|---|---|
| Active turn (ID, phase, in-flight status) | `AgentOrchestrator` actor | Any client via `getActiveTurn` query; `turnStarted`/`turnEnded` events |
| Conversation history (session turns) | `MemoryStore` (write) + `ReplayLog` (append) | Any client via `listTurns` query |
| Voice state machine | `VoiceController` actor | Any client via `getVoiceState` query; `voiceStateChanged` events |
| HUD state (idle/listening/thinking/speaking/awaitingConfirmation) | `HudStateCoordinator` (precedence-ladder resolver) | Webview client only via `hudStateChanged` event (no query needed — always synced at connect) |
| Memory facts | `MemoryStore` actor | Any client via `listRecentFacts` / `searchFacts` queries; `factMutated` events |
| Frame attach state | `FrameAttachController` | Any client via `getFrameAttachState` query; `framePending`/`frameSent`/`frameExpired` events |
| Settings | `ConfigStore` actor | Any client via `getSettings` query; `settingsChanged` events |
| DevSnapshot | `DevSnapshotEmitter` | DevOverlay client via `devSnapshotUpdated` events; harness via `getDevSnapshot` query |
| Self/system state | `SelfStateAdapter` (read-only from hardware) | Any client via `getSelfState` query; `selfStateChanged` events |
| TCC/permission status | AppDelegate permission probes | Any client via `getSelfState` query; `tccStatusChanged` events |

**Rule:** No client writes into another client's state domain. All mutations go through the Swift host via Commands.

---

## 5. Surface Specifications

### 5.1 Turn Surface

The Turn surface owns the agent conversation loop.

#### Commands

```swift
// Start a new turn. Rejected if a turn is already in flight.
// source: "text" | "voice" | "eval" | "replay"
Command.submitTurn(
  text: String,
  source: TurnSource,      // "text" | "voice" | "eval" | "replay"
  images: [ImageRef]?      // nil = no vision; non-nil arms FrameAttachController
) -> Result<TurnAccepted, TurnRejected>

struct TurnAccepted { let turnId: TurnID }
enum TurnRejected {
  case turnInFlight(currentTurnId: TurnID)
  case providerUnavailable(reason: String)
  case configError(detail: String)
}

// Cancel any in-flight turn and immediately start a new one (barge-in).
// Always succeeds; superseded turn emits turnEnded(terminator: .superseded).
Command.bargeIn(
  text: String,
  source: TurnSource
) -> BargeInAccepted

struct BargeInAccepted {
  let supersededTurnId: TurnID?  // nil if nothing was in flight
  let newTurnId: TurnID
}

// Cancel the in-flight turn without starting a new one.
Command.cancelTurn(turnId: TurnID) -> Result<Void, CancelError>
enum CancelError { case noTurnInFlight; case turnIdMismatch }

// Respond to a tool-confirmation prompt.
Command.respondToConfirmation(
  confirmationId: ConfirmationID,
  outcome: ConfirmationResponse  // "approved" | "denied"
) -> Result<Void, ConfirmationError>
enum ConfirmationError { case noSuchConfirmation; case alreadyResolved; case timedOut }
```

#### Events

```swift
// Emitted immediately after submitTurn / bargeIn is accepted.
Event.turnStarted(
  turnId: TurnID,
  source: TurnSource,
  provider: String,          // e.g. "anthropic" | "ollama"
  modelId: String            // e.g. "claude-opus-4-7"
)

// One event per streamed token chunk.
Event.tokenStreamed(turnId: TurnID, text: String)

// Extended thinking delta (Anthropic only; clients may ignore).
Event.thinkingStreamed(turnId: TurnID, text: String)

// Tool call entering the pipeline.
Event.toolCallStarted(
  turnId: TurnID,
  callId: String,
  toolName: String,
  argsPreview: String        // partial JSON preview, ≤256 chars
)

// Args preview updated as more JSON arrives (streaming).
Event.toolCallUpdated(
  turnId: TurnID,
  callId: String,
  argsPreview: String
)

// Tool call completed or failed.
Event.toolCallEnded(
  turnId: TurnID,
  callId: String,
  ok: Bool,
  previewOrError: String     // result preview or error message, ≤256 chars
)

// A confirmation-required tool is waiting for user approval.
Event.confirmationRequested(
  turnId: TurnID,
  confirmationId: ConfirmationID,
  toolName: String,
  argsPreview: String,
  timeoutSeconds: Int        // from ConfirmationPolicy
)

// Confirmation was resolved (approved / denied / timed-out).
Event.confirmationResolved(
  turnId: TurnID,
  confirmationId: ConfirmationID,
  outcome: ConfirmationOutcome   // "approved" | "denied" | "timedOut"
)

// Turn completed normally or was cancelled/superseded.
Event.turnEnded(
  turnId: TurnID,
  terminator: TurnTerminator,    // "completed" | "cancelled" | "superseded"
  usage: TurnUsage?,             // nil on cancel/supersede
  durationMs: Int
)

struct TurnUsage {
  let inputTokens: Int
  let outputTokens: Int
  let cacheCreationTokens: Int
  let cacheReadTokens: Int
}

// Turn failed with an error (provider error, config error, etc.).
Event.turnError(
  turnId: TurnID,
  code: TurnErrorCode,
  message: String
)

enum TurnErrorCode: String {
  case providerError
  case streamTruncated
  case maxTokensExceeded
  case refusal
  case configError
  case internalError
}

// HUD display state. Separate from turn lifecycle — driven by HudStateCoordinator.
Event.hudStateChanged(
  state: HudState     // "idle"|"listening"|"thinking"|"speaking"|"awaitingConfirmation"|"reconfiguring"|"booting"
)
```

#### Queries

```swift
// Returns current in-flight turn or nil if idle.
Query.getActiveTurn() -> ActiveTurnSnapshot?

struct ActiveTurnSnapshot {
  let turnId: TurnID
  let source: TurnSource
  let phase: TurnPhase          // "running" | "awaitingConfirmation"
  let pendingConfirmationId: ConfirmationID?
  let elapsedMs: Int
  let accumulatedText: String   // all text tokens emitted so far
}

// Returns paginated turn history for the current session.
// Use this on connect to hydrate chat panel. Replaces dead BusOutbound.sessionHistory push.
Query.listTurns(
  sessionId: SessionID?,        // nil = current session
  limit: Int,                   // max 100
  beforeTurnId: TurnID?         // cursor for pagination
) -> ListTurnsResponse

struct ListTurnsResponse {
  let sessionId: SessionID
  let turns: [TurnSummary]
  let hasMore: Bool
}

struct TurnSummary {
  let turnId: TurnID
  let source: TurnSource
  let userText: String
  let assistantText: String
  let toolCalls: [ToolCallSummary]
  let terminator: TurnTerminator
  let startedAt: Date
  let durationMs: Int
}

struct ToolCallSummary {
  let callId: String
  let toolName: String
  let ok: Bool
}
```

#### Errors (surface-level)

Any command that fails synchronously (before turn starts) returns a typed error, not a silent `false`/`void`. The client must handle every error case explicitly.

---

### 5.2 Voice Surface

The Voice surface owns the audio pipeline: wake-word, VAD, STT, TTS, PTT, mute controls, and audio-level metering.

#### Commands

```swift
// Start the voice pipeline (wake-word + audio graph).
// Idempotent — safe to call if already running.
Command.startVoice() -> Result<Void, VoiceStartError>
enum VoiceStartError {
  case microphonePermissionDenied
  case audioGraphFailed(reason: String)
}

// Graceful shutdown of voice pipeline.
Command.shutdownVoice() -> Void

// Mute / unmute the always-listening wake-word detector.
Command.muteWakeWord() -> Void
Command.unmuteWakeWord() -> Void

// Push-to-talk (Input Monitoring required).
Command.pttDown() -> Result<Void, PTTError>
Command.pttUp() -> Result<Void, PTTError>
enum PTTError { case inputMonitoringDenied; case voiceNotRunning }

// Cancel any in-flight TTS synthesis.
Command.cancelTTS() -> Void

// Switch TTS tier (takes effect on next synthesis call).
Command.setTTSTier(tier: TTSTier) -> Void   // "tier1" | "tier2"
```

#### Events

```swift
// Voice state machine transition.
Event.voiceStateChanged(
  state: VoiceState,             // "idle"|"listening"|"thinking"|"speaking"|"reconfiguring"
  listeningSource: ListeningSource?  // "wakeWord"|"ptt" when state == "listening"
)

// ~30 Hz RMS update for ring animation.
Event.audioLevelChanged(rms: Float)

// Wake-word detector fired.
Event.wakeWordDetected(confidence: Float)

// Partial STT transcript (streaming hypothesis).
Event.sttTranscriptPartial(text: String)

// Final STT transcript committed; triggers turn submission.
Event.sttTranscriptFinal(
  text: String,
  turnId: TurnID     // the Turn that was submitted with this transcript
)

// TTS synthesis started for an assistant turn.
Event.ttsStarted(turnId: TurnID, tier: TTSTier, text: String)

// TTS synthesis completed or cancelled.
Event.ttsEnded(turnId: TurnID, reason: TTSEndReason)
enum TTSEndReason: String { case completed; case cancelled; case error }

// Voice pipeline degraded (AEC unavailable, mic revoked, etc.).
Event.voiceDegraded(reason: VoiceDegradationReason, bannerText: String)
enum VoiceDegradationReason: String {
  case aecUnavailable; case aecRestored; case microphoneDenied; case microphoneRevoked
}
```

#### Queries

```swift
Query.getVoiceState() -> VoiceStateSnapshot

struct VoiceStateSnapshot {
  let state: VoiceState
  let listeningSource: ListeningSource?
  let wakeWordMuted: Bool
  let ttsTier: TTSTier
  let sttBackend: STTBackend     // "speechAnalyzer" | "whisperKit"
  let isRunning: Bool
  let hasSynthInFlight: Bool
}
```

---

### 5.3 Memory Surface

The Memory surface owns persistent fact storage, hybrid search, and session history access.

#### Commands

```swift
// Mark a fact as forgotten (requires confirmation in production).
Command.forgetFact(
  factId: FactID,
  requiresConfirmation: Bool   // always true in production; false in harness
) -> Result<ForgetFactSuccess, ForgetFactError>

struct ForgetFactSuccess { let factId: FactID; let forgottenAt: Date }
enum ForgetFactError { case factNotFound; case alreadyForgotten; case confirmationDenied }
```

#### Events

```swift
// A fact was created, updated, or marked NOOP by the extractor.
Event.factMutated(
  turnId: TurnID,
  op: MemoryOp,               // "add" | "update" | "noop"
  fact: FactSnapshot?         // nil on NOOP
)

struct FactSnapshot {
  let factId: FactID
  let subject: String
  let predicate: String
  let object: String
  let validFrom: Date
  let validTo: Date?
}

// Facts were retrieved from the store (retrieval logged to replay).
Event.factsRetrieved(
  turnId: TurnID,
  factIds: [FactID],
  retrievalReason: String    // "hybridSearch" | "recentActive"
)
```

#### Queries

```swift
Query.listRecentFacts(limit: Int) -> [FactSnapshot]

Query.searchFacts(
  query: String,
  k: Int                // top-k results, max 20
) -> [FactRef]

struct FactRef {
  let fact: FactSnapshot
  let score: Float
  let matchedBy: FactMatchKind    // "fts5" | "vector" | "hybrid"
}
```

Note: `listTurns` (which hydrates chat history) lives on the Turn surface but reads from `MemoryStore.recentTurnsForSession`. This is intentional: turn history is a Turn concern, not a Memory concern. Memory's role is facts, not conversation structure.

---

### 5.4 Vision Surface

The Vision surface owns camera frame capture, frame-attach lifecycle, and camera TCC state.

#### Commands

```swift
// Arm the 5-second frame-attach window (triggered by HUD camera button or phrase detection).
Command.requestFrameAttach(
  reason: FrameAttachReason    // "hudButton" | "phraseDetected"
) -> Result<FrameAttachArmed, FrameAttachError>

struct FrameAttachArmed {
  let expiresAt: Date   // now + 5 seconds
}
enum FrameAttachError {
  case cameraPermissionDenied
  case alreadyArmed
  case turnInFlight     // can't arm during an active turn
}

// Cancel the pending frame-attach window.
Command.cancelFrameAttach() -> Void
```

#### Events

```swift
// Frame captured and held pending user text submission.
Event.framePending(capturedAt: Date)

// Frame was included in a turn submission.
Event.frameSent(turnId: TurnID)

// Frame-attach window expired without a turn submission.
Event.frameExpired()

// Camera degraded (TCC denied or revoked).
Event.cameraDegraded(reason: VisionDegradationReason)
```

#### Queries

```swift
Query.getFrameAttachState() -> FrameAttachStateSnapshot

struct FrameAttachStateSnapshot {
  let hasPendingFrame: Bool
  let armedUntil: Date?        // nil if not armed
  let cameraTCCGranted: Bool
}
```

---

### 5.5 Settings Surface

The Settings surface owns all runtime-mutable configuration. Launch-time-only config (tool blocklist, logging levels, Ollama base URL) is read-only at this surface and only exposed via `getSettings`.

#### Commands

```swift
Command.setProvider(provider: ProviderSelection) -> Void  // "anthropic" | "ollama"
Command.setTTSTier(tier: TTSTier) -> Void                 // "tier1" | "tier2"
Command.setSTTBackend(backend: STTBackend) -> Void        // "speechAnalyzer" | "whisperKit"
Command.setFeatureFlag(flag: String, enabled: Bool) -> Result<Void, FeatureFlagError>
enum FeatureFlagError { case unknownFlag }

Command.storeAPIKey(key: String) -> Result<Void, APIKeyError>
enum APIKeyError { case keychainWriteFailed(detail: String); case validationFailed(detail: String) }

Command.setHotkey(shortcut: KeyboardShortcut?) -> Result<Void, HotkeyError>
enum HotkeyError { case inputMonitoringDenied; case collision(conflictsWith: String); case bindFailed }

Command.setWakeWordMuted(muted: Bool) -> Void
```

#### Events

```swift
// Any setting changed. Client should call getSettings() to get fresh state.
Event.settingsChanged(changedKeys: [String])
```

#### Queries

```swift
Query.getSettings() -> SettingsSnapshot

struct SettingsSnapshot {
  // Per-turn (mutable at runtime)
  let provider: ProviderSelection
  let ttsTier: TTSTier
  let sttBackend: STTBackend
  let featureFlags: [String: Bool]
  // Launch-only (immutable at runtime)
  let ollamaBaseURL: String
  let toolBlocklist: [String]
  let confirmationTimeoutSeconds: Int
  let appleScriptRequiresConfirmation: Bool
  let loggingFileLevel: String
  // Wizard state
  let apiKeyStored: Bool
  let currentWizardStage: String?
  let hotkey: KeyboardShortcut?
  let wakeWordMuted: Bool
  let launchAtLoginEnabled: Bool
}
```

---

### 5.6 Diagnostics Surface

The Diagnostics surface owns the DevOverlay, state dump, and system banner queue. It is consumed by the DevOverlay window and by the test harness.

#### Commands

```swift
Command.toggleDevOverlay() -> DevOverlayState  // "visible" | "hidden"
Command.copyStateDump() -> Void               // copies JSON to clipboard; emits systemBannerEnqueued
```

#### Events

```swift
// DevSnapshot updated (emitted after every turn, on interval, or on demand).
Event.devSnapshotUpdated(snapshot: DevSnapshotPayload)

struct DevSnapshotPayload {
  let provider: String
  let modelId: String
  let inputTokens: Int
  let outputTokens: Int
  let cacheCreationTokens: Int
  let cacheReadTokens: Int
  let cacheHitPercent: Float
  let ttfbMs: Int?
  let totalTurnMs: Int?
  let lastToolCalls: [ToolCallSummary]   // last 5, capped
}

// A banner was pushed onto the banner queue.
Event.systemBannerEnqueued(
  bannerId: String,
  title: String,
  body: String,
  priority: Int
)

// Current banner was dismissed from the queue.
Event.systemBannerDismissed(bannerId: String)
```

#### Queries

```swift
Query.getDevSnapshot() -> DevSnapshotPayload   // latest snapshot; does not emit event

Query.getStateDump() -> StateDumpPayload        // same as copyStateDump but returns JSON instead of writing clipboard

struct StateDumpPayload {
  // Booleans-only diagnostic JSON matching current copyStateDump output
  let fields: [String: Bool]
}
```

---

### 5.7 Self Surface

The Self surface exposes read-only system identity and hardware state. It has no Commands — all mutations to system hardware go through Settings or OS TCC flows.

#### Events

```swift
// Emitted at connect and whenever self-state changes (e.g. provider identity update).
Event.selfStateChanged(state: SelfStatePayload)

struct SelfStatePayload {
  let appVersion: String
  let buildSHA: String
  let modelId: String             // "claude-opus-4-7" canonical, never paraphrased (fixes B-08)
  let modelDisplayName: String    // "Claude Opus 4.7" human label
  let provider: ProviderSelection
  let sessionId: SessionID
  let uptime: TimeInterval
}

// TCC permission status changed (mic, camera, input monitoring, screen capture).
Event.tccStatusChanged(
  permission: TCCPermission,
  granted: Bool
)
enum TCCPermission: String {
  case microphone; case camera; case inputMonitoring; case screenCapture; case speechRecognition
}
```

#### Queries

```swift
Query.getSelfState() -> SelfStatePayload

Query.listAudioDevices() -> [AudioDeviceInfo]
struct AudioDeviceInfo {
  let uid: String
  let name: String
  let isDefault: Bool
  let sampleRate: Double
  let hasAEC: Bool
}

Query.listCameraDevices() -> [CameraDeviceInfo]
struct CameraDeviceInfo {
  let uniqueID: String
  let localizedName: String
  let isDefault: Bool
}

Query.getActiveAudioRoute() -> AudioRouteInfo?  // nil if audio graph not running
struct AudioRouteInfo {
  let inputDeviceName: String
  let inputUID: String
  let sampleRate: Double
  let aecActive: Bool
}
```

---

## 6. Inventory Coverage Map

Every row from INVENTORY.md is accounted for here. Status codes: **MAPPED** (to a specific API operation), **RETIRED** (explicitly dropped with reasoning), **OPEN** (unresolved — see §8).

| INVENTORY capability | Status | API mapping |
|---|---|---|
| `helloAck(version:)` | MAPPED | Lifecycle / handshake (transport layer, not a surface command) |
| `uiReady` | MAPPED | Lifecycle / connect trigger → client calls `listTurns`, `getSelfState`, `getVoiceState`, `getSettings` |
| `frameAttachRequested` | MAPPED | `Vision.requestFrameAttach(reason: .hudButton)` |
| `chatSubmit(text:)` | MAPPED | `Turn.submitTurn(text:source:images:)` |
| `chatCancelAndSubmit(text:)` | MAPPED | `Turn.bargeIn(text:source:)` |
| `hello(version:)` | MAPPED | Lifecycle handshake (transport layer) |
| `hudState(HudState)` | MAPPED | `Turn.hudStateChanged` event |
| `tokenDelta(text:)` | MAPPED | `Turn.tokenStreamed` event |
| `audioLevel(rms:)` | MAPPED | `Voice.audioLevelChanged` event |
| `toolCallStart(id:name:argsPreview:)` | MAPPED | `Turn.toolCallStarted` event |
| `toolCallEnd(id:ok:previewOrError:)` | MAPPED | `Turn.toolCallEnded` event |
| `turnStarted(id:)` | MAPPED | `Turn.turnStarted` event |
| `turnEnded(id:terminator:)` | MAPPED | `Turn.turnEnded` event |
| `sessionHistory(turns:)` | RETIRED (as push) | Replaced by `Turn.listTurns` Query (client fetches on connect — no push timing race) |
| `submitRejected(reason:)` | MAPPED | `Turn.submitTurn` returns `TurnRejected` error type |
| `TurnRow` (sessionHistory payload) | MAPPED | `TurnSummary` in `ListTurnsResponse` |
| Bus protocol version | MAPPED | Lifecycle handshake (transport layer) |
| Handshake state machine | MAPPED | Lifecycle / sessions §3 |
| Hard-block alert presenter | MAPPED | Transport layer — unchanged |
| Bus reply `{ok:true}` | MAPPED | All Commands return typed Result — transport delivers this |
| `submit(_ input: TurnInput)` | MAPPED | `Turn.submitTurn` |
| `cancelAndSubmit(_ input: TurnInput)` | MAPPED | `Turn.bargeIn` |
| `TurnInput.text(_:)` | MAPPED | `Turn.submitTurn(source: .text)` |
| `TurnInput.voice(_:)` | MAPPED | `Turn.submitTurn(source: .voice)` — B-04 fix unblocks this path |
| `TurnInput.withImages(source:text:images:)` | MAPPED | `Turn.submitTurn(images:)` — B-03 fix unblocks |
| `SubmitOutcome.ran/superseded/rejected` | MAPPED | `TurnAccepted` / `BargeInAccepted` / `TurnRejected` |
| `RejectReason.*` | MAPPED | `TurnRejected` enum cases |
| `turnHadImage(_:)` | MAPPED | `getActiveTurn` → `ActiveTurnSnapshot` (extend with `hadImage: Bool` if needed by harness) |
| `turnSourceWasVoice(_:)` | MAPPED | `TurnSummary.source` |
| `OrchestratorEvent.*` | MAPPED | Turn surface events (tokenStreamed, thinkingStreamed, toolCallStarted/Updated/Ended, turnEnded, turnError) |
| `ToolCardUpdate.Phase` | MAPPED | `Turn.toolCallStarted` / `toolCallUpdated` / `toolCallEnded` |
| Conversation history threading | MAPPED | B-02: `Turn.listTurns` + orchestrator reads history from `MemoryStore.recentTurnsForSession` before building messages array. API contract: `turnStarted` MUST be preceded by history load. |
| Per-turn `cacheHints` | MAPPED | Internal orchestrator detail — not exposed at API surface; exposed in `devSnapshotUpdated.cacheHitPercent` |
| Untrusted-content nonce wrapper | MAPPED | Internal orchestrator security detail — not an API surface |
| Cap-recovery `toolChoice: .none` | MAPPED | Internal orchestrator detail |
| `streamTruncated` retry | MAPPED | `Turn.turnError(code: .streamTruncated)` emitted after retry exhausted |
| Vision T1→T2 escalation | MAPPED | `Turn.toolCallStarted` / `Turn.toolCallEnded` — escalation is transparent to client; `devSnapshotUpdated` can carry escalation marker if needed |
| `BusForwarder.drain` | MAPPED | Internal wiring — not an API surface |
| `LLMProvider.stream(...)` | MAPPED | Internal provider detail |
| `LLMProvider.stream(images:...)` | MAPPED | Internal provider detail |
| `AnthropicProvider` | MAPPED | `Self.getSelfState.provider` + `Settings.setProvider` |
| `OllamaProvider` | MAPPED | `Settings.setProvider(provider: .ollama)` |
| `VllmMlxProvider` | MAPPED | DEFERRED internally; no API surface change |
| `MissingT2Provider` | MAPPED | DEFERRED internally |
| `LLMEvent` cases | MAPPED | Turn surface events |
| `StopReason.*` | MAPPED | `TurnTerminator` + `TurnErrorCode` |
| `TurnUsage` | MAPPED | `Turn.turnEnded.usage` |
| `DevSnapshot` + `DevSnapshotEmitter` | MAPPED | `Diagnostics.devSnapshotUpdated` + `getDevSnapshot` |
| `TurnTranscriptStore.*` | MAPPED | Internal detail; output surfaces as `TurnSummary.assistantText` |
| `ToolDispatcher` protocol | MAPPED | Internal detail — not an API surface |
| `ProviderSelection` | MAPPED | `Settings.setProvider` / `getSettings.provider` |
| Provider identity literal `claude-opus-4-7` | MAPPED | `Self.selfStateChanged.modelId` (canonical, not paraphrased) |
| `VoiceController.start()` | MAPPED | `Voice.startVoice()` |
| `VoiceController.shutdown()` | MAPPED | `Voice.shutdownVoice()` |
| `pttDown()` / `pttUp()` | MAPPED | `Voice.pttDown()` / `Voice.pttUp()` (return `PTTError` — no longer silent) |
| `muteWakeWord()` / `unmuteWakeWord()` | MAPPED | `Voice.muteWakeWord()` / `Voice.unmuteWakeWord()` |
| `handleAECUnavailable()` / `handleAECRestored()` | MAPPED | `Voice.voiceDegraded(reason: .aecUnavailable)` event |
| `setAudioLevelEmitter(_:)` | MAPPED | Internal wiring |
| `VoiceState.*` | MAPPED | `Voice.voiceStateChanged` event |
| `ListeningSource.*` | MAPPED | `Voice.voiceStateChanged.listeningSource` |
| `VoiceHudIntent.*` | MAPPED | Feeds `HudStateCoordinator` → `Turn.hudStateChanged` |
| `VoiceOrchestratorInterface.*` | MAPPED | Internal adapter — not an API surface |
| `VoiceTTSInterface.*` | MAPPED | `Voice.ttsStarted` / `Voice.ttsEnded` events; `Voice.cancelTTS()` command |
| `VoiceBannerInterface.*` | MAPPED | `Diagnostics.systemBannerEnqueued` / `systemBannerDismissed` |
| `BusOutboundEmitter.postAudio(_:)` | MAPPED | `Voice.audioLevelChanged` event |
| `WakeWordDAG.*` | MAPPED | Internal — `Voice.wakeWordDetected` event surfaces the result |
| `OpenWakeWordSession.*` | MAPPED | Internal |
| `SileroVAD.*` | MAPPED | Internal |
| `STTProvider.transcribe/finalize` | MAPPED | Internal — `Voice.sttTranscriptPartial` / `sttTranscriptFinal` surface results |
| `SpeechAnalyzerSTT` | MAPPED | Internal — `Voice.getVoiceState.sttBackend` |
| `WhisperKitSTT` | MAPPED | Internal — `Settings.setSTTBackend(backend: .whisperKit)` |
| `STTBackendSelector` | MAPPED | Internal |
| `TTSEngineActor.*` | MAPPED | `Voice.ttsStarted` / `Voice.ttsEnded` / `Voice.cancelTTS()` |
| `AVSpeechSynth.*` | MAPPED | Internal |
| `OrpheusTTS.*` | MAPPED | Internal — DEFERRED, no API change when it activates |
| `TTSKitFallback.*` | MAPPED | Internal — DEFERRED |
| `InterruptSequence` + `InterruptStepRecorder` | MAPPED | Internal — `Voice.cancelTTS()` triggers; `ttsEnded(reason: .cancelled)` emits |
| `BufferBroadcaster.*` | MAPPED | Internal audio graph |
| `AudioLevelEmitter.*` | MAPPED | Internal — `Voice.audioLevelChanged` surfaces RMS |
| `MuteWakeWord` | MAPPED | `Voice.muteWakeWord()` / `Voice.getVoiceState.wakeWordMuted` |
| `PushToTalk.*` | MAPPED | `Voice.pttDown()` / `Voice.pttUp()` |
| AEC degradation banner copy | MAPPED | `Voice.voiceDegraded` + `Diagnostics.systemBannerEnqueued` |
| Mic TCC request | MAPPED | `Voice.startVoice()` returns `VoiceStartError.microphonePermissionDenied`; `Self.tccStatusChanged` event |
| Production chunk pump | MAPPED | Internal — B-04 fix wires this; no API surface change |
| `TTSTier.*` | MAPPED | `Voice.setTTSTier()` / `Voice.getVoiceState.ttsTier` |
| `MemoryStore.applyOp` | MAPPED | Internal — `Memory.factMutated` event |
| `MemoryStore.recordRetrieval` | MAPPED | Internal — `Memory.factsRetrieved` event |
| `MemoryStore.runHybridSearchSQL` | MAPPED | Internal — `Memory.searchFacts` query uses it |
| `MemoryStore.recentActiveFacts` | MAPPED | `Memory.listRecentFacts` query |
| `MemoryStore.queryActiveFacts(matching:)` | MAPPED | `Memory.searchFacts` query |
| `MemoryStore.recentTurnsForSession` | MAPPED | `Turn.listTurns` query (B-02: orchestrator also calls this before building messages) |
| `MemoryStore.forgetFact` | MAPPED | `Memory.forgetFact` command |
| `MemoryStore.searchFacts` | MAPPED | `Memory.searchFacts` query |
| `MemoryStore.factById` | OPEN | See Q-5 |
| `MemoryStore.activeFacts(subject:predicate:)` | OPEN | See Q-5 |
| `MemoryStore.querySingleString / queryRowCount / rawCountFacts` | MAPPED | Harness-internal; exposed via `Diagnostics.getStateDump` if needed |
| `Fact` struct | MAPPED | `FactSnapshot` in API |
| `MemoryOp` + `FactRef` | MAPPED | `Memory.factMutated.op` + `FactRef` in `searchFacts` response |
| `HybridSearch.searchFacts` | MAPPED | `Memory.searchFacts` query |
| `EmbeddingProviding.embed` | MAPPED | Internal |
| `OllamaEmbeddingClient` | MAPPED | Internal — DEFERRED |
| `SessionHistory.recentTurns` | MAPPED | `Turn.listTurns` query |
| `MemoryExtractionOrchestrator.*` | MAPPED | Internal — `Memory.factMutated` events surface results |
| `MemoryExtractionCoordinator.*` | MAPPED | Internal |
| `MemoryEnqueueing.enqueue` | MAPPED | Internal |
| `MemoryReplaySink` | MAPPED | Internal |
| `MemoryTools` | MAPPED | Internal |
| `MemoryExtractor` | MAPPED | Internal |
| `MemoryPrompts` | MAPPED | Internal |
| `ReplayEvent.memoryMutation / memoryRetrieval` | MAPPED | Internal replay — `Memory.factMutated` / `Memory.factsRetrieved` events are the API surface |
| `CameraCapture.*` | MAPPED | Internal — `Vision.cameraDegraded` event + `Vision.getFrameAttachState.cameraTCCGranted` |
| `CameraCapture.degradationStream` | MAPPED | `Vision.cameraDegraded` event |
| Camera TCC request | MAPPED | `Vision.requestFrameAttach` returns `FrameAttachError.cameraPermissionDenied`; `Self.tccStatusChanged` event |
| `CapturedFrame` | MAPPED | Internal |
| `PresenceFrameSample` | MAPPED | Internal — DEFERRED |
| `FrameAttachController.requestAttach` | MAPPED | `Vision.requestFrameAttach` command |
| `FrameAttachController.confirmSend` | MAPPED | Internal — called by orchestrator on `submitTurn(images:)` |
| `FrameAttachController.cancel()` | MAPPED | `Vision.cancelFrameAttach` command |
| `FrameAttachController.onAssistantTurnComplete()` | MAPPED | Internal — called by orchestrator on `turnEnded` |
| `FrameAttachController.hasPendingFrame` | MAPPED | `Vision.getFrameAttachState.hasPendingFrame` |
| `FrameAttachController.AttachReason.*` | MAPPED | `FrameAttachReason` in `Vision.requestFrameAttach` |
| `FrameAttachReplaySink` | MAPPED | Internal |
| `FrameConfirmationDecision` | MAPPED | Internal — surfaces as `Vision.frameSent` / `Vision.frameExpired` |
| `VisionRouter.route(...)` | MAPPED | Internal |
| `VisionRouter` post-response T2 heuristic | MAPPED | Internal — DEFERRED |
| `VisionRouter.providerForTier` | MAPPED | Internal — DEFERRED |
| `VisionTier.*` | MAPPED | Internal |
| `VisionEscalationHeuristic` | MAPPED | Internal — DEFERRED |
| `VllmMlxAvailability.Configuration` | MAPPED | Internal — DEFERRED |
| `VllmMlxSidecar.*` | MAPPED | Internal — DEFERRED |
| `ContextBuilder.matchesFrameAttachPhrase` | MAPPED | Internal — triggers `Vision.requestFrameAttach(reason: .phraseDetected)` |
| `ContextBuilder.matchesCloudOptIn` | MAPPED | Internal — DEFERRED |
| `PresenceMonitor.*` | MAPPED | Internal — DEFERRED |
| `PresenceSignalBus.*` | MAPPED | Internal — DEFERRED |
| `PresenceEvent.*` / `Presence.*` | MAPPED | Internal — DEFERRED; will surface as `Self.selfStateChanged` presence fields |
| `PresenceStateSnapshot.*` | MAPPED | Internal — DEFERRED |
| `DisablePresence` | MAPPED | Internal test seam |
| `VisionDegradationReason.*` | MAPPED | `Vision.cameraDegraded.reason` |
| `MCPClient.*` | MAPPED | Internal — tool catalog exposed via `Self.getSelfState` extension or `Diagnostics.getStateDump` |
| `ToolMetadata.*` | MAPPED | Internal |
| `ToolRegistry.*` | MAPPED | Internal |
| `MCPToolDispatcher.*` | MAPPED | Internal |
| `ConfirmingToolDispatcher.*` | MAPPED | Internal — `Turn.confirmationRequested` / `Turn.respondToConfirmation` |
| `BusGateway.*` | MAPPED | Internal adapter |
| `ConfirmationBroker.*` | MAPPED | Internal |
| `ConfirmationOutcome.*` | MAPPED | `Turn.confirmationResolved.outcome` |
| `ConfirmationPresenter.*` | MAPPED | Internal |
| `InProcessTool.*` | MAPPED | Internal |
| `InProcessToolRegistry.*` | MAPPED | Internal |
| `InProcessAwareToolDispatcher.*` | MAPPED | Internal |
| `InProcessConfirmationCache` | MAPPED | Internal |
| `get_time` tool | MAPPED | Exposed via agent tool loop — `Turn.toolCallStarted(toolName: "get_time")` |
| `get_clipboard` tool | MAPPED | Same |
| `run_applescript` tool | MAPPED | Same — requires `Turn.confirmationRequested` |
| `forget_fact` tool | MAPPED | Same — `Memory.forgetFact` + confirmation |
| `search_memory` tool | MAPPED | Same — `Memory.factsRetrieved` event |
| `search_conversation` tool | RETIRED | Type + tests exist; no production registration. Retire: `Turn.listTurns` query replaces it for direct client access; agent can use `search_memory` for memory-based lookup. If agent needs conversation search, re-register the tool — but the API surface doesn't need to expose it separately. |
| `get_self_state` tool | MAPPED | `Self.getSelfState` query + `Self.selfStateChanged` event (B-08: `modelId` field is canonical, never paraphrased by the tool result) |
| `list_audio_devices` tool | MAPPED | `Self.listAudioDevices` query |
| `list_camera_devices` tool | MAPPED | `Self.listCameraDevices` query |
| `get_active_audio_route` tool | MAPPED | `Self.getActiveAudioRoute` query |
| `availableToolsResolver` | MAPPED | Internal — wired at orchestrator init |
| `MCPRuntime` aggregate | MAPPED | Internal |
| `MCPRuntimeWiring.build/compose` | MAPPED | Internal |
| `ConfirmationPresenterHolder` | MAPPED | Internal |
| `ToolResultObserver` | MAPPED | Internal |
| `ReplayingToolResultObserver` | MAPPED | Internal |
| `SanitizeForModel` | MAPPED | Internal |
| Per-server restart | MAPPED | Internal — `Diagnostics.getStateDump` can expose server health |
| `ChildSpawnGate` | MAPPED | Internal |
| `ToolSchema.*` | MAPPED | Internal |
| `ConfigStore.*` | MAPPED | `Settings` surface |
| `ConfigLoader.*` | MAPPED | Internal |
| `LaunchSnapshot.*` | MAPPED | `Settings.getSettings` (read-only fields) |
| `PerTurnSnapshot.*` | MAPPED | `Settings.getSettings` / `Settings.setProvider/setTTSTier/...` |
| `OllamaConfig.baseURL` | MAPPED | `Settings.getSettings.ollamaBaseURL` (read-only at runtime) |
| `AppleScriptPolicy.*` | MAPPED | `Settings.getSettings.appleScriptRequiresConfirmation` |
| `ConfirmationPolicy.*` | MAPPED | `Settings.getSettings.confirmationTimeoutSeconds` |
| `STTConfig.*` | MAPPED | `Settings.getSettings.sttBackend` + `Settings.setSTTBackend` |
| `TTSConfig.*` | MAPPED | `Settings.getSettings.ttsTier` + `Settings.setTTSTier` |
| `LoggingLaunchConfig.*` | MAPPED | `Settings.getSettings.loggingFileLevel` (read-only) |
| `FeatureFlag.*` | MAPPED | `Settings.setFeatureFlag` / `Settings.getSettings.featureFlags` |
| `FeatureFlags.isEnabled` / `isEnabledDynamic` | MAPPED | Internal lookup; `Settings.getSettings.featureFlags` exposes current state |
| `SchemaMigrator` | MAPPED | Internal |
| `tool_blocklist` | MAPPED | `Settings.getSettings.toolBlocklist` (read-only at runtime) |
| Config file path | MAPPED | Internal |
| `UserDefaults: features.voice.wakeWordMuted` | MAPPED | `Settings.setWakeWordMuted` / `Settings.getSettings.wakeWordMuted` |
| `UserDefaults: hotkey` | MAPPED | `Settings.setHotkey` / `Settings.getSettings.hotkey` |
| `UserDefaults: WizardState fields` | MAPPED | `Settings.getSettings.currentWizardStage` + `apiKeyStored` |
| `KeychainStore.*` | MAPPED | Internal |
| `SystemKeychainStore` | MAPPED | Internal |
| `KeychainItem.anthropic` | MAPPED | Internal |
| `AnthropicAPIKeyProvider` | MAPPED | Internal |
| `AnthropicKeyValidator.validate` | MAPPED | `Settings.storeAPIKey` validates before writing |
| Menu-bar status item | MAPPED | Host UI — not a client API surface |
| Menu-bar left-click → `toggleHUD()` | MAPPED | Host UI — not a client API surface |
| Menu: **Setup...** | MAPPED | Host UI |
| Menu: **Settings...** | MAPPED | Host UI |
| Menu: **Show Dev Overlay** | MAPPED | `Diagnostics.toggleDevOverlay()` command |
| Menu: **Copy State Dump** | MAPPED | `Diagnostics.copyStateDump()` command |
| Menu: **Quit Jarvis** | MAPPED | Host UI |
| Menu: **Voice Log** (B-07) | MAPPED | `Diagnostics` surface — Voice Log window will expose replay events; design deferred to Plan 10-05 re-scope |
| `JarvisHUDPanel.*` | MAPPED | Host UI — summoned/dismissed by hotkey; `Turn.hudStateChanged` drives content |
| `HUDBannerPanel.*` + `HUDBannerCoordinator.*` | MAPPED | `Diagnostics.systemBannerEnqueued` / `systemBannerDismissed` |
| `BannerContent.*` | MAPPED | `Diagnostics.systemBannerEnqueued.title/body` |
| `HudStateCoordinator.*` | MAPPED | Internal — single writer for `Turn.hudStateChanged` |
| `HudStateBridge.*` | MAPPED | Internal adapter |
| `AgentHudIntent.*` / `ConfirmHudIntent.*` | MAPPED | Internal intents feeding `HudStateCoordinator` |
| `HotkeyBinder.*` | MAPPED | `Settings.setHotkey` command |
| Hotkey bind production wiring | MAPPED | Internal |
| Hotkey-bind-failed banner | MAPPED | `Diagnostics.systemBannerEnqueued` |
| Input Monitoring TCC probe | MAPPED | `Self.tccStatusChanged(permission: .inputMonitoring)` |
| Input-Monitoring-denied banner | MAPPED | `Diagnostics.systemBannerEnqueued` |
| `ShortcutRecorderView` | MAPPED | Host UI |
| `KeyboardShortcut.*` | MAPPED | `Settings.getSettings.hotkey` + `Settings.setHotkey` |
| `CollisionDetector.*` | MAPPED | Internal — `Settings.setHotkey` returns `HotkeyError.collision` |
| `LaunchAtLoginController.*` | MAPPED | `Settings.getSettings.launchAtLoginEnabled` — OPEN for a command to toggle |
| `TCCAlertService.*` | MAPPED | Internal — hard-block remains a direct AppKit call |
| `OnboardingWizardController.*` + `WizardStage.*` | MAPPED | Host UI — `Settings.getSettings.currentWizardStage` exposes state |
| `SettingsWindowController.*` | MAPPED | Host UI |
| Wizard chapter views | MAPPED | Host UI |
| `ReplayLog.*` | MAPPED | Internal — `Diagnostics.getDevSnapshot` surfaces turn-level metrics |
| Replay events (all 12 types) | MAPPED | Internal append-only log — not pushed to API clients. Harness reads replay file directly for oracle checks. |
| `TurnSource.*` | MAPPED | `Turn.submitTurn.source` + `TurnSummary.source` |
| `TurnSource.dispatchesToHUD / speaks` | MAPPED | Internal suppression flags — harness uses `TurnSource.eval` which suppresses HUD and TTS |
| `SessionID.fresh()` | MAPPED | Internal |
| `OrphanDetector` | MAPPED | Internal test tool |
| `TokenDeltaDropOldestChannel` | MAPPED | Internal |
| `Schema.*` | MAPPED | Internal |
| `DevOverlayWindow.*` | MAPPED | `Diagnostics.toggleDevOverlay()` |
| `DevOverlayBridge.*` | MAPPED | Internal |
| `DevOverlayViewModel.*` | MAPPED | Internal |
| DevOverlay UI surfaces | MAPPED | `Diagnostics.devSnapshotUpdated` |
| `DevSnapshotEmitter.*` | MAPPED | Internal |
| `JarvisLogChannel.*` | MAPPED | Internal |
| `LoggingBootstrap.*` | MAPPED | Internal |
| `OSLogHandler` / `FileLogHandler` / `FileRotatingWriter` | MAPPED | Internal |
| `LogPaths.*` | MAPPED | Internal |
| `Redact.string` | MAPPED | Internal |
| `BoundedAsyncChannel<Element>` | MAPPED | Internal |
| `ImageBlock.*` | MAPPED | Internal — `Vision.requestFrameAttach` arms the capture; image bytes never cross the API |
| `LLMMessage.*` | MAPPED | Internal |
| `CacheHints.*` | MAPPED | Internal — cache metrics exposed via `Diagnostics.devSnapshotUpdated.cacheHitPercent` |
| `ToolChoice.*` | MAPPED | Internal |
| `ModelID.*` | MAPPED | `Self.getSelfState.modelId` |
| `TurnID.*` | MAPPED | Universal correlation key across all surfaces |
| `TurnNonce.*` | MAPPED | Internal security — never crosses the API boundary |
| `ConfirmationID.*` | MAPPED | `Turn.confirmationRequested.confirmationId` + `Turn.respondToConfirmation.confirmationId` |
| `TurnState.*` | MAPPED | `Turn.getActiveTurn.phase` |
| Eval harness CLI | MAPPED | Consumes this API directly via Swift actor calls (no transport) |
| `Harness` test-double library | MAPPED | Internal harness |
| Webview `window.jarvisBus.receive` | MAPPED | Transport detail — events arrive here |
| Replay-roundtrip oracle | MAPPED | Harness reads replay file; `Turn.submitTurn(source: .replay)` triggers replay path |
| Harness-eval cohort `TurnSource.eval` | MAPPED | `Turn.submitTurn(source: .eval)` |
| `JarvisEntitlementsVerified` + `verify-entitlements.sh` | MAPPED | Internal boot gate |
| Boot-time hard-block | MAPPED | Internal — hard-blocks before any client can connect |

---

## 7. How This Kills B-02..B-08

### B-02 — Conversation continuity broken ("yes" loses context)

**Root cause:** `AgentOrchestrator` builds messages array as `[system, user(input.userText)]` with no history fetch (`AgentOrchestrator.swift:283-286`). `MemoryStore.recentTurnsForSession` and `SessionHistory.recentTurns` exist but are never called.

**API contract that kills it:** `Turn.submitTurn` has a documented post-condition: the orchestrator MUST prepend prior turns from `MemoryStore.recentTurnsForSession` before building the messages array. The test harness verifies this by submitting two turns and asserting that the second LLM call includes the first turn's user+assistant text in `messages`. Failure to prepend = `MockLLMProvider` receives wrong message count = test fails. The failure is no longer silent.

### B-03 — HUD camera button click does nothing

**Root cause:** `frameAttachRequested` emitted by webview never reaches `AppDelegate.swift:2115-2117`. The webview sends the message; the bus handler exists; something in between is disconnected.

**API contract that kills it:** `Vision.requestFrameAttach(reason: .hudButton)` returns `Result<FrameAttachArmed, FrameAttachError>`. The webview MUST observe a typed response. If the frame-attach window is not armed, the client receives a typed error within 100ms. The harness drives `requestFrameAttach` and asserts `FrameAttachArmed` is returned; if the handler is dead, `FrameAttachError.cameraPermissionDenied` or a timeout returns instead. No silent swallow.

### B-04 — Voice input dead (wake-word + STT never fire)

**Root cause:** `VoiceController.start()` is called but no audio frames reach the `WakeWordDAG`. The audio graph is not wired to produce frames into the DAG.

**API contract that kills it:** `Voice.startVoice()` returns `Result<Void, VoiceStartError>`. If the audio graph fails to start, `VoiceStartError.audioGraphFailed(reason:)` is returned — not a silent `Void`. Additionally, `Voice.audioLevelChanged` must begin emitting within 500ms of a successful `startVoice()`. The harness asserts this timing. If the graph is wired but audio doesn't flow, no `audioLevelChanged` events arrive = test timeout = explicit failure.

### B-05 — TTS silent (text written, no audio)

**Root cause:** `VoiceTTSInterface.synthesize` is invoked but the production adapter `VoiceTTSAdapter.swift:25` is not driven when assistant text completes.

**API contract that kills it:** After a turn where `Turn.turnEnded(terminator: .completed)` is emitted AND `TurnSummary.source == .voice`, the harness asserts that `Voice.ttsStarted(turnId:)` was emitted for the same `turnId`. If TTS is not invoked, `ttsStarted` never fires = test assertion fails. The link between `turnEnded` and `ttsStarted` is a documented invariant: voice-sourced turns with a non-empty assistant text MUST produce a `ttsStarted` event.

### B-06 — Chat panel doesn't auto-scroll

**Root cause:** Missing `scrollIntoView` / `useEffect` in the webview chat component.

**API contract that kills it (partially):** The API guarantees that `Turn.tokenStreamed(turnId:text:)` events are delivered in-order and include the `turnId`. The webview chat panel can use the `turnId` to anchor a scroll target. The test harness verifies that `tokenStreamed` events are delivered in the correct order; the rendering logic is a webview concern, but the harness can drive a headless webview and assert that the DOM scroll position changes after token events. This is the weakest link — the harness cannot fully verify DOM behavior, but the API provides the scroll-anchor contract. (See Q-4 for whether to add a dedicated scroll event.)

### B-07 — Voice Log menu item missing

**Root cause:** Plan 10-05 unrun; `stash@{0}` has partial scaffolding.

**API contract that kills it:** `Diagnostics` surface will own the Voice Log window. The menu item wires to `Diagnostics.toggleVoiceLog()` command (to be added in v0.2 after Plan 10-05 re-scope). The harness will assert that `Diagnostics.getStateDump()` includes `voiceLogVisible: Bool`. If the menu item isn't wired, the state dump doesn't change = harness catches it.

### B-08 — `get_self_state` returns correct model ID but Claude paraphrases "Opus 4.5"

**Root cause:** The tool result text contains the raw model ID; Claude's response generation paraphrases it.

**API contract that kills it:** `Self.getSelfState.modelId` returns `"claude-opus-4-7"` (canonical). `Self.getSelfState.modelDisplayName` returns `"Claude Opus 4.7"` (explicit human-readable string). The `get_self_state` in-process tool MUST return both fields explicitly in its JSON result with a label like `"model_display_name": "Claude Opus 4.7"` that reduces Claude's degrees of freedom. The harness asserts that the string `"Opus 4.5"` never appears in assistant text for turns that called `get_self_state`. This is a soft-failure boundary (LLM output is probabilistic) but the structured field contract makes paraphrase much less likely.

---

## 8. Open Questions for User-Decision Step

**Q-1 — Token vs. sentence granularity for `tokenStreamed`?**
Currently maps 1:1 to `tokenDelta` (individual token chunks). Should the API also emit a `sentenceStreamed` event (complete sentence boundary), or is raw token granularity sufficient for both chat panel rendering and TTS chunked synthesis? Answer affects TTS streaming design.

**Q-2 — Should `enableTTS` / `disableTTS` be per-turn or global?**
Current design: `Settings.setTTSTier` is global and persists across turns. Should there be a `submitTurn`-level override (e.g., `submitTurn(text:source:ttsOverride:)`) so that eval harness turns can suppress TTS without changing global config? Alternative: harness uses `TurnSource.eval` which already suppresses TTS via `dispatchesToHUD / speaks` flags.

**Q-3 — Does `replayTurn(turnId:)` need to be an API command?**
The handoff mentions replay as an offline operation using `TurnSource.replay(sessionId:)`. The harness can drive `submitTurn(source: .replay)` directly. Is there a use case for a client (webview or CLI) to trigger replay of a past turn by ID? If yes, add `Turn.replayTurn(turnId:)` command. If replay is strictly offline/harness-only, no command is needed.

**Q-4 — Explicit scroll-anchor event for chat panel (B-06)?**
Should the API emit a dedicated `Turn.turnTextComplete(turnId:fullText:)` event after `turnEnded`, giving the webview chat panel a single event to scroll to? This is redundant with `turnEnded` + accumulated `tokenStreamed` but removes a client-side accumulation burden and provides a clean scroll trigger. Cost: one extra event type.

**Q-5 — Expose `factById` and `activeFacts(subject:predicate:)` as API Queries?**
Both exist on `MemoryStore` but are not currently called from any client-facing path. They would be useful for a future "memory browser" in the HUD or for harness assertions that verify specific facts. Add them to the Memory surface now (cheap) or defer until a consumer exists?

**Q-6 — Launch-at-login toggle as a Settings command?**
`LaunchAtLoginController` is fully implemented but there's no client-facing command to toggle it. `Settings.getSettings.launchAtLoginEnabled` exposes the current state. Should `Settings.setLaunchAtLogin(enabled: Bool) -> Result<Void, LaunchAtLoginError>` be added now? This affects the Settings window which currently drives it directly through AppKit.

**Q-7 — Presence pipeline API surface?**
All presence capabilities are DEFERRED internally. When the presence pipeline activates, should its state surface through `Self.selfStateChanged` (enrichment to existing event), a new `Presence` surface, or `Voice.voiceStateChanged` (since presence affects the "at desk" listening behavior)? Decide the surface home now so DEFERRED items have a destination.

---

## 9. Glossary

| Term | Definition |
|---|---|
| **Command** | Client-initiated operation that mutates state. Returns a typed Result. |
| **Event** | Server-pushed notification of state change. Client subscribes; server emits. |
| **Query** | Client-initiated read-only state probe. Returns current state without side effects. |
| **Turn** | A single user→assistant exchange, including all tool-call rounds within it. Identified by `TurnID`. |
| **Session** | The process lifetime of the Swift host. Identified by `SessionID`. One session per process. |
| **Barge-in** | Cancelling an in-flight turn and immediately starting a new one. The prior turn terminates with `TurnTerminator.superseded`. |
| **TurnSource** | The origin of a turn: `text` (chat panel), `voice` (wake-word/PTT), `eval` (harness scenario), `replay` (offline oracle). |
| **Surface** | A logical grouping of related Commands, Events, and Queries. The seven surfaces are: Turn, Voice, Memory, Vision, Settings, Diagnostics, Self. |
| **CQRS-flavored** | Commands and Queries are separated; Commands mutate state and return typed outcomes; Queries are read-only. Events are server-push (not part of classic CQRS but added for streaming state propagation). |
| **Canonical model ID** | `"claude-opus-4-7"` — the exact string used in API calls. Distinct from `modelDisplayName` (`"Claude Opus 4.7"`) used in user-facing text. |
| **DEFERRED** | A capability that is intentionally dormant (behind a feature flag or missing dependency). Its API surface home is defined here; implementation follows when the dependency lands. |
| **RETIRED** | A capability that is explicitly removed from the API. `search_conversation` tool is the only retirement in this design. |
