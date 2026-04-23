import Foundation

public enum AnthropicKeyValidationResult: Sendable, Equatable {
    case valid
    case malformed
    case unauthorized
    case network
    case generic
}

/// Abstract the URLSession so tests can inject a MockClient returning a
/// specific HTTPURLResponse status code without hitting the real Anthropic API.
public protocol URLRequestClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLRequestClient {}

/// Validates an Anthropic API key by (1) a local prefix check (no network
/// traffic for obviously-malformed input, per T-04-08 / privacy) and
/// (2) a minimal GET to `api.anthropic.com/v1/models` with the key in the
/// `x-api-key` header. Returns a result enum — never logs the key.
///
/// The key travels in a header, not a query string (T-04-01). HTTPS is
/// enforced by the fixed URL.
///
/// WR-07: the default session is `URLSessionConfiguration.ephemeral` with
/// `connectionProxyDictionary = [:]` (refuses system proxy) and
/// `tlsMinimumSupportedProtocolVersion = .TLSv13`. Without this, the
/// `x-api-key` header would be shipped through a corporate MITM proxy that
/// happens to intercept `api.anthropic.com`, leaking the key on the first
/// validation attempt. Ephemeral also avoids cross-contamination with the
/// app's shared cookie/cache jar.
public struct AnthropicKeyValidator: Sendable {
    public let client: any URLRequestClient

    public init(client: (any URLRequestClient)? = nil) {
        self.client = client ?? AnthropicKeyValidator.makeHardenedSession()
    }

    /// WR-07: dedicated URLSession for key validation. Declines system
    /// proxies, pins TLSv1.3 minimum, and uses an ephemeral configuration
    /// so nothing is cached on disk.
    private static func makeHardenedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Disable any configured system or user proxy. An empty dictionary
        // explicitly overrides the default resolver lookup.
        config.connectionProxyDictionary = [:]
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        // Fail fast on flaky networks — the validator should not block the
        // wizard for minutes.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Don't allow cookies or credential storage for this one-shot call.
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }

    public func validate(key: String) async -> AnthropicKeyValidationResult {
        // Shape check first — no network for obviously-malformed input.
        if !key.hasPrefix("sk-ant-") { return .malformed }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (_, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .generic }
            switch http.statusCode {
            case 200..<300: return .valid
            case 401:       return .unauthorized
            default:        return .generic
            }
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .timedOut {
            return .network
        } catch {
            return .generic
        }
    }
}
