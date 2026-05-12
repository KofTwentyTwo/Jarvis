import Foundation
import AppKit
import AVFoundation
import AgentCore
import Bus
import Config
import Keychain
import JarvisMCP
import JarvisVision
import Memory
import Voice

// Round 2 — concrete probes per the 2026-05-11 handoff.
//
// Each probe is a small Sendable struct that wraps a live read against the
// real subsystem (DB query, /api/tags call, TCC status read, helper-count
// query) and translates the result to a `ProbeOutcome`. No probe reads a
// cached install flag — every status is the result of a fresh round-trip.
//
// All probes are constructed at install time (after the seven install Tasks
// join in AppDelegate) so each probe has a strong reference to the live
// actor / adapter it needs. nil-handling lives in the AppDelegate wire-up:
// a subsystem that never installed registers a no-op probe that returns
// `.unknown(reason: "subsystem dormant")` rather than skipping registration.

// MARK: - Memory

/// Runs `MemoryStatsStoreAdapter.getMemoryStats()` end-to-end. Verifies the
/// schema is queryable, vec0 is loaded, and the DB file is open. Failure
/// here means memory writes silently disappear — the subsystem is broken
/// at its lowest layer.
public struct MemoryBootHealthProbe: BootHealthProbe {
    public let name = "memory"
    private let adapter: MemoryStatsStoreAdapter

    public init(adapter: MemoryStatsStoreAdapter) {
        self.adapter = adapter
    }

    public func probe() async -> ProbeOutcome {
        do {
            let stats = try await adapter.getMemoryStats()
            let evidence = "\(stats.turnsCount) turns, \(stats.factsActive)/\(stats.factsTotal) facts, vec=\(stats.vecVersion), sqlite=\(stats.sqliteVersion)"
            return ProbeOutcome(status: .ok, evidence: evidence)
        } catch {
            // Round 4 — memory IS the agent's grounding. Failure here means
            // facts vanish silently and the agent can lie about remembering
            // (the Toby-the-dog scenario).
            return ProbeOutcome(
                status: .failed(reason: String(describing: error), severity: .critical),
                evidence: "getMemoryStats threw"
            )
        }
    }
}

// MARK: - Anthropic

/// Structural check: API key present in Keychain and non-empty. We do NOT
/// fire a billable network probe at boot — instead the Round 3 Status panel
/// offers an explicit "Re-probe" button so the user pays for verification
/// only when they ask. Evidence is honest about what was verified.
///
/// NOT FAKED: returns `.ok` only when a non-empty key is in the keychain
/// at the configured slot. `.unknown(reason:)` on absence — never `.ok`.
public struct AnthropicBootHealthProbe: BootHealthProbe {
    public let name = "anthropic"
    private let keychain: any KeychainStore

    public init(keychain: any KeychainStore) {
        self.keychain = keychain
    }

    public func probe() async -> ProbeOutcome {
        do {
            let key = try keychain.get(.anthropic)
            guard !key.isEmpty else {
                // Round 4 — empty key is a critical block on the agent (the
                // Anthropic provider can't authenticate).
                return ProbeOutcome(
                    status: .unknown(reason: "API key slot present but empty", severity: .critical),
                    evidence: "key length 0"
                )
            }
            let prefix = String(key.prefix(7))
            let evidence = "key present (\(prefix)…, len=\(key.count)) — network probe deferred to Status menu"
            return ProbeOutcome(status: .ok, evidence: evidence)
        } catch let error as KeychainError {
            switch error {
            case .itemNotFound:
                // Round 4 — missing key is critical (agent can't run).
                return ProbeOutcome(
                    status: .unknown(reason: "no API key in Keychain", severity: .critical),
                    evidence: "keychain.itemNotFound"
                )
            default:
                return ProbeOutcome(
                    status: .failed(reason: "keychain read failed: \(error)", severity: .critical),
                    evidence: "keychain error"
                )
            }
        } catch {
            return ProbeOutcome(
                status: .failed(reason: String(describing: error), severity: .critical),
                evidence: "keychain.get threw unexpected error"
            )
        }
    }
}

