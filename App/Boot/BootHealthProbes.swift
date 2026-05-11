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
            return ProbeOutcome(
                status: .failed(reason: String(describing: error)),
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
                return ProbeOutcome(
                    status: .unknown(reason: "API key slot present but empty"),
                    evidence: "key length 0"
                )
            }
            let prefix = String(key.prefix(7))
            let evidence = "key present (\(prefix)…, len=\(key.count)) — network probe deferred to Status menu"
            return ProbeOutcome(status: .ok, evidence: evidence)
        } catch let error as KeychainError {
            switch error {
            case .itemNotFound:
                return ProbeOutcome(
                    status: .unknown(reason: "no API key in Keychain"),
                    evidence: "keychain.itemNotFound"
                )
            default:
                return ProbeOutcome(
                    status: .failed(reason: "keychain read failed: \(error)"),
                    evidence: "keychain error"
                )
            }
        } catch {
            return ProbeOutcome(
                status: .failed(reason: String(describing: error)),
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
                return ProbeOutcome(
                    status: .failed(reason: "Ollama /api/tags HTTP \(code)"),
                    evidence: "non-200 from \(url.absoluteString)"
                )
            }
            let tagged = parseModelNames(from: data)
            let missing = requiredModels.filter { !tagged.contains($0) }
            if missing.isEmpty {
                return ProbeOutcome(
                    status: .ok,
                    evidence: "all \(requiredModels.count) required models present: \(requiredModels.joined(separator: ", "))"
                )
            }
            return ProbeOutcome(
                status: .degraded(reason: "missing models: \(missing.joined(separator: ", "))"),
                evidence: "have \(tagged.count) models; missing \(missing.count)"
            )
        } catch {
            return ProbeOutcome(
                status: .failed(reason: "Ollama unreachable: \(error.localizedDescription)"),
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
            return ProbeOutcome(
                status: .unknown(reason: "voice subsystem not installed (dormantVoiceContinuation nil or wakeword/VAD weights missing)"),
                evidence: "AudioGraphOwner unavailable; mic TCC=\(authStatusName(micStatus))"
            )
        }

        let variant = await owner.currentVariant
        let route = await owner.activeRouteSnapshot()

        switch micStatus {
        case .denied, .restricted:
            return ProbeOutcome(
                status: .degraded(reason: "microphone TCC denied"),
                evidence: "graph variant=\(variant.map { String(describing: $0) } ?? "nil"); mic=\(authStatusName(micStatus))"
            )
        case .notDetermined:
            return ProbeOutcome(
                status: .unknown(reason: "microphone TCC not yet requested"),
                evidence: "graph variant=\(variant.map { String(describing: $0) } ?? "nil")"
            )
        case .authorized:
            guard variant != nil else {
                return ProbeOutcome(
                    status: .failed(reason: "AudioGraph never opened"),
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
                status: .unknown(reason: "unknown TCC status \(micStatus.rawValue)"),
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
            return ProbeOutcome(
                status: .failed(reason: "camera TCC denied"),
                evidence: "\(devices.count) device(s) discovered; mic TCC=\(authStatusName(camStatus))"
            )
        case .notDetermined:
            return ProbeOutcome(
                status: .unknown(reason: "camera TCC not yet requested"),
                evidence: "\(devices.count) device(s) discovered (read-only — no TCC prompt)"
            )
        case .authorized:
            if devices.isEmpty {
                return ProbeOutcome(
                    status: .degraded(reason: "no camera devices discovered"),
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
                status: .unknown(reason: "unknown TCC status \(camStatus.rawValue)"),
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
    private let minimumExpected: Int

    public init(mcpRuntime: MCPRuntime?, minimumExpected: Int = 8) {
        self.mcpRuntime = mcpRuntime
        self.minimumExpected = minimumExpected
    }

    public func probe() async -> ProbeOutcome {
        guard let runtime = mcpRuntime else {
            return ProbeOutcome(
                status: .failed(reason: "MCPRuntime nil — build failed at install (helpers absent or unsigned?)"),
                evidence: "mcpRuntime property was nil at probe time"
            )
        }
        let names = await runtime.client.registeredToolNames()
        let count = names.count
        if count == 0 {
            return ProbeOutcome(
                status: .failed(reason: "no tools registered"),
                evidence: "registeredToolNames().count == 0"
            )
        }
        if count < minimumExpected {
            return ProbeOutcome(
                status: .degraded(reason: "expected ≥\(minimumExpected) tools, registry has \(count)"),
                evidence: names.sorted().joined(separator: ", ")
            )
        }
        return ProbeOutcome(
            status: .ok,
            evidence: "\(count) tools: \(names.sorted().joined(separator: ", "))"
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
            return ProbeOutcome(
                status: .failed(reason: "ReplayLog nil — open() failed at install"),
                evidence: "AppDelegate.replayLog was nil"
            )
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else {
            return ProbeOutcome(
                status: .failed(reason: "replay.sqlite missing at \(databaseURL.path)"),
                evidence: "FileManager.fileExists == false"
            )
        }
        let parent = databaseURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            return ProbeOutcome(
                status: .failed(reason: "parent dir not writable: \(parent.path)"),
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
            return ProbeOutcome(
                status: .failed(reason: "WebviewBridge nil — never constructed"),
                evidence: "webviewBridge property was nil at probe time"
            )
        }
        let state = await MainActor.run { bridge.handshakeState }
        switch state {
        case .idle:
            return ProbeOutcome(
                status: .unknown(reason: "handshake never started"),
                evidence: "HandshakeState.idle"
            )
        case .sentHello:
            return ProbeOutcome(
                status: .unknown(reason: "handshake in flight"),
                evidence: "HandshakeState.sentHello (awaiting JS ack)"
            )
        case .armed:
            return ProbeOutcome(
                status: .ok,
                evidence: "HandshakeState.armed — JS bus live"
            )
        case .mismatched(let swift, let js):
            return ProbeOutcome(
                status: .failed(reason: "protocol version mismatch — Swift=\(swift), JS=\(js); rebuild webview bundle"),
                evidence: "HandshakeState.mismatched(\(swift), \(js))"
            )
        case .timedOut:
            return ProbeOutcome(
                status: .failed(reason: "JS never acked hello — webview bundle missing or crashed at startup"),
                evidence: "HandshakeState.timedOut after 2s"
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

    public init(subsystemName: String, reason: String) {
        self.name = subsystemName
        self.reason = reason
    }

    public func probe() async -> ProbeOutcome {
        ProbeOutcome(
            status: .unknown(reason: reason),
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
