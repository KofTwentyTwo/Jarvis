import Foundation

/// Plan 10-01 / SELF-02.
///
/// Returns the live audio route the AudioGraph is currently bound to.
/// Reads through the App-side `AudioGraphRouteAdapter` which hops into
/// the `AudioGraphOwner` actor — Swift 6 strict-concurrency safe.
public protocol ActiveAudioRouteDispatching: Sendable {
    func getActiveAudioRoute() async throws -> ActiveAudioRoute?
}

/// Tool-boundary projection of the active mic+speaker route. UID/name
/// fields are optional because CoreAudio may not expose a UID for some
/// transient devices (e.g. AirPods mid-handoff).
public struct ActiveAudioRoute: Sendable, Codable, Equatable {
    public let inputDeviceUID: String?
    public let inputDeviceName: String?
    public let outputDeviceUID: String?
    public let outputDeviceName: String?
    public let sampleRate: Double
    public let channels: Int
    /// `"aecOn"` or `"aecOff"` — corresponds to the `AudioGraphVariant`.
    public let variant: String

    public init(
        inputDeviceUID: String?,
        inputDeviceName: String?,
        outputDeviceUID: String?,
        outputDeviceName: String?,
        sampleRate: Double,
        channels: Int,
        variant: String
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.sampleRate = sampleRate
        self.channels = channels
        self.variant = variant
    }
}

/// `get_active_audio_route` MCP in-process tool. D-10: explicit
/// `requiresConfirmation = false`.
public struct GetActiveAudioRouteTool: InProcessTool {

    public let name: String = "get_active_audio_route"
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

    private let dispatcher: any ActiveAudioRouteDispatching

    public init(dispatcher: any ActiveAudioRouteDispatching) {
        self.dispatcher = dispatcher
    }

    public func call(args _: Data) async throws -> Data {
        let route = try await dispatcher.getActiveAudioRoute()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encode `{"route": <route-or-null>}`. JSONEncoder by default
        // omits nil optional keys; use a custom container so the key is
        // always present (the model needs to disambiguate "no graph"
        // from "graph but missing fields").
        struct Payload: Encodable {
            let route: ActiveAudioRoute?
            enum CodingKeys: String, CodingKey { case route }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let route { try c.encode(route, forKey: .route) }
                else        { try c.encodeNil(forKey: .route) }
            }
        }
        return try encoder.encode(Payload(route: route))
    }
}
