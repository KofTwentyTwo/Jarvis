// GetSelfStateToolTests.swift
//
// Plan 10-01 Wave 0 (RED). Unit test for `get_self_state`. Asserts all
// 11 D-11 fields are populated. Dispatcher is a `Stub*` per D-31.
// First commit MUST fail to compile.

import Testing
import Foundation
@testable import JarvisMCP

@Suite("GetSelfStateTool")
struct GetSelfStateToolTests {

    struct StubSelfStateDispatching: SelfStateDispatching {
        let state: SelfState
        func getSelfState() async -> SelfState { state }
    }

    @Test
    func populatesAllSelfStateFields() async throws {
        let canned = SelfState(
            appName: "Jarvis",
            appVersion: "0.12.0",
            buildMode: "debug",
            pid: 4242,
            uptimeSeconds: 30,
            llmProvider: "anthropic",
            llmModel: "claude-opus-4-7",
            ttsTier: "tier1",
            sttBackend: "speechAnalyzer",
            wakeWordMuted: false,
            voiceLoopState: "idle"
        )
        let stub = StubSelfStateDispatching(state: canned)
        let tool = GetSelfStateTool(dispatcher: stub)

        #expect(tool.name == "get_self_state")
        #expect(tool.requiresConfirmation == false)

        let result = try await tool.call(args: Data("{}".utf8))
        let decoded = try JSONDecoder().decode(SelfState.self, from: result)

        // D-11: assert each of the 11 fields is non-default
        #expect(decoded.appName == "Jarvis")
        #expect(decoded.appVersion == "0.12.0")
        #expect(decoded.buildMode == "debug")
        #expect(decoded.pid == 4242)
        #expect(decoded.uptimeSeconds == 30)
        #expect(decoded.llmProvider == "anthropic")
        #expect(decoded.llmModel == "claude-opus-4-7")
        #expect(decoded.ttsTier == "tier1")
        #expect(decoded.sttBackend == "speechAnalyzer")
        #expect(decoded.wakeWordMuted == false)
        #expect(decoded.voiceLoopState == "idle")
    }
}