// MARK: - Ollama

/// Live `GET /api/tags` against the configured Ollama base URL with a 3-second
/// timeout. Compares the returned model list against the three names the app
/// actually depends on (extractor model, agent-loop fallback, embedder).
///
/// 3-second timeout caps boot delay if Ollama is offline. Probes run in
/// parallel, so this doesn't serialize with the others.
public struct OllamaBootHealthProbe: BootHealthProbe {
    public let name = "ollama"
    private let baseURL: URL
    private let requiredModels: [String]
    private let session: URLSession

    public init(
        baseURL: URL,
        requiredModels: [String] = [
            ModelID.qwen36.rawValue,
            ModelID.qwen25coder32b.rawValue,
            "nomic-embed-text"
        ],
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        self.requiredModels = requiredModels
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 3.0
        self.session = URLSession(configuration: config)
    }

    public func probe() async -> ProbeOutcome {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Round 4 — Ollama unreachable means chat fallback + memory
                // extraction + embeddings are all dead. Loud, not critical:
                // Anthropic path can still work for primary chat.
                return ProbeOutcome(
                    status: .failed(reason: "Ollama /api/tags HTTP \(code)", severity: .loud),
                    evidence: "non-200 from \(url.absoluteString)"
                )
            }
            // Tag-agnostic match — Ollama returns names with `:latest` /
            // `:32b` etc. suffixes. A required model `"nomic-embed-text"`
            // matches against `"nomic-embed-text:latest"` because the user
            // pulled the default tag; explicit `"qwen3.6:latest"` matches
            // only that exact tag. Strip ":<tag>" from EACH side only when
            // the required name has no tag itself.
            let tagged = parseModelNames(from: data)
            let missing = requiredModels.filter { required in
                if required.contains(":") {
                    return !tagged.contains(required)
                }
                return !tagged.contains(where: { $0 == required || $0.hasPrefix(required + ":") })
            }
            if missing.isEmpty {
                return ProbeOutcome(
                    status: .ok,
                    evidence: "all \(requiredModels.count) required models present: \(requiredModels.joined(separator: ", "))"
                )
            }
            // Round 4 — missing models = the Toby case. Embedding step
            // fails, no row inserted in `facts`, agent doesn't know it
            // can't remember. Loud red banner so the user sees it.
            return ProbeOutcome(
                status: .degraded(reason: "missing models: \(missing.joined(separator: ", "))", severity: .loud),
                evidence: "have \(tagged.count) models; missing \(missing.count)"
            )
        } catch {
            return ProbeOutcome(
                status: .failed(reason: "Ollama unreachable: \(error.localizedDescription)", severity: .loud),
                evidence: "\(baseURL.absoluteString) — \(error.localizedDescription)"
            )
        }
    }

    /// Parses the `models` array from `/api/tags` JSON. Tolerant of
    /// surrounding fields and missing keys — returns an empty array if the
    /// shape doesn't match.
    private func parseModelNames(from data: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return Set(models.compactMap { $0["name"] as? String })
    }
}

// MARK: - Voice

/// Microphone TCC status + audio-graph open status. Voice can be:
///   - .ok when graph is open and mic is authorized
///   - .degraded when graph open but mic denied (rare — graph open implies authorized)
///   - .failed when graph never opened
///   - .unknown when voice subsystem short-circuited (AudioGraphOwner nil)
public struct VoiceBootHealthProbe: BootHealthProbe {
    public let name = "voice"
    private let audioGraphOwner: AudioGraphOwner?

    public init(audioGraphOwner: AudioGraphOwner?) {
        self.audioGraphOwner = audioGraphOwner
    }

