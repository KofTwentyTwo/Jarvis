// CrossSurfaceVisionTurn.swift
//
// X-002: Vision → Turn → Diagnostics correlation. Vision frame attach → text
// turn submission → LLM call carries an image → devSnapshot reports imageCount > 0.
// Tightly coupled to F-007 (FrameCaptureID) and G-014 (image-bytes-don't-cross-API).
//
// Modes: both. Scenario IDs: X-002, Vis-001 (cross-surface variant).

import Foundation

public enum CrossSurfaceVisionTurn {

    public static let scenario = Scenario(
        id: "X-002",
        title: "X-002: requestFrameAttach → submitTurn → frameSent → imageCount > 0 in LLM call",
        body: { harness in
            // IMPL outline:
            //   1. injectTCC(.camera, true)
            //   2. armed = await harness.vision.requestFrameAttach(reason: .hudButton)
            //      assert .success(armed); record c1 = armed.captureId
            //   3. await framePending(captureId: c1)
            //   4. accepted = await harness.turn.submitTurn(text: "what is this", source: .text)
            //      record t1 = accepted.turnId
            //   5. await frameSent(turnId: t1, captureId: c1)
            //   6. await turnEnded(t1, .completed)
            //   7. snap = await harness.diagnostics.getDevSnapshot()
            //   8. assert lastLLMCall.imageCount > 0 (G-014: count, not bytes)
            fatalError("not implemented — IMPL: X-002 cross-surface vision turn")
        }
    )
}
