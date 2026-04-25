import Foundation

/// AGENT-10 critical-invariant primitive.
///
/// Single-consumer async channel with a **per-element drop policy**: when the
/// internal buffer overflows, only elements whose `tag == dropTag` are dropped
/// (oldest first). Sends with a non-`dropTag` tag SUSPEND the producer until
/// the consumer drains a slot. This is what the orchestrator (Plan 04-04)
/// uses to fan token-delta + tool-call streams into the replay log: tokens
/// are lossy under firehose load, but tool-calls must NEVER drop.
///
/// **Re-entrancy note.** `send` for a non-`dropTag` element suspends until
/// the consumer drains a slot, then loops to re-attempt the enqueue. The
/// loop is iterative (no recursive `await send(...)` calls) so producer
/// stacks stay O(1) under pathological consumer stalls. Mirrors the shape
/// of `BoundedAsyncChannel.send`.
public actor TokenDeltaDropOldestChannel<Tag: Sendable & Equatable & Hashable>: AsyncSequence {
    public typealias AsyncIterator = Iterator

    /// Tagged payload. `tag` controls the drop policy; `payload` is the bytes
    /// the orchestrator wants to push downstream.
    public struct Element: Sendable {
        public let tag: Tag
        public let payload: Data

        public init(tag: Tag, payload: Data) {
            self.tag = tag
            self.payload = payload
        }
    }

    public let capacity: Int
    public let dropTag: Tag

    private var buffer: [Element] = []
    private var pendingSends: [CheckedContinuation<Void, Never>] = []
    private var pendingReceive: CheckedContinuation<Element?, Never>?
    private var finished: Bool = false

    public init(capacity: Int, dropTag: Tag) {
        precondition(capacity > 0, "TokenDeltaDropOldestChannel capacity must be > 0")
        self.capacity = capacity
        self.dropTag = dropTag
        self.buffer.reserveCapacity(capacity)
    }

    /// Send one element. Behavior on overflow:
    /// - `element.tag == dropTag` → drop the oldest buffered `dropTag` element
    ///   and append. If the buffer contains zero `dropTag` elements (all are
    ///   protected), suspend like a non-dropTag element.
    /// - Else → suspend until the consumer drains a slot.
    ///
    /// **ME-03:** loop, don't recurse. Swift does not guarantee tail-call
    /// elimination across `await` suspension points; `await send(element)`
    /// after resume could grow the stack under pathological consumer
    /// stalls. The `while` loop re-attempts the enqueue at the same stack
    /// frame on every wake-up.
    public func send(_ element: Element) async {
        while true {
            guard !finished else { return }

            // Fast path: a consumer is already waiting.
            if let waiter = pendingReceive {
                pendingReceive = nil
                waiter.resume(returning: element)
                return
            }

            if buffer.count < capacity {
                buffer.append(element)
                return
            }

            // Overflow.
            if element.tag == dropTag,
               let idx = buffer.firstIndex(where: { $0.tag == dropTag }) {
                // Find and evict the oldest dropTag element. If the buffer is
                // saturated with non-dropTag elements (a degenerate case),
                // fall through to the suspend path so we never drop a
                // protected event.
                buffer.remove(at: idx)
                buffer.append(element)
                return
            }

            // Suspend, then loop to re-attempt the enqueue.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                pendingSends.append(cont)
            }
            // Loop continues: re-check finished, fast paths, and overflow.
        }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        if let waiter = pendingReceive {
            pendingReceive = nil
            waiter.resume(returning: nil)
        }
        let drained = pendingSends
        pendingSends.removeAll()
        for cont in drained { cont.resume() }
    }

    /// Internal — pulls one element off the buffer + wakes one suspended sender.
    fileprivate func receive() async -> Element? {
        if !buffer.isEmpty {
            let head = buffer.removeFirst()
            if !pendingSends.isEmpty {
                let cont = pendingSends.removeFirst()
                cont.resume()
            }
            return head
        }
        if finished { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
            pendingReceive = cont
        }
    }

    public nonisolated func makeAsyncIterator() -> Iterator {
        Iterator(channel: self)
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let channel: TokenDeltaDropOldestChannel<Tag>

        init(channel: TokenDeltaDropOldestChannel<Tag>) {
            self.channel = channel
        }

        public mutating func next() async -> Element? {
            await channel.receive()
        }
    }
}
