import Foundation

/// Vision-side analog of Voice.DegradationReason. Yielded on
/// CameraCapture.degradationStream whenever the capture pipeline degrades
/// in a way the user should be notified about (HUD banner via
/// HUDBannerCoordinator).
public enum VisionDegradationReason: Sendable, Equatable {
    /// Camera TCC denied or restricted on open().
    case cameraDenied
    /// AVCaptureSessionRuntimeErrorNotification fired mid-session
    /// (user revoked permission while running, or device became unavailable).
    case midSessionRevoked
}
