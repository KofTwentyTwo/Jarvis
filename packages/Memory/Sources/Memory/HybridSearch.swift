import Foundation
import JarvisLogging
import Logging

public protocol EmbeddingProviding: Sendable {
    func embed(_ input: String) async throws -> [Float]
}

public protocol MemoryReadStore: Sendable {
    func runHybridSearchSQL(query: String, embedding: [Float], k: Int) async throws -> [(Fact, Double)]
    func recordRetrieval(_ ref: FactRef, triggerTurnId: Int64) async
}

/// MEM-07 hybrid search actor. Drives the FTS5 + vec0 RRF SQL and emits
/// exactly one ReplayEvent.memoryRetrieval per returned fact through
/// MemoryStore.recordRetrieval (D-05 single emission site).
///
/// Per D-07 the SQL has no session_id predicate. Session-scoped browsing
/// goes through SessionHistory (TEXT-03).
public actor HybridSearch {

    private let store: any MemoryReadStore
    private let embedder: any EmbeddingProviding
    private let logger: Logger

    public init(store: any MemoryReadStore, embedder: any EmbeddingProviding) {
        self.store = store
        self.embedder = embedder
        self.logger = Logger(label: "memory.search")
    }

    public func searchFacts(query: String, k: Int = 10, triggerTurnId: Int64) async throws -> [FactRef] {
        guard !query.isEmpty else { return [] }
        let embedding = try await embedder.embed(query)
        let rows = try await store.runHybridSearchSQL(query: query, embedding: embedding, k: k)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var refs: [FactRef] = []
        refs.reserveCapacity(rows.count)
        for (fact, rrf) in rows {
            let summary = "\(fact.subject) \(fact.predicate) \(fact.object)"
            let ref = FactRef(
                factId: fact.id,
                summary: summary,
                score: rrf,
                triggerTurnId: triggerTurnId,
                timestamp: now
            )
            refs.append(ref)
            await store.recordRetrieval(ref, triggerTurnId: triggerTurnId)
        }
        // P2-6 (audit 2026-05-04 security MEDIUM-1): never log the raw
        // query at debug level — same discipline as T-06-05-03 enforces
        // for voice transcripts. Log metadata only (length, k, hits,
        // trigger). Voice text and search queries are user-private content.
        logger.debug("searchFacts: queryLen=\(query.count) k=\(k) hits=\(refs.count) triggerTurnId=\(triggerTurnId)")
        return refs
    }
}
