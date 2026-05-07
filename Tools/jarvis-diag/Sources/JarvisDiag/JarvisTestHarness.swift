// JarvisTestHarness.swift
//
// Top-level harness actor. Every scenario in JARVIS-API-TEST-CONTRACT.md drives
// this type. Surface accessors (`turn`, `voice`, `memory`, `vision`, `settings`,
// `diagnostics`, `selfSurface`) mirror the v1.0 API one-to-one. Test seams
// (`injectAudioFrame`, `_forceTCCStatus`, `advanceClock`, etc.) are gated by
// JARVIS_HARNESS=1 per UQ-1.
//
// At Phase 5 every method body is `fatalError("not implemented — IMPL: <id>")`.
// Implementation lands during the migration. The set of scenario IDs covered by
// each accessor / seam is documented in line.

import Foundation

// MARK: - Placeholder ID & state types
//
// Until packages/JarvisAPI lands (M-0 step 1), these placeholders allow the
// skeleton to compile. They will be replaced with imports from JarvisAPI.

public typealias TurnID = String
public typealias ConfirmationID = String
public typealias FrameCaptureID = String
public typealias FactID = String
public typealias SessionID = String

/// Snapshot of harness-observable state at a single moment. Used by scenarios
/// for cross-event-stream invariants (e.g. "after T-002, no events for T1 fire").
public struct JarvisStateSnapshot: Sendable {
    public let activeTurnId: TurnID?
    public let voiceRunning: Bool
    public let pendingConfirmations: [ConfirmationID]
    public let armedFrameCaptureId: FrameCaptureID?
    public init(
        activeTurnId: TurnID?,
        voiceRunning: Bool,
        pendingConfirmations: [ConfirmationID],
        armedFrameCaptureId: FrameCaptureID?
    ) {
        self.activeTurnId = activeTurnId
        self.voiceRunning = voiceRunning
        self.pendingConfirmations = pendingConfirmations
        self.armedFrameCaptureId = armedFrameCaptureId
    }
}

/// Boot failure. Coverage for L-001..L-005 (see test contract §3.8).
public enum BootError: Error, Sendable {
    case harnessGateClosed             // JARVIS_HARNESS=1 missing when harness mode requested
    case entitlementsVerificationFailed(reason: String)
    case sqliteOpenFailed(detail: String)
    case keychainUnavailable
    case mcpHelperLaunchFailed(name: String, detail: String)
    case configCorrupt(detail: String)
}

public enum TCCPermission: String, Sendable, CaseIterable {
    case microphone, camera, inputMonitoring, screenCapture, speechRecognition
}

public enum ConfirmationOutcome: String, Sendable {
    case approved, denied, timedOut
}

// MARK: - Surface placeholders
//
// One marker struct per surface. Real implementation will route to the JarvisAPI
// surface-specific actors (TurnSurface, VoiceSurface, etc.). Each is annotated
// with the scenario IDs it must satisfy.

/// Turn surface accessor. Covers T-001..T-022, X-001..X-008.
public struct TurnSurfaceProxy: Sendable {
    public init() {}
    // IMPL: command + query methods + event AsyncStreams added in M-7.
}

/// Voice surface accessor. Covers V-001..V-012, X-001/X-003/X-007.
public struct VoiceSurfaceProxy: Sendable {
    public init() {}
    // IMPL: pttDown/Up, cancelTTS, synthesizeTurn, _injectAudioFrame, etc. in M-6.
}

/// Memory surface accessor. Covers M-001..M-007, X-001/X-004/X-005.
public struct MemorySurfaceProxy: Sendable {
    public init() {}
    // IMPL: forgetFact, listRecentFacts, searchFacts in M-4.
}

/// Vision surface accessor. Covers Vis-001..Vis-006, X-002.
public struct VisionSurfaceProxy: Sendable {
    public init() {}
    // IMPL: requestFrameAttach, cancelFrameAttach in M-5.
}

/// Settings surface accessor. Covers S-001..S-013, X-006.
public struct SettingsSurfaceProxy: Sendable {
    public init() {}
    // IMPL: setProvider, setTTSTier, ..., _setConfirmationDefault in M-2.
}

