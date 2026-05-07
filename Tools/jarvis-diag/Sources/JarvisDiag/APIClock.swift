// APIClock.swift
//
// G-002 LOCKED: clock injection at every surface boundary. Operations with
// timeouts (frame-attach 5 s, confirmation 30 s, handshake 2 s, hangover 320 ms,
// batcher 16 ms) read from the injected clock. Tests advance ManualClock manually
// for deterministic timeout assertions.
//
// See JARVIS-API-TEST-CONTRACT.md §7 "Determinism" and v0.2 §2.1 G-002.

import Foundation

/// Time abstraction injected into every surface that has a timeout.
///
/// Production wiring uses ``RealClock``; harness scenarios use ``ManualClock``
/// so frame-attach expiry, confirmation timeout, batcher window, and hangover
/// thresholds are all exercised deterministically without `Task.sleep`.
public protocol APIClock: Sendable {
    /// Current wall-clock time. Tests advance `ManualClock.now` via ``advance(by:)``.
    var now: Date { get }

    /// Suspends until the absolute date is reached. Cancellation-aware.
    func sleep(until: Date) async throws

    /// Suspends for `seconds`. Cancellation-aware. Sub-second precision required.
    func sleep(seconds: Double) async throws
}

/// Production clock — backed by `Date()` and `ContinuousClock`.
public struct RealClock: APIClock {
    public init() {}

    public var now: Date {
        // IMPL: return Date()
        fatalError("not implemented — IMPL: RealClock.now (M-0)")
    }

    public func sleep(until: Date) async throws {
        // IMPL: compute interval, call ContinuousClock.sleep(for:)
        fatalError("not implemented — IMPL: RealClock.sleep(until:) (M-0)")
    }

    public func sleep(seconds: Double) async throws {
        // IMPL: try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        fatalError("not implemented — IMPL: RealClock.sleep(seconds:) (M-0)")
    }
}

/// Harness clock — caller controls time. Test seam for timeout-bearing scenarios.
///
/// Sleep calls register a continuation; ``advance(by:)`` resumes any continuations
/// whose deadline falls inside the advance window. Used by:
///   - T-012 (confirmation 30s timeout)
///   - Vis-004 (frame-attach 5s expiry)
///   - V-006 (audio-level 500ms cadence)
///   - any G-002-marked scenario
public actor ManualClock: APIClock {
    public init(initial: Date = Date(timeIntervalSince1970: 0)) {
        // IMPL: store initial as _now
        fatalError("not implemented — IMPL: ManualClock.init (M-0)")
    }

    public nonisolated var now: Date {
        // IMPL: actor-isolated read; expose snapshot via locked storage
        fatalError("not implemented — IMPL: ManualClock.now (M-0)")
    }

    public nonisolated func sleep(until: Date) async throws {
        // IMPL: register continuation against deadline; resumed by advance(by:)
        fatalError("not implemented — IMPL: ManualClock.sleep(until:) (M-0)")
    }

    public nonisolated func sleep(seconds: Double) async throws {
        // IMPL: convert to absolute deadline, delegate to sleep(until:)
        fatalError("not implemented — IMPL: ManualClock.sleep(seconds:) (M-0)")
    }

    /// Advance the clock by the given duration. Resumes any pending sleep
    /// continuations whose deadline falls within the advance window, in order.
    public func advance(by seconds: Double) async {
        // IMPL: walk pending continuations sorted by deadline, resume each up to new now
        fatalError("not implemented — IMPL: ManualClock.advance (M-0)")
    }
}
