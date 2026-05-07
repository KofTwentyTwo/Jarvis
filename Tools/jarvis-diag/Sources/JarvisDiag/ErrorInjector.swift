// ErrorInjector.swift
//
// G-005 LOCKED: every error variant in v1.0 is annotated [trigger: real-only |
// harness-injectable | not-yet-triggerable]. ErrorInjector is the runtime seam
// for harness-injectable variants. Subsystems consult `ErrorInjector.shouldFail`
// before each fallible operation; if the operation/code matches a registered
// injection, the operation returns the canonical typed error.
//
// Gated by JARVIS_HARNESS=1 (UQ-1). Production binary instantiates a no-op
// injector that never returns an error.
//
// See JARVIS-API-TEST-CONTRACT.md §6 "Failure-injection scenarios" and v0.2 §2.1 G-005.

import Foundation

/// Runtime-pluggable error injector. Subsystems probe before fallible ops.
public protocol ErrorInjector: Sendable {
    /// Returns the canonical error code string if the operation should fail,
    /// nil otherwise. Operation/code identifiers are documented per surface
    /// in the test contract failure-injection table.
    func shouldFail(operation: String) async -> String?

    /// Register an injection. Used by harness scenarios.
    /// Operation strings:
    ///   "Voice.synthesizeTurn", "Settings.storeAPIKey",
    ///   "Vision.requestFrameAttach", "Turn.submitTurn", etc.
    /// Code strings are the canonical enum case raw values
    ///   "audioGraphFailed", "keychainWriteFailed", "providerUnavailable", etc.
    func register(operation: String, code: String, fireOnce: Bool) async

    /// Clear all registered injections.
    func reset() async
}

/// Production no-op — never returns an error code.
public struct NoOpErrorInjector: ErrorInjector {
    public init() {}
    public func shouldFail(operation: String) async -> String? { nil }
    public func register(operation: String, code: String, fireOnce: Bool) async {}
    public func reset() async {}
}

/// Harness implementation — used by `JarvisTestHarness` when `JARVIS_HARNESS=1`.
public actor RecordingErrorInjector: ErrorInjector {
    public init() {
        // IMPL: empty registration table
        fatalError("not implemented — IMPL: RecordingErrorInjector.init (M-0)")
    }

    public func shouldFail(operation: String) async -> String? {
        // IMPL: lookup operation; if fireOnce, remove on hit
        fatalError("not implemented — IMPL: RecordingErrorInjector.shouldFail (M-0)")
    }

    public func register(operation: String, code: String, fireOnce: Bool) async {
        // IMPL: store (operation, code, fireOnce) in registration map
        fatalError("not implemented — IMPL: RecordingErrorInjector.register (M-0)")
    }

    public func reset() async {
        // IMPL: clear registration map
        fatalError("not implemented — IMPL: RecordingErrorInjector.reset (M-0)")
    }
}
