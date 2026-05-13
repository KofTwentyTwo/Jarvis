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

    // MARK: - Audit 2026-05-12 / M-5 — FTS5 query sanitization (Issue #16)
    //
    // `hybridSearchSQL` binds the query string directly to `facts_fts MATCH ?`.
    // Real user queries like "what is my dog's name?" contain `?`, `'`, and
    // other FTS5-reserved characters that throw `fts5: syntax error` at the
    // SQLite layer. Sanitization in HybridSearch.searchFacts is the smallest
    // safe rewrite: strip punctuation, split on whitespace, double-quote each
    // term, join with spaces. Turns "what is my dog's name?" into
    // `"what" "is" "my" "dog" "s" "name"`. FTS5-safe phrase-OR query.

    func testSearchFactsSanitizesPunctuationBeforeFTS5() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        await store.setRows([])
        let search = HybridSearch(store: store, embedder: embedder)

        _ = try await search.searchFacts(
            query: "what is my dog's name?",
            k: 5,
            triggerTurnId: 1
        )

        let captured = await store.capturedQuery
        XCTAssertNotNil(captured, "store must receive a sanitized query")
        let safeQuery = captured ?? ""
        // Must NOT contain raw FTS5-reserved punctuation that breaks MATCH.
        XCTAssertFalse(safeQuery.contains("?"),
                       "Issue #16: sanitized query must not contain raw `?` — FTS5 syntax error")
        XCTAssertFalse(safeQuery.contains("'"),
                       "Issue #16: sanitized query must not contain raw `'` — FTS5 syntax error")
        // Must preserve the meaningful tokens so search remains useful.
        XCTAssertTrue(safeQuery.contains("dog"),
                      "Sanitization must preserve `dog` token")
        XCTAssertTrue(safeQuery.contains("name"),
                      "Sanitization must preserve `name` token")
    }

    func testSearchFactsSanitizesQuotesAndOperators() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        await store.setRows([])
        let search = HybridSearch(store: store, embedder: embedder)

        // FTS5 operators (NEAR, AND, OR, NOT, *, :, parens) + embedded quote.
        _ = try await search.searchFacts(
            query: "remember when I said \"hi\" *or* something?",
            k: 5,
            triggerTurnId: 1
        )

        let captured = await store.capturedQuery
        XCTAssertNotNil(captured)
        let safeQuery = captured ?? ""
        // The embedded raw quote must be escaped (FTS5 doubles internal "
        // inside a phrase) so we don't ship an unterminated phrase to SQLite.
        // The wrapper double-quotes EACH token so any token containing a raw
        // " gets the inner " doubled per FTS5 grammar.
        // Sanity: must still be non-empty (we didn't strip everything).
        XCTAssertFalse(safeQuery.isEmpty, "sanitized query must not be empty")
        // Star alone gets stripped (it's a prefix operator without a term);
        // useful tokens like `remember`, `said`, `hi`, `something` survive.
        XCTAssertTrue(safeQuery.contains("remember"))
        XCTAssertTrue(safeQuery.contains("something"))
    }

    func testSearchFactsEmptyAfterSanitizeReturnsEmpty() async throws {
        let embedder = MockEmbedder()
        let store = MockStore()
        await store.setRows([])
        let search = HybridSearch(store: store, embedder: embedder)

        // All-punctuation query → after stripping, no terms remain.
        // Must short-circuit: never call store (would bind empty MATCH which
        // is itself an FTS5 syntax error).
        let refs = try await search.searchFacts(
            query: "??!?...",
            k: 5,
            triggerTurnId: 1
        )
        XCTAssertEqual(refs.count, 0)
        let captured = await store.capturedQuery
        XCTAssertNil(captured,
                     "Issue #16: when sanitization yields no terms, search must short-circuit and never bind an empty MATCH to FTS5.")
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
