import Foundation

/// Read-only event bus for presence signals.
///
/// VISION-03 invariant: this is a bare AsyncStream — there is no
/// subscriber registry, no broadcast fan-out, and no integration point for
/// TTS or AgentOrchestrator. Legitimate consumers (ContextBuilder for
/// system-prompt enrichment per D-10; HudStateCoordinator for the subtle
/// ring indicator per D-10) hold their own iterator off the public stream.
///
/// The bus is OWNED by PresenceMonitor — there is exactly ONE producer
/// (the monitor) and the bus is exposed publicly only as the read end.
/// scripts/check-presence-bus-no-tts-orchestrator.sh enforces no Voice /
/// AgentOrchestrator file references this symbol.
public struct PresenceSignalBus: Sendable {
    public let stream: AsyncStream<PresenceEvent>

    /// Internal-only initializer; only PresenceMonitor constructs the bus.
    /// Public consumers receive an existing PresenceSignalBus by reference.
    internal init(stream: AsyncStream<PresenceEvent>) {
        self.stream = stream
    }
}
