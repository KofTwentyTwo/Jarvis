// B05TTSSynthesize.swift
//
// Reproduces and dissolves B-05: TTS silent on assistant text. UQ-3 LOCKED
// (A) — explicit `Voice.synthesizeTurn(turnId:text:tier:) -> Result<Void, TTSError>`
// command issued by the orchestrator on `turnEnded(.completed)` for voice-source
// turns. Hidden subscription invariant (option B) was rejected.
//
// Pre-fix (B05-repro): voice turn completes; assert
// `Voice.synthesizeTurn` was NEVER issued (matches today's silent handoff).
//
// Post-fix (B05-fix = X-003): voice turn completes → orchestrator issues
// `synthesizeTurn(turnId: t1, ...)` within 500ms → ttsStarted(t1) emitted.
//
// Modes: both — the orchestrator-as-driver pattern is observable on either
// transport (Diagnostics.lastVoiceCommand exposes the command-issued record).
// Scenario IDs: B05-repro, B05-fix, X-003, V-005.

import Foundation

public enum B05TTSSynthesize {

    /// B05-repro — reproduces silent TTS handoff.
    public static let repro = Scenario(
        id: "B05-repro",
        title: "B-05 reproduction: voice turn completes but synthesizeTurn never issued",
        body: { harness in
            // IMPL outline:
            //   inject wake-word + STT("hello", final) → triggers voice turn
            //   await turnEnded(t1, .completed)
            //   assert Diagnostics.lastVoiceCommand for t1 == nil
            //   (current bug: command not issued; ttsStarted never fires)
            fatalError("not implemented — IMPL: B-05 reproduction (pre-fix gate)")
        }
    )

    /// B05-fix — passes after M-6 wires the explicit command path.
    public static let fix = Scenario(
        id: "B05-fix",
        title: "B-05 dissolution: voice-source turnEnded triggers synthesizeTurn within 500ms",
        body: { harness in
            // IMPL outline:
            //   ttsObs = harness.observeTTSAudio()
            //   inject wake-word; injectSTT("hello", final)
            //   t1 = await harness.awaitTurnEnded(/* match voice-source */)
            //   advanceClock(by: 500ms)
            //   record = await ttsObs.first(where: { $0.turnId == t1 })
            //   assert record != nil; ttsStarted/Ended emitted for t1
            fatalError("not implemented — IMPL: B-05 fix (X-003)")
        }
    )
}
