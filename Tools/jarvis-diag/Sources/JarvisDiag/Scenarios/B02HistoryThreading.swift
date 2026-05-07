// B02HistoryThreading.swift
//
// Reproduces and dissolves B-02: conversation continuity broken — "yes" / "why 4.5?"
// lose prior turn context. v0.2 §2.1 R-006 + UQ-2 disposition.
//
// Pre-fix scenario (B02-repro): submit T1, submit T2 with "yes"; assert MockLLM's
// 2nd-call `messages` does NOT contain T1's user/assistant text. Reproduces the
// AgentOrchestrator.swift:283-286 silent-bug.
//
// Post-fix scenario (B02-fix = X-004): same setup; assert 2nd-call `messages`
// DOES contain T1.
//
// Companion regression (B02-r006): two short turns followed by a third — assert
// no `turnError(.streamTruncated)` retries (pins Phase E 2026-05-03 audit gate
// behavior across the cache-eligibility flip).
//
// Modes: both. Scenario does not require real network or hardware.
// Scenario IDs: B02-repro, B02-fix, B02-r006, X-004.

import Foundation

public enum B02HistoryThreading {

    /// B02-repro — runs against pre-fix HEAD, MUST FAIL after migration.
    /// Expected to pass on `1b7fb81` (current HEAD); migration plan removes
    /// this scenario from the green-required list once tactical patch ships.
    public static let repro = Scenario(
        id: "B02-repro",
        title: "B-02 reproduction: 2nd turn LLM call missing T1 context",
        body: { harness in
            fatalError("not implemented — IMPL: B-02 reproduction (pre-fix gate)")
        }
    )

    /// B02-fix — must pass post-tactical-patch and stay green through M-4.
    public static let fix = Scenario(
        id: "B02-fix",
        title: "B-02 dissolution: orchestrator prepends recentTurnsForSession",
        body: { harness in
            // IMPL outline:
            //   1. submit T1 ("I'm James", .text); await turnEnded(t1, .completed)
            //   2. submit T2 ("what's my name", .text); await turnEnded(t2, .completed)
            //   3. snapshot = await harness.diagnostics.snapshotReplayEvents(turnId: t2)
            //   4. assert snapshot's LLM call messages contain T1.userText + T1.assistantText
            fatalError("not implemented — IMPL: B-02 fix (X-004)")
        }
    )

    /// B02-r006 — companion regression for cache-eligibility flip risk.
    public static let cacheRegression = Scenario(
        id: "B02-r006",
        title: "B-02 cache regression: short-turn run produces no streamTruncated retries",
        body: { harness in
            // IMPL outline:
            //   submit 2 short turns; submit a 3rd turn; assert no
            //   turnError(.streamTruncated) emitted on any of the three.
            fatalError("not implemented — IMPL: B-02 r006 (cache-eligibility)")
        }
    )
}
