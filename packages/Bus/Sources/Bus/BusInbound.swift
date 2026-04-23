import Foundation

/// Messages the webview sends to the Swift side.
///
/// Minimal P2 scope (per RESEARCH §Deferred Ideas) — only the handshake ack
/// and a UI-ready ping. P3+ adds user-input, tool-confirm, and other cases.
///
/// Hand-written `Codable` mirrors `BusOutbound` — same `type` discriminator,
/// same exhaustive-switch drift preventer.
public enum BusInbound: Equatable, Sendable {
    case helloAck(version: String)
    case uiReady
}

extension BusInbound: Codable {
    private enum Discriminator: String, Codable {
        case helloAck
        case uiReady
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
        }
    }
}
