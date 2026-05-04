import XCTest
import Foundation
import AgentCore
@testable import Memory

/// Track-D D-4 — end-to-end "remember Brutus" regression scenario.
///
/// Drives the extraction -> store -> search loop with fakes for the
/// vec-dependent + Ollama-dependent surfaces:
///
/// - Real `MemoryExtractionOrchestrator` + `MemoryExtractor`.
/// - Stub `LLMProvider` that turns "My dog Brutus is a Bernese Mountain
///   Dog." into an `apply_memory_ops` ADD call.
/// - In-memory `FakeStore` actor that captures `applyOp` calls and serves
///   the `MemoryReadStore` surface for `HybridSearch` (no real SQLite, no
///   vec0.dylib needed).
/// - Stub `EmbeddingProviding` (returns a constant 768-dim vector).
/// - Real `HybridSearch` actor — what `SearchMemoryTool` calls through
///   `HybridSearchDispatching`. The MCP-side dispatch test lives in
///   `InProcessMemoryToolsTests`.
///
/// **What this protects against:** silent regressions where the
/// extraction pipeline writes facts but the search path can't see them
/// (or vice versa) — the loop break that produced this audit's bullet
/// "memory not actually queryable end-to-end".
final class RememberBrutusEndToEndTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory store that:
    /// 1. Captures `applyOp` calls and assigns auto-incrementing fact ids.
    /// 2. Serves `MemoryReadStore` for `HybridSearch` — returns its
    ///    captured facts as `(Fact, Double)` rows in insertion order with
    ///    flat scores. No real RRF; this isn't a search-quality test.
    actor FakeStore: MemoryReadStore {
        private var facts: [Fact] = []
        private var nextId: Int64 = 1
        private(set) var retrievals: [(FactRef, Int64)] = []

        func applyAdd(subject: String, predicate: String, object: String, sourceTurnId: Int64) -> Fact {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let fact = Fact(
                id: nextId, subject: subject, predicate: predicate, object: object,
                sourceTurnId: sourceTurnId, validFrom: now, validTo: nil,
                supersededBy: nil, forgottenAt: nil, createdAt: now
            )
            nextId += 1
            facts.append(fact)
            return fact
        }

        func snapshot() -> [Fact] { facts }

        // MemoryReadStore conformance.
        func runHybridSearchSQL(query: String, embedding: [Float], k: Int) async throws -> [(Fact, Double)] {
            // Filter active rows; in real SQL this is `valid_to IS NULL
            // AND forgotten_at IS NULL`.
            let active = facts.filter { $0.validTo == nil && $0.forgottenAt == nil }
            return Array(active.prefix(k)).enumerated().map { (i, f) in
                (f, 1.0 / Double(i + 1)) // RRF-like flat scoring
            }
        }
        func recordRetrieval(_ ref: FactRef, triggerTurnId: Int64) async {
            retrievals.append((ref, triggerTurnId))
        }
    }

    /// Stub embedder — constant 768-dim vector. The real
    /// `nomic-embed-text` runs through `OllamaEmbeddingClient`; we don't
    /// exercise that here.
    actor StubEmbedder: EmbeddingProviding {
        func embed(_ input: String) async throws -> [Float] {
            Array(repeating: Float(0.1), count: MemoryConstants.embeddingDim)
        }
    }

    /// Stub provider that emits exactly one ADD op for the Brutus turn,
    /// then `messageStop`. Independent of the system prompt — the
    /// extractor's prompt construction is exercised separately in
    /// `MemoryExtractorTests`.
    final class BrutusProvider: LLMProvider, @unchecked Sendable {
        func stream(
            messages: [LLMMessage],
            tools: [ToolSchema],
            toolChoice: ToolChoice,
            model: ModelID,
            maxOutputTokens: Int,
            cacheHints: CacheHints?
        ) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { cont in
                Task {
                    let payload: [String: Any] = ["ops": [
                        [
                            "op": "ADD",
                            "subject": "Brutus",
                            "predicate": "breed",
                            "object": "Bernese Mountain Dog",
                        ]
                    ]]
                    let json = try! JSONSerialization.data(withJSONObject: payload)
                    cont.yield(.toolUseRequested(
                        ToolUseRequest(id: "t-brutus", name: "apply_memory_ops", argsJSON: json)
                    ))
                    cont.yield(.messageStop)
                    cont.finish()
                }
            }
        }
    }

    // MARK: - Test

    func testExtractionWriteThenSearchFindsBrutus() async throws {
        let store = FakeStore()

        // 1. Extraction wiring.
        let extractor = MemoryExtractor(provider: BrutusProvider())
        let orchestrator = MemoryExtractionOrchestrator(
            extractor: extractor,
            applyOp: { op, turnId in
                guard case let .add(subject, predicate, object, _) = op else {
                    XCTFail("D-4: stub provider should produce only ADD; got \(op)")
                    return
                }
                _ = await store.applyAdd(
                    subject: subject, predicate: predicate, object: object,
                    sourceTurnId: turnId
                )
            }
        )
        await orchestrator.start()

        // 2. User turn 1 — "remember Brutus".
        await orchestrator.enqueue(ExtractionJob(
            turnId: TurnID(rawValue: "turn-brutus-1"),
            userText: "My dog Brutus is a Bernese Mountain Dog.",
            assistantText: "Got it — I'll remember Brutus."
        ))

        // 3. Wait for extraction to drain.
        let deadline = Date().addingTimeInterval(2.0)
        while await store.snapshot().isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let written = await store.snapshot()
        XCTAssertEqual(written.count, 1, "extraction should have written exactly one fact")
        XCTAssertEqual(written.first?.subject, "Brutus")
        XCTAssertEqual(written.first?.predicate, "breed")
        XCTAssertEqual(written.first?.object, "Bernese Mountain Dog")

        // 4. Search wiring — same store, stub embedder.
        let search = HybridSearch(store: store, embedder: StubEmbedder())

        // 5. User turn 2 — "What breed is Brutus?". Search must surface
        //    the fact written in turn 1.
        let hits = try await search.searchFacts(
            query: "What breed is Brutus?",
            k: 5,
            triggerTurnId: 2
        )

        XCTAssertEqual(hits.count, 1, "D-4: search must find the fact written by extraction")
        XCTAssertEqual(hits.first?.summary, "Brutus breed Bernese Mountain Dog",
                       "FactRef.summary is `subject predicate object` per HybridSearch")

        // 6. Retrieval was recorded for DevOverlay correlation (D-05 single
        //    emission site).
        let retrievals = await store.retrievals
        XCTAssertEqual(retrievals.count, 1)
        XCTAssertEqual(retrievals.first?.1, 2)

        await orchestrator.shutdown()
    }
}
