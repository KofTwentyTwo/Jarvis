import XCTest
@testable import Jarvis

/// CR-02 (SEC-01): `WizardStageAPIKeyView` must shorten the plaintext API
/// key's memory lifetime as much as possible. Swift `String` is CoW/immutable,
/// so we can't truly zero the backing page, but we can sever @State's strong
/// reference on both success paths and view teardown — that lets ARC release
/// the CoW page when no other strong reference exists.
///
/// This is a source-level grep gate — SwiftUI @State behaviour is not
/// observable from XCTest without ViewInspector, so we guard the regression
/// at the text level. Any refactor that removes the `onDisappear { clearAPIKey() }`
/// wiring or the "clear apiKey before Task" line in `verify()` fails this
/// test.
final class WizardStageAPIKeyViewTests: XCTestCase {
    private func sourceText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // AppTests/
            .deletingLastPathComponent()    // Tests/
            .deletingLastPathComponent()    // App/
            .appendingPathComponent("App/Wizard/WizardStageAPIKeyView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_onDisappearClearsAPIKey() throws {
        let source = try sourceText()
        XCTAssertTrue(
            source.contains(".onDisappear"),
            "CR-02 regression: WizardStageAPIKeyView must hook .onDisappear"
        )
        XCTAssertTrue(
            source.contains("clearAPIKey()"),
            "CR-02 regression: WizardStageAPIKeyView must call clearAPIKey() on teardown"
        )
    }

    func test_clearAPIKeyZerosAndEmptiesState() throws {
        let source = try sourceText()
        XCTAssertTrue(
            source.contains("private func clearAPIKey()"),
            "CR-02 regression: clearAPIKey() helper must exist"
        )
        // Must overwrite with zeros before dropping to empty — comment /
        // implementation may vary but the `\\0` literal must be present.
        XCTAssertTrue(
            source.contains("\"\\0\""),
            "CR-02 regression: clearAPIKey must overwrite with null bytes before empty assignment"
        )
        XCTAssertTrue(
            source.contains("apiKey = \"\""),
            "CR-02 regression: clearAPIKey must reassign apiKey to empty"
        )
    }

    func test_verifyCapturesKeyAndClearsStateImmediately() throws {
        let source = try sourceText()
        // The verify() function must capture the apiKey into a local before
        // spawning the async task, then clear @State immediately.
        XCTAssertTrue(
            source.contains("let capturedKey = apiKey"),
            "CR-02 regression: verify() must capture apiKey into a local before async work"
        )
        // After capturing, the @State slot must be cleared so SwiftUI stops
        // retaining the plaintext in its attribute graph.
        let pattern = "let capturedKey = apiKey\n        apiKey = \"\""
        XCTAssertTrue(
            source.contains(pattern),
            "CR-02 regression: verify() must assign apiKey = \"\" immediately after capturing"
        )
    }
}
