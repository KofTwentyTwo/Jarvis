// LogBroadcaster.swift
//
// Process-wide fan-out of swift-log records to in-app subscribers. The
// file + os.Logger handlers already cover persistence and the system
// log; this third handler exists exclusively so the DevOverlay (and any
// future in-process diagnostic surface) can tail every log line live
// without polling files or relying on Console.app.
//
// Design:
//   - `BroadcastLogHandler` (LogHandler conformance) formats each log
//     call into a `LogLine` value and hands it to `LogBroadcaster.shared`.
//   - `LogBroadcaster` is an actor that owns a bounded ring buffer
//     (default 500) plus a set of subscriber continuations. New
//     subscribers receive the buffer's contents replayed in order, then
//     all subsequent live lines.
//   - The shape is borrowed from `OrchestratorEventBroadcaster` so the
//     mental model is consistent across the project's three broadcasters:
//     subscriber stream + bounded back-pressure + drop-oldest under load.
//
// Threading:
//   - `LogBroadcaster` is a global actor (`shared`). All mutating work
//     (`publish`, `subscribe`, `unsubscribe`) hops to the actor.
//   - `BroadcastLogHandler.log(...)` is synchronous and reentrancy-safe;
//     it schedules an unstructured `Task { await broadcaster.publish(...) }`
//     so the caller never blocks on the actor. Drop-oldest under load on
//     the subscriber side means a slow consumer never pressures the
//     emitter.
//
// Why not just write to a file the UI tails? Because the UI would have
// to re-parse the file, the file goes through the redaction pipeline
// (good for disk, lossy for live UX), and a third subscriber surface
// (DevOverlay) is the same architectural shape the project already
// uses for OrchestratorEvents — keeping it consistent beats inventing.

import Foundation
import Logging

/// One log entry as it appears in the broadcaster. Equatable + Sendable
/// so SwiftUI can store an array of these in a `@Published` slot and
/// re-diff cheaply.
///
/// ## Topics
///
/// - ``timestamp``
/// - ``channel``
/// - ``level``
/// - ``message``
/// - ``metadata``
public struct LogLine: Sendable, Equatable, Identifiable {
    /// Deterministic identity for SwiftUI's `ForEach`. Composed from
    /// timestamp + a monotonic sequence so identical messages a
    /// millisecond apart still render as distinct rows.
    public let id: UInt64
    public let timestamp: Date
    public let channel: String
    public let level: Logger.Level
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UInt64,
        timestamp: Date,
        channel: String,
        level: Logger.Level,
        message: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

/// Process-wide actor that fans out `LogLine`s to in-app subscribers.
///
/// ## Overview
///
/// Each subscriber gets the current buffer replayed at subscribe time
/// (so a DevOverlay opened mid-run shows the last 500 lines immediately),
/// followed by live lines as they're published. Subscribers are
/// identified by `UUID`; cancelling the AsyncStream's terminator removes
/// them from the broadcaster set.
///
/// ## Threading
///
/// Global actor. Every mutating method must be `await`-called. The
/// `BroadcastLogHandler` side schedules unstructured `Task { … }` writes
/// rather than blocking the logging caller — swift-log handlers must be
/// synchronous, so we trade strict ordering for non-blocking semantics.
/// Under heavy logging the ring buffer's drop-oldest keeps memory bounded.
public actor LogBroadcaster {
    public static let shared = LogBroadcaster()

    /// Bounded ring of the most recent lines. Subscribers joining late
    /// replay this slice in order before going live.
    private var buffer: [LogLine] = []
    private let bufferCapacity: Int

    /// Live subscribers. Continuations finish on `unsubscribe`.
    private var subscribers: [UUID: AsyncStream<LogLine>.Continuation] = [:]

    /// Monotonic sequence used to give each line a unique `id`.
    private var sequence: UInt64 = 0

    public init(bufferCapacity: Int = 500) {
        precondition(bufferCapacity > 0)
        self.bufferCapacity = bufferCapacity
    }

    /// Append a log line to the ring + fan out to every live subscriber.
    public func publish(
        timestamp: Date,
        channel: String,
        level: Logger.Level,
        message: String,
        metadata: [String: String]
    ) {
        sequence &+= 1
        let line = LogLine(
            id: sequence,
            timestamp: timestamp,
            channel: channel,
            level: level,
            message: message,
            metadata: metadata
        )
        buffer.append(line)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
        for cont in subscribers.values {
            cont.yield(line)
        }
    }

    /// Subscribe to the live stream. The current buffer is replayed first,
    /// then new lines arrive as they're published. Cancel the consumer's
    /// task or break out of the for-await to terminate.
    ///
    /// The stream is `.bufferingNewest(256)` — a slow consumer drops the
    /// oldest in-flight lines rather than back-pressuring the publisher.
    public func subscribe() -> AsyncStream<LogLine> {
        let id = UUID()
        let snapshot = buffer
        let (stream, cont) = AsyncStream<LogLine>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        // Replay buffer in order so the UI shows historical context the
        // instant it opens.
        for line in snapshot {
            cont.yield(line)
        }
        subscribers[id] = cont
        cont.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        return stream
    }

    /// Internal helper for `onTermination` cleanup.
    fileprivate func removeSubscriber(id: UUID) {
        if let cont = subscribers.removeValue(forKey: id) {
            cont.finish()
        }
    }

    /// Test seam — count of live subscribers.
    public var subscriberCount: Int { subscribers.count }

    /// Test seam — current buffer size.
    public var bufferedCount: Int { buffer.count }
}

/// `swift-log` LogHandler that forwards every record to `LogBroadcaster.shared`.
///
/// Constructed by `LoggingBootstrap.make(label:)` alongside the file +
/// os.Logger handlers. The three handlers are wrapped in a
/// `MultiplexLogHandler`; this one is purely additive — disabling it
/// (removing it from the multiplex) leaves persistence + os logging
/// untouched.
///
/// Redaction note: the file handler's `Redact.apply(_:)` strips secrets
/// from disk writes. The broadcaster sees the **raw** message because
/// the DevOverlay is a developer-only surface running in-process; a
/// developer trying to debug their own session needs to see what
/// they actually logged. If this ever becomes user-facing, route through
/// `Redact.apply(_:)` before publishing.
public struct BroadcastLogHandler: LogHandler {
    public let label: String
    public var logLevel: Logger.Level = .trace
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?

    public init(label: String) {
        self.label = label
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        var flat: [String: String] = [:]
        flat.reserveCapacity(merged.count)
        for (k, v) in merged {
            flat[k] = "\(v)"
        }
        // Snapshot values into Sendable locals before hopping to the actor.
        let ts = Date()
        let channelCopy = label
        let levelCopy = level
        let msgCopy = "\(message)"
        let metaCopy = flat
        Task {
            await LogBroadcaster.shared.publish(
                timestamp: ts,
                channel: channelCopy,
                level: levelCopy,
                message: msgCopy,
                metadata: metaCopy
            )
        }
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}
