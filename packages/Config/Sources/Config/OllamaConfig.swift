import Foundation

public struct OllamaConfig: Sendable, Codable, Equatable {
    public let baseURL: URL

    public init(baseURL: URL) throws {
        try Self.validateHost(baseURL)
        self.baseURL = baseURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let urlString = try container.decode(String.self, forKey: .baseURL)
        guard let url = URL(string: urlString) else {
            throw ConfigError.malformed(reason: "ollama.baseURL is not a valid URL: \(urlString)")
        }
        try Self.validateHost(url)
        self.baseURL = url
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL.absoluteString, forKey: .baseURL)
    }

    private enum CodingKeys: String, CodingKey { case baseURL }

    /// AGENT-05: only 127.0.0.1, localhost, ::1 permitted. Non-matching hosts
    /// fail decoding with ConfigError.invalidOllamaHost.
    private static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private static func validateHost(_ url: URL) throws {
        let host = url.host ?? ""
        guard allowedHosts.contains(host.lowercased()) else {
            throw ConfigError.invalidOllamaHost(host)
        }
    }
}
