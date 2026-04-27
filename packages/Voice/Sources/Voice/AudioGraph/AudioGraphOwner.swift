import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "AudioGraphOwner")

/// Actor that owns the live `AudioGraph` and manages its full lifecycle.
///
/// Responsibilities:
/// - Build and start the graph via `open()`.
/// - Run the canonical six-step teardown + rebuild on four triggers (VOICE-10).
/// - Surface degradation events (VOICE-09) and rebuild events to consumers.
/// - Manage three background watchers: device-change, mic-re-grant, ring-overflow.
///
/// ## VOICE-09: AEC-off as distinct variant
/// If `setVoiceProcessingEnabled(true)` throws on the initial build, the owner
/// emits `.aecUnavailable` on `degradationStream` THEN rebuilds with `aec: false`.
/// If that also fails, `open()` throws `.bothVariantsFailed`.
///
/// ## VOICE-10: Six-step teardown (DRY)
/// All four rebuild triggers call the single `teardown()` private method:
///   1. `await cancelInFlight?()`        — cancel in-flight callbacks
///   2. `graph?.stop()`                  — stop the engine
///   3. `graph?.removeAllTaps()`         — remove all taps
///   4. `graph?.releaseRings()`          — release ring buffer
///   5. `await releaseORTSessions?()`    — release ORT sessions (no-op stub until 06-02)
///   6. `rebuildCont.yield(.reconfiguring(reason: trigger))` — emit rebuild event
///
/// ## Slots reserved for downstream plans
/// `cancelInFlight` — Plan 06-02 (wake-word DAG cancellation)
/// `releaseORTSessions` — Plan 06-04 (TTS producer cancellation)
/// Both are `(@Sendable () async -> Void)?` initialised to `nil` here.
public actor AudioGraphOwner {

    // MARK: - Public API

    /// The graph variant currently active (nil if not yet opened or closed).
    public var currentVariant: AudioGraphVariant? { graph?.variant }

    /// The ring buffer from the current graph (nil if not yet opened or closed).
    public var ringBuffer: RingBuffer? { graph?.ringBuffer }

    // MARK: - Init

    /// Creates the owner with stream continuations and an optional graph builder.
    ///
    /// - Parameters:
    ///   - degradationContinuation: Yields `DegradationReason` events when the
    ///     graph falls back to a degraded mode.
    ///   - rebuildContinuation: Yields `RebuildEvent` on every teardown.
    ///   - graphBuilder: Injected for testing; defaults to `LiveGraphBuilder()`.
    public init(
        degradationContinuation: AsyncStream<DegradationReason>.Continuation,
        rebuildContinuation: AsyncStream<RebuildEvent>.Continuation,
        graphBuilder: any GraphBuilder = LiveGraphBuilder()
    ) {
        self.degradationCont = degradationContinuation
        self.rebuildCont = rebuildContinuation
        self.graphBuilder = graphBuilder
    }

    // MARK: - Lifecycle

    /// Builds and starts the audio graph.
    ///
    /// Attempts `aec: true` first.  If VPIO fails, emits `.aecUnavailable` and
    /// retries with `aec: false`.  If both fail, throws `.bothVariantsFailed`.
    ///
    /// After a successful build, starts the three background watchers.
    public func open() async throws {
        let graph = try await buildGraph(preferAec: true)
        self.graph = graph
        startWatchers()
        logger.info("AudioGraphOwner: opened with variant \(String(describing: graph.variant))")
    }

    /// Tears down the current graph and rebuilds it.
    ///
    /// All four `RebuildTrigger` cases flow through this single method.
    ///
    /// - Parameter trigger: What caused the rebuild.
    public func rebuild(trigger: RebuildTrigger) async {
        let wantAec: Bool
        if let current = graph?.variant {
            switch current {
            case .aecOn: wantAec = true
            case .aecOff: wantAec = false
            }
        } else {
            wantAec = true
        }

        await teardown(trigger: trigger)
        graph = nil

        do {
            // If the trigger is aecFallback, we know aec=true just failed —
            // rebuild directly with aec=false to avoid emitting a duplicate
            // aecUnavailable event.
            let useAec = trigger == .aecFallback ? false : wantAec
            graph = try await buildGraph(preferAec: useAec)
            logger.info("AudioGraphOwner: rebuild(\(String(describing: trigger))) succeeded with \(String(describing: self.graph?.variant))")
        } catch {
            logger.error("AudioGraphOwner: rebuild(\(String(describing: trigger))) failed: \(error)")
        }
    }

    /// Cancels all watchers and stops the engine cleanly.
    public func shutdown() async {
        cancelWatchers()
        await teardown(trigger: .deviceChange)   // trigger value unused on shutdown
        graph = nil
        degradationCont.finish()
        rebuildCont.finish()
    }

    // MARK: - Slots for downstream plans

    /// Cancels in-flight processing tasks before teardown (step 1).
    /// Populated by Plan 06-02 (wake-word + VAD DAG cancellation).
    /// `(@Sendable () async -> Void)?` — must be `nil`-safe.
    public var cancelInFlight: (@Sendable () async -> Void)?

    /// Releases ORT inference sessions before teardown (step 5).
    /// Populated by Plan 06-04 (TTS ORT session release).
    /// `(@Sendable () async -> Void)?` — must be `nil`-safe.
    public var releaseORTSessions: (@Sendable () async -> Void)?

    // MARK: - Internal test seam: override auth status probe

    /// Test seam for mic-re-grant watcher.  In tests, inject a closure that
    /// simulates `AVCaptureDevice.authorizationStatus(for: .audio)` transitions.
    internal var authStatusProbe: (@Sendable () -> Bool)?   // returns true if authorized

    // MARK: - Private state

    private var graph: AudioGraph?
    private let degradationCont: AsyncStream<DegradationReason>.Continuation
    private let rebuildCont: AsyncStream<RebuildEvent>.Continuation
    private let graphBuilder: any GraphBuilder

    private var deviceChangeWatcher: Task<Void, Never>?
    private var micRegrantWatcher: Task<Void, Never>?
    private var overflowWatcher: Task<Void, Never>?
    private var inTeardown: Bool = false
    private var lastMicStatus: Bool = false   // last known "authorized" state

    // MARK: - Graph build helper

    private func buildGraph(preferAec: Bool) async throws -> AudioGraph {
        do {
            return try AudioGraph(aec: preferAec, builder: graphBuilder)
        } catch AudioGraphError.aecUnavailable {
            if preferAec {
                // AEC-on failed — emit degradation BEFORE retry.
                // T-06-01-06: AEC-off must never be user-invisible.
                logger.warning("AudioGraphOwner: VPIO unavailable — degraded mode (aecOff)")
                degradationCont.yield(.aecUnavailable)
                // Retry with aec=false
                do {
                    return try AudioGraph(aec: false, builder: graphBuilder)
                } catch {
                    logger.error("AudioGraphOwner: aec=false fallback also failed: \(error)")
                    throw AudioGraphError.bothVariantsFailed
                }
            } else {
                throw AudioGraphError.bothVariantsFailed
            }
        }
    }

    // MARK: - Six-step teardown (VOICE-10)

    /// Canonical teardown sequence (VOICE-10).  DRY: all four RebuildTrigger
    /// cases call this single method.
    ///
    /// ```
    /// (1) await cancelInFlight?()
    /// (2) graph?.stop()
    /// (3) graph?.removeAllTaps()
    /// (4) graph?.releaseRings()
    /// (5) await releaseORTSessions?()
    /// (6) rebuildCont.yield(.reconfiguring(reason: trigger))
    /// ```
    private func teardown(trigger: RebuildTrigger) async {
        inTeardown = true
        defer { inTeardown = false }

        // Step 1 — cancel in-flight callbacks (wake-word DAG, TTS, etc.)
        await cancelInFlight?()

        // Step 2 — stop the engine
        graph?.stop()

        // Step 3 — remove all taps
        graph?.removeAllTaps()

        // Step 4 — release ring buffers
        graph?.releaseRings()

        // Step 5 — release ORT inference sessions (no-op stub until Plan 06-02/04)
        await releaseORTSessions?()

        // Step 6 — emit rebuild event to consumers (VOICE-10 / T-06-01-07)
        rebuildCont.yield(.reconfiguring(reason: trigger))
        logger.info("AudioGraphOwner: teardown complete (trigger=\(String(describing: trigger)))")
    }

    // MARK: - Background watchers

    private func startWatchers() {
        startDeviceChangeWatcher()
        startMicRegrantWatcher()
        startOverflowWatcher()
    }

    private func cancelWatchers() {
        deviceChangeWatcher?.cancel()
        micRegrantWatcher?.cancel()
        overflowWatcher?.cancel()
        deviceChangeWatcher = nil
        micRegrantWatcher = nil
        overflowWatcher = nil
    }

    /// Watches for `AVAudioEngineConfigurationChangeNotification`.
    /// Assumption A7 (06-RESEARCH): this is the canonical device-change signal
    /// on macOS 26 Tahoe.  The raw Obj-C string constant `AVAudioEngineConfigurationChangeNotification`
    /// is used because the Swift wrapper `AVAudioEngine.configurationChangeNotification`
    /// does not exist on macOS — use the `Notification.Name` from the raw string instead.
    private func startDeviceChangeWatcher() {
        deviceChangeWatcher = Task { [weak self] in
            let notificationName = Notification.Name("AVAudioEngineConfigurationChange")
            let stream = NotificationCenter.default.notifications(named: notificationName)
            for await _ in stream {
                guard let self else { return }
                guard await !self.inTeardown else { continue }
                logger.info("AudioGraphOwner: device change detected")
                await self.rebuild(trigger: .deviceChange)
            }
        }
    }

    /// Polls `AVCaptureDevice.authorizationStatus(for: .audio)` every 2 s.
    /// Fires `rebuild(trigger: .micRegrant)` on `.denied → .authorized` transition.
    /// Pitfall #5 (06-RESEARCH): KVO is unavailable on authorization status.
    private func startMicRegrantWatcher() {
        micRegrantWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let isAuthorized: Bool
                if let probe = await self.authStatusProbe {
                    isAuthorized = probe()
                } else {
                    isAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                }
                let wasAuthorized = await self.lastMicStatus
                await self.setLastMicStatus(isAuthorized)
                if !wasAuthorized && isAuthorized && !Task.isCancelled {
                    guard await !self.inTeardown else { continue }
                    logger.info("AudioGraphOwner: mic re-granted")
                    await self.rebuild(trigger: .micRegrant)
                }
            }
        }
    }

    /// Polls `ringBuffer.overflowDetected` every 250 ms.
    /// Fires `rebuild(trigger: .ringOverflow)` when overflow is sustained.
    /// Pitfall #4 (06-RESEARCH): do NOT silently drop overflow samples.
    private func startOverflowWatcher() {
        overflowWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard await !self.inTeardown else { continue }
                guard let ring = await self.graph?.ringBuffer else { continue }
                if ring.overflowDetected {
                    logger.warning("AudioGraphOwner: ring overflow detected")
                    await self.rebuild(trigger: .ringOverflow)
                    // After rebuild, the new ring starts fresh — watcher resets.
                }
            }
        }
    }

    /// Helper to update `lastMicStatus` from a non-isolated context.
    private func setLastMicStatus(_ value: Bool) {
        lastMicStatus = value
    }
}
