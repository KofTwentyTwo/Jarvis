import Foundation
import AgentCore  // TurnID

/// Per-turn (userText, assistantText) accumulator used by Plan 1's
/// `lookupTurnContent` closure to feed `MemoryExtractionCoordinator`.
///
/// **BLOCKER-1 fix.** Without this store, the AppDelegate-supplied
/// `lookupTurnContent` returned nil and `MemoryExtractionCoordinator`'s
/// drain SKIPPED extraction entirely (see
/// `MemoryExtractionCoordinator.swift` lines 46-49). This store is the
/// source of truth: Plan 1's transcript subscriber feeds the assistant
/// side from `.tokenDelta` events; Plan 4 feeds the user side at
/// submit-time. `flushPair` is called from `lookupTurnContent` on
/// `.turnEnd`; both halves are required for a non-nil return.
///
/// **Lifetime:** owned strongly by AppDelegate, parallel to
/// OrchestratorEventBroadcaster.
///
/// **Home note:** placed in the AgentOrchestrator target rather than
/// `App/AgentRuntime/` because the App target lacks SPM test
/// discovery; the tests live alongside the broadcaster's tests in
/// `AgentOrchestratorTests`. Decision recorded in 09-01-SUMMARY.
public actor TurnTranscriptStore {
    public enum Role: Sendable {
        case user
        case assistant
    }

    private struct Entry {
        var userText: String?      // nil until first user-side append
        var assistantText: String  // accumulated via append; "" until first delta
    }

    private var entries: [TurnID: Entry] = [:]

    public init() {}

    /// Append a fragment. Multiple `.assistant` appends concatenate into a
    /// single string (token streaming). User-side append is typically a
    /// single call with the full text at submit time.
    public func append(turnId: TurnID, role: Role, deltaText: String) {
        var entry = entries[turnId] ?? Entry(userText: nil, assistantText: "")
        switch role {
        case .user:
            // First user append wins; subsequent appends concatenate (defensive).
            if let existing = entry.userText {
                entry.userText = existing + deltaText
            } else {
                entry.userText = deltaText
            }
        case .assistant:
            entry.assistantText += deltaText
        }
        entries[turnId] = entry
    }

    /// Returns `(userText, assistantText)` iff BOTH sides have been populated;
    /// removes the entry from the store on success (bounded memory). Returns
    /// nil if either side is missing.
    public func flushPair(_ turnId: TurnID) -> (userText: String, assistantText: String)? {
        guard let entry = entries[turnId] else { return nil }
        guard let userText = entry.userText, !userText.isEmpty else { return nil }
        guard !entry.assistantText.isEmpty else { return nil }
        entries.removeValue(forKey: turnId)
        return (userText: userText, assistantText: entry.assistantText)
    }

    /// Drop a turn without flushing — e.g., when a turn is cancelled.
    public func discard(_ turnId: TurnID) {
        entries.removeValue(forKey: turnId)
    }
}
