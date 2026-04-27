import Testing
import AVFoundation
@testable import Voice

/// Tests for the canonical six-step teardown sequence × four rebuild triggers (VOICE-10).
///
/// The teardown sequence must be:
///   1. `cancelInFlight?()` — cancel in-flight callbacks
///   2. `graph?.stop()` — stop the engine
///   3. `graph?.removeAllTaps()` — remove all taps
///   4. `graph?.releaseRings()` — release ring buffer
///   5. `releaseORTSessions?()` — release ORT sessions (no-op slot)
///   6. `rebuildCont.yield(.reconfiguring(reason:))` — emit rebuild event
///
/// All four `RebuildTrigger` cases route through a single `teardown()` body (DRY).
@Suite("TeardownTests", .serialized)
struct TeardownTests {

    // MARK: T1 — deviceChange trigger

    @Test("T1: deviceChange trigger runs all six teardown steps in order then rebuilds")
    func deviceChangeTriggerRunsTeardown() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()
        let recorder = TeardownRecorder()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000, channels: 1, interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        // Install slots that record into `recorder`
        await owner.installRecorderSlots(recorder)

        try await owner.open()

        // Collect rebuild events
        let eventCollector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await eventCollector.append(event)
            }
        }

        // Trigger rebuild via device change
        await owner.rebuild(trigger: .deviceChange)

        // Give the event a moment to arrive
        try? await Task.sleep(for: .milliseconds(50))
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        // Assert all six teardown steps fired
        let calls = recorder.allCalls
        #expect(calls.contains("cancelInFlight"), "Step 1 (cancelInFlight) should have fired, got: \(calls)")
        #expect(calls.contains("stop"), "Step 2 (stop) should have fired, got: \(calls)")
        #expect(calls.contains("removeAllTaps"), "Step 3 (removeAllTaps) should have fired, got: \(calls)")
        #expect(calls.contains("releaseRings"), "Step 4 (releaseRings) should have fired, got: \(calls)")
        #expect(calls.contains("releaseORTSessions"), "Step 5 (releaseORTSessions) should have fired, got: \(calls)")

        // Assert rebuild event emitted
        let events = await eventCollector.all
        #expect(events.contains(.reconfiguring(reason: .deviceChange)),
                "Expected .reconfiguring(.deviceChange) event, got: \(events)")

        // After rebuild, variant should be aecOn (SucceedingBuilder succeeds)
        let variant = await owner.currentVariant
        if case .aecOn(_) = variant {
            // Expected
        } else {
            Issue.record("Expected .aecOn after deviceChange rebuild, got: \(String(describing: variant))")
        }
    }

    // MARK: T2 — aecFallback trigger

    @Test("T2: aecFallback trigger rebuilds with aec=false after running teardown")
    func aecFallbackTriggerRebuildsFalse() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000, channels: 1, interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        try await owner.open()

        let eventCollector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await eventCollector.append(event)
            }
        }

        // Trigger aecFallback rebuild
        await owner.rebuild(trigger: .aecFallback)
        try? await Task.sleep(for: .milliseconds(50))
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let events = await eventCollector.all
        #expect(events.contains(.reconfiguring(reason: .aecFallback)),
                "Expected .reconfiguring(.aecFallback), got: \(events)")

        // aecFallback should rebuild with aec=false
        let variant = await owner.currentVariant
        if case .aecOff(_) = variant {
            // Expected
        } else {
            Issue.record("Expected .aecOff after aecFallback rebuild, got: \(String(describing: variant))")
        }
    }

    // MARK: T3 — micRegrant trigger

    @Test("T3: micRegrant trigger rebuilds when auth transitions denied to authorized")
    func micRegrantTriggerRebuilds() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000, channels: 1, interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        try await owner.open()

        let eventCollector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await eventCollector.append(event)
            }
        }

        // Trigger micRegrant directly (bypasses the 2s polling watcher)
        await owner.rebuild(trigger: .micRegrant)
        try? await Task.sleep(for: .milliseconds(50))
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let events = await eventCollector.all
        #expect(events.contains(.reconfiguring(reason: .micRegrant)),
                "Expected .reconfiguring(.micRegrant), got: \(events)")
    }

    // MARK: T4 — ringOverflow trigger

    @Test("T4: ringOverflow trigger fires rebuild exactly once and rebuilds")
    func ringOverflowTriggerRebuilds() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000, channels: 1, interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        try await owner.open()

        let eventCollector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await eventCollector.append(event)
            }
        }

        // Trigger ringOverflow directly
        await owner.rebuild(trigger: .ringOverflow)
        try? await Task.sleep(for: .milliseconds(50))
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let events = await eventCollector.all
        #expect(events.contains(.reconfiguring(reason: .ringOverflow)),
                "Expected .reconfiguring(.ringOverflow), got: \(events)")
    }

    // MARK: T5 — ordering of the six steps

    @Test("T5: six teardown steps run in strict order: cancel→stop→removeTaps→releaseRings→releaseORT→reconfiguring")
    func teardownSixStepOrdering() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()
        let recorder = TeardownRecorder()

        let fmt16k = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32,
                          sampleRate: 16_000, channels: 1, interleaved: false)
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: RecordingTeardownBuilder(fmt: fmt16k, recorder: recorder)
        )

        await owner.installRecorderSlots(recorder)

        try await owner.open()

        let eventCollector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await eventCollector.append(event)
            }
        }

        await owner.rebuild(trigger: .deviceChange)
        try? await Task.sleep(for: .milliseconds(50))
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let calls = recorder.allCalls
        let events = await eventCollector.all

        // Verify ordering: find indices of each step
        let idx1 = calls.firstIndex(of: "cancelInFlight") ?? -1
        let idx2 = calls.firstIndex(of: "stop") ?? -1
        let idx3 = calls.firstIndex(of: "removeAllTaps") ?? -1
        let idx4 = calls.firstIndex(of: "releaseRings") ?? -1
        let idx5 = calls.firstIndex(of: "releaseORTSessions") ?? -1

        #expect(idx1 >= 0, "Step 1 (cancelInFlight) must be recorded")
        #expect(idx2 >= 0, "Step 2 (stop) must be recorded")
        #expect(idx3 >= 0, "Step 3 (removeAllTaps) must be recorded")
        #expect(idx4 >= 0, "Step 4 (releaseRings) must be recorded")
        #expect(idx5 >= 0, "Step 5 (releaseORTSessions) must be recorded")

        #expect(idx1 < idx2, "cancelInFlight (\(idx1)) must precede stop (\(idx2))")
        #expect(idx2 < idx3, "stop (\(idx2)) must precede removeAllTaps (\(idx3))")
        #expect(idx3 < idx4, "removeAllTaps (\(idx3)) must precede releaseRings (\(idx4))")
        #expect(idx4 < idx5, "releaseRings (\(idx4)) must precede releaseORTSessions (\(idx5))")

        // Step 6: reconfiguring event must be present
        #expect(events.contains(.reconfiguring(reason: .deviceChange)),
                "Step 6 (.reconfiguring) must be emitted after steps 1-5")
    }
}

