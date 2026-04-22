import XCTest
@testable import JarvisLogging

final class RedactTests: XCTestCase {
    func test_anthropicKey() {
        let input = "my key is sk-ant-api03-abc123XYZ-0987654321"
        let out = Redact.apply(input)
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains("sk-ant-api03-abc123XYZ-0987654321"))
    }

    func test_openAIKey() {
        let input = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
        let out = Redact.apply(input)
        XCTAssertTrue(out.contains("<redacted>"))
    }

    func test_authorizationBearer() {
        let input = "Authorization: Bearer abcdefghij1234567890"
        let out = Redact.apply(input)
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains("abcdefghij1234567890"))
    }

    func test_awsAccessKey() {
        let input = "AKIAIOSFODNN7EXAMPLE"
        let out = Redact.apply(input)
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    func test_githubToken() {
        let input = "ghp_abcdef1234567890ABCDEF1234567890abcdef"
        let out = Redact.apply(input)
        XCTAssertTrue(out.contains("<redacted>"))
    }

    func test_plainTextUnchanged() {
        let input = "Hello, this is a totally normal log line with no secrets."
        XCTAssertEqual(Redact.apply(input), input)
    }

    func test_anthropicBranchBeatsOpenAIBranch() {
        // sk-ant-... should match pattern 1 (Anthropic), not pattern 3 (OpenAI sk-).
        let input = "sk-ant-api03-abcdef1234567890abcdef"
        let out = Redact.apply(input)
        // Both branches redact, but we check that the ENTIRE sk-ant- prefix is captured.
        // A regression where branch 3 matched first would leave "sk-ant-" prefix visible.
        XCTAssertFalse(out.contains("sk-ant-"), "Anthropic branch should consume the full prefix")
    }
}
