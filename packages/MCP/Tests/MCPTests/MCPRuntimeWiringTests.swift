// MCPRuntimeWiringTests.swift
//
// Plan 10-01 Wave 0. Asserts the four self-knowledge tools register in an
// `InProcessToolRegistry` and each carries `requiresConfirmation == false`
// (D-10 — explicit, not defaulted).
//
// This is a structural assertion against the registry — no AppDelegate
// install path executed. The registry-level assertion is sufficient
// because the `register(_:)` calls in `installAgent` are simple
// translations of these same lines (verified by `MemoryInstallWiringTests`'
// `buildInProcessToolRegistry` test seam pattern).

import Testing
import Foundation
@testable import JarvisMCP

@Suite("MCPRuntimeWiring (self-knowledge tools)")
struct MCPRuntimeWiringTests {

    // Stubs per D-31 — return canned data, no recording.
    struct StubAudioDeviceListing: AudioDeviceListing {
        func listAudioDevices() async throws -> [AudioDeviceEntry] { [] }
    }
    struct StubActiveAudioRouteDispatching: ActiveAudioRouteDispatching {
        func getActiveAudioRoute() async throws -> ActiveAudioRoute? { nil }
    }
    struct StubSelfStateDispatching: SelfStateDispatching {
        func getSelfState() async -> SelfState {
            SelfState(
                appName: "Jarvis",
                appVersion: "0.0.0",
                buildMode: "debug",
                pid: 0,
                uptimeSeconds: 0,
                llmProvider: "anthropic",
                llmModel: "claude-opus-4-7",
                ttsTier: "tier1",
                sttBackend: "speechAnalyzer",
                wakeWordMuted: false,
                voiceLoopState: "idle"
            )
        }
    }
    struct StubCameraDeviceListing: CameraDeviceListing {
        func listCameraDevices() async throws -> [CameraDeviceEntry] { [] }
    }

    @Test
    func registersFourSelfKnowledgeTools() async {
        let registry = InProcessToolRegistry()
        await registry.register(ListAudioDevicesTool(dispatcher: StubAudioDeviceListing()))
        await registry.register(GetActiveAudioRouteTool(dispatcher: StubActiveAudioRouteDispatching()))
        await registry.register(GetSelfStateTool(dispatcher: StubSelfStateDispatching()))
        await registry.register(ListCameraDevicesTool(dispatcher: StubCameraDeviceListing()))

        let tools = await registry.registered()
        let names = Set(tools.map(\.name))
        #expect(names.contains("list_audio_devices"))
        #expect(names.contains("get_active_audio_route"))
        #expect(names.contains("get_self_state"))
        #expect(names.contains("list_camera_devices"))

        // D-10: every self-knowledge tool MUST register with
        // requiresConfirmation:false explicitly (not defaulted). The
        // ConfirmingToolDispatcher's confirmation gate stays reserved for
        // mcp-applescript only.
        let selfKnowledgeNames: Set<String> = [
            "list_audio_devices",
            "get_active_audio_route",
            "get_self_state",
            "list_camera_devices",
        ]
        for tool in tools where selfKnowledgeNames.contains(tool.name) {
            #expect(
                tool.requiresConfirmation == false,
                "D-10: \(tool.name) must register with requiresConfirmation:false"
            )
        }
    }
}
