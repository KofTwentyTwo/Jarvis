import AVFoundation
import OSLog

// MARK: - GraphBuilder protocol (test seam)

/// The four wiring operations performed on an `AVAudioEngine` when building
/// the audio graph.  Production code uses `LiveGraphBuilder`; tests inject
/// `RecordingGraphBuilder` or stub builders to assert call ordering and
/// simulate hardware failures.
///
/// Having a protocol here is the ONLY mechanism that lets us test VPIO
/// ordering without a live audio device — `flipVPIO` is the load-bearing
/// operation: it MUST be the first call (before any attach/connect/installTap).
/// Pitfall #7: flipping VPIO after connect is a silent no-op on Tahoe and a
/// crash on Sonoma.
public protocol GraphBuilder: Sendable {
    /// Call `AVAudioInputNode.setVoiceProcessingEnabled(true)`.
    func flipVPIO(_ inputNode: AVAudioInputNode) throws
    /// Call `AVAudioEngine.attach(_:)`.
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode)
    /// Call `AVAudioEngine.connect(_:to:format:)`.
    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?)
    /// Call `AVAudioNode.installTap(onBus:bufferSize:format:block:)`.
    func installTap(
        on node: AVAudioNode,
        bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    )
    /// Call `AVAudioEngine.start()`.
    /// Default implementation calls through to the live engine.
    func startEngine(_ engine: AVAudioEngine) throws
    /// Probe the post-VPIO input format.
    /// Default calls `InputFormatProbe.probe(inputNode:)` — tests may override.
    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat
}

public extension GraphBuilder {
    func startEngine(_ engine: AVAudioEngine) throws {
        try engine.start()
    }

    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat {
        InputFormatProbe.probe(inputNode: inputNode)
    }
}

// MARK: - Live implementation

/// Default production builder that calls through to AVFoundation directly.
/// Separated from `AudioGraph` so `AudioGraph.init` never needs to know
/// whether it's running in tests or production.
public struct LiveGraphBuilder: GraphBuilder {
    public init() {}

    public func flipVPIO(_ inputNode: AVAudioInputNode) throws {
        // LOAD-BEARING: must be called before any connect/installTap.
        // Pitfall #7 (06-RESEARCH): flipping after connect is silent no-op on
        // Tahoe and a crash on Sonoma.
        try inputNode.setVoiceProcessingEnabled(true)
    }

    public func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {
        engine.attach(node)
    }

    public func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {
        engine.connect(src, to: dst, format: format)
    }

    public func installTap(
        on node: AVAudioNode,
        bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        node.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
    }
}

// MARK: - AudioGraph

private let logger = Logger(subsystem: "com.koftwentytwo.jarvis", category: "AudioGraph")

/// Concrete wrapper around an `AVAudioEngine` with a VPIO-enabled input tap.
///
/// Construction order (VOICE-08 / Pitfall #7 — DO NOT REORDER):
///   1. `if aec { try builder.flipVPIO(engine.inputNode) }` — MUST be first.
///   2. Probe `inputNode.outputFormat(forBus: 0)` to discover post-AEC format.
///   3. `attach(mixer)` + `connect(inputNode → mixer, format: probedFormat)`.
///      Channel coerce (mixer) happens HERE, before rate convert (step 5).
///      R4-D4 / Pitfall #3: rate-convert AFTER channel-coerce, never before.
///   4. Compute target format: 16 kHz Float32 mono — the single source of
///      truth for all downstream consumers (VOICE-01/02 contracts).
///   5. `mixer.installTap(format: targetFmt) { ringBuffer.write($0) }` —
///      AVAudioEngine inserts an internal rate converter when tap format ≠
///      connection format, so the tap callback always receives 16 kHz mono.
///   6. `engine.start()`.
///
/// `AudioGraph` is a value-like object (not an actor) — it is owned and
/// driven exclusively by `AudioGraphOwner` which is an actor.
public final class AudioGraph: Sendable {

    // MARK: - Public surface

    public let variant: AudioGraphVariant

    /// The audio-graph tap publishes every captured buffer to this
    /// broadcaster (Track B-7, 2026-05-03 voice audit fix). New consumers
    /// MUST subscribe via `AudioGraphOwner.subscribe()` to get their own
    /// per-subscriber ring — this is the multi-consumer fan-out fix.
    public let broadcaster: BufferBroadcaster

