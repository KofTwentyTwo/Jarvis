// CrossSurfaceMultiTool.swift
//
// X-005: Turn × Memory × confirmation × Voice cancelTTS, then bargeIn.
//
// The hairiest correlation scenario — proves that a single turn with parallel
// confirmations, fact mutation, and TTS handles bargeIn cleanly.
//
// Modes: both. Scenario IDs: X-005.

import Foundation

public enum CrossSurfaceMultiTool {

    public static let scenario = Scenario(
        id: "X-005",
        title: "X-005: voice turn → forget_fact + get_time → TTS → barge-in cancels TTS",
        body: { harness in
            // IMPL outline:
            //   1. seed fact F1; setConfirmationDefault(.deny) initially, override per-call
            //   2. injectWakeWord; injectSTT("forget my coffee preference and tell me the time", final)
            //   3. await confirmationRequested(c1, "forget_fact")
            //   4. await harness.turn.respondToConfirmation(c1, .approved)
            //   5. await confirmationResolved(c1, .approved); toolCallEnded(forget_fact, ok: true);
            //      factMutated(turnId: t1, op: .update, validTo set)
            //   6. await toolCallStarted/Ended(get_time, ok: true)
            //   7. await turnEnded(t1, .completed); ttsStarted(t1)
            //   8. await harness.turn.bargeIn(text: "stop", source: .voice) → t2
            //   9. assert ordering: ttsEnded(t1, .cancelled) BEFORE turnStarted(t2)
            //  10. assert no events for t1 emitted post-cancel
            fatalError("not implemented — IMPL: X-005 multi-tool cross-surface scenario")
        }
    )
}
