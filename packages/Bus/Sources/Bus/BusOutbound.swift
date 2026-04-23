import Foundation

/// Messages the Swift side sends to the webview.
///
/// IMPORTANT: `Codable` conformance is declared in an **extension** (below),
/// not on the enum declaration. This is load-bearing: Swift's synthesized
/// `Codable` (SE-0295) would encode associated-value enums as
/// `{"hudState": {"_0": "idle"}}`, which does NOT match the TS mirror's
/// `{"type": "hudState", "state": "idle"}` shape. Hand-writing the
/// `init(from:)` and `encode(to:)` methods with exhaustive switches is the
/// schema-drift preventer at the language level — adding a case without
/// updating both methods is a compile error.
public enum BusOutbound: Equatable, Sendable {
    case hello(version: String)
    case hudState(HudState)
    case tokenDelta(text: String)
    case audioLevel(rms: Float)
    case toolCallStart(id: UUID, name: String, argsPreview: String)
    case toolCallEnd(id: UUID, ok: Bool, previewOrError: String)
    case turnStarted(id: UUID)
    case turnEnded(id: UUID, terminator: TurnTerminator)
}

extension BusOutbound: Codable {
    /// Discriminator tag used as the `type` field in the wire format.
    /// Declaring this as a `String`-raw-value enum means an unknown tag in
    /// inbound JSON surfaces as `DecodingError.dataCorrupted` from the
    /// `try c.decode(Discriminator.self, forKey: .type)` call below.
    private enum Discriminator: String, Codable {
        case hello
        case hudState
        case tokenDelta
        case audioLevel
        case toolCallStart
        case toolCallEnd
        case turnStarted
        case turnEnded
    }

    /// All `CodingKeys` across every case. Swift's keyed container does not
    /// care about unused keys per-case; the per-case `encode(to:)` only
    /// writes the fields relevant to the variant.
    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case state
        case text
        case rms
        case id
        case name
        case argsPreview
        case ok
        case previewOrError
        case terminator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Discriminator.self, forKey: .type)
        switch tag {
        case .hello:
            let version = try container.decode(String.self, forKey: .version)
            self = .hello(version: version)
        case .hudState:
            let state = try container.decode(HudState.self, forKey: .state)
            self = .hudState(state)
        case .tokenDelta:
            let text = try container.decode(String.self, forKey: .text)
            self = .tokenDelta(text: text)
        case .audioLevel:
            let rms = try container.decode(Float.self, forKey: .rms)
            self = .audioLevel(rms: rms)
        case .toolCallStart:
            let id = try Self.decodeUUID(container: container, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let argsPreview = try container.decode(String.self, forKey: .argsPreview)
            self = .toolCallStart(id: id, name: name, argsPreview: argsPreview)
        case .toolCallEnd:
            let id = try Self.decodeUUID(container: container, forKey: .id)
            let ok = try container.decode(Bool.self, forKey: .ok)
            let previewOrError = try container.decode(String.self, forKey: .previewOrError)
            self = .toolCallEnd(id: id, ok: ok, previewOrError: previewOrError)
        case .turnStarted:
            let id = try Self.decodeUUID(container: container, forKey: .id)
            self = .turnStarted(id: id)
        case .turnEnded:
            let id = try Self.decodeUUID(container: container, forKey: .id)
            let terminator = try container.decode(TurnTerminator.self, forKey: .terminator)
            self = .turnEnded(id: id, terminator: terminator)
        }
        // NO default branch — adding a Discriminator case without also adding
        // a matching switch arm here is a compile error. That is the entire
        // reason this Codable is hand-written.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version):
            try container.encode(Discriminator.hello, forKey: .type)
            try container.encode(version, forKey: .version)
        case .hudState(let state):
            try container.encode(Discriminator.hudState, forKey: .type)
            try container.encode(state, forKey: .state)
        case .tokenDelta(let text):
            try container.encode(Discriminator.tokenDelta, forKey: .type)
            try container.encode(text, forKey: .text)
        case .audioLevel(let rms):
            try container.encode(Discriminator.audioLevel, forKey: .type)
            try container.encode(rms, forKey: .rms)
        case .toolCallStart(let id, let name, let argsPreview):
            try container.encode(Discriminator.toolCallStart, forKey: .type)
            try container.encode(id.uuidString.lowercased(), forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(argsPreview, forKey: .argsPreview)
        case .toolCallEnd(let id, let ok, let previewOrError):
            try container.encode(Discriminator.toolCallEnd, forKey: .type)
            try container.encode(id.uuidString.lowercased(), forKey: .id)
            try container.encode(ok, forKey: .ok)
            try container.encode(previewOrError, forKey: .previewOrError)
        case .turnStarted(let id):
            try container.encode(Discriminator.turnStarted, forKey: .type)
            try container.encode(id.uuidString.lowercased(), forKey: .id)
        case .turnEnded(let id, let terminator):
            try container.encode(Discriminator.turnEnded, forKey: .type)
            try container.encode(id.uuidString.lowercased(), forKey: .id)
            try container.encode(terminator, forKey: .terminator)
        }
        // Exhaustive at encode site — adding a case without encoding it is a
        // compile error, mirroring the init(from:) drift preventer.
    }

    /// `UUID` is encoded as a lowercase string (Pitfall 6). Decoder accepts
    /// either case since `UUID(uuidString:)` is case-insensitive, but we
    /// route the parse through an explicit helper so bad payloads surface
    /// as structured `DecodingError`s instead of silent `fatalError`s.
    private static func decodeUUID(
        container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        let raw = try container.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "invalid UUID string: \(raw)"
            )
        }
        return uuid
    }
}
