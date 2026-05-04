import XCTest
@testable import JarvisMCP

/// Plan 07-03 Task 3 — end-to-end tests for the three in-process MCP tools
/// dispatched through InProcessToolRegistry. Mock HybridSearch /
/// SessionHistory / forget surfaces avoid a real DB.
final class InProcessMemoryToolsTests: XCTestCase {

    actor MockHybrid: HybridSearchDispatching {
        var calls: [(String, Int, Int64)] = []
        var rowsToReturn: [SearchMemoryHit] = []
        func searchFacts(query: String, k: Int, triggerTurnId: Int64) async throws -> [SearchMemoryHit] {
            calls.append((query, k, triggerTurnId))
            return rowsToReturn
        }
        func setRows(_ rows: [SearchMemoryHit]) { rowsToReturn = rows }
    }

    actor MockHistory: SessionHistoryDispatching {
        var calls: [(String, Int)] = []
        var rowsToReturn: [SearchConversationTurn] = []
        func recentTurns(sessionId: String, limit: Int) async throws -> [SearchConversationTurn] {
            calls.append((sessionId, limit))
            return rowsToReturn
        }
        func setRows(_ rows: [SearchConversationTurn]) { rowsToReturn = rows }
    }

    actor MockForget: ForgetFactDispatching {
        var calls: [(Int64, Int64)] = []
        var nextResult: Bool = true
        func forgetFact(id: Int64, triggerTurnId: Int64) async throws -> Bool {
            calls.append((id, triggerTurnId))
            return nextResult
        }
        func set(_ value: Bool) { nextResult = value }
    }

    func testSearchMemoryToolDispatch() async throws {
        let stub = MockHybrid()
        await stub.setRows([
            SearchMemoryHit(factId: 1, summary: "S P O", score: 0.5, triggerTurnId: 42),
        ])
        let registry = InProcessToolRegistry()
        await registry.register(SearchMemoryTool(dispatcher: stub))

        let args = try JSONSerialization.data(withJSONObject: [
            "query": "Sarah", "k": 5, "triggerTurnId": 42,
        ])
        let result = try await registry.dispatch("search_memory", args: args)

        let calls = await stub.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "Sarah")
        XCTAssertEqual(calls[0].1, 5)
        XCTAssertEqual(calls[0].2, 42)

        let decoded = try JSONDecoder().decode([String: [SearchMemoryHit]].self, from: result)
        XCTAssertEqual(decoded["hits"]?.count, 1)
    }

    func testSearchConversationToolDispatch() async throws {
        let stub = MockHistory()
        await stub.setRows([
            SearchConversationTurn(id: 1, sessionId: "A", role: "user",
                                   content: "hi", source: "userText", createdAt: 1),
        ])
        let registry = InProcessToolRegistry()
        await registry.register(SearchConversationTool(dispatcher: stub))

        let args = try JSONSerialization.data(withJSONObject: [
            "sessionId": "A", "limit": 20,
        ])
        let result = try await registry.dispatch("search_conversation", args: args)

        let calls = await stub.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "A")
        XCTAssertEqual(calls[0].1, 20)

        let decoded = try JSONDecoder().decode([String: [SearchConversationTurn]].self, from: result)
        XCTAssertEqual(decoded["turns"]?.count, 1)
    }

    func testForgetFactToolDispatchSuccess() async throws {
        let stub = MockForget()
        await stub.set(true)
        let registry = InProcessToolRegistry()
        await registry.register(ForgetFactTool(dispatcher: stub))

        let args = try JSONSerialization.data(withJSONObject: [
            "factId": 42, "triggerTurnId": 7,
        ])
        let result = try await registry.dispatch("forget_fact", args: args)

        let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        XCTAssertEqual(json?["forgotten"] as? Bool, true)
        // factId may decode as Int or NSNumber depending on JSONSerialization
        let factIdAny = json?["factId"]
        if let n = factIdAny as? NSNumber {
            XCTAssertEqual(n.int64Value, 42)
        } else {
            XCTFail("factId not numeric: \(String(describing: factIdAny))")
        }
    }

    func testForgetFactToolDispatchUnknownId() async throws {
        let stub = MockForget()
        await stub.set(false)
        let registry = InProcessToolRegistry()
        await registry.register(ForgetFactTool(dispatcher: stub))

        let args = try JSONSerialization.data(withJSONObject: [
            "factId": 99, "triggerTurnId": 1,
        ])
        let result = try await registry.dispatch("forget_fact", args: args)

        let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        XCTAssertEqual(json?["forgotten"] as? Bool, false)
    }

    func testRequiresConfirmationFlags() {
        let hybrid = MockHybrid()
        let history = MockHistory()
        let forget = MockForget()
        XCTAssertEqual(SearchMemoryTool(dispatcher: hybrid).requiresConfirmation, false)
        XCTAssertEqual(SearchConversationTool(dispatcher: history).requiresConfirmation, false)
        XCTAssertEqual(ForgetFactTool(dispatcher: forget).requiresConfirmation, true,
                       "D-02: forget_fact must always confirmation-gate.")
    }

    func testRegistryUnknownToolThrows() async {
        let registry = InProcessToolRegistry()
        do {
            _ = try await registry.dispatch("nonexistent", args: Data())
            XCTFail("expected unknownTool")
        } catch let InProcessToolError.unknownTool(name) {
            XCTAssertEqual(name, "nonexistent")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
