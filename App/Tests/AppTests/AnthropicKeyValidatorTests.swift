import XCTest
@testable import Jarvis

final class AnthropicKeyValidatorTests: XCTestCase {
    private struct MockClient: URLRequestClient {
        let status: Int
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    func test_malformedSkipsNetwork() async {
        // status=500 would bubble as .generic if the client were called —
        // since the key doesn't start with sk-ant-, the validator must short
        // out BEFORE hitting the network.
        let validator = AnthropicKeyValidator(client: MockClient(status: 500))
        let result = await validator.validate(key: "not-an-anthropic-key")
        XCTAssertEqual(result, .malformed)
    }

    func test_unauthorized() async {
        let validator = AnthropicKeyValidator(client: MockClient(status: 401))
        let result = await validator.validate(key: "sk-ant-api03-fake-key-shape")
        XCTAssertEqual(result, .unauthorized)
    }

    func test_valid() async {
        let validator = AnthropicKeyValidator(client: MockClient(status: 200))
        let result = await validator.validate(key: "sk-ant-api03-fake-key-shape")
        XCTAssertEqual(result, .valid)
    }
}
