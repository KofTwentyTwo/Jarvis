import XCTest
@testable import Memory

final class MemoryStoreTests: XCTestCase {

    /// Without vec0.dylib in Bundle.module (the 07-01 placeholder bundle
    /// state), MemoryStore.init throws .vecLoadFailed. AppDelegate
    /// installMemory() (Plan 07-06) catches this and degrades gracefully.
    func testInitThrowsWhenVecDylibMissing() throws {
        // Defensive: clear the env-var stub so the lookup hits the missing path.
        let priorStub = ProcessInfo.processInfo.environment["JARVIS_VEC0_STUB_PATH"]
        if priorStub != nil {
            unsetenv("JARVIS_VEC0_STUB_PATH")
        }
        defer {
            if let priorStub {
                setenv("JARVIS_VEC0_STUB_PATH", priorStub, 1)
            }
        }

        let tmp = try Self.tempDB()
        XCTAssertThrowsError(try MemoryStore(databaseURL: tmp)) { err in
            guard case MemoryError.vecLoadFailed = err else {
                return XCTFail("Expected MemoryError.vecLoadFailed, got \(err)")
            }
        }
    }

    /// When JARVIS_VEC0_STUB_PATH is set to a real vec0.dylib (e.g., a
    /// developer-installed system copy of sqlite-vec for tests), init
    /// succeeds and the schema tables exist.
    ///
    /// Skipped unless the env var is set — this is an env-gated probe (S-8).
    func testInitWithStubVecDylib() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_VEC0_STUB_PATH"] != nil,
                          "Set JARVIS_VEC0_STUB_PATH to a vec0.dylib to exercise the real load path.")
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

        // facts_vec exists.
        let vecCount = try await store.queryRowCount(
            "SELECT name FROM sqlite_master WHERE name='facts_vec'"
        )
        XCTAssertEqual(vecCount, 1)
    }

    private static func tempDB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorytests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.appendingPathComponent("jarvis.db")
    }
}
