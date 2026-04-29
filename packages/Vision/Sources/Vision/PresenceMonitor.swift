import Foundation
import Vision
import CoreImage
import CoreMedia
import CoreGraphics
import Logging

/// Actor consuming PresenceFrameSample from CameraCapture.frameStream and
/// publishing edge-debounced PresenceEvent to PresenceSignalBus.
///
/// Pattern: WakeWordDAG (packages/Voice/Sources/Voice/WakeWord/WakeWordDAG.swift) —
/// actor + nonisolated bus + Task.detached feed loop + paused/resume + cancel.
/// Adapted to Vision framework face detection.
///
/// D-11 thresholds:
///   - 2.0s debounce on edge transitions (.present <-> .absent)
///   - 5min secondary "absent long-term" threshold for context-state framing
public actor PresenceMonitor {

    public static let logChannel = "vision.presence"

    public nonisolated let bus: PresenceSignalBus

    private let frameStream: AsyncStream<PresenceFrameSample>
    private let busCont: AsyncStream<PresenceEvent>.Continuation
    private let logger: Logger

    /// Test seam: clock used for debounce + 5min thresholds. Defaults to Date.init.
    internal var clock: @Sendable () -> Date = { Date() }

    private var feedTask: Task<Void, Never>?
    private var paused: Bool = false
    private var lastObservation: (faceDetected: Bool, at: Date)?
    private var currentState: Presence = .unknown
    private var lastTransitionAt: Date = .distantPast
    private var longTermTimer: Task<Void, Never>?

    public static let debounceWindow: TimeInterval = 2.0
    public static let absentLongTermThreshold: TimeInterval = 5 * 60   // D-11

    /// Production initializer. Builds its own bus stream + continuation.
    public init(frameStream: AsyncStream<PresenceFrameSample>) {
        let (busStream, busCont) = AsyncStream<PresenceEvent>.makeStream()
        self.frameStream = frameStream
        self.bus = PresenceSignalBus(stream: busStream)
        self.busCont = busCont
        self.logger = Logger(label: Self.logChannel)
    }

    public func start() async {
        feedTask?.cancel()
        let stream = frameStream
        feedTask = Task.detached { [weak self] in
            for await sample in stream {
                if Task.isCancelled { break }
                guard let self else { return }
                await self.consume(sample)
            }
        }
    }

    public func pause() async {
        paused = true
        // Cancel pending long-term timer; will re-arm on resume if still absent.
        longTermTimer?.cancel()
        longTermTimer = nil
    }

    public func resume() async {
        paused = false
        // Re-arm long-term timer if we are currently in a confirmed absent state.
        if case .absent(let since) = currentState {
            armLongTermTimer(absentSince: since)
        }
    }

    public func cancel() async {
        feedTask?.cancel()
        feedTask = nil
        longTermTimer?.cancel()
        longTermTimer = nil
        busCont.finish()
    }

    // MARK: - Test seams (internal — exercised by PresenceMonitorDebounceTests)

    /// Synchronously feed a single observation and run the state machine
    /// once. Tests use this to drive the debounce window without a real
    /// Vision request. Honors the paused gate identically to consume().
    internal func feedObservation(faceDetected: Bool, at timestamp: Date) async {
        guard !paused else { return }
        await applyObservation(faceDetected: faceDetected, at: timestamp)
    }

    /// Drive the long-term threshold synchronously. Tests advance their
    /// fake clock past 5min and call this to fire the elevation event.
    internal func evaluateLongTerm(now: Date) async {
        guard !paused else { return }
        guard case .absent(let since) = currentState else { return }
        if now.timeIntervalSince(since) >= Self.absentLongTermThreshold {
            currentState = .absentLongTerm(since: since)
            busCont.yield(.transition(
                to: .absentLongTerm(since: since),
                at: now,
                debounced: Self.debounceWindow
            ))
        }
    }

    // MARK: - Internals

    private func consume(_ sample: PresenceFrameSample) async {
        guard !paused else { return }
        let now = clock()
        switch sample {
        case .syntheticDetection(let faceDetected, let ts):
            await applyObservation(faceDetected: faceDetected, at: ts)
        case .sampleBuffer(let buf):
            await runVision(on: buf, now: now)
        case .cgImage(let img, let ts):
            await runVision(onCG: img, now: ts)
        }
    }

    private func applyObservation(faceDetected: Bool, at timestamp: Date) async {
        // Edge-debounced state machine. We track the last observation and
        // its timestamp; only when an opposing observation has been stable
        // for >= debounceWindow do we publish a transition.
        let prev = lastObservation
        lastObservation = (faceDetected, timestamp)

        // Determine candidate state purely from the latest observation.
        let candidate: Presence = faceDetected ? .present : .absent(since: timestamp)

        // If state is unchanged structurally, nothing to do.
        if presenceMatches(currentState, candidate) {
            return
        }

        // Has the candidate state been sustained for >= debounceWindow?
        // We require a prior matching observation at least debounceWindow ago.
        guard let prev else { return }                       // no history yet
        guard prev.faceDetected == faceDetected else { return } // flipped — restart debounce
        let elapsed = timestamp.timeIntervalSince(prev.at)
        guard elapsed >= Self.debounceWindow else { return }  // not yet stable

        // Publish the transition.
        currentState = candidate
        lastTransitionAt = timestamp
        busCont.yield(.transition(
            to: candidate,
            at: timestamp,
            debounced: Self.debounceWindow
        ))
        logger.debug("Presence transition -> \(String(describing: candidate))")

        // Arm secondary 5-min absent threshold if absent.
        if case .absent(let since) = candidate {
            armLongTermTimer(absentSince: since)
        } else {
            longTermTimer?.cancel()
            longTermTimer = nil
        }
    }

    private func armLongTermTimer(absentSince: Date) {
        longTermTimer?.cancel()
        longTermTimer = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.absentLongTermThreshold * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let now = await self.clock()
            await self.evaluateLongTerm(now: now)
        }
    }

    private func runVision(on buffer: CMSampleBuffer, now: Date) async {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: buffer, options: [:])
        do {
            try handler.perform([request])
            let detected = !(request.results?.isEmpty ?? true)
            await applyObservation(faceDetected: detected, at: now)
        } catch {
            logger.warning("Vision request failed: \(String(describing: error))")
        }
    }

    private func runVision(onCG image: CGImage, now: Date) async {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            let detected = !(request.results?.isEmpty ?? true)
            await applyObservation(faceDetected: detected, at: now)
        } catch {
            logger.warning("Vision request failed: \(String(describing: error))")
        }
    }

    private func presenceMatches(_ a: Presence, _ b: Presence) -> Bool {
        switch (a, b) {
        case (.present, .present): return true
        case (.absent, .absent): return true
        case (.absentLongTerm, .absentLongTerm): return true
        case (.unknown, .unknown): return true
        default: return false
        }
    }
}
