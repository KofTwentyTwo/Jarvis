import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

    /// WR-03: DNS-rebind-safe host validation.
    ///   1. Normalize IPv6-bracketed hosts (`[::1]` → `::1`).
    ///   2. String-level allowlist (first pass — fast reject).
    ///   3. For `localhost`, additionally resolve via `getaddrinfo` and
    ///      assert every resolved address is loopback. Defeats an
    ///      `/etc/hosts` hijack that points `localhost` to a non-loopback IP.
    private static func validateHost(_ url: URL) throws {
        let rawHost = url.host ?? ""
        let normalized: String = {
            if rawHost.hasPrefix("[") && rawHost.hasSuffix("]") {
                return String(rawHost.dropFirst().dropLast())
            }
            return rawHost
        }().lowercased()

        guard allowedHosts.contains(normalized) else {
            throw ConfigError.invalidOllamaHost(rawHost)
        }

        // IP literals don't need resolution — they're loopback by construction.
        if normalized == "127.0.0.1" || normalized == "::1" { return }

        // `localhost`: resolve and reject if any resolved address is non-loopback.
        try assertResolvesToLoopbackOnly(host: normalized)
    }

    /// WR-03: `getaddrinfo`-based check that every returned IPv4/IPv6 address
    /// for `host` is in 127.0.0.0/8 or ::1. Throws `invalidOllamaHost` on
    /// mismatch. Scoped to `localhost` only — the IP-literal branches of
    /// `validateHost` skip this to avoid a pointless DNS call.
    private static func assertResolvesToLoopbackOnly(host: String) throws {
        #if canImport(Darwin)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC       // both IPv4 + IPv6
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        if status != 0 {
            // If resolution fails we reject — conservative posture. An
            // unresolvable localhost is a misconfiguration worth flagging.
            throw ConfigError.invalidOllamaHost(host)
        }
        defer { freeaddrinfo(result) }

        var current = result
        while let node = current {
            guard let addr = node.pointee.ai_addr else {
                current = node.pointee.ai_next
                continue
            }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                var sin = sockaddr_in()
                memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
                // 127.0.0.0/8: top octet of 4-byte address is 0x7f.
                let be = UInt32(bigEndian: sin.sin_addr.s_addr)
                if (be >> 24) != 0x7f {
                    throw ConfigError.invalidOllamaHost(host)
                }
            case AF_INET6:
                var sin6 = sockaddr_in6()
                memcpy(&sin6, addr, MemoryLayout<sockaddr_in6>.size)
                // ::1 = 15 zero bytes followed by 0x01.
                let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                let isLoopback = bytes.count == 16
                    && bytes[0..<15].allSatisfy { $0 == 0 }
                    && bytes[15] == 1
                if !isLoopback {
                    throw ConfigError.invalidOllamaHost(host)
                }
            default:
                // Unknown family — reject to fail closed.
                throw ConfigError.invalidOllamaHost(host)
            }
            current = node.pointee.ai_next
        }
        #else
        // Non-Darwin platforms aren't supported by the rest of Jarvis, but
        // don't block compilation.
        _ = host
        #endif
    }
}
