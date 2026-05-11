// InProcessMemoryAdapters.swift
//
// Track-D D-2: bridges MCP's tool dispatch protocols
// (`HybridSearchDispatching`, `ForgetFactDispatching`) to the Memory module's
// concrete actors. These adapters live in App/ rather than packages/MCP/
// because they cross the module boundary — JarvisMCP intentionally does NOT
// import Memory (Plan 07-03 design: protocol seam keeps MCP unaware of
// SQLite/HybridSearch internals).
//
// Both adapters are `Sendable` value types with an internal actor reference;
// conformance methods hop into the actor and translate Memory's return types
// to MCP's tool-boundary types so MCP doesn't have to import Memory.

import Foundation
import JarvisMCP
import Memory

/// Bridges `SearchMemoryTool`'s `HybridSearchDispatching` protocol to a
/// concrete `Memory.HybridSearch` actor. Translates `[Memory.FactRef]` rows
/// into `[SearchMemoryHit]` so the MCP module doesn't depend on Memory's
/// FactRef type.
public struct HybridSearchAdapter: HybridSearchDispatching {
    private let hybrid: HybridSearch

    public init(hybrid: HybridSearch) {
        self.hybrid = hybrid
    }

    public func searchFacts(query: String, k: Int, triggerTurnId: Int64) async throws -> [SearchMemoryHit] {
        let refs = try await hybrid.searchFacts(query: query, k: k, triggerTurnId: triggerTurnId)
        return refs.map { ref in
            SearchMemoryHit(
                factId: ref.factId,
                summary: ref.summary,
                score: ref.score,
                triggerTurnId: ref.triggerTurnId
            )
        }
    }
}

/// Bridges `ForgetFactTool`'s `ForgetFactDispatching` protocol to
/// `MemoryStore.forgetFact`. The store actor's `forgetFact` is a synchronous
/// throwing method (it wraps an internal SQLite transaction); the adapter
/// hops into the actor and forwards.
public struct ForgetFactStoreAdapter: ForgetFactDispatching {
    private let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public func forgetFact(id: Int64, triggerTurnId: Int64) async throws -> Bool {
        try await store.forgetFact(id: id, triggerTurnId: triggerTurnId)
    }
}

/// D-5/D-6 closure follow-up: bridges `GetMemoryStatsTool`'s
/// `MemoryStatsDispatching` protocol to `MemoryStore`. Reads counts
/// + size via the store's public `queryRowCount` / `querySingleString`
/// seams and `FileManager` for the on-disk file size. The DB URL must
/// be passed at construction since `MemoryStore` doesn't expose it
/// publicly.
public struct MemoryStatsStoreAdapter: MemoryStatsDispatching {
    private let store: MemoryStore
    private let databaseURL: URL

    public init(store: MemoryStore, databaseURL: URL) {
        self.store = store
        self.databaseURL = databaseURL
    }

    public func getMemoryStats() async throws -> MemoryStats {
        let turnsCount = try await store.queryRowCount("SELECT id FROM turns")
        let factsTotal = try await store.queryRowCount("SELECT id FROM facts")
        let factsActive = try await store.queryRowCount(
            "SELECT id FROM facts WHERE valid_to IS NULL AND forgotten_at IS NULL"
        )
        let sessionsCount = try await store.queryRowCount(
            "SELECT DISTINCT session_id FROM turns"
        )
        let vecVersion = (try await store.querySingleString("SELECT vec_version()")) ?? "unknown"
        let sqliteVersion = (try await store.querySingleString("SELECT sqlite_version()")) ?? "unknown"

        // Max created_at; nil when the corresponding table is empty.
        let lastTurnAt = try await maxCreatedAt(from: "turns")
        let lastFactAt = try await maxCreatedAt(from: "facts")

        // File size — kernel view of jarvis.db; WAL/SHM sidecars not included.
        let dbFileBytes: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
           let size = attrs[.size] as? Int64 {
            dbFileBytes = size
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
                  let size = attrs[.size] as? Int {
            dbFileBytes = Int64(size)
        } else {
            dbFileBytes = 0
        }

        return MemoryStats(
            turnsCount: turnsCount,
            factsTotal: factsTotal,
            factsActive: factsActive,
            sessionsCount: sessionsCount,
            dbFileBytes: dbFileBytes,
            vecVersion: vecVersion,
            sqliteVersion: sqliteVersion,
            lastTurnAtUnixMs: lastTurnAt,
            lastFactAtUnixMs: lastFactAt
        )
    }

    /// Returns max created_at as Int64 unix-ms, or nil if the table is empty.
    /// SQLite's MAX over an empty set returns NULL → querySingleString returns
    /// nil; we forward the nil rather than masking it as 0.
    private func maxCreatedAt(from table: String) async throws -> Int64? {
        // Whitelist table name to defend against future call-site changes.
        guard table == "turns" || table == "facts" else { return nil }
        let s = try await store.querySingleString("SELECT MAX(created_at) FROM \(table)")
        guard let s, let n = Int64(s) else { return nil }
        return n
    }
}
