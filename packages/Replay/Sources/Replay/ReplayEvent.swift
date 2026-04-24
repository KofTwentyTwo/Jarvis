import Foundation

/// Source channel that produced a turn.
///
/// Surfaces in the `turns.source` column for cross-cohort eval slicing (text vs
/// voice latency, memory-extraction-only error rates, etc.).
public enum TurnSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case text
    case voice
    case memoryExtraction
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
        }
    }
}
