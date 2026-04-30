import XCTest
@testable import Memory
import AgentCore
import OllamaProvider

// MARK: - MemoryRegressionCorpusTests
//
// Scaffold-time regression corpus for the Phase 7 memory subsystem
// (RESEARCH Open Q #3). 10 end-to-end scenarios covering ADD/UPDATE/NOOP
// extraction, supersede invariants, FTS5+vec hybrid retrieval ranking,
// and forget_fact validity-closure semantics.
//
// Gated by JARVIS_REAL_MODELS=1 — skipped in CI. Runs interactively against
// a real local Ollama with both `nomic-embed-text` (embedding) and
// `qwen2.5-coder:32b` (extractor) pulled.
//
// Run interactively on the developer's Apple Silicon Mac:
//   JARVIS_REAL_MODELS=1 swift test --package-path packages/Memory --filter MemoryRegressionCorpusTests
//
// The test fixture spins up a fresh sqlite DB (under
// FileManager.default.temporaryDirectory) per test so scenarios don't
// bleed state. Each test is its own transaction boundary.
//
// Pattern source: packages/Voice/Tests/VoiceTests/OrpheusTTFATests.swift
// lines 26-29 (env-gated probe gate).
//
// Note: many real-DB cases also depend on `vec0.dylib` being available
// (currently env-gated via JARVIS_VEC0_STUB_PATH; bundling deferred to
// a future ops plan). When `vec0.dylib` isn't loadable, MemoryStore.init
// throws MemoryError.vecLoadFailed; the test surfaces that as a SKIP
// (the regression corpus is a developer-only convenience).

final class MemoryRegressionCorpusTests: XCTestCase {

    // MARK: - Env gate