    /// Legacy single-consumer ring buffer.
    ///
    /// Kept as a back-compat surface for `WakeWordDAG.start(ring:)` and the
    /// overflow watcher. It is now backed by a dedicated broadcaster
    /// subscription rather than fed directly from the tap, so it no longer
    /// races with other consumers that subscribe through `broadcaster`.
    /// New code should call `AudioGraphOwner.subscribe()` instead.
    public let ringBuffer: RingBuffer

    /// Retains the primary subscription so its ring is not unsubscribed
    /// while the graph is alive. Held privately — callers see only
    /// `ringBuffer` for back-compat.
    private let primarySubscription: BufferBroadcaster.Subscription

    /// Probed input format — what AVAudioEngine reported BEFORE the
    /// 16 kHz mono target. Plan 10-01 / SELF-02: exposed via
    /// `AudioGraphOwner.activeRouteSnapshot()` so `get_active_audio_route`
    /// can answer "what mic is the graph bound to?" with the actual
    /// hardware-side sample rate, not the downstream contract value.
    public let probedFormat: AVAudioFormat

    // MARK: - Private AVFoundation objects

    // `nonisolated(unsafe)` because they are created once in `init` and then
    // only accessed from `AudioGraphOwner` (which serialises access via actor).
    nonisolated(unsafe) private let engine: AVAudioEngine
    nonisolated(unsafe) private let mixer: AVAudioMixerNode

    // MARK: - Init

    /// Builds the audio graph.
    ///
    /// - Parameters:
    ///   - aec: If `true`, calls `setVoiceProcessingEnabled(true)` before
    ///     wiring.  If `false`, skips VPIO — the graph is the AEC-off fallback
    ///     variant (VOICE-09).
    ///   - builder: Production code uses `LiveGraphBuilder()`; tests inject a
    ///     stub to record call ordering or simulate failures.
    ///   - ringCapacityFrames: Capacity of the SPSC ring buffer in 16 kHz
    ///     frames.  Default = 2 s worth (32 000 frames).
    public init(
        aec: Bool,
        builder: any GraphBuilder = LiveGraphBuilder(),
        ringCapacityFrames: Int = 32_000
    ) throws {
        let eng = AVAudioEngine()
        let mix = AVAudioMixerNode()

        // Track B-7 (2026-05-03 voice audit fix): the tap callback fans
        // captured buffers out via a `BufferBroadcaster`. Each consumer
        // (WakeWordDAG, AudioLevelEmitter, chunk pump) subscribes through
        // the owner to get its own per-subscriber RingBuffer.
        // The `primarySubscription` below is the legacy single-consumer
        // back-compat surface still used by WakeWordDAG.start(ring:)
        // and the overflow watcher.
        let broadcaster = BufferBroadcaster()
        let primarySub = broadcaster.subscribe(capacityFrames: ringCapacityFrames)
        let ring = primarySub.ring

        // ── Step 1 ─────────────────────────────────────────────────────────
        // VPIO MUST be enabled BEFORE any connect/installTap.
        // Pitfall #7: flipping after connect is a silent no-op on Tahoe and a
        // crash on Sonoma.  AudioGraphError.vpioNotEnabled is the guard surface
        // for callers that try to build without AEC but still attempt AEC taps.
        if aec {
            do {
                try builder.flipVPIO(eng.inputNode)
            } catch {
                throw AudioGraphError.aecUnavailable
            }
        }

        // ── Step 2 ─────────────────────────────────────────────────────────
        // Probe the post-VPIO format — never hardcode 16 kHz or 24 kHz.
        // Tahoe typically returns 24 kHz stereo; Sonoma 16 kHz mono.
        // R4-D4 / Assumption A7 (06-RESEARCH): always probe.
        // `builder.probeFormat` allows test injection without a global mutable seam.
        let probedFormat = builder.probeFormat(eng.inputNode)
        logger.info("AudioGraph: probed format sampleRate=\(probedFormat.sampleRate, format: .fixed(precision: 0)) channels=\(probedFormat.channelCount) aec=\(aec)")

        // ── Step 3 ─────────────────────────────────────────────────────────
        // Attach the mixer node, then connect input → mixer at probedFormat.
        // The MIXER node is the channel-coerce stage (stereo → mono).
        // R4-D4 / Pitfall #3: channel-coerce BEFORE rate-convert, never after.
        builder.attach(eng, mix)
        builder.connect(eng, eng.inputNode, to: mix, format: probedFormat)

        // ── Step 4 ─────────────────────────────────────────────────────────
        // Target format: 16 kHz Float32 mono.
        // This is the SINGLE source of truth for all downstream consumers
        // (VOICE-01/02 contracts: wake-word + Silero VAD both expect 16k mono).
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,     // sampleRate: 16_000 (anchor for downstream contract)
            channels: 1,
            interleaved: false
        ) else {
            throw AudioGraphError.formatProbeFailed
        }

