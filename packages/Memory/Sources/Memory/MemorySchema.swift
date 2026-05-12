import Foundation

/// Memory subsystem schema (RESEARCH section 1, section 3).
///
/// All CREATE statements use `IF NOT EXISTS` so re-opening an existing DB is a
/// no-op. The facts_vec virtual table interpolates MemoryConstants.embeddingDim
/// — the canonical embedding-dimension constant (MEM-02) is the single source
/// of truth.
public enum MemorySchema {

    public static let pragmas: [String] = [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        "PRAGMA busy_timeout=3000;",
        "PRAGMA foreign_keys=ON;",
        "PRAGMA temp_store=MEMORY;",
    ]

    public static let allStatements: [String] = [
        // RESEARCH section 1: Raw turns (TEXT-03 browsing + replay corpus).
        """
        CREATE TABLE IF NOT EXISTS turns (
          id INTEGER PRIMARY KEY,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          source TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id, created_at);",

        // Facts table — temporal validity + supersede chain + soft delete.
        //
        // `source_turn_id` is a CORRELATION TAG, NOT a foreign key. The
        // memory-extraction writer (`MemoryExtractionOrchestrator.process`)
        // FNV-1a-hashes the originating `TurnID` UUID to an Int64 because
        // `TurnID` is a string-backed UUID and the writer needs an integer
        // column. The hash space and `turns.id` (AUTOINCREMENT) never
        // collide by design — they're disjoint number systems — so any
        // `REFERENCES turns(id)` on this column would fail every insert
        // with SQLITE_CONSTRAINT_FOREIGNKEY (code 19). The constraint was
        // present in the original schema and silently broke fact persistence
        // for the entire history of the project until the 2026-05-12 dogfood
        // surfaced it. Reintroducing the FK without first wiring the writer
        // to use real `turns.id` rowids would re-break persistence.
        //
        // `superseded_by REFERENCES facts(id)` IS a real FK — the supersede
        // chain uses `priorFact.id` from a previous `applyOp` return value,
        // which is the actual AUTOINCREMENT rowid.
        """
        CREATE TABLE IF NOT EXISTS facts (
          id INTEGER PRIMARY KEY,
          subject TEXT NOT NULL,
          predicate TEXT NOT NULL,
          object TEXT NOT NULL,
          source_turn_id INTEGER,
          valid_from INTEGER NOT NULL,
          valid_to INTEGER,
          superseded_by INTEGER REFERENCES facts(id),
          forgotten_at INTEGER,
          created_at INTEGER NOT NULL
        );
        """,
        // Partial index: only currently-active rows (valid_to IS NULL AND forgotten_at IS NULL).
        "CREATE INDEX IF NOT EXISTS idx_facts_active ON facts(subject, predicate) WHERE valid_to IS NULL AND forgotten_at IS NULL;",

        // RESEARCH section 1: FTS5 virtual tables. unicode61 + remove_diacritics 2 for international names (Pitfall P8).
        "CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(subject, predicate, object, content=facts, content_rowid=id, tokenize='unicode61 remove_diacritics 2');",
        "CREATE VIRTUAL TABLE IF NOT EXISTS turns_fts USING fts5(content, content=turns, content_rowid=id, tokenize='unicode61 remove_diacritics 2');",

        // FTS5 content-table sync triggers (RESEARCH section 1 — INS/UPD/DEL on the content table replicates to fts).
        """
        CREATE TRIGGER IF NOT EXISTS facts_fts_ai AFTER INSERT ON facts BEGIN
          INSERT INTO facts_fts(rowid, subject, predicate, object) VALUES (new.id, new.subject, new.predicate, new.object);
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS facts_fts_ad AFTER DELETE ON facts BEGIN
          INSERT INTO facts_fts(facts_fts, rowid, subject, predicate, object) VALUES ('delete', old.id, old.subject, old.predicate, old.object);
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS facts_fts_au AFTER UPDATE ON facts BEGIN
          INSERT INTO facts_fts(facts_fts, rowid, subject, predicate, object) VALUES ('delete', old.id, old.subject, old.predicate, old.object);
          INSERT INTO facts_fts(rowid, subject, predicate, object) VALUES (new.id, new.subject, new.predicate, new.object);
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS turns_fts_ai AFTER INSERT ON turns BEGIN
          INSERT INTO turns_fts(rowid, content) VALUES (new.id, new.content);
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS turns_fts_ad AFTER DELETE ON turns BEGIN
          INSERT INTO turns_fts(turns_fts, rowid, content) VALUES ('delete', old.id, old.content);
        END;
        """,

        // RESEARCH section 1 + section 3: vector table. Interpolates MemoryConstants.embeddingDim.
        // sqlite-vec requires the dimension as a literal in the column type; no parameterization.
        // The canonical embedding-dim constant (MEM-02) — schema and code share one symbol.
        "CREATE VIRTUAL TABLE IF NOT EXISTS facts_vec USING vec0(fact_id INTEGER PRIMARY KEY, embedding FLOAT[\(MemoryConstants.embeddingDim)]);",
    ]
}
