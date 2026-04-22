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
public struct AnthropicKeyValidator: Sendable {
    public let client: any URLRequestClient

    public init(client: any URLRequestClient = URLSession.shared) {
        self.client = client
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
