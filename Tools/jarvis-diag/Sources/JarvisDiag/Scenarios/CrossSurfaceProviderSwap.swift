// CrossSurfaceProviderSwap.swift
//
// X-006: Settings → Voice → Turn correlation across a mid-session provider swap.
// Tests that runtime provider changes propagate cleanly without re-boot, and
// that selfStateChanged fires twice (once per provider).
//
// Modes: both. Scenario IDs: X-006.

import Foundation

public enum CrossSurfaceProviderSwap {

    public static let scenario = Scenario(
        id: "X-006",
        title: "X-006: setProvider mid-session — turnStarted.provider reflects new value",
        body: { harness in
            // IMPL outline:
            //   1. boot with provider == .anthropic
            //   2. observe selfStateChanged emit #1 — provider == .anthropic
            //   3. await harness.turn.submitTurn(text: "hi", source: .text); record t1
            //      assert turnStarted(t1).provider == "anthropic"
            //      await turnEnded(t1, .completed)
            //   4. await harness.settings.setProvider(.ollama)
            //      assert settingsChanged(["provider"])
            //      observe selfStateChanged emit #2 — provider == .ollama
            //   5. submitTurn(text: "hi again", source: .text) → t2
            //      assert turnStarted(t2).provider == "ollama"
            fatalError("not implemented — IMPL: X-006 provider swap mid-session")
        }
    )
}
