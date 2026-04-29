import Foundation

/// Plan 07-05 / D-14 — outcome of the always-confirm gate.
///
/// Default semantic: anything other than `.send` discards the captured frame.
/// `.timeout` is the implicit-cancel that fires when the user neither
/// confirms nor explicitly cancels within `VisionRouterConfig.frameConfirm
/// Timeout` (~2 seconds).
public enum FrameConfirmationDecision: Sendable, Equatable {
    case send
    case cancel
    case timeout
}
