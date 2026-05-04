import XCTest
@testable import Memory

/// Plan 07-03 Task 2 — HybridSearch unit tests with mock embedder + mock store.
final class HybridSearchTests: XCTestCase {

    actor MockEmbedder: EmbeddingProviding {
        var calls: [String] = []
        func embed(_ input: String) async throws -> [Float] {
            calls.append(input)
            return Array(repeating: Float(0.1), count: MemoryConstants.embeddingDim)
        }
    }

    actor MockStore: MemoryReadStore {
        var capturedQuery: String?
        var capturedK: Int?
        var capturedEmbeddingDim: Int?
        var rowsToReturn: [(Fact, Double)] = []
        var retrievalRecords: [(FactRef, Int64)] = []

        func runHybridSearchSQL(query: String, embedding: [Float], k: Int) async throws -> [(Fact, Double)] {
            capturedQuery = query
            capturedK = k
            capturedEmbeddingDim = embedding.count
            return rowsToReturn
        }

        func recordRetrieval(_ ref: FactRef, triggerTurnId: Int64) async {
            retrievalRecords.append((ref, triggerTurnId))
        }

        func setRows(_ rows: [(Fact, Double)]) { rowsToReturn = rows }
    }

    private func makeFact(id: Int64, subject: String, predicate: String, object: String) -> Fact {
        Fact(
            id: id,
            subject: subject, predicate: predicate, object: object,
            sourceTurnId: nil, validFrom: 1, validTo: nil,
            supersededBy: nil, forgottenAt: nil, createdAt: 1
        )
    }

    func testSearchFactsCallsEmbedderOnce() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        await store.setRows([
            (makeFact(id: 1, subject: "Sarah", predicate: "works_at", object: "Acme"), 0.05),
            (makeFact(id: 2, subject: "Sarah", predicate: "lives_in", object: "Boston"), 0.04),
            (makeFact(id: 3, subject: "Sarah", predicate: "drives", object: "Honda"), 0.03),
        ])
        let search = HybridSearch(store: store, embedder: embedder)

        let refs = try await search.searchFacts(query: "hello", k: 5, triggerTurnId: 7)

        let calls = await embedder.calls
        XCTAssertEqual(calls, ["hello"])
        XCTAssertEqual(refs.count, 3)
        let records = await store.retrievalRecords
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0.1 }, [7, 7, 7])
        XCTAssertEqual(records.map { $0.0.factId }, [1, 2, 3])
        XCTAssertEqual(records.map { $0.0.score }, [0.05, 0.04, 0.03])
    }

    func testSearchFactsRespectsKArgument() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        await store.setRows([])
        let search = HybridSearch(store: store, embedder: embedder)
        _ = try await search.searchFacts(query: "x", k: 2, triggerTurnId: 1)
        let k = await store.capturedK
        XCTAssertEqual(k, 2)
    }

    func testSearchFactsReturnsFactRefs() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        await store.setRows([
            (makeFact(id: 1, subject: "S", predicate: "P", object: "O"), 0.5),
        ])
        let search = HybridSearch(store: store, embedder: embedder)
        let refs = try await search.searchFacts(query: "x", k: 1, triggerTurnId: 99)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].summary, "S P O")
        XCTAssertEqual(refs[0].score, 0.5)
        XCTAssertEqual(refs[0].triggerTurnId, 99)
    }

    func testSearchFactsEmptyQueryShortCircuits() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        let search = HybridSearch(store: store, embedder: embedder)
        let refs = try await search.searchFacts(query: "", k: 5, triggerTurnId: 1)
        XCTAssertTrue(refs.isEmpty)
        let calls = await embedder.calls
        XCTAssertEqual(calls, [])
    }

    /// D-07 real-DB integration coverage is gated on JARVIS_VEC0_STUB_PATH;
    /// full implementation lives in 07-06 regression-corpus.
    func testSearchFactsAllSessionsInvariantPlaceholder() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_VEC0_STUB_PATH"] != nil,
                          "Set JARVIS_VEC0_STUB_PATH to enable real-DB cases.")
        XCTAssertTrue(true, "Real-DB execution lives in 07-06 regression-corpus.")
    }

    // MARK: - P2-6: log scrub regression guard
    //
    // T-06-05-03 enforces "voice transcript content is never logged" via a
    // grep gate; memory queries are equivalently user-private content. This
    // test grep-asserts the source file at runtime so a future regression
    // that logs `query='\(query)'` (the pattern that just landed in P2-6)
    // is caught at test time rather than discovered in production logs.
    func testSearchFactsDoesNotLogRawQuery() throws {
        let thisFile = URL(fileURLWithPath: #file)
        let sourceFile = thisFile
            .deletingLastPathComponent()  // MemoryTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Sources/Memory/HybridSearch.swift")

        let contents = try String(contentsOf: sourceFile, encoding: .utf8)
        let nonCommentLines = contents.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // Anti-pattern: emitting the raw query string in any log statement.
        // The current correct shape is `queryLen=\(query.count)` — length only.
        let bannedPattern = "query='\\(query)'"
        XCTAssertFalse(nonCommentLines.contains(bannedPattern),
            "HybridSearch.swift must not log raw query content (P2-6 / T-06-05-03 analog).")

        // Positive: the metadata-only pattern must be present.
        XCTAssertTrue(nonCommentLines.contains("queryLen="),
            "HybridSearch.swift must log query length (queryLen=) instead of raw content.")
    }
}