    private func skipIfNotRealModels() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JARVIS_REAL_MODELS"] == "1",
            "Set JARVIS_REAL_MODELS=1 to run memory regression corpus (requires local Ollama with nomic-embed-text + qwen2.5-coder:32b, plus a loadable vec0.dylib)"
        )
    }

    // MARK: - Fixture

    private struct Fixture: Sendable {
        let store: MemoryStore
        let embedder: OllamaEmbeddingClient
        let extractor: MemoryExtractor
    }

    private func freshFixture() async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memcorpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dbURL = tmp.appendingPathComponent("jarvis.db")

        let store = try MemoryStore(databaseURL: dbURL)
        let embedder = try OllamaEmbeddingClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        let provider = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:11434")!)
        let extractor = MemoryExtractor(provider: provider)
        return Fixture(store: store, embedder: embedder, extractor: extractor)
    }

    // MARK: - Scenarios 1-3: ADD / UPDATE / NOOP extraction (D-03 / MEM-04)

    func testScenario01_AddNewDurableFact() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        let ops = try await f.extractor.extract(
            userText: "My favorite editor is Helix.",
            assistantText: "Got it — I'll remember Helix as your editor of choice.",
            priorActiveFacts: []
        )

        let adds = ops.filter { if case .add = $0 { return true } else { return false } }
        XCTAssertEqual(adds.count, 1, "Expected exactly one ADD op; got: \(ops)")

        // Apply and assert row is active.
        for op in ops {
            _ = try await f.store.applyOp(op, sourceTurnId: 1)
        }
        let active = try await f.store.searchFacts(query: "editor", k: 5, embedder: f.embedder)
        XCTAssertTrue(active.contains(where: { $0.object.lowercased().contains("helix") }))
    }

    func testScenario02_NoopOnTrivia() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        let ops = try await f.extractor.extract(
            userText: "How tall is the Eiffel Tower?",
            assistantText: "The Eiffel Tower is 330 meters tall.",
            priorActiveFacts: []
        )

        let mutations = ops.filter {
            switch $0 {
            case .add, .update: return true
            case .noop: return false
            }
        }
        XCTAssertEqual(mutations.count, 0, "Trivia should yield NOOP only; got: \(ops)")
    }

    func testScenario03_UpdateOnContradiction() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        // Seed: the prior fact.
        let seedAdd: MemoryOp = .add(
            subject: "user", predicate: "favorite_editor", object: "Helix", embedding: nil
        )
        _ = try await f.store.applyOp(seedAdd, sourceTurnId: 1)
        let seeded = try await f.store.searchFacts(query: "editor", k: 5, embedder: f.embedder)
        XCTAssertTrue(seeded.contains(where: { $0.object.lowercased().contains("helix") }))

        // New turn that should produce an UPDATE.
        let priorActive = try await f.store.queryActiveFacts(matching: "user")
        let ops = try await f.extractor.extract(
            userText: "Actually I switched to Zed last week.",
            assistantText: "Updated — Zed is now your editor.",
            priorActiveFacts: priorActive
        )

        let updates = ops.filter { if case .update = $0 { return true } else { return false } }
        XCTAssertEqual(updates.count, 1, "Contradiction should yield exactly one UPDATE; got: \(ops)")
    }

    // MARK: - Scenarios 4-5: Supersede invariants (MEM-05)

    func testScenario04_SupersedeNeverDeletes() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        // Seed.
        _ = try await f.store.applyOp(
            .add(subject: "user", predicate: "favorite_editor", object: "Helix", embedding: nil),
            sourceTurnId: 1
        )
        let priorRows = try await f.store.rawCountFacts(predicate: "favorite_editor")
        XCTAssertEqual(priorRows, 1)

        // Supersede.
        let priorActive = try await f.store.activeFacts(subject: "user", predicate: "favorite_editor")
        let priorId = priorActive.first?.id
        XCTAssertNotNil(priorId)
        _ = try await f.store.applyOp(
            .update(supersedes: priorId!,
                    subject: "user", predicate: "favorite_editor", object: "Zed", embedding: nil),
            sourceTurnId: 2
        )

        // Both rows must exist (no DELETE).
        let allRows = try await f.store.rawCountFacts(predicate: "favorite_editor")
        XCTAssertEqual(allRows, 2, "MEM-05: supersede must NEVER delete the prior row.")

        // Old row's valid_to is set; superseded_by points to the new row.
        let oldRow = try await f.store.factById(priorId!)
        XCTAssertNotNil(oldRow?.validTo,
                        "Superseded row must have valid_to populated.")
        XCTAssertNotNil(oldRow?.supersededBy,
                        "Superseded row must link superseded_by.")
    }

    func testScenario05_SupersedeIndexHonored() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        _ = try await f.store.applyOp(
            .add(subject: "user", predicate: "favorite_editor", object: "Helix", embedding: nil),
            sourceTurnId: 1
        )
        let priorActive = try await f.store.activeFacts(subject: "user", predicate: "favorite_editor")
        let priorId = priorActive.first?.id
        XCTAssertNotNil(priorId)
        _ = try await f.store.applyOp(
            .update(supersedes: priorId!,
                    subject: "user", predicate: "favorite_editor", object: "Zed", embedding: nil),
            sourceTurnId: 2
        )

        // Active query (uses idx_facts_active partial index) returns exactly
        // the new row.
        let activeRows = try await f.store.activeFacts(
            subject: "user", predicate: "favorite_editor"
        )
        XCTAssertEqual(activeRows.count, 1)
        XCTAssertEqual(activeRows.first?.object.lowercased(), "zed")
    }

    // MARK: - Scenarios 6-8: FTS5+vec hybrid retrieval ranking (MEM-07)

    func testScenario06_HybridRetrievalKeywordHit() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        _ = try await f.store.applyOp(.add(subject: "user", predicate: "city", object: "Brooklyn", embedding: nil),
                                      sourceTurnId: 1)
        _ = try await f.store.applyOp(.add(subject: "user", predicate: "occupation", object: "Pilot", embedding: nil),
                                      sourceTurnId: 2)
        _ = try await f.store.applyOp(.add(subject: "user", predicate: "favorite_food", object: "Sushi", embedding: nil),
                                      sourceTurnId: 3)

        let results = try await f.store.searchFacts(query: "Brooklyn", k: 5, embedder: f.embedder)
        XCTAssertTrue(results.first?.object == "Brooklyn",
                      "Exact keyword hit must rank first; got: \(results)")
    }

    func testScenario07_HybridRetrievalSemanticHit() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        _ = try await f.store.applyOp(.add(subject: "user", predicate: "city", object: "Brooklyn", embedding: nil),
                                      sourceTurnId: 1)
        _ = try await f.store.applyOp(.add(subject: "user", predicate: "occupation", object: "Pilot", embedding: nil),
                                      sourceTurnId: 2)
        _ = try await f.store.applyOp(.add(subject: "user", predicate: "favorite_food", object: "Sushi", embedding: nil),
                                      sourceTurnId: 3)

        // Paraphrase: no keyword overlap with "Pilot".
        let results = try await f.store.searchFacts(query: "airline captain", k: 5, embedder: f.embedder)
        XCTAssertEqual(results.first?.object, "Pilot",
                       "Semantic hit must rank first when no keyword overlap; got: \(results)")
    }

    func testScenario08_HybridRetrievalActiveOnly() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        _ = try await f.store.applyOp(.add(subject: "user", predicate: "city", object: "Brooklyn", embedding: nil),
                                      sourceTurnId: 1)
        let priorActive = try await f.store.activeFacts(subject: "user", predicate: "city")
        let priorId = priorActive.first?.id
        XCTAssertNotNil(priorId)
        _ = try await f.store.applyOp(
            .update(supersedes: priorId!,
                    subject: "user", predicate: "city", object: "Manhattan", embedding: nil),
            sourceTurnId: 2
        )

        let results = try await f.store.searchFacts(query: "Brooklyn", k: 5, embedder: f.embedder)
        XCTAssertFalse(results.contains(where: { $0.id == priorId }),
                       "Superseded fact must NOT appear in retrieval (valid_to IS NULL filter).")
    }

    // MARK: - Scenarios 9-10: forget_fact (D-02)

    func testScenario09_ForgetClosesValidTo() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        _ = try await f.store.applyOp(.add(subject: "user", predicate: "city", object: "Brooklyn", embedding: nil),
                                      sourceTurnId: 1)
        let priorActive = try await f.store.activeFacts(subject: "user", predicate: "city")
        let factId = priorActive.first?.id
        XCTAssertNotNil(factId)

        _ = try await f.store.forgetFact(id: factId!, triggerTurnId: 99)

        // Row still exists.
        let row = try await f.store.factById(factId!)
        XCTAssertNotNil(row, "D-02: forget_fact must NEVER delete; got nil row.")

        // valid_to and forgotten_at both populated.
        XCTAssertNotNil(row?.validTo)
        XCTAssertNotNil(row?.forgottenAt)
    }

    func testScenario10_ForgottenFactNotRetrieved() async throws {
        try skipIfNotRealModels()
        let f = try await freshFixture()

        _ = try await f.store.applyOp(.add(subject: "user", predicate: "city", object: "Brooklyn", embedding: nil),
                                      sourceTurnId: 1)
        let priorActive = try await f.store.activeFacts(subject: "user", predicate: "city")
        let factId = priorActive.first?.id
        XCTAssertNotNil(factId)
        _ = try await f.store.forgetFact(id: factId!, triggerTurnId: 99)

        let results = try await f.store.searchFacts(query: "Brooklyn", k: 5, embedder: f.embedder)
        XCTAssertFalse(results.contains(where: { $0.id == factId }),
                       "Forgotten fact must NOT appear in active search.")
    }
}
