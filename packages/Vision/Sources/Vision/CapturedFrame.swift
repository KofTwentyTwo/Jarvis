import Foundation

/// A single still frame captured from the webcam (VISION-04 frame-attach
/// payload). Used by Plan 07-05 (frame-attach + multimodal routing); 07-04
/// only validates the type + that captureFrame() returns it.
///
/// jpegData is downscaled to max 1024 dim, JPEG quality 0.85 per
/// RESEARCH section 11 (Opus 4.7 image-token cost containment). For T1/T2
/// local routing the same frame is reused (no re-encode) — Plan 07-05
/// adds the routing layer that consumes this struct.
public struct CapturedFrame: Sendable, Equatable {
    public let jpegData: Data
    public let width: Int
    public let height: Int
    public let capturedAt: Date

    public init(jpegData: Data, width: Int, height: Int, capturedAt: Date) {
        self.jpegData = jpegData
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
    }
}
