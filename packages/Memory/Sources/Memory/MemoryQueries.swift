import Foundation

/// Static SQL strings for the memory read path (Plan 07-03).
///
/// Hybrid search SQL is the RESEARCH section 8 RRF expression with two
/// adaptations:
///   1. The active-row predicate is layered onto the final SELECT
///      (`f.valid_to IS NULL AND f.forgotten_at IS NULL`) — D-02 forgotten
///      facts are excluded from active queries.
///   2. The vec0 cohort templates `AND k = <literal>` (RESEARCH P9: forgetting
///      `k` silently returns zero rows; vec0 cannot bind k).
///
/// RRF k constant (`rrfK`) is exposed as a planner-tunable per CONTEXT.md
/// "Claude's Discretion: hybrid search ranking weights". Default 60 matches
/// RESEARCH section 8 verbatim.
///
/// D-07 all-sessions: there is NO `session_id` predicate in the hybrid SQL.
/// search_memory deliberately searches the full facts table.
public enum MemoryQueries {

    /// Reciprocal-Rank-Fusion constant. RESEARCH section 8 uses 60.
    public static let rrfK: Int = 60

    /// Hybrid search SQL. Bindings (positional):
    ///   1. text query for FTS5 MATCH
    ///   2. query embedding BLOB for vec0 MATCH
    ///
    /// `k` is interpolated as a literal (vec0 requires it; RESEARCH P9).
    ///
    /// Returned columns: f.id, f.subject, f.predicate, f.object, f.valid_from,
    /// f.valid_to, fused.rrf — the rrf column lets the caller surface a score
    /// in FactRef.
    public static func hybridSearchSQL(k: Int) -> String {
        let kLiteral = max(1, k)
        return """
        WITH
          kw AS (
            SELECT rowid AS fact_id, bm25(facts_fts) AS s
            FROM facts_fts
            WHERE facts_fts MATCH ?
            LIMIT \(kLiteral)
          ),
          vc AS (
            SELECT fact_id, distance AS s
            FROM facts_vec
            WHERE embedding MATCH ?
              AND k = \(kLiteral)
          ),
          fused AS (
            SELECT fact_id, SUM(1.0/(\(rrfK)+rank)) AS rrf FROM (
              SELECT fact_id, ROW_NUMBER() OVER (ORDER BY s ASC) AS rank FROM kw
              UNION ALL
              SELECT fact_id, ROW_NUMBER() OVER (ORDER BY s ASC) AS rank FROM vc
            ) GROUP BY fact_id
          )
        SELECT f.id, f.subject, f.predicate, f.object, f.valid_from, f.valid_to, fused.rrf
        FROM facts f
        JOIN fused ON f.id = fused.fact_id
        WHERE f.valid_to IS NULL AND f.forgotten_at IS NULL
        ORDER BY fused.rrf DESC
        LIMIT \(kLiteral);
        """
    }

    /// TEXT-03 chat-panel hydration source. Bindings: session_id, limit.
    public static let sessionHistorySQL: String = """
    SELECT id, session_id, role, content, source, created_at
    FROM turns
    WHERE session_id = ?
    ORDER BY created_at DESC, id DESC
    LIMIT ?;
    """

    /// D-02 forget tool dispatch. Bindings: now, now, fact_id.
    /// `WHERE valid_to IS NULL AND forgotten_at IS NULL` makes this idempotent
    /// (second call matches 0 rows). NEVER DELETEs.
    public static let forgetFactSQL: String = """
    UPDATE facts
       SET valid_to = ?, forgotten_at = ?
     WHERE id = ?
       AND valid_to IS NULL
       AND forgotten_at IS NULL;
    """

    /// Subject lookup for queryActiveFacts.
    public static let activeFactsBySubjectSQL: String = """
    SELECT id, subject, predicate, object, source_turn_id, valid_from, valid_to,
           superseded_by, forgotten_at, created_at
    FROM facts
    WHERE subject = ?
      AND valid_to IS NULL
      AND forgotten_at IS NULL
    ORDER BY created_at DESC;
    """
}
