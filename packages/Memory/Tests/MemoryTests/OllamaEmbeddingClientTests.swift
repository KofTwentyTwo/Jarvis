import XCTest
import Foundation
@testable import Memory

/// Plan 07-02 Task 2: OllamaEmbeddingClient
///
/// Covers the eight in-process happy/sad path behaviors. The dedicated
/// MEM-04 sandbox file (EmbeddingNetworkSandboxTests) covers the
/// non-loopback rejection invariants.
final class OllamaEmbeddingClientTests: XCTestCase {

    // MARK: - URLProtocolStub

    final class URLProtocolStub: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
        nonisolated(unsafe) static var nextStatus: Int = 200
        nonisolated(unsafe) static var nextBody: Data = Data()

        static func reset(status: Int = 200, body: Data = Data()) {
            lock.lock(); defer { lock.unlock() }
            capturedRequests.removeAll()
            nextStatus = status
            nextBody = body
        }

        static var lastRequest: URLRequest? {
            lock.lock(); defer { lock.unlock() }
            return capturedRequests.last
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // URLSession copies httpBody into a stream — read it back so tests
            // can assert on the body.
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                var data = Data()
                let bufSize = 8192
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { buf.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: bufSize)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                captured.httpBody = data
            }
            Self.lock.lock()
            Self.capturedRequests.append(captured)
            let status = Self.nextStatus
            let body = Self.nextBody
            Self.lock.unlock()

            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - helpers

    private func makeStubbedClient() -> OllamaEmbeddingClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: cfg)
        // safe — default baseURL is loopback and assertLoopback accepts it
        return try! OllamaEmbeddingClient(session: session)
    }

    private func dim768Body(_ value: Float = 0.5) throws -> Data {
        let floats = Array(repeating: value, count: 768)
        return try JSONSerialization.data(withJSONObject: ["embeddings": [floats]])
    }

    // MARK: - Tests

    func testInitRejectsNonLoopbackHost() {
        let url = URL(string: "https://example.com")!
        XCTAssertThrowsError(try OllamaEmbeddingClient(baseURL: url)) { err in
            guard case let MemoryError.embeddingNonLoopbackHost(host) = err else {
                return XCTFail("Expected embeddingNonLoopbackHost, got \(err)")
            }
            XCTAssertEqual(host, "example.com")
        }
    }

    func testInitAcceptsLoopback() {
        let urls: [String] = [
            "http://127.0.0.1:11434",
            "http://localhost:11434",
            "http://[::1]:11434",
            "http://LOCALHOST:11434",
        ]
        for s in urls {
            let url = URL(string: s)!
            XCTAssertNoThrow(try OllamaEmbeddingClient(baseURL: url),
                             "Loopback URL \(s) must be accepted at construction.")
        }
    }

    func testEmbedHits127001PortDefault() async throws {
        URLProtocolStub.reset(status: 200, body: try dim768Body())
        let client = makeStubbedClient()
        _ = try await client.embed("hello")

        let req = URLProtocolStub.lastRequest
        XCTAssertEqual(req?.url?.host, "127.0.0.1")
        XCTAssertEqual(req?.url?.port, 11434)
        XCTAssertEqual(req?.url?.path, "/api/embed")
    }

    func testEmbedSendsCorrectBody() async throws {
        URLProtocolStub.reset(status: 200, body: try dim768Body())
        let client = makeStubbedClient()
        _ = try await client.embed("hello")

        guard let body = URLProtocolStub.lastRequest?.httpBody,
              let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return XCTFail("could not parse request body")
        }
        XCTAssertEqual(dict["model"] as? String, "nomic-embed-text")
        XCTAssertEqual(dict["input"] as? String, "hello")
    }

    func testEmbedReturns768DimVector() async throws {
        URLProtocolStub.reset(status: 200, body: try dim768Body())
        let client = makeStubbedClient()
        let v = try await client.embed("hello")
        XCTAssertEqual(v.count, 768)
        XCTAssertEqual(v.first, 0.5)
    }

    func testEmbedThrowsDimensionMismatch() async throws {
        let bad = try JSONSerialization.data(withJSONObject: [
            "embeddings": [Array(repeating: Float(0.1), count: 769)]
        ])
        URLProtocolStub.reset(status: 200, body: bad)
        let client = makeStubbedClient()
        do {
            _ = try await client.embed("hello")
            XCTFail("expected dimensionMismatch")
        } catch let MemoryError.dimensionMismatch(expected, actual) {
            XCTAssertEqual(expected, 768)
            XCTAssertEqual(actual, 769)
        } catch {
            XCTFail("expected dimensionMismatch, got \(error)")
        }
    }

    func testEmbedThrowsOnHTTPError() async throws {
        URLProtocolStub.reset(status: 503, body: Data("{}".utf8))
        let client = makeStubbedClient()
        do {
            _ = try await client.embed("hello")
            XCTFail("expected embeddingHTTP")
        } catch let MemoryError.embeddingHTTP(statusCode) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("expected embeddingHTTP, got \(error)")
        }
    }

    func testEmbedThrowsOnEmptyEmbeddingsArray() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["embeddings": [] as [[Float]]])
        URLProtocolStub.reset(status: 200, body: body)
        let client = makeStubbedClient()
        do {
            _ = try await client.embed("hello")
            XCTFail("expected embeddingShapeError")
        } catch MemoryError.embeddingShapeError {
            // expected
        } catch {
            XCTFail("expected embeddingShapeError, got \(error)")
        }
    }
}
