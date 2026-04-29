import XCTest
@testable import Memory

final class MemorySchemaTests: XCTestCase {

    /// Schema string interpolation must produce a literal "FLOAT[768]" — not
    /// the raw template string. If this fails, the executor wrote backslash-paren
    /// without Swift's interpolation evaluating it (likely double-escaped).
    func testSchemaInterpolatesEmbeddingDim() {
        let joined = MemorySchema.allStatements.joined(separator: "\n")
        XCTAssertTrue(joined.contains("FLOAT[768]"),
                      "facts_vec DDL must contain the literal FLOAT[768]; got:\n\(joined)")
        XCTAssertFalse(joined.contains("MemoryConstants.embeddingDim"),
                       "facts_vec DDL must contain the interpolated value, not the symbol literal.")
    }

    /// Schema must include the WAL pragma + foreign keys + busy_timeout.
    func testPragmasIncludeWAL() {
        let joined = MemorySchema.pragmas.joined(separator: "\n")
        XCTAssertTrue(joined.contains("PRAGMA journal_mode=WAL"))
        XCTAssertTrue(joined.contains("PRAGMA foreign_keys=ON"))
        XCTAssertTrue(joined.contains("PRAGMA busy_timeout=3000"))
    }

    /// D-02: forgotten_at column must be in the facts DDL.
    func testFactsDDLHasForgottenAt() {
        let factsDDL = MemorySchema.allStatements.first(where: { $0.contains("CREATE TABLE IF NOT EXISTS facts") }) ?? ""
        XCTAssertTrue(factsDDL.contains("forgotten_at INTEGER"),
                      "D-02 forget_fact tool requires forgotten_at column on facts.")
        XCTAssertTrue(factsDDL.contains("valid_from INTEGER NOT NULL"),
                      "MEM-05 temporal validity requires valid_from NOT NULL.")
        XCTAssertTrue(factsDDL.contains("valid_to INTEGER"),
                      "MEM-05 temporal validity requires valid_to (nullable).")
        XCTAssertTrue(factsDDL.contains("superseded_by INTEGER REFERENCES facts(id)"),
                      "MEM-05 supersede graph requires superseded_by FK.")
    }

    /// idx_facts_active is a partial index — only on rows where valid_to IS NULL AND forgotten_at IS NULL.
    func testActiveIndexIsPartial() {
        let idxDDL = MemorySchema.allStatements.first(where: { $0.contains("idx_facts_active") }) ?? ""
        XCTAssertTrue(idxDDL.contains("WHERE valid_to IS NULL AND forgotten_at IS NULL"),
                      "Partial index keeps the hot active-fact lookup fast; missing predicate scans the full table.")
    }
}
