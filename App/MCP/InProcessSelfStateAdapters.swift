// InProcessSelfStateAdapters.swift
//
// Plan 10-01 / Track D-2 pattern. Bridges JarvisMCP's self-knowledge tool
// dispatcher protocols (`AudioDeviceListing`, `ActiveAudioRouteDispatching`,
// `SelfStateDispatching`, `CameraDeviceListing`) to concrete runtime
// sources. These adapters live in App/ rather than packages/MCP/ because
// they cross the module boundary — JarvisMCP intentionally does NOT
// import Voice/AVFoundation/CoreAudio (Track D-2 design: protocol seam
// keeps MCP unaware of subsystem internals; mirrors the
// `InProcessMemoryAdapters.swift` shape from commit 707c45b).
//
// All four adapters are read-only. None require user confirmation
// (D-10). None cache (D-09 / AP-11) — every call queries fresh state.

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import JarvisMCP
import Voice

// MARK: - CoreAudio device enumeration (SELF-01)

/// Pure synchronous CoreAudio enumeration. ~80 LOC of
/// `AudioObjectGetPropertyData` boilerplate per RESEARCH §Example 1
/// (template: argmax-oss-swift WhisperKit AudioProcessor.swift:818-879).
enum CoreAudioIntrospection {

    enum CoreAudioError: Error {
        case size(OSStatus)
        case fetch(OSStatus)
    }

    /// Returns one entry per (device, direction) pair. A duplex device
    /// emits TWO entries — one with `isInput=true`, one with `isInput=false`.
    /// Devices with no streams in a given direction are skipped for that
    /// direction.
    static func snapshotDevices() throws -> [AudioDeviceEntry] {
        let allDeviceIDs = try fetchAllDeviceIDs()
        let defaultInputID = (try? fetchDefaultDeviceID(isInput: true)) ?? AudioDeviceID(0)
        let defaultOutputID = (try? fetchDefaultDeviceID(isInput: false)) ?? AudioDeviceID(0)

        var entries: [AudioDeviceEntry] = []
        entries.reserveCapacity(allDeviceIDs.count * 2)

        for deviceID in allDeviceIDs {
            // Resolve name + UID once per device.
            let name = (try? fetchString(
                deviceID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            )) ?? "<unknown>"
            let uid = (try? fetchString(
                deviceID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            )) ?? "<no-uid>"
            let sampleRate = (try? fetchSampleRate(deviceID: deviceID)) ?? 0

            // Probe each direction independently — most devices are
            // unidirectional, but Aggregate / VPIO devices can be both.
            for isInput in [true, false] {
                let scope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
                let channels = (try? fetchChannelCount(deviceID: deviceID, scope: scope)) ?? 0
                if channels == 0 { continue }   // direction not supported
                let isDefault = isInput
                    ? (deviceID == defaultInputID)
                    : (deviceID == defaultOutputID)
                let isActive = sampleRate > 0 && channels > 0
                entries.append(AudioDeviceEntry(
                    name: name,
                    uid: uid,
                    isDefault: isDefault,
                    isActive: isActive,
                    isInput: isInput,
                    sampleRate: sampleRate,
                    channels: channels
                ))
            }
        }

        return entries
    }

    /// Returns the UID of the system default input or output device, or
    /// nil if the query fails (rare — usually means no audio hardware).
    static func defaultDeviceUID(isInput: Bool) -> (uid: String, name: String)? {
        guard let id = try? fetchDefaultDeviceID(isInput: isInput),
              id != AudioDeviceID(0) else { return nil }
        let uid = try? fetchString(
            deviceID: id,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let name = try? fetchString(
            deviceID: id,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard let uid else { return nil }
        return (uid: uid, name: name ?? "<unknown>")
    }

    // MARK: - Private CoreAudio helpers

    private static func fetchAllDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr else { throw CoreAudioError.size(status) }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        guard status == noErr else { throw CoreAudioError.fetch(status) }
        return ids
    }

    private static func fetchDefaultDeviceID(isInput: Bool) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: isInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { throw CoreAudioError.fetch(status) }
        return deviceID
    }

    private static func fetchString(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = cfString else {
            throw CoreAudioError.fetch(status)
        }
        return s as String
    }

    private static func fetchSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr else { throw CoreAudioError.fetch(status) }
        return rate
    }

    private static func fetchChannelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError.size(status) }
        guard size > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        // Allocate enough room for the variable-length AudioBufferList tail.
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer {
            raw.deallocate()
            bufferList.deallocate()
        }
        let typedRaw = raw.bindMemory(to: AudioBufferList.self, capacity: Int(size))
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, typedRaw)
        guard status == noErr else { throw CoreAudioError.fetch(status) }
        let abl = UnsafeMutableAudioBufferListPointer(typedRaw)
        var channels = 0
        for buffer in abl {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }
}

// MARK: - SELF-01 adapter

