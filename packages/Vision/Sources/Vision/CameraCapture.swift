import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import ImageIO
import Logging

/// Actor-owned AVCaptureSession with Camera TCC lifecycle.
///
/// Shape mirrors packages/Voice/Sources/Voice/AudioGraph/AudioGraphOwner.swift
/// (07-PATTERNS.md section 2.11): nonisolated degradationStream,
/// open()/shutdown() lifecycle (no auto-start in init), test seam
/// authStatusProbe, and watcher Task for mid-session revocation.
///
/// VISION-04 frame-attach: captureFrame() returns ONE still frame on
/// demand. There is intentionally no public API that exposes a continuous
/// video buffer to consumers outside the Vision package — only
/// frameStream(forPresence:) is published, and PresenceMonitor is the only
/// in-tree consumer of that stream.
public actor CameraCapture {

    public static let logChannel = "vision.capture"

    public nonisolated let degradationStream: AsyncStream<VisionDegradationReason>
    private let degradationCont: AsyncStream<VisionDegradationReason>.Continuation

    private let logger: Logger
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private var runtimeErrorObserver: NSObjectProtocol?
    /// Audit 2026-05-12 F-V3 — observer for `AVCaptureSessionWasInterrupted`.
    /// macOS surfaces mid-session Camera TCC revoke via the interruption
    /// notification, NOT `RuntimeError`. Without this observer the revoke
    /// arrives silently and the `cameraRevoked` HUD banner never fires.
    private var interruptionObserver: NSObjectProtocol?

    /// Test seam — defaults to AVCaptureDevice.authorizationStatus(for: .video).
    /// Tests inject a closure to simulate denied/notDetermined/authorized.
    /// Mirrors AudioGraphOwner.authStatusProbe.
    internal var authStatusProbe: (@Sendable () -> AVAuthorizationStatus)?

    /// Test seam — overrides the photo capture path entirely. When set,
    /// `captureFrame()` calls this closure instead of driving the real
    /// `AVCapturePhotoOutput.capturePhoto(...)` delegate flow. Production
    /// leaves it `nil` and goes through the real delegate path.
    /// Mirrors `authStatusProbe` shape.
    internal var photoCaptureOverride: (@Sendable () async throws -> CapturedFrame)?

    /// Track-C 2: video data output sample-buffer delegate. Constructed in
    /// `buildSession()` so the AVCaptureVideoDataOutput's sample handler can
    /// fan out to the multiple frameStream continuations.
    internal var videoSampleDelegate: VideoSampleDelegate?

    public init(
        degradationContinuation: AsyncStream<VisionDegradationReason>.Continuation,
        degradationStream: AsyncStream<VisionDegradationReason>
    ) {
        self.degradationStream = degradationStream
        self.degradationCont = degradationContinuation
        self.logger = Logger(label: Self.logChannel)
    }

    /// Convenience init for production: builds its own stream pair.
    public init() {
        let (stream, cont) = AsyncStream<VisionDegradationReason>.makeStream()
        self.degradationStream = stream
        self.degradationCont = cont
        self.logger = Logger(label: Self.logChannel)
    }

    /// Open the capture session. Throws on TCC denial or hardware absence.
    ///
    /// On .denied/.restricted: yields .cameraDenied on degradationStream
    /// AND throws — caller (AppDelegate.installVision in 07-06) catches
    /// and continues without vision; banner already shown by HUD.
    public func open() async throws {
        let status = (authStatusProbe ?? Self.liveAuthStatus)()
        switch status {
        case .authorized:
            try buildSession()
            try startWatchers()
            session?.startRunning()
            logger.info("CameraCapture opened (.authorized)")
        case .notDetermined:
            // Per RESEARCH section 10: do NOT prompt here. Caller invokes
            // AVCaptureDevice.requestAccess(for: .video) and re-calls open().
            throw VisionError.tccNotDetermined
        case .denied, .restricted:
            degradationCont.yield(.cameraDenied)
            throw VisionError.tccDenied
        @unknown default:
            throw VisionError.tccUnknown
        }
    }

    /// Called by AppDelegate (07-06) after AVCaptureDevice.requestAccess
    /// granted .authorized. D-09: presence-on-by-default after first grant.
    public func becameAuthorized() async throws {
        try await open()
    }

    public func shutdown() async {
        if let obs = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(obs)
            runtimeErrorObserver = nil
        }
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        session?.stopRunning()
        videoSampleDelegate?.finishAllStreams()
        videoSampleDelegate = nil
        videoOutput = nil
        photoOutput = nil
        session = nil
        degradationCont.finish()
    }

    /// Single-frame-on-demand capture (VISION-04). Throws if open() was
    /// never called, was denied, or shutdown() ran. Routes through the
    /// `AVCapturePhotoOutput` delegate flow: invokes `capturePhoto(...)`
    /// with a fresh `PhotoCaptureProxy` whose continuation resolves on
    /// `photoOutput(_:didFinishProcessingPhoto:error:)`.
    ///
    /// Test seam: when `photoCaptureOverride` is set, the override is
    /// invoked instead of the real delegate path. Tests use this to assert
    /// that `captureFrame()` reaches the production code path without
    /// requiring a real camera.
    public func captureFrame() async throws -> CapturedFrame {
        guard let session, session.isRunning else {
            throw VisionError.sessionNotRunning
        }
        if let override = photoCaptureOverride {
            return try await override()
        }
        guard let photoOutput else {
            throw VisionError.sessionNotRunning
        }
        let settings = AVCapturePhotoSettings(
            format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
        )
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedFrame, Error>) in
            // PhotoCaptureProxy retains itself in init (AVCapturePhotoOutput
            // holds the delegate weakly); the cycle is broken on the first
            // didFinishProcessingPhoto callback.
            let proxy = PhotoCaptureProxy(continuation: cont)
            photoOutput.capturePhoto(with: settings, delegate: proxy)
        }
    }

    /// Publishes a CMSampleBuffer-derived frame stream. Each call returns
    /// a fresh AsyncStream backed by the live AVCaptureVideoDataOutput
    /// delegate (`VideoSampleDelegate`); cancellation removes the
    /// continuation from the fan-out set; `shutdown()` finishes all
    /// outstanding streams.
    ///
    /// PresenceMonitor is the only in-tree consumer today. If the session
    /// has not yet been built (open() not called), the stream is finished
    /// immediately so consumers' `for await` exits rather than hanging.
    public nonisolated func frameStream(forPresence: Bool) -> AsyncStream<PresenceFrameSample> {
        let token = UUID()
        return AsyncStream<PresenceFrameSample> { cont in
            cont.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.detachFrameContinuation(token: token)
                }
            }
            // Hop into the actor to register against the live delegate.
            Task { [weak self] in
                guard let self else {
                    cont.finish()
                    return
                }
                await self.attachFrameContinuation(cont, token: token)
            }
        }
    }

    /// Attach an in-flight continuation to the live video sample delegate.
    /// If the delegate isn't built yet (open() not called), finish the
    /// continuation immediately so consumers don't hang.
    private func attachFrameContinuation(
        _ cont: AsyncStream<PresenceFrameSample>.Continuation,
        token: UUID
    ) async {
        if let delegate = videoSampleDelegate {
            delegate.add(token: token, continuation: cont)
        } else {
            cont.finish()
        }
    }

    private func detachFrameContinuation(token: UUID) async {
        videoSampleDelegate?.remove(token: token)
    }

    // MARK: - Internals

    private func buildSession() throws {
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .hd1280x720    // RESEARCH section 9: 720p
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw VisionError.noCameraDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw VisionError.noCameraDevice }
        s.addInput(input)

        let videoOut = AVCaptureVideoDataOutput()
        let delegate = VideoSampleDelegate(label: Self.logChannel)
        let queue = DispatchQueue(label: "jarvis.vision.video-sample-queue", qos: .userInitiated)
        videoOut.setSampleBufferDelegate(delegate, queue: queue)
        videoOut.alwaysDiscardsLateVideoFrames = true
        if s.canAddOutput(videoOut) { s.addOutput(videoOut) }
        self.videoOutput = videoOut
        self.videoSampleDelegate = delegate

        let photoOut = AVCapturePhotoOutput()
        if s.canAddOutput(photoOut) { s.addOutput(photoOut) }
        self.photoOutput = photoOut

        s.commitConfiguration()
        self.session = s
    }

    private func startWatchers() throws {
        // Mid-session revocation (RESEARCH section 10).
        // The notification block runs on an arbitrary queue; capture only
        // Sendable values (Continuation is Sendable; we pre-format the
        // log line into a String to avoid capturing the Logger reference
        // across the @Sendable closure boundary).
        let cont = degradationCont
        let label = Self.logChannel
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { note in
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?
                .localizedDescription ?? "unknown"
            // Defer logging to a fresh Logger to keep the closure Sendable.
            let localLogger = Logger(label: label)
            localLogger.warning("CameraCapture mid-session error: \(err)")
            cont.yield(.midSessionRevoked)
        }
        // Audit 2026-05-12 F-V3 — observe `AVCaptureSessionWasInterrupted`.
        // macOS surfaces TCC revoke + device-stolen-by-other-client events
        // through the interruption notification, NOT through RuntimeError.
        //
        // Important macOS quirk: `AVCaptureSessionInterruptionReasonKey` and
        // the `AVCaptureSession.InterruptionReason` enum are
        // **API_UNAVAILABLE(macos)** (iOS / macCatalyst / tvOS / visionOS
        // only — see AVCaptureSession.h, macOS SDK 26). So we cannot
        // discriminate by reason here. Any interruption on macOS means the
        // session can't continue capturing — we surface the revoked banner
        // unconditionally. The most common causes are user-revoke via System
        // Settings and device-in-use-by-another-process; both warrant the
        // banner.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { _ in
            let localLogger = Logger(label: label)
            localLogger.warning("CameraCapture mid-session interrupted")
            cont.yield(.midSessionRevoked)
        }
    }

    /// Audit 2026-05-12 F-V3 — test seam for the mid-session interruption
    /// path. Posts an `AVCaptureSession.wasInterruptedNotification` against
    /// the live session; the registered observer yields `.midSessionRevoked`.
    /// Routes through the SAME code path as a real OS-fired notification,
    /// so a passing test proves the production observer is wired correctly.
    /// Throws when `open()` hasn't built a session yet.
    internal func simulateInterruption() throws {
        guard let session else { throw VisionError.sessionNotRunning }
        NotificationCenter.default.post(
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
    }

    private static func liveAuthStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }
}

