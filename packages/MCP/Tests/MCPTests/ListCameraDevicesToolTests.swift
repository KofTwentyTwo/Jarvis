// ListCameraDevicesToolTests.swift
//
// Plan 10-01 Wave 0 (RED). Unit test for `list_camera_devices`.
// Dispatcher is a `Stub*` per D-31. First commit MUST fail to compile.

import Testing
import Foundation
@testable import JarvisMCP

@Suite("ListCameraDevicesTool")
struct ListCameraDevicesToolTests {

    struct StubCameraDeviceListing: CameraDeviceListing {
        let entries: [CameraDeviceEntry]
        func listCameraDevices() async throws -> [CameraDeviceEntry] { entries }
    }

    @Test
    func encodesCameraEntriesArrayInResponseJSON() async throws {
        let canned: [CameraDeviceEntry] = [
            CameraDeviceEntry(
                localizedName: "FaceTime HD Camera",
                uniqueID: "0x1420000005ac8514",
                isConnected: true,
                position: "front"
            )
        ]
        let stub = StubCameraDeviceListing(entries: canned)
        let tool = ListCameraDevicesTool(dispatcher: stub)

        #expect(tool.name == "list_camera_devices")
        #expect(tool.requiresConfirmation == false)

        let result = try await tool.call(args: Data("{}".utf8))
        let decoded = try JSONDecoder().decode([String: [CameraDeviceEntry]].self, from: result)
        let cams = try #require(decoded["cameras"])
        #expect(cams.count == 1)
        #expect(cams.first?.localizedName == "FaceTime HD Camera")
        #expect(cams.first?.position == "front")
    }
}