    public func probe() async -> ProbeOutcome {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard let owner = audioGraphOwner else {
            // Round 4 — dormant voice install is a soft state: text input
            // still works fine.
            return ProbeOutcome(
                status: .unknown(reason: "voice subsystem not installed (dormantVoiceContinuation nil or wakeword/VAD weights missing)", severity: .soft),
                evidence: "AudioGraphOwner unavailable; mic TCC=\(authStatusName(micStatus))"
            )
        }

        let variant = await owner.currentVariant
        let route = await owner.activeRouteSnapshot()

        switch micStatus {
        case .denied, .restricted:
            // Round 4 — voice loop dead, but text still works. Loud.
            return ProbeOutcome(
                status: .degraded(reason: "microphone TCC denied", severity: .loud),
                evidence: "graph variant=\(variant.map { String(describing: $0) } ?? "nil"); mic=\(authStatusName(micStatus))"
            )
        case .notDetermined:
            return ProbeOutcome(
                status: .unknown(reason: "microphone TCC not yet requested", severity: .soft),
                evidence: "graph variant=\(variant.map { String(describing: $0) } ?? "nil")"
            )
        case .authorized:
            guard variant != nil else {
                return ProbeOutcome(
                    status: .failed(reason: "AudioGraph never opened", severity: .loud),
                    evidence: "mic authorized but currentVariant=nil"
                )
            }
            let routeDesc = route.map { "\($0.sampleRate.formatted())Hz × \($0.channels)ch" } ?? "no route"
            return ProbeOutcome(
                status: .ok,
                evidence: "variant=\(variant!) — \(routeDesc)"
            )
        @unknown default:
            return ProbeOutcome(
                status: .unknown(reason: "unknown TCC status \(micStatus.rawValue)", severity: .soft),
                evidence: "AVCaptureDevice.authorizationStatus returned unrecognized case"
            )
        }
    }
}

// MARK: - Vision

/// Camera TCC status + camera device enumeration. No camera frame is
/// captured — `AVCaptureDevice.DiscoverySession` is read-only and does
/// not trigger the TCC prompt (RESEARCH §Example 2).
public struct VisionBootHealthProbe: BootHealthProbe {
    public let name = "vision"

    public init() {}

    public func probe() async -> ProbeOutcome {
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = session.devices

        switch camStatus {
        case .denied, .restricted:
            // Round 4 — vision is optional. The agent works fine without
            // it; soft severity per the slice plan.
            return ProbeOutcome(
                status: .failed(reason: "camera TCC denied", severity: .soft),
                evidence: "\(devices.count) device(s) discovered; mic TCC=\(authStatusName(camStatus))"
            )
        case .notDetermined:
            return ProbeOutcome(
                status: .unknown(reason: "camera TCC not yet requested", severity: .soft),
                evidence: "\(devices.count) device(s) discovered (read-only — no TCC prompt)"
            )
        case .authorized:
            if devices.isEmpty {
                return ProbeOutcome(
                    status: .degraded(reason: "no camera devices discovered", severity: .soft),
                    evidence: "AVCaptureDevice.DiscoverySession returned 0 devices"
                )
            }
            let firstName = devices.first?.localizedName ?? "unknown"
            return ProbeOutcome(
                status: .ok,
                evidence: "\(devices.count) device(s); primary=\(firstName)"
            )
        @unknown default:
            return ProbeOutcome(
                status: .unknown(reason: "unknown TCC status \(camStatus.rawValue)", severity: .soft),
                evidence: "AVCaptureDevice.authorizationStatus returned unrecognized case"
            )
        }
    }
}

// MARK: - MCP

