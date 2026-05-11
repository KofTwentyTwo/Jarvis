import XCTest
@testable import Memory

/// **D-5/D-6 closure (2026-05-11):** vec0 is now statically linked into
/// CSQLiteVec (jkrukowski/SQLiteVec). `MemoryStore.init` always has vec0
/// available — there's no "missing dylib" path to test. The prior
/// `testInitThrowsWhenVecDylibMissing` case was removed; its dormant-
/// memory rationale no longer applies because AppDelegate.installMemory
/// hard-fails at boot (no graceful degradation).
final class MemoryStoreTests: XCTestCase {

    /// MemoryStore.init succeeds: schema tables exist, WAL is active, and
    /// the `facts_vec` virtual table (vec0-backed) was created during
    /// migration — proving auto-extension registration via
    /// `CSQLiteVec.core_vec_init()` fired before `sqlite3_open`.
    func testInitCreatesSchemaWithVec0Available() async throws {
        let tmp = try Self.tempDB()
        let store = try MemoryStore(databaseURL: tmp)

        // turns + facts tables exist.
        let count = try await store.queryRowCount(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('turns','facts')"
        )
        XCTAssertEqual(count, 2)

        // WAL active.
        let mode = try await store.querySingleString("PRAGMA journal_mode")
        XCTAssertEqual(mode?.lowercased(), "wal")

        // facts_vec virtual table exists — the load-bearing vec0 proof.
        let vecCount = try await store.queryRowCount(
            "SELECT name FROM sqlite_master WHERE name='facts_vec'"
        )
        XCTAssertEqual(vecCount, 1)

        // vec_version() reads back — auto-extension registration succeeded.
        let v = try await store.querySingleString("SELECT vec_version()")
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.hasPrefix("v") == true, "vec_version must be tagged like 'v0.1.x'")
    }

    private static func tempDB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorytests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.appendingPathComponent("jarvis.db")
    }
}
