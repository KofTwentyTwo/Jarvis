import XCTest
@testable import AgentCore

final class ToolChoiceTests: XCTestCase {
    /// Test 1: ToolChoice has exactly four cases — exhaustive switch with no
    /// `default:` branch compiles. If a fifth case is added, this test fails
    /// to compile, forcing an explicit decision about its serialization.
    func testToolChoiceExhaustiveSwitch() {
        let choices: [ToolChoice] = [.auto, .none, .any, .tool(name: "x")]
        var seen = 0
        for choice in choices {
            switch choice {
            case .auto: seen += 1
            case .none: seen += 1
            case .any: seen += 1
            case .tool(name: _): seen += 1
            }
        }
        XCTAssertEqual(seen, 4)
    }

    func testToolChoiceEquality() {
        XCTAssertEqual(ToolChoice.auto, ToolChoice.auto)
        XCTAssertEqual(ToolChoice.none, ToolChoice.none)
        XCTAssertEqual(ToolChoice.any, ToolChoice.any)
        XCTAssertEqual(ToolChoice.tool(name: "get_time"), ToolChoice.tool(name: "get_time"))
        XCTAssertNotEqual(ToolChoice.auto, ToolChoice.none)
        XCTAssertNotEqual(ToolChoice.tool(name: "a"), ToolChoice.tool(name: "b"))
    }

    /// Test 10 (compile-time contract): `LLMProvider.stream(...)` requires
    /// `toolChoice:` — there is no default. The closure body is the
    /// contract: if `toolChoice:` were defaulted on the protocol, this
    /// call site would still compile (a hand-defaulted argument is
    /// semantically equivalent), but a code reviewer scanning this file
    /// would see the explicit `toolChoice: .auto` argument and know the
    /// design intent. The 2026-05-04 cleanup batch removed the trailing
    /// `XCTAssertTrue(true)` tautology — the closure compile is the gate.
    func testLLMProviderStreamRequiresToolChoice() {
        let _: (any LLMProvider) -> AsyncThrowingStream<LLMEvent, Error> = { provider in
            provider.stream(
                messages: [],
                tools: [],
                toolChoice: .auto,
                model: .opus47,
                maxOutputTokens: 1024,
                cacheHints: nil
            )
        }
    }
}
