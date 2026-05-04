import Foundation

/// Errors thrown by the Vision subsystem.
///
/// VISION-03 reminder: none of these errors flow to TTS — error handling
/// stays inside Vision and AppDelegate (which routes to HUDBannerCoordinator).
public enum VisionError: Error, Sendable {
    /// AVCaptureDevice.authorizationStatus returned .notDetermined.
    /// Caller must call AVCaptureDevice.requestAccess(for: .video) and
    /// then re-invoke CameraCapture.open().
    case tccNotDetermined
    /// Camera TCC denied or restricted. Surfaces graceful-denial banner.
    case tccDenied
    /// macOS returned @unknown default for the auth status (defensive).
    case tccUnknown
    /// AVCaptureDevice.default(for: .video) returned nil (no camera).
    case noCameraDevice
    /// Mid-session AVCaptureSessionRuntimeErrorNotification fired.
    case midSessionRuntimeError(String)
    /// VNImageRequestHandler.perform([request]) threw.
    case visionRequestFailed(underlying: any Error)
    /// captureFrame() invoked while session is not running (paused / shut down).
    case sessionNotRunning
    /// Plan 07-05 / Task 4: vllm-mlx sidecar /health probe didn't reach 200
    /// within the bounded warmup window. Caller falls back to T1 for the
    /// remainder of the process lifetime.
    case sidecarStartupTimeout
    /// Track-C 4: T2 (vllm-mlx local-quality) provider is not yet wired in
    /// AppDelegate. `MissingT2Provider.stream(...)` surfaces this error
    /// instead of silently re-running on T1. Production code paths must
    /// gate T2 escalation on `VisionRouter.evaluatePostResponse(...,
    /// t2Available: false)` so this error never reaches the orchestrator.
    case t2ProviderUnavailable
}
