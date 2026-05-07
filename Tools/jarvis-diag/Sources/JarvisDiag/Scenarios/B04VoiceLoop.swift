// B04VoiceLoop.swift
//
// Reproduces and dissolves B-04: voice input dead — wake-word + STT never fire
// because audio frames don't reach the WakeWordDAG (TCC requestAccess landed in
// b92d062 but no audio reaches the DAG). v0.2 §2.1 R-007 + UQ-2 disposition
// (B-04 stays in M-6, no tactical patch).
//
// Pre-fix (B04-repro): setVoiceRunning(true) returns success but no
// audioLevelChanged events arrive within 500ms. Reproduces today's silent
// log-and-degrade.
//
// Post-fix (B04-fix = V-006): setVoiceRunning(true) returns .success;
// ≥10 audioLevelChanged events within 500ms. Failure path:
//   forceError("setVoiceRunning", "audioGraphFailed") →
//   .failure(.audioGraphFailed(reason:"ringBuffer nil after open()"))
// surfaces a typed error, not silent degradation.
//
// Modes: actor (audio-graph wiring is internal); jsonRoundTrip transport doesn't
// add coverage and would slow runtime. Real-hardware variant uses
// JARVIS_REAL_AUDIO=1 outside the default suite.
// Scenario IDs: B04-repro, B04-fix, V-006.

import Foundation

public enum B04VoiceLoop {

    /// B04-repro — reproduces silent audio-graph failure.
    public static let repro = Scenario(
        id: "B04-repro",
        title: "B-04 reproduction: setVoiceRunning(true) succeeds but no audio flows",
        mode: .actorOnly(reason: "audio-graph behavior is internal; transport doesn't change observability"),
        body: { harness in
            // IMPL outline:
            //   setVoiceRunning(true)
            //   inject 15 audio frames
            //   try await harness.awaitEvent(matching: { (_ : VoiceEvent) in true }, timeout: 500ms)
            //   assert TIMEOUT (current bug)
            fatalError("not implemented — IMPL: B-04 reproduction (V-006 pre-fix)")
        }
    )

    /// B04-fix — must pass after M-6.
    public static let fix = Scenario(
        id: "B04-fix",
        title: "B-04 dissolution: ≥10 audioLevelChanged within 500ms of setVoiceRunning(true)",
        mode: .actorOnly(reason: "audio path internal"),
        body: { harness in
            // IMPL outline:
            //   await harness.settings.setVoiceRunning(true)
            //   for _ in 0..<15 { await harness.injectAudioFrame(pcm: silenceFrame) }
            //   await harness.advanceClock(by: .milliseconds(500))
            //   collect audioLevelChanged events; assert count >= 10
            fatalError("not implemented — IMPL: B-04 fix (V-006)")
        }
    )

    /// B04-typed-error — proves the failure path returns a typed error, not a silent log.
    public static let typedError = Scenario(
        id: "B04-typed-error",
        title: "B-04 typed-error path: setVoiceRunning surfaces audioGraphFailed",
        mode: .actorOnly(reason: "ErrorInjector path"),
        body: { harness in
            // IMPL outline:
            //   await harness.forceError(operation: "Settings.setVoiceRunning", code: "audioGraphFailed")
            //   result = await harness.settings.setVoiceRunning(true)
            //   assert .failure(.audioGraphFailed(reason: contains "ringBuffer"))
            fatalError("not implemented — IMPL: B-04 typed-error coverage")
        }
    )
}
