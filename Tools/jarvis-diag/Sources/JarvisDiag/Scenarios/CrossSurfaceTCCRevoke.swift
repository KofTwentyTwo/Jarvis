// CrossSurfaceTCCRevoke.swift
//
// X-007: Self → Voice cascade when mic TCC is revoked mid-listening.
// Asserts the chain: tccStatusChanged → voiceDegraded(.microphoneRevoked)
// → voiceStateChanged(idle) → systemBannerEnqueued. Any in-flight STT turn ends
// with turnError.
//
// Modes: both. Scenario IDs: X-007, V-010 (cross-surface variant).

import Foundation

public enum CrossSurfaceTCCRevoke {

    public static let scenario = Scenario(
        id: "X-007",
        title: "X-007: mid-listening mic revocation cascade",
        body: { harness in
            // IMPL outline:
            //   1. boot; injectTCC(.microphone, true)
            //   2. await harness.settings.setVoiceRunning(true)
            //   3. injectWakeWord(0.9); state → listening
            //   4. injectAudioFrame*N (mid-stream)
            //   5. await harness.injectTCC(.microphone, false)
            //   6. assert events in order:
            //        tccStatusChanged(.microphone, false)
            //        voiceDegraded(.microphoneRevoked)
            //        voiceStateChanged(state: .idle, listeningSource: nil)
            //        systemBannerEnqueued(priority > 0)
            //   7. if a turn was in flight, assert turnError(code: .internalError) or
            //      turnEnded(.cancelled) — whichever the migration plan picks
            fatalError("not implemented — IMPL: X-007 TCC revocation cascade")
        }
    )
}