/// MCPRuntime registered-tool count. Verifies the runtime build succeeded
/// and that the expected tools were registered into the in-process registry
/// plus stdio helpers (mcp-time / mcp-clipboard / mcp-applescript).
///
/// Expected tool count at full registration:
///   - 3 stdio helpers (mcp-time → get_time; mcp-clipboard → get_clipboard;
///     mcp-applescript → run_applescript)
///   - 1 memory-stats (registered in installSelfKnowledgeTools)
///   - 4 self-knowledge (list_audio_devices, get_active_audio_route,
///     get_self_state, list_camera_devices)
///   - 0–2 memory tools (search_memory + forget_fact when vec0 + embedder up)
///
/// Anything under 8 is degraded; anything at zero is failed.
public struct MCPBootHealthProbe: BootHealthProbe {
    public let name = "mcp"
    private let mcpRuntime: MCPRuntime?
    private let inProcessRegistry: InProcessToolRegistry?
    private let minimumExpected: Int

    public init(
        mcpRuntime: MCPRuntime?,
        inProcessRegistry: InProcessToolRegistry? = nil,
        minimumExpected: Int = 8
    ) {
        self.mcpRuntime = mcpRuntime
        self.inProcessRegistry = inProcessRegistry
        self.minimumExpected = minimumExpected
    }

    public func probe() async -> ProbeOutcome {
        guard let runtime = mcpRuntime else {
            // Round 4 — no MCP = no tools = agent has no leverage on the host.
            // Critical.
            return ProbeOutcome(
                status: .failed(reason: "MCPRuntime nil — build failed at install (helpers absent or unsigned?)", severity: .critical),
                evidence: "mcpRuntime property was nil at probe time"
            )
        }
        // Stdio helpers + in-process tools live in separate registries.
        // The composite dispatcher routes both. The agent uses both.
        // Probe must count both.
        let stdioNames = await runtime.client.registeredToolNames()
        let inProcessNames: [String]
        if let registry = inProcessRegistry {
            let tools = await registry.registered()
            inProcessNames = tools.map(\.name)
        } else {
            inProcessNames = []
        }
        let names = Array(Set(stdioNames + inProcessNames)).sorted()
        let count = names.count
        if count == 0 {
            return ProbeOutcome(
                status: .failed(reason: "no tools registered", severity: .critical),
                evidence: "no stdio + no in-process tools"
            )
        }
        if count < minimumExpected {
            return ProbeOutcome(
                status: .degraded(reason: "expected ≥\(minimumExpected) tools, registry has \(count)", severity: .loud),
                evidence: "stdio: \(stdioNames.count); in-process: \(inProcessNames.count); names: \(names.joined(separator: ", "))"
            )
        }
        return ProbeOutcome(
            status: .ok,
            evidence: "\(count) tools (\(stdioNames.count) stdio + \(inProcessNames.count) in-process): \(names.joined(separator: ", "))"
        )
    }
}

// MARK: - Replay

/// Replay log file presence + writability. Doesn't insert/rollback (the
/// ReplayLog actor doesn't expose a probe API), but verifies the file
/// exists, is reachable on disk, and is in a writable directory.
public struct ReplayBootHealthProbe: BootHealthProbe {
    public let name = "replay"
    private let databaseURL: URL
    private let replayLogPresent: Bool

    public init(databaseURL: URL, replayLogPresent: Bool) {
        self.databaseURL = databaseURL
        self.replayLogPresent = replayLogPresent
    }

    public func probe() async -> ProbeOutcome {
        guard replayLogPresent else {
            // Round 4 — ReplayLog init failure is critical (no audit trail,
            // no eval harness data, observability collapses).
            return ProbeOutcome(
                status: .failed(reason: "ReplayLog nil — open() failed at install", severity: .critical),
                evidence: "AppDelegate.replayLog was nil"
            )
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else {
            // Round 4 — missing file (existing log got moved/deleted) is loud:
            // a fresh one would be re-created, but the old one is gone.
            return ProbeOutcome(
                status: .failed(reason: "replay.sqlite missing at \(databaseURL.path)", severity: .loud),
                evidence: "FileManager.fileExists == false"
            )
        }
        let parent = databaseURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            return ProbeOutcome(
                status: .failed(reason: "parent dir not writable: \(parent.path)", severity: .loud),
                evidence: "FileManager.isWritableFile(parent) == false"
            )
        }
        let size: Int64
        if let attrs = try? fm.attributesOfItem(atPath: databaseURL.path),
           let s = attrs[.size] as? Int64 {
            size = s
        } else {
            size = 0
        }
        return ProbeOutcome(
            status: .ok,
            evidence: "\(databaseURL.lastPathComponent) — \(size) bytes; parent writable"
        )
    }
}

