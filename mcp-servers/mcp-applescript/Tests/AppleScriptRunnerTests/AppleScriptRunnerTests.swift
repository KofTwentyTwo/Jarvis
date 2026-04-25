// AppleScriptRunnerTests.swift
//
// Plan 05-03 / Task 1 (TDD RED → GREEN).
//
// Coverage for `NSAppleScriptRunner` — the in-process `NSAppleScript` wrapper
// the helper uses to execute script sources. Tests cover:
//   - valid script returning a string literal → .success
//   - invalid syntax → .compileFailure
//   - runtime `error … number N` → .runtimeError
//   - empty source → .compileFailure
//
// `NSAppleScript` requires `+[NSAppleScript executeAndReturnError:]` to run on
// the main thread under most macOS conditions, but the call is synchronous and
// works without `NSApp.run()` for v1's "execute and return result" contract
// (RESEARCH Open Question #3, Assumption A4). The plan's scaffold-time stderr
// probe in main.swift verifies this empirically at helper init.
//
// Tests can be opted out via `JARVIS_SKIP_NSAPPLESCRIPT=1` for headless CI
// environments where AppleScript is unavailable.

import XCTest
@testable import mcp_applescript

final class AppleScriptRunnerTests: XCTestCase {

    /// Skip body if running headless (env opt-out for CI).
    private func skipIfHeadless() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["JARVIS_SKIP_NSAPPLESCRIPT"] != nil,
            "Skipping under JARVIS_SKIP_NSAPPLESCRIPT — NSAppleScript unavailable in headless test runner"
        )
    }

    func test_validScript_returnsSuccessWithStringValue() throws {
        try skipIfHeadless()
        let runner = NSAppleScriptRunner()
        let outcome = runner.run(source: "return \"hello\"")
        XCTAssertEqual(outcome, .success("hello"))
    }

    func test_invalidSyntax_returnsCompileFailure() throws {
        try skipIfHeadless()
        let runner = NSAppleScriptRunner()
        let outcome = runner.run(source: "this is not applescript")
        XCTAssertEqual(outcome, .compileFailure)
    }

    func test_runtimeError_returnsRuntimeError() throws {
        try skipIfHeadless()
        let runner = NSAppleScriptRunner()
        let outcome = runner.run(source: "error \"bad things\" number 42")
        switch outcome {
        case .runtimeError(let number, let message):
            XCTAssertEqual(number, 42)
            XCTAssertTrue(
                message.contains("bad things"),
                "expected runtime error message to contain 'bad things', got \(message)"
            )
        default:
            XCTFail("expected .runtimeError, got \(outcome)")
        }
    }

    func test_emptySource_returnsCompileFailure() throws {
        try skipIfHeadless()
        let runner = NSAppleScriptRunner()
        let outcome = runner.run(source: "")
        XCTAssertEqual(outcome, .compileFailure)
    }
}
