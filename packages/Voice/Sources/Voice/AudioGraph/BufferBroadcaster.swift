import AVFoundation
import os

/// Multi-consumer fan-out hub for the audio-graph tap (Track B-7,
/// 2026-05-03 voice audit fix).
///
/// `RingBuffer` is documented SPSC: only one consumer may call
/// `readMono16k`. In practice the production audio graph had three
/// concurrent consumers — `WakeWordDAG` (always-on for wake detection),
/// the Track B-5 chunk pump (active while listening), and
/// `AudioLevelEmitter` (active while listening for HUD pulse) — each
/// advancing the same read pointer. Consumers stole samples from each other.
///
/// `BufferBroadcaster` solves this by giving each consumer its own
/// per-subscriber `RingBuffer`. The audio-graph tap calls
/// `publish(_:)` once per buffer; the broadcaster fans the buffer out by
/// calling `ring.write(buffer)` on every active subscriber's ring. Reads
/// remain SPSC against each subscriber's own ring — the existing
/// `RingBuffer` contract is preserved.
///
/// ## Threading
/// - `publish(_:)` is called on the Core Audio tap thread (real-time priority).
///   It MUST be lock-free or use a wait-free uncontested-lock primitive.
///   This implementation takes a snapshot of the subscribers array under
///   `OSAllocatedUnfairLock` and iterates outside the lock. Apple
///   blesses `OSAllocatedUnfairLock` for use from real-time threads when
///   contention is rare; the lock is held only for the duration of an
///   array copy (<= a few pointers in practice).
/// - `subscribe()` / `unsubscribe()` are infrequent (once per voice session
///   lifetime). They take the same lock and replace the subscribers array
///   copy-on-write so in-flight `publish` snapshots are unaffected.
///
/// ## Why `@unchecked Sendable`
/// The lock-protected mutable state (`subscribers`) is the only mutable
/// member; all other writes happen through that lock. Per-subscriber
/// `RingBuffer` writes are themselves lock-free (SPSC). The compiler
/// can't prove this discipline so we vouch for it via `@unchecked`.
public final class BufferBroadcaster: @unchecked Sendable {

    /// A handle returned by `subscribe()`. Owns a per-subscriber
    /// `RingBuffer` that receives a copy of every published buffer until
    /// `unsubscribe()` is called.
    ///
    /// `Subscription` is reference-typed so multiple references share the
    /// same underlying ring (e.g., AppDelegate hands the subscription to
    /// `WakeWordDAG.start(ring:)` while also keeping a reference for
    /// teardown).
    public final class Subscription: @unchecked Sendable {
        /// The per-subscriber ring buffer. Read this with `readMono16k`
        /// exactly as you would the legacy SPSC ring.
        public let ring: RingBuffer

        // Identity for the broadcaster's subscribers array. ObjectIdentifier
        // is stable for the lifetime of the subscription instance.
        fileprivate let id: ObjectIdentifier

        // Unowned back-reference is intentional — Subscription's lifetime
        // is bounded by the broadcaster's lifetime in production. We use
        // `weak` to be defensive in tests where the broadcaster may
        // deinit first.
        private weak var broadcaster: BufferBroadcaster?

        fileprivate init(broadcaster: BufferBroadcaster, ring: RingBuffer) {
            self.broadcaster = broadcaster
            self.ring = ring
            self.id = ObjectIdentifier(ring)
        }

        /// Stop receiving published buffers. Idempotent.
        public func unsubscribe() {
            broadcaster?.unsubscribe(self)
            broadcaster = nil
        }
    }

    // MARK: - Init

    /// Default subscriber-ring capacity: 2 s of 16 kHz mono — matches the
    /// legacy `AudioGraph` ring capacity so each subscriber has the same
    /// overflow margin as the pre-broadcaster single ring.
    public static let defaultSubscriberCapacityFrames: Int = 32_000

    public init() {}

    // MARK: - Subscribe / unsubscribe

    /// Adds a new subscriber and returns its handle.
    ///
    /// The new subscription receives only buffers published *after* this
    /// call returns — pre-existing buffers are not replayed.
    public func subscribe(capacityFrames: Int = BufferBroadcaster.defaultSubscriberCapacityFrames) -> Subscription {
        let ring = RingBuffer(capacityFrames: capacityFrames)
        let sub = Subscription(broadcaster: self, ring: ring)
        lock.withLock { subs in
            subs.append(sub)
        }
        return sub
    }

    private func unsubscribe(_ subscription: Subscription) {
        lock.withLock { subs in
            subs.removeAll { $0 === subscription }
        }
    }

    // MARK: - Publish (Core Audio tap thread)

    /// Fan out a buffer to every active subscriber.
    ///
    /// MUST be safe to call on the Core Audio tap thread. The lock here
    /// is uncontested in steady state (subscribe/unsubscribe happens once
    /// per voice session), and we copy the subscribers array out of the
    /// lock before iterating so per-subscriber writes never hold it.
    public func publish(_ buffer: AVAudioPCMBuffer) {
        // Snapshot subscribers under the lock, then iterate outside it.
        // The snapshot is a CoW Array — the copy is O(n) pointer-copies
        // where n is small (3 in production today).
        let snapshot: [Subscription] = lock.withLock { $0 }
        for sub in snapshot {
            sub.ring.write(buffer)
        }
    }

    // MARK: - Diagnostics

    /// Current subscriber count. Cheap; intended for tests and logging.
    public var subscriberCount: Int {
        lock.withLock { $0.count }
    }

    // MARK: - Private

    private let lock = OSAllocatedUnfairLock<[Subscription]>(initialState: [])
}