/// Sample buffer wrapper produced by frameStream(forPresence:). Vision
/// framework's VNImageRequestHandler wraps either a CGImage or a CMSampleBuffer;
/// this enum keeps the producer/consumer decoupled.
///
/// `@unchecked Sendable` because CMSampleBuffer + CGImage are reference types
/// from C frameworks; in this codebase they are produced and consumed once
/// (single-producer single-consumer queue), so we override the Sendable
/// requirement at the type boundary.
public enum PresenceFrameSample: @unchecked Sendable {
    case sampleBuffer(CMSampleBuffer)
    case cgImage(CGImage, timestamp: Date)

    /// For unit tests: synthetic "face was detected / not detected" sample.
    case syntheticDetection(faceDetected: Bool, timestamp: Date)
}

// MARK: - PhotoCaptureProxy (C-1)

/// Concrete `AVCapturePhotoCaptureDelegate` that bridges the one-shot photo
/// capture into a Swift continuation. AVCapturePhotoOutput holds the delegate
/// only weakly, so the proxy retains itself for the lifetime of the capture
/// via `selfRetain`. The retain cycle is broken on the FIRST delegate callback
/// by setting `selfRetain = nil`.
final class PhotoCaptureProxy: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<CapturedFrame, Error>?
    private var selfRetain: PhotoCaptureProxy?

    init(continuation: CheckedContinuation<CapturedFrame, Error>) {
        self.continuation = continuation
        super.init()
        self.selfRetain = self
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { selfRetain = nil }
        guard let cont = continuation else { return }
        continuation = nil
        if let error {
            cont.resume(throwing: VisionError.visionRequestFailed(underlying: error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            cont.resume(throwing: VisionError.sessionNotRunning)
            return
        }
        // Read width/height from the photo's resolved settings; fall back
        // to decoded JPEG dimensions if the resolution isn't reported.
        var width = photo.resolvedSettings.photoDimensions.width
        var height = photo.resolvedSettings.photoDimensions.height
        if width == 0 || height == 0,
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int { width = Int32(w) }
            if let h = props[kCGImagePropertyPixelHeight] as? Int { height = Int32(h) }
        }
        cont.resume(returning: CapturedFrame(
            jpegData: data,
            width: Int(width),
            height: Int(height),
            capturedAt: Date()
        ))
    }
}

