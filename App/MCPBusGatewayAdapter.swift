import Foundation
import CryptoKit
import Bus               // OutboundBatcher, BusOutbound
import JarvisMCP        // BusGateway

/// BLOCKER-INT-1 fix: real `BusGateway` implementation that forwards
/// `ConfirmingToolDispatcher`'s tool-call events to the HUD via
/// `OutboundBatcher`. Replaces the prior `NoopBusGateway` in `AppDelegate.swift`
/// (line ~503) which silently dropped every tool-call card.
///
/// Wire mapping:
/// - `emitToolCallStart(toolUseId:name:argsPreview:)` →
///   `BusOutbound.toolCallStart(id: stableUUID(toolUseId), name:, argsPreview:)`
/// - `updateArgsPreview(toolUseId:name:argsPreview:)` →
///   second `.toolCallStart` with the SAME id; the HUD's `upsertToolCall`
///   reconciler patches the existing card with the post-approval
///   `argsPreview`. Drift the audit calls out in `streaming.test.tsx D5b`
///   is preserved (whitespace-insensitive parser on JS side).
/// - `emitToolCallEnd(toolUseId:name:ok:previewOrError:)` →
///   `BusOutbound.toolCallEnd(id: stableUUID(toolUseId), ok:, previewOrError:)`
///
/// `BusOutbound.toolCallStart/End` use `UUID` for `id` (Phase 2 closed schema);
/// the dispatcher's protocol uses `String` (Anthropic `toolu_01ABCD…` /
/// Ollama free-form, never UUID — see CR-03 in
/// `ConfirmingToolDispatcher.swift`). We bridge with a deterministic SHA256
/// → UUID derivation so:
///   1. `emitToolCallStart(id="toolu_01X")` and `emitToolCallEnd(id="toolu_01X")`
///      produce the IDENTICAL `UUID`, allowing the HUD to reconcile by id.
///   2. The mapping is one-way (we never decode UUID back to original id);
///      the audit-trail correlation across bus / replay / orchestrator
///      already lives at the String layer in `ReplayingToolResultObserver`.
///   3. Two distinct dispatcher String ids hash to two distinct UUIDs with
///      negligible collision probability (SHA256 truncated to 128 bits).
///
/// Late binding: at the time `mcpInstallTask` captures the gateway (step 10
/// of `applicationWillFinishLaunching`), `OutboundBatcher` is not yet
/// constructed — `installAgent` (step 13) builds it. The gateway uses a
/// `@Sendable` resolver closure so `OutboundBatcher?` is read at emit-time,
/// not capture-time. Until the batcher exists, emissions are dropped (the
/// observer-side replay log still records the call).
public actor MCPBusGatewayAdapter: BusGateway {
    private let resolveBatcher: @Sendable () async -> OutboundBatcher?

    /// `resolveBatcher` returns the live `OutboundBatcher` (or nil if not
    /// yet constructed / app shutting down). Production path: closure
    /// hops to MainActor and reads `appDelegate.outboundBatcher`.
    public init(resolveBatcher: @escaping @Sendable () async -> OutboundBatcher?) {
        self.resolveBatcher = resolveBatcher
    }

    // MARK: BusGateway

    public func emitToolCallStart(toolUseId: String, name: String, argsPreview: String) async {
        guard let batcher = await resolveBatcher() else { return }
        let uuid = Self.stableUUID(from: toolUseId)
        try? await batcher.flushAndSend(.toolCallStart(id: uuid, name: name, argsPreview: argsPreview))
    }

    public func updateArgsPreview(toolUseId: String, name: String, argsPreview: String) async {
        guard let batcher = await resolveBatcher() else { return }
        let uuid = Self.stableUUID(from: toolUseId)
        // Re-emit toolCallStart with same id; HUD upserts the args field
        // by id (see webview/packages/hud/src/bus/client.ts case
        // 'toolCallStart' → `store.upsertToolCall(msg.id, …)`).
        try? await batcher.flushAndSend(.toolCallStart(id: uuid, name: name, argsPreview: argsPreview))
    }

    public func emitToolCallEnd(toolUseId: String, name: String, ok: Bool, previewOrError: String) async {
        guard let batcher = await resolveBatcher() else { return }
        let uuid = Self.stableUUID(from: toolUseId)
        try? await batcher.flushAndSend(.toolCallEnd(id: uuid, ok: ok, previewOrError: previewOrError))
    }

    // MARK: - Stable id derivation

    /// Deterministic `String → UUID` derivation: SHA256 of UTF-8 bytes, take
    /// the first 16 bytes, set the version (5) and variant (RFC 4122)
    /// bits per RFC 4122 §4.4 so the resulting UUID is well-formed. The
    /// hash is the load-bearing property — RFC compliance is incidental
    /// but makes the values valid `UUID(uuidString:)` round-trips.
    static func stableUUID(from toolUseId: String) -> UUID {
        let digest = SHA256.hash(data: Data(toolUseId.utf8))
        var bytes = [UInt8](digest.prefix(16))
        // RFC 4122 §4.4: set version (top nibble of byte 6) to 5
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        // RFC 4122 §4.4: set variant (top two bits of byte 8) to 10
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple = (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
