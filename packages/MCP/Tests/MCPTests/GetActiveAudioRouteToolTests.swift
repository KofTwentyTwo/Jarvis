// GetActiveAudioRouteToolTests.swift
//
// Plan 10-01 Wave 0 (RED). Unit test for `get_active_audio_route`. The
// dispatcher double is a `Stub*` per D-31 — returns canned data only.
// First commit MUST fail to compile (types not yet defined).

import Testing
import Foundation
@testable import JarvisMCP

@Suite("GetActiveAudioRouteTool")
struct GetActiveAudioRouteToolTests {

    struct StubActiveAudioRouteDispatching: ActiveAudioRouteDispatching {
        let route: ActiveAudioRoute?
        func getActiveAudioRoute() async throws -> ActiveAudioRoute? { route }
    }

    @Test
    func encodesActiveRoutePayload() async throws {
        let canned = ActiveAudioRoute(
            inputDeviceUID: "BuiltInMicrophoneDevice",
            inputDeviceName: "MacBook Pro Microphone",
            outputDeviceUID: "BuiltInSpeakerDevice",
            outputDeviceName: "MacBook Pro Speakers",
            sampleRate: 24_000,
            channels: 1,
            variant: "aecOn"
        )
        let stub = StubActiveAudioRouteDispatching(route: canned)
        let tool = GetActiveAudioRouteTool(dispatcher: stub)

        #expect(tool.name == "get_active_audio_route")
        #expect(tool.requiresConfirmation == false)

        let result = try await tool.call(args: Data("{}".utf8))
        let decoded = try JSONDecoder().decode([String: ActiveAudioRoute?].self, from: result)
        let route = try #require(decoded["route"] ?? nil)
        #expect(route.inputDeviceUID == "BuiltInMicrophoneDevice")
        #expect(route.outputDeviceUID == "BuiltInSpeakerDevice")
        #expect(route.sampleRate == 24_000)
        #expect(route.channels == 1)
        #expect(route.variant == "aecOn")
    }

    @Test
    func encodesNilRouteWhenGraphClosed() async throws {
        let stub = StubActiveAudioRouteDispatching(route: nil)
        let tool = GetActiveAudioRouteTool(dispatcher: stub)
        let result = try await tool.call(args: Data("{}".utf8))
        let decoded = try JSONDecoder().decode([String: ActiveAudioRoute?].self, from: result)
        // Key present, value nil
        #expect(decoded.keys.contains("route"))
        #expect(decoded["route"] == nil || decoded["route"]! == nil)
    }
}
