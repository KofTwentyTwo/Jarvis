import XCTest
import AgentCore
@testable import JarvisMCP

/// Plan 10-02b / B-01: assert `InProcessToolRegistry.toolSchemas()`
/// projects every registered in-process tool to a `ToolSchema` suitable for
/// the Anthropic / Ollama tools[] payload, including the new
/// `toolDescription` field that the substrate fix introduced. Catches
/// regressions where a new tool is added without a description (otherwise
/// the description would silently default and the model would lose
/// context about when to call it).
final class InProcessToolRegistrySchemasTests: XCTestCase {

    actor StubHybrid: HybridSearchDispatching {
        func searchFacts(query: String, k: Int, triggerTurnId: Int64) async throws -> [SearchMemoryHit] { [] }
    }
    actor StubForget: ForgetFactDispatching {
        func forgetFact(id: Int64, triggerTurnId: Int64) async throws -> Bool { false }
    }
    actor StubHistory: SessionHistoryDispatching {
        func recentTurns(sessionId: String, limit: Int) async throws -> [SearchConversationTurn] { [] }
    }
    actor StubAudio: AudioDeviceListing {
        func listAudioDevices() async throws -> [AudioDeviceEntry] { [] }
    }
    actor StubRoute: ActiveAudioRouteDispatching {
        func getActiveAudioRoute() async throws -> ActiveAudioRoute? { nil }
    }
    actor StubSelfState: SelfStateDispatching {
        func getSelfState() async -> SelfState {
            SelfState(appName: "Jarvis", appVersion: "test", buildMode: "debug",
                      pid: 0, uptimeSeconds: 0, llmProvider: "anthropic",
                      llmModel: "claude-opus-4-7", ttsTier: "tier1",
                      sttBackend: "speechAnalyzer", wakeWordMuted: false,
                      voiceLoopState: "idle")
        }
    }
    actor StubCamera: CameraDeviceListing {
        func listCameraDevices() async throws -> [CameraDeviceEntry] { [] }
    }

    /// Registers all 7 production in-process tools and asserts
    /// `toolSchemas()` returns one ToolSchema per tool, sorted by name,
    /// with non-empty `description` and matching `inputSchema` bytes.
    func test_toolSchemas_projectsAllRegisteredTools() async throws {
        let registry = InProcessToolRegistry()
        await registry.register(SearchMemoryTool(dispatcher: StubHybrid()))
        await registry.register(ForgetFactTool(dispatcher: StubForget()))
        await registry.register(SearchConversationTool(dispatcher: StubHistory()))
        await registry.register(ListAudioDevicesTool(dispatcher: StubAudio()))
        await registry.register(GetActiveAudioRouteTool(dispatcher: StubRoute()))
        await registry.register(GetSelfStateTool(dispatcher: StubSelfState()))
        await registry.register(ListCameraDevicesTool(dispatcher: StubCamera()))

        let schemas = await registry.toolSchemas()

        // 7 tools registered, 7 schemas projected — no silent loss.
        XCTAssertEqual(schemas.count, 7,
                       "toolSchemas() lost a tool — registered 7, got \(schemas.count)")

        // Sorted by name (deterministic for prompt-cache stability).
        XCTAssertEqual(schemas.map(\.name), schemas.map(\.name).sorted(),
                       "toolSchemas() must return name-sorted schemas")

        // Every schema has a non-empty description (B-01: model needs the
        // description to know WHEN to call each tool).
        for schema in schemas {
            XCTAssertFalse(schema.description.isEmpty,
                           "tool \(schema.name) has empty description — model has no signal for when to call it")
        }

        // Every schema's inputSchema is non-empty JSON bytes.
        for schema in schemas {
            XCTAssertFalse(schema.inputSchema.isEmpty,
                           "tool \(schema.name) has empty inputSchema bytes")
        }

        // Spot-check: every expected tool name is present.
        let names = Set(schemas.map(\.name))
        let expected: Set<String> = [
            "search_memory", "forget_fact", "search_conversation",
            "list_audio_devices", "get_active_audio_route", "get_self_state",
            "list_camera_devices",
        ]
        XCTAssertEqual(names, expected,
                       "tool name set does not match expected production catalog")
    }
}
