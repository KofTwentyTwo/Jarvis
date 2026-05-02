import Foundation
import Voice  // VoiceTTSInterface, TTSEngineActor, TTSTier

/// Production adapter bridging `Voice.VoiceTTSInterface` to `TTSEngineActor`.
///
/// Phase 9 / Plan 4 / D-09: replaces `NullTTSAdapter`.
///
/// **Engine optional.** Plan 4 wires the adapter regardless of whether a
/// real `TTSEngineActor` has been constructed by `installVoice`. When
/// `engine == nil` the adapter no-ops gracefully — preserves the current
/// production behaviour (TTSEngineActor construction is gated on Orpheus
/// MLX weights + AVSpeech availability and lands in a follow-on plan) while
/// the rest of the orchestrator wiring goes live.
///
/// **Tier resolver.** The TTS tier (tier1 AVSpeech vs tier2 Orpheus) is
/// resolved per-synthesis from `PerTurnSnapshot.tts.tier` so a config
/// change picks up on the next call without restarting voice. Defaults to
/// `.tier1` when no resolver is supplied.
///
/// **Voice id.** Defaulted to `"en-US"` for tier-1 (AVSpeech accepts a
/// language code via `AVSpeechSynthesisVoice(language:)`) and `"tara"` for
/// tier-2 (Orpheus voice character per RESEARCH-DELTAS). The plan-level
/// research notes that Orpheus streaming is confirmed; voice character is
/// fixed for now and revisited when TTS configurability lands.
actor VoiceTTSAdapter: VoiceTTSInterface {
    private let engine: TTSEngineActor?
    private let tierResolver: @Sendable () async -> TTSTier

    init(
        engine: TTSEngineActor?,
        tierResolver: @escaping @Sendable () async -> TTSTier = { .tier1 }
    ) {
        self.engine = engine
        self.tierResolver = tierResolver
    }

    var hasSynthInFlight: Bool {
        get async {
            guard let engine else { return false }
            return await engine.hasSynthInFlight
        }
    }

    func synthesize(_ text: String) async {
        guard let engine else { return }  // dormant — no engine wired yet
        let tier = await tierResolver()
        let voiceId = voiceIDForTier(tier)
        // TTSEngineActor.synthesize throws on cancellation / synthesis
        // failure. We swallow these here because Voice's protocol is
        // throwing-free; the underlying error is already logged through
        // TTSEvent and JarvisLogChannel.tts.
        try? await engine.synthesize(text, tier: tier, voice: voiceId)
    }

    func cancelTTS() async {
        guard let engine else { return }
        await engine.cancel()
    }

    private nonisolated func voiceIDForTier(_ tier: TTSTier) -> String {
        switch tier {
        case .tier1:
            return "en-US"  // AVSpeech language code
        case .tier2:
            return "tara"    // Orpheus voice character (RESEARCH-DELTAS)
        }
    }
}
