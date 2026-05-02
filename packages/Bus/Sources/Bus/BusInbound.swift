import Foundation

/// Messages the webview sends to the Swift side.
///
/// Minimal P2 scope (per RESEARCH §Deferred Ideas) — handshake ack, a UI-ready
/// ping, and Phase 9 / D-15's frame-attach trigger from the HUD camera button.
/// Plan 4 adds user-input + tool-confirm cases.
///
/// Hand-written `Codable` mirrors `BusOutbound` — same `type` discriminator,
/// same exhaustive-switch drift preventer.
public enum BusInbound: Equatable, Sendable {
    case helloAck(version: String)
    case uiReady
    /// Plan 09-02 / D-15 / VIS-07 — HUD camera-icon button. AppDelegate's
    /// onInbound handler routes this into
    /// `FrameAttachController.requestAttach(reason: .hudButton)`.
    case frameAttachRequested
}

extension BusInbound: Codable {
    private enum Discriminator: String, Codable {
        case helloAck
        case uiReady
        case frameAttachRequested
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Discriminator.self, forKey: .type)
        switch tag {
        case .helloAck:
            let version = try container.decode(String.self, forKey: .version)
            self = .helloAck(version: version)
        case .uiReady:
            self = .uiReady
        case .frameAttachRequested:
            self = .frameAttachRequested
        }
        // NO default — adding a case without a matching arm is a compile error.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .helloAck(let version):
            try container.encode(Discriminator.helloAck, forKey: .type)
            try container.encode(version, forKey: .version)
        case .uiReady:
            try container.encode(Discriminator.uiReady, forKey: .type)
        case .frameAttachRequested:
            try container.encode(Discriminator.frameAttachRequested, forKey: .type)
        }
    }
}