/// Bridges `ListAudioDevicesTool` to `CoreAudioIntrospection.snapshotDevices()`.
/// Stateless. No caching (D-09).
public struct CoreAudioDeviceListAdapter: AudioDeviceListing {
    public init() {}
    public func listAudioDevices() async throws -> [AudioDeviceEntry] {
        try CoreAudioIntrospection.snapshotDevices()
    }
}

// MARK: - SELF-02 adapter

/// Bridges `GetActiveAudioRouteTool` to `AudioGraphOwner.activeRouteSnapshot()`.
/// Hops into the actor on each call. Resolves the input/output device
/// UID + name via CoreAudio (the AudioGraph itself doesn't expose these;
/// `AudioGraphOwner.activeRouteSnapshot()` returns only sampleRate +
/// channels from the probed format — see Plan 10-01 design notes).
public actor AudioGraphRouteAdapter: ActiveAudioRouteDispatching {

    private let owner: AudioGraphOwner

    public init(owner: AudioGraphOwner) {
        self.owner = owner
    }

    public func getActiveAudioRoute() async throws -> ActiveAudioRoute? {
        guard let variant = await owner.currentVariant else { return nil }
        guard let snap = await owner.activeRouteSnapshot() else { return nil }
        let input = CoreAudioIntrospection.defaultDeviceUID(isInput: true)
        let output = CoreAudioIntrospection.defaultDeviceUID(isInput: false)
        let variantStr: String = {
            switch variant {
            case .aecOn:  return "aecOn"
            case .aecOff: return "aecOff"
            }
        }()
        return ActiveAudioRoute(
            inputDeviceUID:   input?.uid,
            inputDeviceName:  input?.name,
            outputDeviceUID:  output?.uid,
            outputDeviceName: output?.name,
            sampleRate: snap.sampleRate,
            channels: snap.channels,
            variant: variantStr
        )
    }
}

// MARK: - SELF-03 adapter

/// Bridges `GetSelfStateTool` to `Bundle.main.infoDictionary` +
/// `ProcessInfo` + closure-injected probes for actor-isolated state
/// (provider, voice loop state, TTS tier, STT backend, wake-word mute).
///
/// Closures keep the adapter free of `Voice` / `Config` actor imports —
/// AppDelegate constructs the closures with live references at install
/// time. This avoids deadlock if the adapter is invoked from the agent
/// loop while one of those actors is mid-transition: the hops await
/// naturally rather than block.
public struct SelfStateAdapter: SelfStateDispatching {

    public typealias ProviderIdentity = (provider: String, model: String)

    private let bundle: Bundle
    private let launchInstant: Date
    private let providerIdentity: @Sendable () async -> ProviderIdentity
    private let voiceState:       @Sendable () async -> String?
    private let ttsTier:          @Sendable () async -> String
    private let sttBackend:       @Sendable () async -> String
    private let wakeWordMuted:    @Sendable () async -> Bool

    public init(
        bundle: Bundle = .main,
        launchInstant: Date,
        providerIdentity: @escaping @Sendable () async -> ProviderIdentity,
        voiceState:       @escaping @Sendable () async -> String?,
        ttsTier:          @escaping @Sendable () async -> String,
        sttBackend:       @escaping @Sendable () async -> String,
        wakeWordMuted:    @escaping @Sendable () async -> Bool
    ) {
        self.bundle = bundle
        self.launchInstant = launchInstant
        self.providerIdentity = providerIdentity
        self.voiceState = voiceState
        self.ttsTier = ttsTier
        self.sttBackend = sttBackend
        self.wakeWordMuted = wakeWordMuted
    }

    public func getSelfState() async -> SelfState {
        let info = bundle.infoDictionary ?? [:]
        let appName    = (info["CFBundleName"] as? String) ?? "Jarvis"
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let buildMode: String = {
            #if DEBUG
            return "debug"
            #else
            return "release"
            #endif
        }()
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let uptime = max(0, Int(Date().timeIntervalSince(launchInstant)))
        let provider = await providerIdentity()
        return SelfState(
            appName: appName,
            appVersion: appVersion,
            buildMode: buildMode,
            pid: pid,
            uptimeSeconds: uptime,
            llmProvider: provider.provider,
            llmModel: provider.model,
            ttsTier: await ttsTier(),
            sttBackend: await sttBackend(),
            wakeWordMuted: await wakeWordMuted(),
            voiceLoopState: await voiceState() ?? "idle"
        )
    }
}

// MARK: - SELF-04 adapter

/// Bridges `ListCameraDevicesTool` to `AVCaptureDevice.DiscoverySession`.
/// Read-only; does NOT trigger camera TCC prompt (RESEARCH §Example 2).
public struct AVCaptureDeviceListAdapter: CameraDeviceListing {

    public init() {}

    public func listCameraDevices() async throws -> [CameraDeviceEntry] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { dev in
            CameraDeviceEntry(
                localizedName: dev.localizedName,
                uniqueID: dev.uniqueID,
                isConnected: dev.isConnected,
                position: Self.positionString(dev.position)
            )
        }
    }

    private static func positionString(_ p: AVCaptureDevice.Position) -> String {
        switch p {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "external"
        @unknown default: return "unknown"
        }
    }
}
