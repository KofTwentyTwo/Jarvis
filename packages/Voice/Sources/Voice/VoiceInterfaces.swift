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
