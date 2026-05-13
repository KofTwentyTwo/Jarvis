import Foundation

// MARK: - VoiceOrchestratorInterface
//
// Protocol abstraction over AgentOrchestrator so VoiceController can live
// in the Voice package without importing AgentCore (which would create a
// package dependency cycle).
//
// AppDelegate wires the real AgentOrchestrator via a thin adapter.

/// Events the voice controller cares about from the orchestrator.
public enum VoiceOrchestratorEvent: Sendable {
    /// Orchestrator completed a turn and produced final text for TTS.
    case turnEnded(finalText: String)
    /// Orchestrator's prior turn was cancelled (barge-in displacement).
    case cancelled
    /// Orchestrator encountered an error (voice turn returns to .idle).
    case error
}

/// Minimal orchestrator interface consumed by VoiceController.
///
/// `AgentOrchestrator` conforms to this via an adapter in AppDelegate.
public protocol VoiceOrchestratorInterface: Sendable {
    /// Stream of events relevant to voice state transitions.
    var voiceEvents: AsyncStream<VoiceOrchestratorEvent> { get }

    /// Submit a voice turn. Called when VAD .speechEnd + STT finalizes.
    func submit(text: String) async

    /// Cancel the in-flight turn and submit a new one.
    ///
    /// Barge-in: called with `text = ""` as a displacement sentinel.
    /// The orchestrator supersedes the prior turn and returns to idle.
    func cancelAndSubmit(text: String) async
}

// MARK: - VoiceTTSInterface
//
// Protocol abstraction over TTSEngineActor so tests can inject a mock without
// the real Orpheus MLX dependency.

/// Minimal TTS surface consumed by VoiceController.
public protocol VoiceTTSInterface: Sendable {
    /// Whether synthesis is currently in flight (for InterruptSequence idempotency).
    var hasSynthInFlight: Bool { get async }

    /// Synthesize the given text using tier-2 (Orpheus) if available.
    func synthesize(_ text: String) async

    /// Cancel any in-flight synthesis (step 1 of InterruptSequence).
    func cancelTTS() async
}

// MARK: - VoiceBannerInterface
//
// Thin abstraction over HUDBannerCoordinator so Voice package doesn't import
// the App target.

/// Minimal banner surface consumed by VoiceController for AEC fallback (VOICE-09).
public protocol VoiceBannerInterface: Sendable {
    /// Show a persistent banner message. Safe to call multiple times.
    func showBanner(message: String)

    /// Dismiss the currently shown banner.
    func dismissBanner()
}

// MARK: - VoiceHudIntent
//
// Intents produced by the voice subsystem for HUD state resolution.
// Defined here (Voice package) so VoiceController can reference it without
// importing the App target. App/HUD/HudStateIntent.swift re-exports this via
// `public typealias VoiceHudIntent = Voice.VoiceHudIntent`.

/// The three voice-subsystem states visible to the HUD coordinator.
public enum VoiceHudIntent: Sendable, Equatable {
    /// Voice pipeline is idle — no activation, no reconfiguration.
    case silent
    /// Microphone is active; listening for speech.
    case listening
    /// Audio graph is rebuilding (AEC route change, etc.).
    case reconfiguring
}

// MARK: - BusOutboundEmitter
//
// Thin protocol over OutboundBatcher so Voice package doesn't import Bus.
// Plan 03-03's RingMesh consumes `BusOutbound.audioLevel(rms:)` at ~30 Hz.

/// Minimal bus emission surface for audio-level RMS (VOICE Plan 03-03 wiring).
///
/// Production conformance: `OutboundBatcher` from the Bus package.
/// Test conformance: `MockBusEmitter` in VoiceTests.
public protocol BusOutboundEmitter: Sendable {
    /// Post an RMS audio level value to the bus (~30 Hz during .listening).
    func postAudio(_ rms: Float) async
}

// MARK: - VoiceTapSink
//
// Optional, opt-in observer used by the App-target Voice Log window. The
// Voice package exposes only a tiny enum of "publisher events" — App-side
// code translates these into `VoiceLog.VoiceLogEvent` and posts to the
// publisher. The Voice package itself stays agnostic of the VoiceLog
// package (no dep cycle).
//
// **T-06-05-03 carve-out.** The protocol carries transcript/TTS text
// payload because the Voice Log is an in-process, user-controlled UI
// surface. Conformers MUST NOT route these payloads to OSLog or persist
// them to disk; the production conformer (`VoiceLogTapAdapter` in App/
// Voice/) only forwards to the in-memory `VoiceLogPublisher`.

/// Events emitted by `VoiceController` for diagnostic observers.
public enum VoiceTapEvent: Sendable {
    case stateTransition(from: VoiceState, to: VoiceState)
    case orchestratorSubmit(text: String)
    case orchestratorTurnEnd(text: String)
    case orchestratorCancelled
    case orchestratorError
    case ttsSynthesizeStart(text: String)
    case ttsSynthesizeComplete
    case ttsCancel
    case vadSpeechStart
    case vadSpeechEnd
    case vadSpeech
    case vadSilence
    case sttPartial(text: String)
    case sttFinal(text: String)
    case wakeWordFired
}

/// Optional diagnostic tap installed by the App target. Production
/// conformer is `VoiceLogTapAdapter` (App/Voice/) which forwards to the
/// in-process `VoiceLogPublisher`. Tests pass a `NullVoiceTap` or capture
/// to an array.
public protocol VoiceTapSink: Sendable {
    func emit(_ event: VoiceTapEvent) async
}

/// No-op tap. Default for `VoiceController.init` so production code paths
/// that don't wire the Voice Log keep their existing behavior.
public struct NullVoiceTap: VoiceTapSink {
    public init() {}
    public func emit(_ event: VoiceTapEvent) async {}
}