        // ── Step 5 ─────────────────────────────────────────────────────────
        // Install the tap at `targetFormat`.  AVAudioEngine inserts an internal
        // sample-rate converter when tap format ≠ connection format (which it
        // does whenever probedFormat.sampleRate != 16_000).
        // Rate convert happens IMPLICITLY here — AFTER channel coerce (step 3).
        // Pitfall #3 / R4-D4 is satisfied: mixer (channel) → tap (rate).
        builder.installTap(
            on: mix,
            bus: 0,
            bufferSize: 1024,
            format: targetFormat
        ) { [broadcaster] buffer, _ in
            // Core Audio tap thread — must be lock-free.
            // The broadcaster snapshots its subscribers under
            // `OSAllocatedUnfairLock` (uncontested in steady state) and
            // calls `RingBuffer.write` on each — both lock-free per
            // subscriber. Track B-7 fan-out for multi-consumer audio.
            broadcaster.publish(buffer)
        }

        // ── Step 6 ─────────────────────────────────────────────────────────
        // Start the engine. This may throw if the hardware is unavailable
        // (e.g. device unplugged between probe and start).
        // The `builder.startEngine` indirection allows test injection.
        do {
            try builder.startEngine(eng)
        } catch {
            throw AudioGraphError.engineStartFailed
        }

        self.engine = eng
        self.mixer = mix
        self.broadcaster = broadcaster
        self.primarySubscription = primarySub
        self.ringBuffer = ring
        self.probedFormat = probedFormat
        self.variant = aec
            ? .aecOn(targetFormat)
            : .aecOff(targetFormat)
    }

    // MARK: - Lifecycle helpers (called by AudioGraphOwner teardown)

    /// Stops the engine.  Step 2 of the six-step teardown sequence.
    func stop() {
        engine.stop()
    }

    /// Removes all taps on the mixer node.  Step 3 of teardown.
    /// Guards against the case where the mixer was never attached to an engine
    /// (e.g. in test builders that no-op the `attach` step — mixer.engine is nil).
    func removeAllTaps() {
        guard mixer.engine != nil else { return }
        mixer.removeTap(onBus: 0)
    }

    /// Releases the ring buffer by draining all frames.  Step 4 of teardown.
    /// The ring itself is retained by downstream consumers until they drop
    /// their reference; we just mark it as logically released here.
    func releaseRings() {
        // Ring is reference-typed (class); the owner drops its reference
        // when `graph` is set to nil in AudioGraphOwner.  This method is a
        // semantic hook for the teardown ordering test (VOICE-10).
        _ = ringBuffer
    }

    // MARK: - Test seams for teardown recording

    /// Optional hook called BEFORE `stop()` (step 2) in teardown.
    /// Populated by tests to record the stop event.  nil in production.
    nonisolated(unsafe) internal var _stopHook: (() -> Void)?

    /// Optional hook called AFTER `removeAllTaps()` (step 3) in teardown.
    /// Populated by tests to record the remove-taps event.  nil in production.
    nonisolated(unsafe) internal var _removeTapsHook: (() -> Void)?

    /// Optional hook called AFTER `releaseRings()` (step 4) in teardown.
    /// Populated by tests to record the release-rings event.  nil in production.
    nonisolated(unsafe) internal var _releaseRingsHook: (() -> Void)?
}
