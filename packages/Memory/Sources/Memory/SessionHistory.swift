import Foundation
import JarvisLogging
import Logging

public protocol SessionHistoryReading: Sendable {
    func recentTurnsForSession(sessionId: String, limit: Int) async throws -> [TurnRow]
}

/// TEXT-03 chat-panel session-history surface. Queries the turns table for
/// the most recent N turns in the given session, ordered by created_at DESC.
///
/// Pure read actor — no mutation, no DevOverlay emit (memoryRetrieval is
/// reserved for facts; turns are conversational history, not extracted memory).
public actor SessionHistory {

    private let store: any SessionHistoryReading
    private let logger: Logger

    public init(store: any SessionHistoryReading) {
        self.store = store
        self.logger = Logger(label: "memory.history")
    }

    public func recentTurns(sessionId: String, limit: Int = 50) async throws -> [TurnRow] {
        // Defensive cap. CONTEXT.md "no manual memory browser UI" — 500 is
        // the max anyone could plausibly hydrate into the chat panel without
        // virtualization (P3 RESEARCH §A8 deferred virtualization to P8).
        let bounded = max(0, min(limit, 500))
        let rows = try await store.recentTurnsForSession(sessionId: sessionId, limit: bounded)
        logger.debug("recentTurns: sessionId=\(sessionId) limit=\(bounded) rows=\(rows.count)")
        return rows
    }
}
