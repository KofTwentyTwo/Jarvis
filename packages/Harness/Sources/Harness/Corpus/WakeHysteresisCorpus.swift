import Foundation

/// One labeled WAV clip in the wake-hysteresis corpus.
///
/// Per D-18, the corpus is operator-recorded per host (the operator's own
/// voice + room background). `labels.json` ships empty by default; the
/// `Corpora/wake-hysteresis/README.md` documents the recording protocol.
public struct WakeClip: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    /// Filename relative to `Corpora/wake-hysteresis/` (must end in `.wav`).
    public let fileName: String
    public let label: Label
    public let durationSeconds: Double
    /// Free-form noise-profile tag — `quiet`, `speech-bg`, `music-bg`,
    /// `outdoor`, `synthetic-pink` are the conventional values.
    public let noiseProfile: String

    public enum Label: String, Sendable, Codable, Equatable {
        /// Clip contains the wake phrase ("hey jarvis"); session is
        /// expected to fire at least once.
        case positive
        /// Clip does NOT contain the wake phrase; session is expected to
        /// remain quiet through the entire clip.
        case negative
    }

    public init(
        id: String,
        fileName: String,
        label: Label,
        durationSeconds: Double,
        noiseProfile: String
    ) {
        self.id = id
        self.fileName = fileName
        self.label = label
        self.durationSeconds = durationSeconds
        self.noiseProfile = noiseProfile
    }
}

public struct WakeHysteresisCorpus: Sendable, Equatable {
    public let clips: [WakeClip]

    public init(clips: [WakeClip]) {
        self.clips = clips
    }

    public static func loadFromBundle() throws -> WakeHysteresisCorpus {
        guard let url = Bundle.module.url(
            forResource: "labels",
            withExtension: "json",
            subdirectory: "Corpora/wake-hysteresis"
        ) else {
            // Empty corpus is a valid scaffold per Plan 08-02 Task 3 — the
            // operator records clips on their host. The runner reports
            // `passed: false` with a diagnostic when the corpus is empty.
            return WakeHysteresisCorpus(clips: [])
        }
        let data = try Data(contentsOf: url)
        let clips = try JSONDecoder().decode([WakeClip].self, from: data)
        return WakeHysteresisCorpus(clips: clips)
    }

    public static func wavURL(for clip: WakeClip) throws -> URL {
        let basename = clip.fileName.replacingOccurrences(of: ".wav", with: "")
        guard let url = Bundle.module.url(
            forResource: basename,
            withExtension: "wav",
            subdirectory: "Corpora/wake-hysteresis"
        ) else {
            throw LoaderError.clipNotFound(id: clip.id, file: clip.fileName)
        }
        return url
    }

    public enum LoaderError: Swift.Error, Equatable {
        case clipNotFound(id: String, file: String)
    }
}
