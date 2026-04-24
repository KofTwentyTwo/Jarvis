import Foundation

/// A bounded, single-consumer async channel with three back-pressure policies.
///
/// **AGENT-10 primitive.** The orchestrator (Plan 04-04) wires per-event-type
/// channels with appropriate policies — `.dropOldest` for `tokenDelta` (lossy
/// token rendering is acceptable), `.suspend` for control events. Plan 04-03
/// (replay) consumes the same primitive with `.dropOldest` for replay log
/// frames.
///
/// **Single consumer.** Calling `makeAsyncIterator()` more than once is a
/// programmer error (returns a fresh iterator wrapping the same internal
/// buffer; only one task should drain the channel).
public actor BoundedAsyncChannel<Element: Sendable> {
    public enum Policy: Sendable {
        /// Producer awaits until consumer drains a slot.
        case suspend

        /// Drop the oldest buffered item to make room for the new one.
        /// Used for lossy token rendering where freshness > completeness.
        case dropOldest

        /// Drop the new item; buffer stays as-is.
        case dropNewest
    }

    // `nonisolated` so topology tests (Plan 04-05 AGENT-10 four-seam
    // verification) can introspect channel configuration without hopping into
    // the actor's isolation domain. Both are let-constants set at init — no
    // mutation to guard.
    public nonisolated let capacity: Int
    public nonisolated let policy: Policy

    private var buffer: [Element] = []
    private var pendingSends: [CheckedContinuation<Void, Never>] = []
    private var pendingReceive: CheckedContinuation<Element?, Never>?
    private var finished: Bool = false

    public init(capacity: Int, policy: Policy) {
        precondition(capacity > 0, "BoundedAsyncChannel capacity must be > 0")
        self.capacity = capacity
        self.policy = policy
        self.buffer.reserveCapacity(capacity)
    }

    /// Send one element. Behavior on full buffer depends on `policy`:
    /// - `.suspend`: awaits until a slot opens.
    /// - `.dropOldest`: discards `buffer[0]`, appends.
    /// - `.dropNewest`: silently discards the new element.
    public func send(_ element: Element) async {
        guard !finished else { return }

        // Fast path: a consumer is already waiting. Hand the item directly.
        if let waiter = pendingReceive {
            pendingReceive = nil
            waiter.resume(returning: element)
            return
        }

        if buffer.count < capacity {
            buffer.append(element)
            return
        }

        // Buffer is full — branch on policy.
        switch policy {
        case .suspend:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pendingSends.append(cont)
            }
            // After resume, a slot has opened (consumer drained one).
            // Re-check finished state in case consumer terminated.
            if !finished {
                buffer.append(element)
            }
        case .dropOldest:
            buffer.removeFirst()
            buffer.append(element)
        case .dropNewest:
            return
        }
    }

    /// Mark the channel finished. The consumer's iterator returns `nil` after
    /// the buffer drains. Any pending senders are resumed without inserting
    /// (their elements are dropped).
    public func finish() {
        guard !finished else { return }
        finished = true
        // Wake any pending receiver so it can observe end-of-stream.
        if let waiter = pendingReceive {
            pendingReceive = nil
            waiter.resume(returning: nil)
        }
        // Wake all pending senders; they'll observe `finished` and bail.
        let drainedSends = pendingSends
        pendingSends.removeAll()
        for cont in drainedSends {
            cont.resume()
        }
    }

    /// Receive one element. `nil` indicates end-of-stream.
    /// Internal — called by the iterator.
    fileprivate func receive() async -> Element? {
        if !buffer.isEmpty {
            let head = buffer.removeFirst()
            // Drained one slot — wake one suspended sender if any.
            if !pendingSends.isEmpty {
                let cont = pendingSends.removeFirst()
                cont.resume()
            }
            return head
        }
        if finished {
            return nil
        }
        // Buffer empty and not finished — suspend.
        return await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
            pendingReceive = cont
        }
    }
}

// MARK: - AsyncSequence conformance

extension BoundedAsyncChannel: AsyncSequence {
    public typealias AsyncIterator = Iterator

    public nonisolated func makeAsyncIterator() -> Iterator {
        Iterator(channel: self)
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let channel: BoundedAsyncChannel<Element>

        init(channel: BoundedAsyncChannel<Element>) {
            self.channel = channel
        }

        public mutating func next() async -> Element? {
            await channel.receive()
        }
    }
}
