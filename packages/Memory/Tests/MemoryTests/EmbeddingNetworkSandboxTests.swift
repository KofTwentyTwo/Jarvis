import XCTest
@testable import Memory

/// MEM-04 network-sandbox invariant: the embedding client REFUSES any
/// non-loopback baseURL at construction — no bytes reach the wire for
/// remote hosts.
///
/// CONTEXT.md mandates: "Zero user data leaves the machine for memory or
/// vision." The embedding client is the only component in the memory
/// write path that does HTTP I/O; this test enforces that its origin is
/// always the user's own machine.
final class EmbeddingNetworkSandboxTests: XCTestCase {

    func testRemoteHostsAreRejectedAtConstruction() throws {
        let nonLoopbackURLs: [String] = [
            "http://10.0.0.5:11434",
            "https://api.openai.com",
            "http://192.168.1.10:11434",
            "http://example.com:11434",
            "https://anthropic.com",
            "http://[2001:db8::1]:11434",
        ]
        for s in nonLoopbackURLs {
            let url = URL(string: s)!
            XCTAssertThrowsError(try OllamaEmbeddingClient(baseURL: url)) { err in
                guard case MemoryError.embeddingNonLoopbackHost = err else {
                    return XCTFail("Expected embeddingNonLoopbackHost for \(s); got \(err)")
                }
            }
        }
    }

    func testLoopbackHostsAreAccepted() throws {
        let loopbackURLs: [String] = [
            "http://127.0.0.1:11434",
            "http://localhost:11434",
            "http://[::1]:11434",
            "http://LOCALHOST:11434",
        ]
        for s in loopbackURLs {
            let url = URL(string: s)!
            XCTAssertNoThrow(try OllamaEmbeddingClient(baseURL: url),
                             "Loopback host \(s) must be accepted by the sandbox guard.")
        }
    }

    /// Belt-and-suspenders: call the static guard directly to make absolutely
    /// sure no future refactor moves the assertion past a network call.
    func testStaticGuardIsCallableWithoutNetwork() {
        XCTAssertThrowsError(try OllamaEmbeddingClient.assertLoopback(URL(string: "https://evil.example.com")!))
        XCTAssertNoThrow(try OllamaEmbeddingClient.assertLoopback(URL(string: "http://127.0.0.1:11434")!))
    }
}
