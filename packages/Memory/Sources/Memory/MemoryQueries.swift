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

    /// B-02 turn-row writer. Single row per (role, content) pair.
    /// Bindings (positional): session_id, role, content, source, created_at.
    /// The schema's FTS5 trigger (MemorySchema.swift:74) mirrors `content`
    /// into `turns_fts` automatically — no separate insert needed.
    public static let turnInsertSQL: String = """
    INSERT INTO turns(session_id, role, content, source, created_at)
    VALUES (?, ?, ?, ?, ?);
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

    /// Track-D D-3: recent active facts feed for the mem0 extractor's
    /// priorFacts context. Used by `MemoryExtractionOrchestrator.process`
    /// to give the model UPDATE-vs-ADD information without doing per-job
    /// FTS5 shortlisting (Plan 07-03 deferred work). Bindings: limit.
    public static let recentActiveFactsSQL: String = """
    SELECT id, subject, predicate, object, source_turn_id, valid_from, valid_to,
           superseded_by, forgotten_at, created_at
    FROM facts
    WHERE valid_to IS NULL
      AND forgotten_at IS NULL
    ORDER BY created_at DESC
    LIMIT ?;
    """

    /// Audit 2026-05-12 / M-5 (Issue #16) — FTS5-safe query rewriter.
    ///
    /// `hybridSearchSQL` binds the query text directly to `facts_fts MATCH ?`.
    /// FTS5's MATCH grammar accepts terms, AND/OR/NOT/NEAR, column filters,
    /// and phrase quoting — but raw natural language with `?`, `'`, `:`, `-`,
    /// `*`, or other reserved characters throws `fts5: syntax error` at the
    /// SQLite layer. Live probe before this fix:
    ///   sqlite3 jarvis.db "SELECT rowid FROM facts_fts
    ///     WHERE facts_fts MATCH 'what is my dog name?'"
    ///   → Error: stepping, fts5: syntax error near "?"
    ///
    /// Rewriter strategy (simplest defensible):
    ///   1. Replace anything that isn't a unicode letter or digit with a
    ///      space. This drops `?`, `'`, `:`, `-`, `*`, `(`, `)`, `"`, etc.
    ///   2. Split on whitespace.
    ///   3. Wrap each remaining token in double quotes, escaping any
    ///      embedded `"` per FTS5 grammar (doubled `""`). The class-1
    ///      filter strips `"` characters, so step (3) escape is belt-and-
    ///      suspenders against future relaxation of the class filter.
    ///   4. Join tokens with spaces.
    ///
    /// Turns `"what is my dog's name?"` into
    /// `"what" "is" "my" "dog" "s" "name"` — a FTS5-safe phrase-OR query.
    /// Returns nil if no usable tokens remain (caller short-circuits to
    /// empty results rather than binding an empty MATCH that would itself
    /// be a syntax error).
    ///
    /// Long-term we want a real query AST; this is the minimum fix that
    /// stops the footgun #14 (preamble add) is about to wire up.
    public static func sanitizeFTS5Query(_ raw: String) -> String? {
        // Step 1: replace non-alphanumeric (per Unicode) with space.
        let scalarsKept = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let scrubbed = String(scalarsKept)

        // Step 2: split on whitespace, drop empties.
        let tokens = scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        // Step 3 + 4: double-quote each token (escape any internal " per
        // FTS5 — doubled), join with spaces.
        let quoted = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return quoted.joined(separator: " ")
    }
}