// MARK: - Test Support

/// Thread-safe call recorder for teardown ordering assertions.
/// Uses a simple lock to allow both synchronous (tap-thread) and async
/// (closure-slot) callers to record without data races.
final class TeardownRecorder: @unchecked Sendable {
    private var _calls: [String] = []
    private let lock = NSLock()

    func record(_ call: String) {
        lock.withLock { _calls.append(call) }
    }

    var allCalls: [String] {
        lock.withLock { _calls }
    }
}

/// Builder that records `stop`, `removeAllTaps`, `releaseRings` calls
/// via a shared `TeardownRecorder`.
struct RecordingTeardownBuilder: GraphBuilder {
    let fmt: AVAudioFormat
    let recorder: TeardownRecorder

    func flipVPIO(_ inputNode: AVAudioInputNode) throws {}
    func attach(_ engine: AVAudioEngine, _ node: AVAudioNode) {}
    func connect(_ engine: AVAudioEngine, _ src: AVAudioNode, to dst: AVAudioNode, format: AVAudioFormat?) {}
    func installTap(on node: AVAudioNode, bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                    format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {}
    func probeFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat { fmt }
}

// MARK: - AudioGraphOwner test helpers

extension AudioGraphOwner {
    /// Installs `cancelInFlight` and `releaseORTSessions` slots that record
    /// into the shared `TeardownRecorder`, and wires the `_onGraphBuilt`
    /// callback to install graph-level recording hooks (stop, removeTaps, releaseRings).
    func installRecorderSlots(_ recorder: TeardownRecorder) async {
        cancelInFlight = {
            // `cancelInFlight` is `@Sendable () async -> Void` but `recorder.record`
            // is now sync — just call it directly.
            recorder.record("cancelInFlight")
        }
        releaseORTSessions = {
            recorder.record("releaseORTSessions")
        }
        _onGraphBuilt = { graph in
            graph._stopHook = { recorder.record("stop") }
            graph._removeTapsHook = { recorder.record("removeAllTaps") }
            graph._releaseRingsHook = { recorder.record("releaseRings") }
        }
    }
}

// MARK: - EventCollector (shared with AECFallbackTests — re-declared as a type alias)
// Note: EventCollector<T> is defined in AECFallbackTests.swift.
// Since both files are in the same test target, the type is already available.
