import Foundation

/// Source channel that produced a turn.
///
/// Surfaces in the `turns.source` column for cross-cohort eval slicing (text vs
/// voice latency, memory-extraction-only error rates, etc.).
///
/// **Phase 8 Strategy B (Plan 08-01):** the replay/evaluation cases carry
/// associated values so the orchestrator's `.replay` MCP swap can reach the
/// recorded `sessionId` without a sidecar context (R4-L7 suppression by
/// construction). Adding associated values requires hand-rolling `rawValue` —
/// `String, RawRepresentable, CaseIterable` synthesis no longer applies.
public enum TurnSource: Sendable, Equatable, Hashable {
    case text
    case voice
    case memoryExtraction
    /// Phase 8 — replay-roundtrip oracle (Plan 08-01). Suppresses HUD dispatch
    /// and TTS; routes tool calls through `ReplayMCPAdapter` keyed by
    /// `sessionId`.
    case replay(sessionId: UUID)
    /// Phase 8 — evaluation matrix (Plans 08-02 / 08-03). Suppresses HUD
    /// dispatch and TTS; uses live MCP helpers (integration-test shape).
    /// `scenarioId` carries the corpus-item identifier for per-item
    /// diagnostics.
    case evaluation(scenarioId: String)

    /// SQLite source column raw value. Hand-rolled because associated-value
    /// cases break `String` raw-representable synthesis.
    public var rawValue: String {
        switch self {
        case .text: return "text"
        case .voice: return "voice"
        case .memoryExtraction: return "memoryExtraction"
        case .replay: return "replay"
        case .evaluation: return "evaluation"
        }
    }

    /// R4-L7 suppression — replay/evaluation/memoryExtraction do not dispatch
    /// HUD events. Only `.text` / `.voice` (real user-facing turns) do.
    public var dispatchesToHUD: Bool {
        switch self {
        case .text, .voice: return true
        case .memoryExtraction, .replay, .evaluation: return false
        }
    }

    /// R4-L7 suppression — replay/evaluation/memoryExtraction do not speak.
    /// Only `.text` / `.voice` (real user-facing turns) do.
    public var speaks: Bool {
        switch self {
        case .text, .voice: return true
        case .memoryExtraction, .replay, .evaluation: return false
        }
    }
}

/// Stable identifier for a session (one app launch).
///
/// Wraps a UUID string. New sessions are created via `ReplayLog.beginSession`.
public struct SessionID: Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Generate a fresh SessionID backed by a UUID.
    public static func fresh() -> SessionID {
        SessionID(rawValue: UUID().uuidString)
    }
}

/// One entry in the replay log. Ten cases — exactly the set surfaced by the
/// orchestrator (Plan 04-04) plus HUD/error event sinks.
///
/// Payloads are stored byte-for-byte in `events.payload_bytes` (BLOB). The
/// "nothing-masked" guarantee (OBS-02) lives at this layer: redaction is the
/// **viewer's** responsibility (Phase 8), not the writer's.
public enum ReplayEvent: Sendable {
    /// Raw user input bytes (text turn) OR the placeholder JSON for an
    /// image-bearing turn (Plan 07-05 / D-15). For image turns, the payload
    /// is the literal byte string
    /// `{"type":"image","discarded":true,"text":"<original-user-text>"}` —
    /// the captured image bytes themselves NEVER reach this sink.
    /// `FrameAttachReplaySink.placeholder(for:)` is the SOLE producer of
    /// the placeholder shape; the raw-bytes egress fence in
    /// `FrameAttachDiscardSiteGrepTests` enforces no png/jpeg serialization
    /// patterns appear in this package's sources.
    case userInput(Data)
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallRequested(id: String, name: String, argsJSON: Data)
    case toolResultFull(toolUseId: String, bytes: Data)
    case usage(Data)
    case stopReason(String)
    case turnEnd
    case hudEvent(Data)
    case error(Data)
    /// MEM-08 / D-05 surface: emitted by `MemoryStore.applyOp` (Plan 07-02).
    /// Payload is JSON-encoded with shape:
    /// `{"op":"ADD"|"UPDATE","subject","predicate","object","factId",
    ///   "supersedesFactId","triggerTurnId","triggerSource","timestamp"}`.
    /// NOOPs are NOT recorded (debug-log only per RESEARCH §13).
    ///
    /// Single-emission-site invariant: `MemoryStore.applyOp` is the only
    /// production code that records this event. Enforced by
    /// `SingleEmissionSiteGrepTests` in the Memory test target.
    case memoryMutation(Data)
    /// MEM-08 / D-05 surface: emitted by `MemoryStore.recordRetrieval` (Plan
    /// 07-03 task 1) — symmetric to `.memoryMutation`.
    /// Payload shape: factId, summary, score, triggerTurnId, timestamp
    /// (JSON encoded). Single-emission-site enforced by
    /// `SingleEmissionSiteGrepTests.testMemoryRetrievalHasSingleEmissionSite`.
    case memoryRetrieval(Data)
}

extension ReplayEvent {
    /// Encode this event to the on-disk shape: a `kind` rawValue (matching
    /// `ReplayEventKind`) plus the BLOB bytes that go into `events.payload_bytes`.
    ///
    /// - Textual cases (`.textDelta`, `.thinkingDelta`, `.stopReason`) → UTF-8 bytes.
    /// - Binary cases (`.userInput`, `.toolResultFull`, `.usage`, `.hudEvent`,
    ///   `.error`) → carried `Data` verbatim.
    /// - `.toolCallRequested` → JSON `{id, name, args_json: <base64 of argsJSON>}`.
    /// - `.turnEnd` → empty Data.
    public func encoded() -> (kind: String, payloadBytes: Data) {
        switch self {
        case .userInput(let data):
            return (ReplayEventKind.userInput.rawValue, data)
        case .textDelta(let s):
            return (ReplayEventKind.textDelta.rawValue, Data(s.utf8))
        case .thinkingDelta(let s):
            return (ReplayEventKind.thinkingDelta.rawValue, Data(s.utf8))
        case .toolCallRequested(let id, let name, let argsJSON):
            // Base64-encode the args bytes so the JSON envelope stays text-safe.
            let envelope: [String: String] = [
                "id": id,
                "name": name,
                "args_json": argsJSON.base64EncodedString(),
            ]
            // JSONSerialization is deterministic enough for our round-trip
            // tests; key order is not asserted by the schema.
            let bytes = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
            return (ReplayEventKind.toolCallRequested.rawValue, bytes)
        case .toolResultFull(let toolUseId, let bytes):
            // Wrap in a JSON envelope with base64'd bytes — viewer needs the
            // toolUseId and the raw output is sometimes binary (e.g., screenshots).
            let envelope: [String: String] = [
                "tool_use_id": toolUseId,
                "bytes": bytes.base64EncodedString(),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
            return (ReplayEventKind.toolResultFull.rawValue, data)
        case .usage(let data):
            return (ReplayEventKind.usage.rawValue, data)
        case .stopReason(let s):
            return (ReplayEventKind.stopReason.rawValue, Data(s.utf8))
        case .turnEnd:
            return (ReplayEventKind.turnEnd.rawValue, Data())
        case .hudEvent(let data):
            return (ReplayEventKind.hudEvent.rawValue, data)
        case .error(let data):
            return (ReplayEventKind.error.rawValue, data)
        case .memoryMutation(let data):
            return (ReplayEventKind.memoryMutation.rawValue, data)
        case .memoryRetrieval(let data):
            return (ReplayEventKind.memoryRetrieval.rawValue, data)
        }
    }
}
