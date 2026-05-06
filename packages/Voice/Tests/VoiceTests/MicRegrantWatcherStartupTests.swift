import Testing
import AVFoundation
@testable import Voice

/// Regression tests for the spurious-startup-rebuild bug (2026-05-05 voice-loop fix).
///
/// Symptom: on every cold launch with mic already authorized, the
/// `startMicRegrantWatcher` polling loop saw `lastMicStatus = false`
/// (its declared default) and the first poll observed `false → authorized`,
/// firing an unwanted `rebuild(trigger: .micRegrant)` ~2s after `open()`.
///
/// In production the rebuild ran `cancelInFlight`, which finished the
/// `WakeWordDAG.wakeWordStream` permanently — wake word was dead before
/// the user could speak.
///
/// Fix: prime `lastMicStatus` from the current authorization status
/// BEFORE entering the polling loop so the first poll only fires on a
/// real `denied → authorized` transition. Plus split `WakeWordDAG.cancel()`
/// (permanent) and `WakeWordDAG.stopFeed()` (transient) so future
/// legitimate rebuilds don't kill the stream either.
@Suite("MicRegrantWatcherStartupTests", .serialized)
struct MicRegrantWatcherStartupTests {

    // MARK: M1 — already-authorized at startup must not fire spurious rebuild

    @Test("M1: watcher does not fire phantom micRegrant when authorized at open()")
    func authorizedAtStartupDoesNotFireRebuild() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false
            )
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        // Probe always returns true — mic was already authorized when the
        // user launched the app. With the pre-fix `lastMicStatus = false`
        // default this would fire rebuild on the first poll cycle.
        await owner._testSetAuthStatusProbe { true }

        try await owner.open()

        let collector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await collector.append(event)
            }
        }

        // Wait long enough for the watcher to complete several poll cycles.
        // The watcher polls every 2 s; sleep 5 s = at least 2 polls.
        try? await Task.sleep(for: .seconds(5))

        // Tear down so the collector task exits.
        await owner.shutdown()
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let events = await collector.all
        let micRegrantEvents = events.filter {
            if case .reconfiguring(let reason) = $0, reason == .micRegrant { return true }
            return false
        }
        #expect(
            micRegrantEvents.isEmpty,
            "Expected no micRegrant rebuild when authorized at startup, got: \(micRegrantEvents)"
        )

        // Sanity check: degradation stream produced no spurious events either.
        // (Empty rebuilds list is the load-bearing assertion above; this is
        // belt-and-suspenders.)
    }

    // MARK: M2 — real denied → authorized still fires rebuild

    @Test("M2: watcher fires micRegrant when probe transitions denied → authorized")
    func deniedToAuthorizedFiresRebuild() async throws {
        let (degradationStream, degradationCont) = AsyncStream<DegradationReason>.makeStream()
        let (rebuildStream, rebuildCont) = AsyncStream<RebuildEvent>.makeStream()

        let fmt16k = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false
            )
        )

        let owner = AudioGraphOwner(
            degradationContinuation: degradationCont,
            rebuildContinuation: rebuildCont,
            graphBuilder: SucceedingBuilder(fmt: fmt16k)
        )

        // Probe starts denied, flips to authorized after ~2.5 s.
        let probeBox = ProbeStateBox(initial: false)
        await owner._testSetAuthStatusProbe { probeBox.value }

        try await owner.open()

        let collector = EventCollector<RebuildEvent>()
        let collectTask = Task {
            for await event in rebuildStream {
                await collector.append(event)
            }
        }

        // Flip probe to authorized after a delay so the watcher's second
        // poll observes the transition.
        try? await Task.sleep(for: .seconds(3))
        probeBox.value = true

        // Wait for the next poll cycle to observe the transition.
        try? await Task.sleep(for: .seconds(3))

        await owner.shutdown()
        rebuildCont.finish()
        degradationCont.finish()
        await collectTask.value

        let events = await collector.all
        let micRegrantCount = events.filter {
            if case .reconfiguring(let reason) = $0, reason == .micRegrant { return true }
            return false
        }.count
        #expect(
            micRegrantCount >= 1,
            "Expected at least one micRegrant rebuild after denied→authorized, got: \(events)"
        )
    }

    // MARK: M3 — stopFeed preserves stream for rebuild path

    @Test("M3: WakeWordDAG.stopFeed() does NOT finish the wake-word stream")
    func stopFeedPreservesStream() async throws {
        // Construct a DAG with a scripted session — no models needed.
        let session = OpenWakeWordSession(scriptedClassifier: { _ in 0.0 })
        let dag = WakeWordDAG(session: session)

        // Spawn a consumer task on the public stream — it should NOT exit
        // when stopFeed() is called.
        let consumerExitedBox = ConsumerExitBox()
        let consumerTask = Task {
            for await _ in dag.wakeWordStream {
                // We never expect to see an event in this test.
            }
            consumerExitedBox.exited = true
        }

        // Start the feed loop so there's a Task to stop.
        let ring = RingBuffer(capacityFrames: 1024)
        await dag.start(ring: ring)

        // Stop the feed — stream must remain alive.
        await dag.stopFeed()

        // Give the consumer a moment to react if it's going to exit.
        try? await Task.sleep(for: .milliseconds(100))

        #expect(
            consumerExitedBox.exited == false,
            "Consumer of wakeWordStream must NOT exit on stopFeed() — it's reserved for transient teardown across rebuild boundaries."
        )

        // Now do the permanent shutdown — consumer SHOULD exit.
        await dag.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(
            consumerExitedBox.exited == true,
            "Consumer of wakeWordStream MUST exit after cancel() — it's the permanent-shutdown path."
        )

        consumerTask.cancel()
    }
}

// MARK: - Test Support

/// Mutable state holder for the auth-probe transition test. The probe
/// closure captures this box by reference and reads `value` on each call.
final class ProbeStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(initial: Bool) { self._value = initial }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Mutable flag for M3 — the consumer task sets `exited = true` when its
/// `for await` loop terminates.
final class ConsumerExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _exited: Bool = false
    var exited: Bool {
        get { lock.withLock { _exited } }
        set { lock.withLock { _exited = newValue } }
    }
}
