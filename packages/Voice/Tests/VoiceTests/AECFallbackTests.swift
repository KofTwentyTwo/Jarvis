import Testing
import AVFoundation
@testable import Voice

/// Tests for AEC-off fallback path (VOICE-09).
///
/// AEC-off is a DISTINCT graph variant, not a runtime toggle.
/// When `setVoiceProcessingEnabled(true)` throws, `AudioGraphOwner.open()`
/// must:
///   1. Emit exactly one `DegradationReason.aecUnavailable` on `degradationStream`.
///   2. Rebuild the graph with `aec: false`.
///   3. Expose `currentVariant == .aecOff(...)`.
///
/// When both variants fail, `open()` throws `AudioGraphError.bothVariantsFailed`
/// and no extra degradation events are emitted.
///
/// `.serialized` is required because these tests set `InputFormatProbe._probeOverride`
/// and must not run concurrently with other suites using the same global test seam.
@Suite("AECFallbackTests", .serialized)
struct AECFallbackTests {

    // MARK: A1 — VPIO failure triggers aecOff rebuild + degradation event

    @Test("A1: VPIO failure causes aecOff rebuild and emits exactly one aecUnavailable")
    func vpioFailureCausesAecOffRebuild() async throws {
        let collector = EventCollector<DegradationReason>()
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (_, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: FailingVPIOBuilder(fmt: fmt16k)
        )

        // Collect degradation events concurrently using an actor-isolated collector
        let collectTask = Task {
            for await event in degradationStream {
                await collector.append(event)
            }
        }

        try await owner.open()
        degradationCont.finish()
        await collectTask.value

        let events = await collector.all
        #expect(events.count == 1, "Expected exactly 1 degradation event, got: \(events)")
        #expect(events.first == .aecUnavailable)

        let variant = await owner.currentVariant
        if case .aecOff(_) = variant {
            // Expected
        } else {
            Issue.record("Expected .aecOff variant after VPIO failure, got: \(String(describing: variant))")
        }
    }

    // MARK: A2 — Both variants fail → throws bothVariantsFailed

    @Test("A2: both variants fail throws bothVariantsFailed with at most one degradation event")
    func bothVariantsFailThrows() async throws {
        let collector = EventCollector<DegradationReason>()
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (_, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: AlwaysFailingBuilder(fmt: fmt16k)
        )

        let collectTask = Task {
            for await event in degradationStream {
                await collector.append(event)
            }
        }

        do {
            try await owner.open()
            Issue.record("Expected bothVariantsFailed to be thrown")
        } catch let error as AudioGraphError {
            #expect(error == .bothVariantsFailed)
        }
        degradationCont.finish()
        await collectTask.value

        // The aecUnavailable event was still emitted (before the AEC-off attempt),
        // but no additional events should follow.
        let events = await collector.all
        #expect(events.count <= 1, "Expected at most 1 degradation event, got: \(events)")
    }

    // MARK: A3 — Successful aec=true build emits ZERO degradation events

    @Test("A3: successful aec=true build emits zero degradation events")
    func successfulBuildNoDegradation() async throws {
        let collector = EventCollector<DegradationReason>()
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (_, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000,
                          channels: 1,
                          interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        let collectTask = Task {
            for await event in degradationStream {
                await collector.append(event)
            }
        }

        try await owner.open()
        degradationCont.finish()
        await collectTask.value

        let events = await collector.all
        #expect(events.isEmpty, "Expected 0 degradation events for successful build, got: \(events)")

        let variant = await owner.currentVariant
        if case .aecOn(_) = variant {
            // Expected
        } else {
            Issue.record("Expected .aecOn variant for successful build, got: \(String(describing: variant))")
        }
    }
}

// MARK: - Test Support

/// Actor-isolated event collector used instead of capturing mutable arrays in
/// concurrent Tasks (which would be unsafe under Swift 6 strict concurrency).
actor EventCollector<T: Sendable> {
    private var events: [T] = []
    func append(_ event: T) { events.append(event) }
    var all: [T] { events }
}

/// Builder where `flipVPIO` always throws (simulating hardware refusal).
/// The AEC-off build (`aec: false`) succeeds because `flipVPIO` is skipped.
struct FailingVPIOBuilder: GraphBuilder {
    let fmt: AVAudioFormat
    func flipVPIO(_ inputNode: AVAudioInputNode) throws {
        throw MockVPIOError.refused
    }
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {}
    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {}
    func installTap(on node: AVAudioNode, bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                    format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {}
    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat { fmt }
}

/// Builder where `flipVPIO` throws (first attempt fails with aecUnavailable)
/// AND `startEngine` also throws (second aec=false attempt also fails).
/// This covers the `bothVariantsFailed` path.
struct AlwaysFailingBuilder: GraphBuilder {
    let fmt: AVAudioFormat
    func flipVPIO(_ inputNode: AVAudioInputNode) throws {
        throw MockVPIOError.refused  // causes aecUnavailable on first attempt
    }
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {}
    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {}
    func installTap(on node: AVAudioNode, bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                    format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {}
    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat { fmt }
    /// Throws on the aec=false retry — this makes `AudioGraphOwner` reach
    /// the `bothVariantsFailed` throw path.
    func startEngine(_ engine: AVAudioEngine) throws {
        throw MockVPIOError.engineFailed
    }
}

/// Builder where everything succeeds (no-op for all steps).
struct SucceedingBuilder: GraphBuilder {
    let fmt: AVAudioFormat
    func flipVPIO(_ inputNode: AVAudioInputNode) throws {}
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {}
    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {}
    func installTap(on node: AVAudioNode, bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                    format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {}
    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat { fmt }
}

enum MockVPIOError: Error { case refused, engineFailed }
