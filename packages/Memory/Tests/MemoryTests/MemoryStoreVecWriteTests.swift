import XCTest
import Foundation
import AgentCore
import Replay
@testable import Memory

/// Audit 2026-05-12 / M-1 (Issue #12) — facts_vec write-side coverage.
///
/// The schema declares `facts_vec` (sqlite-vec virtual table) and the read
/// path's RRF SQL joins against it, but before this fix no producer ever
/// wrote into it. Result: the `vc` CTE in `hybridSearchSQL` returned zero
/// rows on every call and RRF degenerated to FTS5-only ranking. Semantic
/// recall ("dog" → "Toby" via embedding similarity) silently didn't work
/// despite vec0 being loaded and the embedder client being healthy.
///
/// Test plan:
///   - applyOp(.add) with a stub embedder injected → assert exactly one
///     facts_vec row exists for the new fact's id.
///   - applyOp(.add) with NO embedder injected → fact still persists with
///     FTS5 row; facts_vec row absent (degraded-but-searchable mode).
///   - applyOp(.add) with an embedder that throws → fact still persists;
///     embedder failure must not roll back the facts row.
final class MemoryStoreVecWriteTests: XCTestCase {

    /// Stub embedder returning a constant 768-dim vector — no call recording,
    /// no scripting. (Per project convention: Stub*, not Mock*.)
    actor StubEmbedder: EmbeddingProviding {
        let vector: [Float]
        init(value: Float = 0.1) {
            self.vector = Array(repeating: value, count: MemoryConstants.embeddingDim)
        }
        func embed(_ input: String) async throws -> [Float] {
            return vector
        }
    }

    /// Stub embedder that always throws — used to verify the writer's
    /// degraded-mode discipline (FTS row stays, vec row absent, fact still
    /// persisted).
    actor ThrowingEmbedder: EmbeddingProviding {
        struct Boom: Error {}
        func embed(_ input: String) async throws -> [Float] {
            throw Boom()
        }
    }

    // MARK: - Tests

    func testApplyOpADDWritesFactsVecRowWhenEmbedderInjected() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp, embedder: StubEmbedder())

        let fact = try await store.applyOp(
            .add(subject: "user", predicate: "has_dog_named", object: "Toby", embedding: nil),
            sourceTurnId: 0
        )
        XCTAssertNotNil(fact)
        guard let fact else { return }

        // facts row count = 1, facts_vec row count = 1 (parity invariant).
        let factsCount = try await store.queryRowCount("SELECT id FROM facts")
        XCTAssertEqual(factsCount, 1)

        let vecCount = try await store.queryRowCount(
            "SELECT fact_id FROM facts_vec WHERE fact_id = \(fact.id)"
        )
        XCTAssertEqual(
            vecCount, 1,
            "Issue #12: facts_vec must contain exactly one row matching the new fact's id."
        )
    }

    func testApplyOpADDPersistsFactWhenNoEmbedderInjected() async throws {
        let tmp = try Self.tempDB()
        // No embedder → facts row persists, facts_vec stays empty (degraded
        // but searchable via FTS5 + recentActiveFacts).
        let store = try MemoryStore(databaseURL: tmp, embedder: nil)

        let fact = try await store.applyOp(
            .add(subject: "user", predicate: "has_dog_named", object: "Toby", embedding: nil),
            sourceTurnId: 0
        )
        XCTAssertNotNil(fact)
        guard let fact else { return }

        let factsCount = try await store.queryRowCount("SELECT id FROM facts")
        XCTAssertEqual(factsCount, 1)

        let vecCount = try await store.queryRowCount(
            "SELECT fact_id FROM facts_vec WHERE fact_id = \(fact.id)"
        )
        XCTAssertEqual(
            vecCount, 0,
            "Without an embedder, facts_vec must NOT be populated — degraded but searchable mode."
        )
    }

    func testApplyOpADDPersistsFactWhenEmbedderThrows() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp, embedder: ThrowingEmbedder())

        // The embedder will throw — the fact INSERT must still succeed and
        // be searchable via FTS5. Audit recommendation: "log + leave the FTS
        // row (degraded but searchable) rather than rolling back the fact
        // row."
        let fact = try await store.applyOp(
            .add(subject: "user", predicate: "has_dog_named", object: "Toby", embedding: nil),
            sourceTurnId: 0
        )
        XCTAssertNotNil(fact)
        guard let fact else { return }

        let factsCount = try await store.queryRowCount("SELECT id FROM facts")
        XCTAssertEqual(factsCount, 1,
                       "Embedder failure must not roll back the facts row.")

        let vecCount = try await store.queryRowCount(
            "SELECT fact_id FROM facts_vec WHERE fact_id = \(fact.id)"
        )
        XCTAssertEqual(
            vecCount, 0,
            "When the embedder throws, facts_vec row must be absent (FTS row remains)."
        )
    }

    // MARK: - helpers

    private static func tempDB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoryvecwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.appendingPathComponent("jarvis.db")
    }
}