// MARK: - Webview

/// WKWebView ↔ Swift handshake state. `.armed` = HUD JS has acked the
/// protocol version → bus is live. Anything else is a failure or pending.
public struct WebviewBootHealthProbe: BootHealthProbe {
    public let name = "webview"
    private let bridge: WebviewBridge?

    public init(bridge: WebviewBridge?) {
        self.bridge = bridge
    }

    public func probe() async -> ProbeOutcome {
        guard let bridge = bridge else {
            // Round 4 — no bridge = no UI at all. Critical.
            return ProbeOutcome(
                status: .failed(reason: "WebviewBridge nil — never constructed", severity: .critical),
                evidence: "webviewBridge property was nil at probe time"
            )
        }
        let state = await MainActor.run { bridge.handshakeState }
        switch state {
        case .idle:
            return ProbeOutcome(
                status: .unknown(reason: "handshake never started", severity: .soft),
                evidence: "HandshakeState.idle"
            )
        case .sentHello:
            return ProbeOutcome(
                status: .unknown(reason: "handshake in flight", severity: .soft),
                evidence: "HandshakeState.sentHello (awaiting JS ack)"
            )
        case .armed:
            return ProbeOutcome(
                status: .ok,
                evidence: "HandshakeState.armed — JS bus live"
            )
        case .mismatched(let swift, let js):
            // Round 4 — protocol mismatch is non-recoverable without rebuild.
            return ProbeOutcome(
                status: .failed(reason: "protocol version mismatch — Swift=\(swift), JS=\(js); rebuild webview bundle", severity: .critical),
                evidence: "HandshakeState.mismatched(\(swift), \(js))"
            )
        case .timedOut:
            return ProbeOutcome(
                status: .failed(reason: "JS never acked hello — webview bundle missing or crashed at startup", severity: .critical),
                evidence: "HandshakeState.timedOut after 2s"
            )
        case .loadFailed(let reason):
            // Audit-2026-05-12 S1 / #40 — bundle navigation failed before
            // `didFinish` could fire. Same severity as `.timedOut`: the
            // user sees no HUD until the bundle is rebuilt.
            return ProbeOutcome(
                status: .failed(reason: "webview bundle load failed: \(reason); rebuild webview bundle", severity: .critical),
                evidence: "HandshakeState.loadFailed(\(reason))"
            )
        }
    }
}

// MARK: - Dormant placeholder

/// Used when a subsystem never installed — e.g., `memoryStore` is nil
/// because `MemoryStore.init` threw at boot. We register this rather than
/// skipping registration so every subsystem has a row in the snapshot
/// (honest absence > silent omission).
public struct DormantSubsystemProbe: BootHealthProbe {
    public let name: String
    private let reason: String
    private let severity: FailureSeverity

    /// Round 4 — `severity` defaults to `.soft`. Callers wiring memory or
    /// MCP placeholders override to `.critical` so an outright-failed
    /// install doesn't get downgraded to "couldn't probe yet."
    public init(subsystemName: String, reason: String, severity: FailureSeverity = .soft) {
        self.name = subsystemName
        self.reason = reason
        self.severity = severity
    }

    public func probe() async -> ProbeOutcome {
        ProbeOutcome(
            status: .unknown(reason: reason, severity: severity),
            evidence: "subsystem actor unavailable at probe-registration time"
        )
    }
}

// MARK: - Helpers

private func authStatusName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}
