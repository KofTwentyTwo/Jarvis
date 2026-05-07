// CrossSurfaceVoiceTurn.swift
//
// X-001: Voice → Turn → Memory → Diagnostics correlation.
//
// Voice turn produces a fact and HUD reflects state transitions. Asserts the
// canonical TurnID-correlation invariant: every event for the turn carries
// turnId t1 (or contributes via factMutated which carries t1); no orphans.
//
// Modes: both. Scenario IDs: X-001.

import Foundation

public enum CrossSurfaceVoiceTurn {

    public static let scenario = Scenario(
        id: "X-001",
        title: "X-001: voice turn → factMutated → hudStateChanged correlation by turnId",
        body: { harness in
            // IMPL outline:
            //   1. seed StubMemoryExtractor with "I like coffee" → ADD op
            //   2. injectWakeWord(0.9); injectSTT("I like coffee", final)
            //   3. capture turnStarted; record turnId t1; assert source == .voice
            //   4. await turnEnded(t1, .completed)
            //   5. assert factMutated event carried turnId t1, op == .add
            //   6. assert hudStateChanged sequence: idle → listening → thinking → speaking → idle
            //   7. assert no events emitted with a different turnId during this window
            fatalError("not implemented — IMPL: X-001 cross-surface voice turn")
        }
    )
}