// MARK: - VideoSampleDelegate (C-2)

/// Concrete `AVCaptureVideoDataOutputSampleBufferDelegate` that fans incoming
/// CMSampleBuffers to a set of registered AsyncStream continuations. The
/// AVFoundation sample-buffer queue is a serial DispatchQueue, so the lock
/// guards subscriber-set mutations from concurrent
/// `attach`/`detach`/`finishAllStreams` calls dispatched from the actor.
/// Each subscription is keyed by a UUID generated at frameStream() call time
/// and stored both on the consumer's onTermination closure and inside this
/// delegate.
final class VideoSampleDelegate: NSObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PresenceFrameSample>.Continuation] = [:]
    private let logger: Logger

    init(label: String) {
        self.logger = Logger(label: label)
        super.init()
    }

    func add(token: UUID, continuation: AsyncStream<PresenceFrameSample>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        continuations[token] = continuation
    }

    func remove(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations.removeValue(forKey: token)
    }

    func finishAllStreams() {
        lock.lock()
        let snapshot = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for cont in snapshot {
            cont.finish()
        }
    }

    /// AVFoundation entry point. Runs on the serial sample-buffer DispatchQueue.
    /// Routes each frame to every registered continuation via a snapshot copy
    /// taken under the lock.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        if snapshot.isEmpty { return }
        let sample = PresenceFrameSample.sampleBuffer(sampleBuffer)
        for cont in snapshot {
            cont.yield(sample)
        }
    }

    /// Test seam: synthesise a sample on the same fan-out path used by the
    /// real AVCapture callback. Used by the C-2 unit tests to assert
    /// continuation routing without a real `AVCaptureSession`.
    func injectForTesting(_ sample: PresenceFrameSample) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for cont in snapshot {
            cont.yield(sample)
        }
    }

    /// Test seam: subscriber count for assertions.
    func subscriberCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }
}