/// Diagnostics surface accessor. Covers D-001..D-011, X-008.
public struct DiagnosticsSurfaceProxy: Sendable {
    public init() {}
    // IMPL: toggleDevOverlay, copyStateDump, dismissBanner, streamReplayEvents in M-3.
}

/// Self surface accessor. Covers Sf-001..Sf-006, X-007, B08-fix.
public struct SelfSurfaceProxy: Sendable {
    public init() {}
    // IMPL: getSelfState, listAudioDevices, _forceTCCStatus in M-1.
}

// MARK: - JarvisTestHarness

/// The top-level test harness for the v1.0 API. Every scenario in
/// `JARVIS-API-TEST-CONTRACT.md` is implemented as a function on or against
/// this actor.
///
/// Construction requires `JARVIS_HARNESS=1` in the environment. Production
/// builds never instantiate this type; harness builds always do.
public actor JarvisTestHarness {

    /// Construct a harness instance. Asserts `JARVIS_HARNESS=1`. Boots a
    /// JarvisHost with the provided overrides; returns once the host has emitted
    /// `selfStateChanged` (boot complete).
    ///
    /// - Parameters:
    ///   - transport: UQ-5 — `.inProcessActor` or `.jsonRoundTripWebView`.
    ///   - clock: G-002 — typically `ManualClock` for deterministic timeouts.
    ///   - providerOverrides: G-004 — provider doubles. Default: deterministic.
    ///   - errorInjector: G-005 — nil → `NoOpErrorInjector`.
    ///   - tccOverrides: G-003 — initial TCC permission map. Synthesized via
    ///       `Self._forceTCCStatus` on each entry during boot.
    public init(
        transport: TransportMode,
        clock: APIClock,
        providerOverrides: ProviderOverrides = .deterministicDefaults(),
        errorInjector: ErrorInjector? = nil,
        tccOverrides: [TCCPermission: Bool]? = nil
    ) async throws {
        // IMPL: assert JARVIS_HARNESS=1, boot JarvisHost(transport, clock, overrides),
        //       wait for selfStateChanged, apply tccOverrides via _forceTCCStatus.
        fatalError("not implemented — IMPL: JarvisTestHarness.init (M-0)")
    }

    // MARK: - Surface accessors

    public var turn: TurnSurfaceProxy {
        get { fatalError("not implemented — IMPL: turn accessor (M-7)") }
    }

    public var voice: VoiceSurfaceProxy {
        get { fatalError("not implemented — IMPL: voice accessor (M-6)") }
    }

    public var memory: MemorySurfaceProxy {
        get { fatalError("not implemented — IMPL: memory accessor (M-4)") }
    }

    public var vision: VisionSurfaceProxy {
        get { fatalError("not implemented — IMPL: vision accessor (M-5)") }
    }

    public var settings: SettingsSurfaceProxy {
        get { fatalError("not implemented — IMPL: settings accessor (M-2)") }
    }

    public var diagnostics: DiagnosticsSurfaceProxy {
        get { fatalError("not implemented — IMPL: diagnostics accessor (M-3)") }
    }

    public var selfSurface: SelfSurfaceProxy {
        get { fatalError("not implemented — IMPL: selfSurface accessor (M-1)") }
    }

    // MARK: - Scenario primitives

    /// Block until a typed Event matches `predicate`, or throw on timeout.
    /// Backed by `clock.sleep(seconds:)` so ManualClock advances drive timeouts
    /// deterministically.
    public func awaitEvent<E: Sendable>(
        matching predicate: @Sendable (E) -> Bool,
        timeout: Duration
    ) async throws -> E {
        fatalError("not implemented — IMPL: awaitEvent (M-0)")
    }

    /// Convenience for the common case "wait until `turnEnded(turnId)` arrives."
    public func awaitTurnEnded(_ turnId: TurnID) async throws -> Any {
        // IMPL: return TurnEnded once JarvisAPI defines it
        fatalError("not implemented — IMPL: awaitTurnEnded — covers T-001, T-005, X-* (M-7)")
    }

    /// Snapshot of the harness's view of host state. Used as a quick
    /// post-condition assertion in cross-surface scenarios.
    public func snapshotState() async -> JarvisStateSnapshot {
        fatalError("not implemented — IMPL: snapshotState (M-0)")
    }

    // MARK: - Test seams (require JARVIS_HARNESS=1)

    /// G-001: feed a synthetic PCM frame into the audio graph.
    /// Covers V-006, X-001 (cross-surface voice), B04-fix.
    public func injectAudioFrame(pcm: [Float], sampleRate: Int = 16_000) async {
        fatalError("not implemented — IMPL: injectAudioFrame (M-6)")
    }

    /// G-001: short-circuit wake-word detection. Bypasses the DAG; emits
    /// `Voice.wakeWordDetected` directly.
    /// Covers V-007, X-001.
    public func injectWakeWord(confidence: Float) async {
        fatalError("not implemented — IMPL: injectWakeWord (M-6)")
    }

    /// G-001: short-circuit STT. Emits `sttTranscriptPartial` (isFinal=false)
    /// or `sttTranscriptFinal` (isFinal=true), submitting a turn on final.
    /// Covers V-008, X-001.
    public func injectSTT(text: String, isFinal: Bool) async {
        fatalError("not implemented — IMPL: injectSTT (M-6)")
    }

    /// G-001: subscribe to TTS synthesis records (no audio emitted beyond the
    /// boundary; record carries `{turnId, tier, sampleCount, started, ended}`).
    /// Covers V-005, X-003, B05-fix.
    public func observeTTSAudio() -> AsyncStream<TTSSynthesisRecord> {
        fatalError("not implemented — IMPL: observeTTSAudio (M-6)")
    }

    /// G-003: force TCC status for `permission`. Re-emits `tccStatusChanged`;
    /// downstream subsystems re-probe and may emit `voiceDegraded` /
    /// `cameraDegraded`.
    /// Covers Sf-002, V-002, V-010, Vis-002, Vis-005, X-007.
    public func injectTCC(_ permission: TCCPermission, granted: Bool) async {
        fatalError("not implemented — IMPL: injectTCC (M-1)")
    }

    /// G-002: advance ManualClock. Resumes pending sleep continuations whose
    /// deadline falls within the window, in order. Real-clock harness builds
    /// fail closed.
    /// Covers T-012 (confirmation timeout), Vis-004 (frame expiry), V-006
    /// (audio-level cadence), and any §6 timing assertion.
    public func advanceClock(by duration: Duration) async {
        fatalError("not implemented — IMPL: advanceClock (M-0)")
    }

    /// Settings test seam (orch-default): set the auto-resolution outcome for
    /// confirmation prompts. `.deny` is the harness default to keep production
    /// safety semantics; scenarios that want auto-approve flip explicitly.
    /// Covers T-010, T-011.
    public func setConfirmationDefault(_ outcome: ConfirmationOutcome) async {
        fatalError("not implemented — IMPL: setConfirmationDefault (M-2)")
    }

    /// G-005: register an error injection. The next call to `operation` returns
    /// the canonical typed error for `code`.
    /// Covers all `[trigger: harness-injectable]` rows in §6.
    public func forceError(operation: String, code: String, fireOnce: Bool = true) async {
        fatalError("not implemented — IMPL: forceError (M-0)")
    }

    /// Tear down the harness, flush replay log, terminate JarvisHost.
    public func shutdown() async {
        fatalError("not implemented — IMPL: shutdown (M-0)")
    }
}

/// Captured TTS synthesis side-effect; never carries raw PCM beyond the boundary.
/// Used by V-005, X-003, B05-fix.
public struct TTSSynthesisRecord: Sendable, Equatable {
    public let turnId: TurnID
    public let tier: String         // "tier1" | "tier2"
    public let sampleCount: Int
    public let started: Date
    public let ended: Date?

    public init(turnId: TurnID, tier: String, sampleCount: Int, started: Date, ended: Date?) {
        self.turnId = turnId
        self.tier = tier
        self.sampleCount = sampleCount
        self.started = started
        self.ended = ended
    }
}
