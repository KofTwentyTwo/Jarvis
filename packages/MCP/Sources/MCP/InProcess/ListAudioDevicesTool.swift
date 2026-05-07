import Foundation

/// Plan 10-01 / SELF-01.
///
/// Read-only MCP in-process tool: returns an entry for every CoreAudio
/// device on the host (one entry per direction — input streams emit
/// `isInput=true`, output streams emit `isInput=false`). The dispatcher
/// is injected so JarvisMCP does NOT have to import CoreAudio /
/// AVFoundation; the App-side `CoreAudioDeviceListAdapter` provides the
/// concrete enumeration.
///
/// D-09: dispatcher MUST NOT cache. Hardware can be unplugged between
/// calls; freshness > performance.
public protocol AudioDeviceListing: Sendable {
    func listAudioDevices() async throws -> [AudioDeviceEntry]
}

/// Tool-boundary projection of a CoreAudio device entry. Stays free of
/// CoreAudio types so MCP doesn't need to import AudioToolbox.
public struct AudioDeviceEntry: Sendable, Codable, Equatable {
    public let name: String
    public let uid: String
    public let isDefault: Bool
    public let isActive: Bool
    public let isInput: Bool
    public let sampleRate: Double
    public let channels: Int

    public init(
        name: String,
        uid: String,
        isDefault: Bool,
        isActive: Bool,
        isInput: Bool,
        sampleRate: Double,
        channels: Int
    ) {
        self.name = name
        self.uid = uid
        self.isDefault = isDefault
        self.isActive = isActive
        self.isInput = isInput
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// `list_audio_devices` MCP in-process tool. D-10: registers with
/// `requiresConfirmation = false` explicitly (read-only, no side effects).
public struct ListAudioDevicesTool: InProcessTool {

    public let name: String = "list_audio_devices"
    public let toolDescription: String = """
    Lists every audio I/O device on the user's Mac (one entry per direction — \
    inputs and outputs as separate rows). Each entry includes name, UID, \
    sample rate, channel count, default-device flag, and active flag. Call \
    this tool when the user asks about microphones, speakers, headphones, or \
    audio devices in general — never speculate or tell them to open System \
    Settings.
    """
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

    private let dispatcher: any AudioDeviceListing

    public init(dispatcher: any AudioDeviceListing) {
        self.dispatcher = dispatcher
    }

    public func call(args _: Data) async throws -> Data {
        let entries = try await dispatcher.listAudioDevices()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(["devices": entries])
    }
}
