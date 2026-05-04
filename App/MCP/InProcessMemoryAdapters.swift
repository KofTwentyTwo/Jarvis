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
