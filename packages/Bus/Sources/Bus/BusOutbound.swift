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
    /// TEXT-03 chat-panel hydration. Emitted on webview-ready by AppDelegate
    /// (Plan 07-06) carrying the most-recent turns for the active session.
    /// Additive (MINOR) bump per Phase 2 protocol versioning.
    case sessionHistory(turns: [TurnRow])
    /// Plan 09-04 / D-10 text-path rejection toast. Emitted by AppDelegate's
    /// `handleTextOutcome` when `AgentOrchestrator.submit(.text(...))` returns
    /// `SubmitOutcome.rejected`. Body strings come from `RejectReasonCopy`
    /// — byte-identical to the voice-path HUD banner so users see the same
    /// wording regardless of input source.
    case submitRejected(reason: String)
}

/// Local mirror of Memory.TurnRow used by `BusOutbound.sessionHistory`.
///
/// Bus deliberately does not depend on the Memory package — adding that edge
/// would pull Memory's transitive deps (Replay, AgentCore) into Bus, which
/// is undesirable for the lightweight bridge layer. The shape mirrors
/// Memory.TurnRow one-for-one; AppDelegate.installMemory (Plan 07-06)
/// translates between the two when emitting.
public struct TurnRow: Codable, Equatable, Sendable {
    public let id: Int64
    public let sessionId: String
    public let role: String          // "user" | "assistant" | "tool"
    public let content: String
    public let source: String        // TurnSource rawValue
    public let createdAt: Int64      // unix-ms

    public init(
        id: Int64,
        sessionId: String,
        role: String,
        content: String,
        source: String,
        createdAt: Int64
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.source = source
        self.createdAt = createdAt
    }
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
        case sessionHistory
        case submitRejected
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
        case turns
        case reason
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
        case .sessionHistory:
            let turns = try container.decode([TurnRow].self, forKey: .turns)
            self = .sessionHistory(turns: turns)
        case .submitRejected:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .submitRejected(reason: reason)
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
            // Issue #47: JSON has no canonical encoding for `Float.nan` or
            // `±Float.infinity`. Foundation's `JSONEncoder` defaults to
            // throwing for non-finite floats (`JSONEncoder.NonConformingFloat-
            // EncodingStrategy.throw`), which would crash the per-frame bus
            // path the moment `AudioLevelEmitter` produces a NaN — easy to
            // hit on a CoreAudio over-/underflow or a buffer of all-zero
            // samples. Clamp non-finite to 0.0 inline at the encode site so
            // the rms float in the wire JSON is always a finite, ring-shader-
            // safe number. The HUD-side consumer (`webview/packages/hud/src/
            // bus/client.ts`) currently no-ops on audioLevel; the clamp is
            // defensive against the bug becoming active once the consumer is
            // wired up.
            let safe = rms.isFinite ? rms : 0.0
            try container.encode(safe, forKey: .rms)
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
        case .sessionHistory(let turns):
            try container.encode(Discriminator.sessionHistory, forKey: .type)
            try container.encode(turns, forKey: .turns)
        case .submitRejected(let reason):
            try container.encode(Discriminator.submitRejected, forKey: .type)
            try container.encode(reason, forKey: .reason)
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
