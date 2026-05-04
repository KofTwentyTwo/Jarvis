import XCTest
@testable import Memory

/// Plan 07-03 Task 2 — SessionHistory unit tests with mock store.
final class SessionHistoryTests: XCTestCase {

    actor MockStore: SessionHistoryReading {
        var capturedSessionId: String?
        var capturedLimit: Int?
        var rowsToReturn: [TurnRow] = []

        func recentTurnsForSession(sessionId: String, limit: Int) async throws -> [TurnRow] {
            capturedSessionId = sessionId
            capturedLimit = limit
            return rowsToReturn
        }

        func setRows(_ rows: [TurnRow]) { rowsToReturn = rows }
    }

    private func makeRow(id: Int64, sessionId: String, createdAt: Int64) -> TurnRow {
        TurnRow(id: id, sessionId: sessionId, role: "user", content: "hi",
                source: "userText", createdAt: createdAt)
    }

    func testRecentTurnsPassesSessionAndLimit() async throws {
        let store = MockStore()
        await store.setRows([])
        let hist = SessionHistory(store: store)
        _ = try await hist.recentTurns(sessionId: "A", limit: 7)
        let sid = await store.capturedSessionId
        let lim = await store.capturedLimit
        XCTAssertEqual(sid, "A")
        XCTAssertEqual(lim, 7)
    }

    func testRecentTurnsCapsLimit() async throws {
        let store = MockStore()
        await store.setRows([])
        let hist = SessionHistory(store: store)
        _ = try await hist.recentTurns(sessionId: "A", limit: 100_000)
        let lim = await store.capturedLimit
        XCTAssertEqual(lim, 500)
    }

    func testRecentTurnsReturnsRowsAsIs() async throws {
        let store = MockStore()
        let row = makeRow(id: 1, sessionId: "A", createdAt: 5)
        await store.setRows([row])
        let hist = SessionHistory(store: store)
        let rows = try await hist.recentTurns(sessionId: "A", limit: 50)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], row)
    }
}
