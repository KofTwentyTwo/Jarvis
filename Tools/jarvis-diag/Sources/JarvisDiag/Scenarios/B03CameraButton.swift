// B03CameraButton.swift
//
// Reproduces and dissolves B-03: HUD camera button click does nothing — webview
// emits frameAttachRequested but it never lands at AppDelegate.swift:2045.
//
// This is the canonical proof-of-need for UQ-5 (transport equivalence): the
// scenario only reproduces in `.jsonRoundTripWebView` mode. In `.inProcessActor`
// mode it passes today.
//
// Pre-fix (B03-repro): json transport; click button; assert no framePending
// arrives within 200ms.
//
// Post-fix (B03-fix = Vis-001 with json mode forced): json transport; click
// button; assert FrameAttachArmed returned within 100ms; framePending(captureId)
// emitted; orchestrator's last LLM call has imageCount > 0.
//
// Modes: jsonOnly (essential — actor mode passes today; B-03 is JSON-transport-specific).
// Scenario IDs: B03-repro, B03-fix, Vis-001 (json variant).

import Foundation

public enum B03CameraButton {

    /// B03-repro — only meaningful pre-fix.
    public static let repro = Scenario(
        id: "B03-repro",
        title: "B-03 reproduction: HUD camera click is silently dropped on JSON transport",
        mode: .jsonOnly(reason: "B-03 only reproduces over WebView round-trip"),
        body: { harness in
            // IMPL outline:
            //   send `frameAttachRequested` JSON inbound; await framePending
            //   timeout 200ms; assert TIMEOUT (current bug = no event arrives)
            fatalError("not implemented — IMPL: B-03 reproduction (json transport only)")
        }
    )

    /// B03-fix — passes only after M-5 lands the typed Vision surface.
    public static let fix = Scenario(
        id: "B03-fix",
        title: "B-03 dissolution: requestFrameAttach returns FrameAttachArmed across both transports",
        mode: .both,        // post-fix, both transports must agree
        body: { harness in
            // IMPL outline:
            //   result = await harness.vision.requestFrameAttach(reason: .hudButton)
            //   guard case .success(let armed) = result else { fail }
            //   await harness.awaitEvent(matching: { (e: VisionEvent) -> Bool in
            //     if case .framePending(let id) = e { return id == armed.captureId }
            //     return false
            //   }, timeout: .milliseconds(200))
            fatalError("not implemented — IMPL: B-03 fix (Vis-001)")
        }
    )
}
