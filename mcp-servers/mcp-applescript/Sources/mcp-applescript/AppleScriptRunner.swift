// AppleScriptRunner.swift
//
// Testable extraction of the AppleScript execution path for the
// mcp-applescript helper. Production code constructs `NSAppleScriptRunner`,
// which wraps `NSAppleScript(source:).executeAndReturnError(_:)`.
//
// SECURITY (Plan 05-03 / SEC-08, T-05-03-04):
//   This runner has NO allowlist, NO regex skip-rules, NO content
//   inspection. Every call is privileged in v1 — the user-confirmation gate
//   is the orchestrator's ConfirmationBroker (Plan 05-05). Adding a "safe
//   pattern" allowlist here would silently bypass the confirmation FSM and
//   violate SEC-08.
//
// SECURITY (T-05-03-03):
//   We intentionally use in-process `NSAppleScript`, NOT a `Process()`
//   subprocess. Spawning a child binary to run scripts would put execution
//   under a different TCC identity than this helper bundle, defeating
//   per-helper TCC isolation. The plan's verification grep enforces absence
//   of the subprocess CLI binary name in source files.
//
// CONCURRENCY:
//   `NSAppleScript` itself is not Sendable, so we never hold one across
//   suspensions — the runner constructs, executes, and returns within a
//   single synchronous call. The `NSAppleScriptRunner` struct is Sendable
//   because it carries no stored state.

import Foundation

public protocol AppleScriptRunning: Sendable {
    func run(source: String) -> AppleScriptOutcome
}

public enum AppleScriptOutcome: Sendable, Equatable {
    case success(String)
    case runtimeError(number: Int, message: String)
    case compileFailure
}

public struct NSAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(source: String) -> AppleScriptOutcome {
        // Empty / whitespace-only source: NSAppleScript happily compiles an
        // empty script and "succeeds" with no return value. The plan's
        // contract treats this as `.compileFailure` — there's nothing to run,
        // and accepting it would let the model invoke the helper with empty
        // input and consume a confirmation prompt for nothing.
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .compileFailure
        }
        guard let script = NSAppleScript(source: source) else {
            return .compileFailure
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            // Documented keys: NSAppleScriptErrorAppName,
            // NSAppleScriptErrorBriefMessage, NSAppleScriptErrorMessage,
            // NSAppleScriptErrorNumber, NSAppleScriptErrorRange. We surface
            // number + message; brief is the fallback when message is absent.
            let num = err["NSAppleScriptErrorNumber"] as? Int ?? 0
            let msg = (err["NSAppleScriptErrorMessage"] as? String)
                ?? (err["NSAppleScriptErrorBriefMessage"] as? String)
                ?? "unknown error"

            // executeAndReturnError merges compile-time and runtime failures
            // into the same dictionary. The OSA error-number ranges
            // distinguish them (Apple OSA.h):
            //   -2700 .. -2799  : compile / parse errors (errOSAScriptError range
            //                     for syntax / undefined identifiers)
            // Anything outside that range — including user-thrown
            // `error "…" number N` — is a runtime error.
            if num <= -2700 && num >= -2799 {
                return .compileFailure
            }
            return .runtimeError(number: num, message: msg)
        }
        return .success(result.stringValue ?? "(no return value)")
    }
}
