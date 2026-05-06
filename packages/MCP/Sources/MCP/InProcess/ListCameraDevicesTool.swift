import Foundation

/// Plan 10-01 / SELF-04.
///
/// Read-only MCP in-process tool: returns every `AVCaptureDevice` the
/// host exposes. The dispatcher is injected so JarvisMCP doesn't need to
/// import AVFoundation; the App-side `AVCaptureDeviceListAdapter`
/// provides the concrete enumeration.
///
/// TCC: `AVCaptureDevice.DiscoverySession` enumeration is metadata-only
/// and does NOT trigger the camera TCC prompt (verified RESEARCH §Example
/// 2). The model can know the camera exists before TCC is granted; the
/// actual capture will still fail until TCC is granted.
public protocol CameraDeviceListing: Sendable {
    func listCameraDevices() async throws -> [CameraDeviceEntry]
}

/// Tool-boundary projection of an AVCaptureDevice. Stays free of
/// AVFoundation types.
public struct CameraDeviceEntry: Sendable, Codable, Equatable {
    public let localizedName: String
    public let uniqueID: String
    public let isConnected: Bool
    /// `"front"` | `"back"` | `"external"` | `"unknown"`.
    public let position: String

    public init(
        localizedName: String,
        uniqueID: String,
        isConnected: Bool,
        position: String
    ) {
        self.localizedName = localizedName
        self.uniqueID = uniqueID
        self.isConnected = isConnected
        self.position = position
    }
}

/// `list_camera_devices` MCP in-process tool. D-10: explicit
/// `requiresConfirmation = false`.
public struct ListCameraDevicesTool: InProcessTool {

    public let name: String = "list_camera_devices"
    public let requiresConfirmation: Bool = false

    public var schemaJSON: Data { Self.schema }

    private static let schema: Data = {
        let s: [String: Any] = [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String],
        ]
        return (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])) ?? Data()
    }()

    private let dispatcher: any CameraDeviceListing

    public init(dispatcher: any CameraDeviceListing) {
        self.dispatcher = dispatcher
    }

    public func call(args _: Data) async throws -> Data {
        let entries = try await dispatcher.listCameraDevices()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(["cameras": entries])
    }
}
