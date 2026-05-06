// ListAudioDevicesToolTests.swift
//
// Plan 10-01 Wave 0 (RED). Unit test for the `list_audio_devices` MCP
// in-process tool. The dispatcher double is a `Stub*` per CLAUDE.md
// §"Test naming conventions" (D-31): returns canned data without
// recording calls.
//
// On first commit this MUST fail to compile because the production
// types `ListAudioDevicesTool`, `AudioDeviceListing`, and
// `AudioDeviceEntry` do not yet exist. Task 2 makes it GREEN.

import Testing
import Foundation
@testable import JarvisMCP

@Suite("ListAudioDevicesTool")
struct ListAudioDevicesToolTests {

    /// Stub dispatcher: returns canned `[AudioDeviceEntry]`. No recording.
    struct StubAudioDeviceListing: AudioDeviceListing {
        let entries: [AudioDeviceEntry]
        func listAudioDevices() async throws -> [AudioDeviceEntry] { entries }
    }

    @Test
    func encodesDevicesArrayInResponseJSON() async throws {
        let canned: [AudioDeviceEntry] = [
            AudioDeviceEntry(
                name: "MacBook Pro Microphone",
                uid: "BuiltInMicrophoneDevice",
                isDefault: true,
                isActive: true,
                isInput: true,
                sampleRate: 48_000,
                channels: 1
            ),
            AudioDeviceEntry(
                name: "MacBook Pro Speakers",
                uid: "BuiltInSpeakerDevice",
                isDefault: true,
                isActive: true,
                isInput: false,
                sampleRate: 48_000,
                channels: 2
            ),
        ]
        let stub = StubAudioDeviceListing(entries: canned)
        let tool = ListAudioDevicesTool(dispatcher: stub)

        #expect(tool.name == "list_audio_devices")
        #expect(tool.requiresConfirmation == false)

        let result = try await tool.call(args: Data("{}".utf8))
        let decoded = try JSONDecoder().decode([String: [AudioDeviceEntry]].self, from: result)
        let devices = try #require(decoded["devices"])
        #expect(devices.count == 2)
        #expect(devices.first?.uid == "BuiltInMicrophoneDevice")
        #expect(devices.first?.isInput == true)
        #expect(devices.last?.uid == "BuiltInSpeakerDevice")
        #expect(devices.last?.isInput == false)
    }
}
