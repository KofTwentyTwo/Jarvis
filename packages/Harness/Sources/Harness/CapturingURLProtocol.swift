import Foundation

/// `URLProtocol` subclass that records outbound `httpBody` /
/// `httpBodyStream` bytes and serves a canned response. Used by
/// `ToolCapRecoveryRunner` (Plan 08-03 Task 3) to enforce the D-21 dual
/// assertion: the cap-recovery turn must serialize `tool_choice: .none`
/// in its outbound bytes (Anthropic) or omit the `tools` array entirely
/// (Ollama).
///
/// Single global capture buffer: only one instance is registered per
/// runner invocation and `reset()` is called before each registration.
/// The wider `URLProtocol` ABI is shared, so we lock around state
/// mutation.
public final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    public static let lock = NSLock()
    nonisolated(unsafe) public static var capturedBodies: [Data] = []
    nonisolated(unsafe) public static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) public static var cannedResponse: Data = Data()
    nonisolated(unsafe) public static var cannedHeaders: [String: String] = [
        "Content-Type": "text/event-stream"
    ]
    nonisolated(unsafe) public static var cannedStatusCode: Int = 200

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        if let body = request.httpBody {
            Self.capturedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            // Anthropic / Ollama use streaming uploads in some shapes; we
            // drain the stream eagerly so the captured bytes mirror what
            // the server would have read.
            stream.open()
            var buffer = Data()
            let bufSize = 4096
            var chunk = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: bufSize)
                if n <= 0 { break }
                buffer.append(chunk, count: n)
            }
            stream.close()
            Self.capturedBodies.append(buffer)
        } else {
            // Some clients send empty-body requests (GET); record an empty
            // Data so capturedBodies.count == capturedRequests.count.
            Self.capturedBodies.append(Data())
        }
        let url = request.url ?? URL(string: "about:blank")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: Self.cannedStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: Self.cannedHeaders
        )!
        Self.lock.unlock()

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.cannedResponse.isEmpty {
            client?.urlProtocol(self, didLoad: Self.cannedResponse)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}

    /// Clear all capture state. Call BEFORE each test/run that registers
    /// the protocol, NOT during `startLoading` (which can race with
    /// concurrent in-flight captures).
    public static func reset() {
        lock.lock()
        capturedBodies.removeAll()
        capturedRequests.removeAll()
        cannedResponse = Data()
        cannedHeaders = ["Content-Type": "text/event-stream"]
        cannedStatusCode = 200
        lock.unlock()
    }
}
