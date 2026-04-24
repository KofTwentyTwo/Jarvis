import XCTest
@testable import Replay

final class SchemaTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-schema-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        // Clean up WAL/SHM siblings if SQLite created them.
        try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        let walPath = dbURL.path + "-wal"
        let shmPath = dbURL.path + "-shm"
        try? FileManager.default.removeItem(atPath: walPath)
        try? FileManager.default.removeItem(atPath: shmPath)
        super.tearDown()
    }

    // S1: After running `Schema.allStatements`, the schema contains exactly
    // four tables: meta, sessions, turns, events.
    func test_S1_createsExactlyFourTables() throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }

        // Filter out internal `sqlite_*` tables (e.g., sqlite_sequence is
        // autocreated by AUTOINCREMENT on events.row_id).
        let names: [String] = try conn.query(
            "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
            map: { $0.columnText(at: 0) ?? "" }
        )
        XCTAssertEqual(Set(names), Set(["meta", "sessions", "turns", "events"]))
    }

    // S2: `turns.retry_of` has a FOREIGN KEY referencing turns(turn_id).
    func test_S2_retryOfForeignKey() throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }

        // PRAGMA foreign_key_list returns one row per FK with columns:
        // (id, seq, table, from, to, on_update, on_delete, match).
        let fks: [(String, String, String)] = try conn.query(
            "PRAGMA foreign_key_list(turns);",
            map: { stmt in
                (
                    stmt.columnText(at: 2) ?? "", // referenced table
                    stmt.columnText(at: 3) ?? "", // from column
                    stmt.columnText(at: 4) ?? ""  // to column
                )
            }
        )
        // We expect at least one FK from `retry_of` -> `turns(turn_id)`.
        XCTAssertTrue(
            fks.contains(where: { $0.0 == "turns" && $0.1 == "retry_of" && $0.2 == "turn_id" }),
            "Expected FK retry_of -> turns(turn_id); got \(fks)"
        )
    }

    // S3: `events.payload_bytes` is BLOB NOT NULL.
    func test_S3_eventsPayloadBytesIsBlobNotNull() throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }

        // PRAGMA table_info returns (cid, name, type, notnull, dflt_value, pk).
        let cols: [(String, String, Int64)] = try conn.query(
            "PRAGMA table_info(events);",
            map: { stmt in
                (
                    stmt.columnText(at: 1) ?? "",
                    stmt.columnText(at: 2) ?? "",
                    stmt.columnInt(at: 3)
                )
            }
        )
        let payload = cols.first(where: { $0.0 == "payload_bytes" })
        XCTAssertNotNil(payload, "expected payload_bytes column")
        XCTAssertEqual(payload?.1.uppercased(), "BLOB")
        XCTAssertEqual(payload?.2, 1, "payload_bytes must be NOT NULL")
    }

    // S4: Indices `events_by_turn` and `turns_by_session` exist.
    func test_S4_indicesExist() throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }

        let indexNames: [String] = try conn.query(
            "SELECT name FROM sqlite_schema WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
            map: { $0.columnText(at: 0) ?? "" }
        )
        XCTAssertTrue(indexNames.contains("events_by_turn"))
        XCTAssertTrue(indexNames.contains("turns_by_session"))
    }

    // S5: Pragmas applied — journal_mode=wal, synchronous=1 (NORMAL),
    // foreign_keys=1, busy_timeout=3000.
    func test_S5_pragmasApplied() throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }

        let journal: String = try conn.query(
            "PRAGMA journal_mode;",
            map: { $0.columnText(at: 0) ?? "" }
        ).first ?? ""
        XCTAssertEqual(journal.lowercased(), "wal")

        let synchronous: Int64 = try conn.query(
            "PRAGMA synchronous;",
            map: { $0.columnInt(at: 0) }
        ).first ?? -1
        XCTAssertEqual(synchronous, 1, "synchronous=NORMAL should report 1")

        let fk: Int64 = try conn.query(
            "PRAGMA foreign_keys;",
            map: { $0.columnInt(at: 0) }
        ).first ?? -1
        XCTAssertEqual(fk, 1)

        let busy: Int64 = try conn.query(
            "PRAGMA busy_timeout;",
            map: { $0.columnInt(at: 0) }
        ).first ?? -1
        XCTAssertEqual(busy, 3000)
    }

    // S6: Initial meta rows seeded — schema_version=1, crash_count=0.
    func test_S6_metaSeeded() throws {
        let conn = try SQLiteConnection.open(at: dbURL)
        for sql in Schema.pragmas { try conn.execute(sql) }
        for sql in Schema.allStatements { try conn.execute(sql) }
        for sql in Schema.seedMeta { try conn.execute(sql) }

        let rows: [(String, String)] = try conn.query(
            "SELECT key, value FROM meta ORDER BY key;",
            map: { ($0.columnText(at: 0) ?? "", $0.columnText(at: 1) ?? "") }
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.0 == "schema_version" })?.1, "1")
        XCTAssertEqual(rows.first(where: { $0.0 == "crash_count" })?.1, "0")
    }

    // S7: Idempotent open — re-running DDL + seed does not duplicate rows or
    // overwrite an updated crash_count.
    func test_S7_idempotentOpen() throws {
        // First open: seed schema and bump crash_count to 5.
        do {
            let conn = try SQLiteConnection.open(at: dbURL)
            for sql in Schema.pragmas { try conn.execute(sql) }
            for sql in Schema.allStatements { try conn.execute(sql) }
            for sql in Schema.seedMeta { try conn.execute(sql) }
            try conn.execute("UPDATE meta SET value='5' WHERE key='crash_count';")
            try conn.close()
        }
        // Second open: schema + seed must NOT clobber the bumped crash_count.
        do {
            let conn = try SQLiteConnection.open(at: dbURL)
            for sql in Schema.pragmas { try conn.execute(sql) }
            for sql in Schema.allStatements { try conn.execute(sql) }
            for sql in Schema.seedMeta { try conn.execute(sql) }

            let crash: String = try conn.query(
                "SELECT value FROM meta WHERE key='crash_count';",
                map: { $0.columnText(at: 0) ?? "" }
            ).first ?? ""
            XCTAssertEqual(crash, "5", "INSERT OR IGNORE preserved updated crash_count")

            // No row duplication.
            let count: Int64 = try conn.query(
                "SELECT COUNT(*) FROM meta;",
                map: { $0.columnInt(at: 0) }
            ).first ?? 0
            XCTAssertEqual(count, 2)
            try conn.close()
        }
    }
}
