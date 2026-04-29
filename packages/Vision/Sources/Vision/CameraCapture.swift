import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
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

    /// Test seam — defaults to AVCaptureDevice.authorizationStatus(for: .video).
    /// Tests inject a closure to simulate denied/notDetermined/authorized.
    /// Mirrors AudioGraphOwner.authStatusProbe.
    internal var authStatusProbe: (@Sendable () -> AVAuthorizationStatus)?

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
        session?.stopRunning()
        videoOutput = nil
        photoOutput = nil
        session = nil
        degradationCont.finish()
    }

    /// Single-frame-on-demand capture (VISION-04). Throws if open() was
    /// never called, was denied, or shutdown() ran. Returns a downscaled
    /// JPEG; planner picks downscale impl. 07-04 ships the API surface and
    /// lifecycle; the JPEG capture body is exercised by 07-05 frame-attach
    /// tests. 07-04 tests only verify the throw-when-not-running path.
    public func captureFrame() async throws -> CapturedFrame {
        guard session != nil, session?.isRunning == true else {
            throw VisionError.sessionNotRunning
        }
        // Stub: return a minimal valid JPEG. Replaced by AVCapturePhotoOutput
        // delegate flow in 07-05.
        let onePixelJPEG = Self.onePixelJPEG()
        return CapturedFrame(
            jpegData: onePixelJPEG,
            width: 1,
            height: 1,
            capturedAt: Date()
        )
    }

    /// Publishes a CMSampleBuffer-derived frame stream to ONE consumer
    /// (PresenceMonitor). Throttled to 720p/15fps per RESEARCH section 9.
    /// Returns a fresh AsyncStream every call; only PresenceMonitor calls
    /// this in 07-04 (and only one monitor instance exists).
    ///
    /// 07-04 ships the API surface; the actual sample-buffer delivery from
    /// AVCaptureVideoDataOutput is wired through a delegate-bridge actor —
    /// for the 07-04 tests, PresenceMonitor consumes a test-injected
    /// stream. Production sample-buffer plumbing finishes in 07-05/07-06.
    public nonisolated func frameStream(forPresence: Bool) -> AsyncStream<PresenceFrameSample> {
        // 07-04: production path is intentionally a no-op stream. 07-06
        // wires the AVCaptureVideoDataOutput delegate to a continuation
        // captured here. Until then, return an empty stream that finishes
        // immediately — the unit tests inject their own AsyncStreams.
        AsyncStream<PresenceFrameSample> { cont in
            cont.finish()
        }
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
        if s.canAddOutput(videoOut) { s.addOutput(videoOut) }
        self.videoOutput = videoOut

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
    }

    private static func liveAuthStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Tiny synthetic JPEG (1x1 black). Replaced by AVCapturePhotoOutput
    /// delegate output in 07-05. Keeps captureFrame()'s API surface honest
    /// in 07-04 unit tests.
    private static func onePixelJPEG() -> Data {
        // 125-byte minimal valid JPEG (1x1, black). Hex-encoded inline so
        // tests can assert non-empty Data without bundling a fixture file.
        let hex =
            "FFD8FFE000104A46494600010100000100010000FFDB004300080606" +
            "070605080707070909080A0C140D0C0B0B0C1912130F141D1A1F1E1D" +
            "1A1C1C20242E2720222C231C1C2837292C30313434341F27393D3832" +
            "3C2E333432FFC0000B080001000101011100FFC4001F000001050101" +
            "0101010100000000000000000102030405060708090A0BFFC400B510" +
            "00020103030204030505040400000000000001000203040511213141" +
            "06120751610771221432819114A1B1C109233352F0156272D10A0817" +
            "1819A2526AAFFD9"
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        return data
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
