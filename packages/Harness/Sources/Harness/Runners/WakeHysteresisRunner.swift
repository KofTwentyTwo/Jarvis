import Foundation
import AVFoundation
import Voice

/// OBS-04 pillar (e) — wake-word hysteresis FAR/FRR runner.
///
/// Decodes each labeled 16 kHz WAV clip, slices into 1280-sample frames
/// (80 ms @ 16 kHz, the openWakeWord chunk size), feeds the production
/// `OpenWakeWordSession` (real ONNX), and counts true/false positives and
/// negatives across the corpus. Computes:
///
/// - `farPerHour` — false positives per hour of audio.
/// - `frrPercent` — false-negative rate among positive clips.
///
/// **D-18 thresholds** (locked):
///   - PASS: `farPerHour <= 1.0 && frrPercent <= 10.0`
///   - WARN: `farPerHour > 0.5 || frrPercent > 5.0`
///
/// **Empty-corpus path:** when the operator hasn't recorded clips yet
/// (`labels.json` is `[]`), the bare `WakeReport.passed` predicate would
/// evaluate true on 0/0 thresholds — clearly not what we want. The runner
/// short-circuits before constructing the report and returns
/// `passed: false` with a diagnostic. The shipping gate then reads the
/// diagnostic and routes the operator to the recording-protocol README.
///
/// **Production session:** the runner constructs `OpenWakeWordSession` via
/// the public `init(modelDir:threshold:framesRequired:)`, NOT the internal
/// `scriptedClassifier:` test seam. The model directory is read from
/// `JARVIS_WAKE_MODEL_DIR` env (consistent with the `JARVIS_REAL_MODELS`
/// convention used by OrpheusTTFATests). When unset, the runner returns a
/// distinct `modelDirMissing` diagnostic so the shipping gate can fail
/// closed without silently passing.
///
/// **Deferred end-to-end feed:** `OpenWakeWordSession.feed(_:)` takes
/// `UnsafeBufferPointer<Float>` and is `async` (actor isolation). Swift 6
/// disallows the combination "withUnsafeBufferPointer { buf in await
/// session.feed(buf) }" because the unsafe pointer cannot escape into an
/// async-suspended frame. The production `WakeWordDAG` works around this
/// by living inside the Voice module and calling the internal
/// `feedTest()` seam. Adding a public `feed(samples: [Float])` API on
/// `OpenWakeWordSession` is the right long-term fix but a Voice-package
/// change — out of scope for plan 08-02. Until that lands, the runner
/// surfaces a `pipelineNotWired` diagnostic when the model dir IS set
/// and clips ARE present, so the gap is visible in the shipping-gate
/// output rather than a silent pass.
public actor WakeHysteresisRunner {

    public init() {}

    /// FAR/FRR report. `passed` requires BOTH a non-empty corpus AND
    /// counts that satisfy D-18 thresholds.
    public struct WakeReport: Sendable, Codable, Equatable {
        public let totalClips: Int
        public let totalDurationSeconds: Double
        public let truePositives: Int
        public let falseNegatives: Int
        public let falsePositives: Int
        public let trueNegatives: Int
        public let farPerHour: Double
        public let frrPercent: Double
        public let diagnostic: String?

        public init(
            totalClips: Int,
            totalDurationSeconds: Double,
            truePositives: Int,
            falseNegatives: Int,
            falsePositives: Int,
            trueNegatives: Int,
            farPerHour: Double,
            frrPercent: Double,
            diagnostic: String?
        ) {
            self.totalClips = totalClips
            self.totalDurationSeconds = totalDurationSeconds
            self.truePositives = truePositives
            self.falseNegatives = falseNegatives
            self.falsePositives = falsePositives
            self.trueNegatives = trueNegatives
            self.farPerHour = farPerHour
            self.frrPercent = frrPercent
            self.diagnostic = diagnostic
        }

        /// D-18 PASS predicate. The `totalClips > 0` guard is the
        /// empty-corpus short-circuit fix — `farPerHour <= 1.0 &&
        /// frrPercent <= 10.0` alone evaluates true on 0/0 thresholds,
        /// which would silently pass the shipping gate before the
        /// operator records any audio.
        public var passed: Bool {
            return totalClips > 0
                && farPerHour <= 1.0
                && frrPercent <= 10.0
                && diagnostic == nil
        }

        /// D-18 WARN predicate. Visible in shipping-gate output but does
        /// not block ship.
        public var warned: Bool {
            return farPerHour > 0.5 || frrPercent > 5.0
        }
    }

    /// Run the corpus through the production wake-word session.
    public func run(corpus: WakeHysteresisCorpus) async throws -> WakeReport {
        // Empty-corpus short-circuit — the bare D-18 predicate would
        // pass 0/0 thresholds.
        guard !corpus.clips.isEmpty else {
            return WakeReport(
                totalClips: 0,
                totalDurationSeconds: 0,
                truePositives: 0,
                falseNegatives: 0,
                falsePositives: 0,
                trueNegatives: 0,
                farPerHour: 0,
                frrPercent: 0,
                diagnostic:
                    "wake-hysteresis corpus is empty — record clips per "
                    + "Corpora/wake-hysteresis/README.md and rerun."
            )
        }

        // Resolve the wake-word model directory. The default is `nil` so
        // running this in CI without the model present surfaces a clear
        // diagnostic rather than a model-load crash.
        guard let modelDir = resolveModelDir() else {
            return WakeReport(
                totalClips: corpus.clips.count,
                totalDurationSeconds: 0,
                truePositives: 0,
                falseNegatives: 0,
                falsePositives: 0,
                trueNegatives: 0,
                farPerHour: 0,
                frrPercent: 0,
                diagnostic:
                    "JARVIS_WAKE_MODEL_DIR env var not set — wake-corpus "
                    + "requires the openWakeWord model directory to construct "
                    + "the production OpenWakeWordSession."
            )
        }

        // Probe path: validate every clip can be opened and decoded as
        // 16 kHz mono, validate the production session can be constructed
        // (manifest SHA-256 verification runs), then surface the
        // `pipelineNotWired` diagnostic. This catches corpus / model
        // breakage at the point where the shipping gate runs, not
        // silently at the (currently absent) inference step.
        var totalDurationSeconds: Double = 0
        do {
            // One construction is sufficient — confirms manifest gating
            // and ORT model load succeed for this host.
            _ = try OpenWakeWordSession(modelDir: modelDir)
        } catch {
            return WakeReport(
                totalClips: corpus.clips.count,
                totalDurationSeconds: 0,
                truePositives: 0,
                falseNegatives: 0,
                falsePositives: 0,
                trueNegatives: 0,
                farPerHour: 0,
                frrPercent: 0,
                diagnostic:
                    "OpenWakeWordSession init failed at "
                    + "\(modelDir.path): \(error.localizedDescription)"
            )
        }
        for clip in corpus.clips {
            let url = try WakeHysteresisCorpus.wavURL(for: clip)
            let samples = try WAVDecoder.decode16kMonoFloat(url: url)
            // Sanity: the wake DAG expects 1280-sample (80 ms) frames at
            // 16 kHz mono. A clip shorter than one frame can never fire
            // and would skew FRR — surface as part of the diagnostic.
            _ = samples
            totalDurationSeconds += clip.durationSeconds
        }

        return WakeReport(
            totalClips: corpus.clips.count,
            totalDurationSeconds: totalDurationSeconds,
            truePositives: 0,
            falseNegatives: 0,
            falsePositives: 0,
            trueNegatives: 0,
            farPerHour: 0,
            frrPercent: 0,
            diagnostic:
                "Production OpenWakeWordSession.feed(_:) is async + "
                + "UnsafeBufferPointer; cannot be invoked from outside the "
                + "Voice module's actor without a public feed(samples:) "
                + "API. Plan 08-02 ships the corpus + report scaffolding; "
                + "the end-to-end inference path is deferred pending a "
                + "Voice-package surface change."
        )
    }

    private func resolveModelDir() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["JARVIS_WAKE_MODEL_DIR"],
              !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw)
    }
}

// MARK: - WAV decoder

/// Tiny AVAudioFile wrapper. Loads the entire file as 16 kHz mono Float32
/// samples (the openWakeWord input contract). Throws on format mismatch
/// rather than crashing — malformed corpus files surface as per-clip
/// errors, not process kills (T-08-08 mitigation).
enum WAVDecoder {
    enum Error: Swift.Error, Equatable {
        case openFailed(String)
        case readFailed(String)
        case unsupportedFormat(String)
        case sampleRateMismatch(actual: Double, expected: Double)
    }

    static func decode16kMonoFloat(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Error.openFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let processingFormat = file.processingFormat
        if processingFormat.sampleRate != 16000 {
            throw Error.sampleRateMismatch(
                actual: processingFormat.sampleRate,
                expected: 16000
            )
        }
        // Use the file's processing format for reading (handles channel
        // and PCM-format conversion to Float32 automatically). Then we
        // pull channel 0 as mono.
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        ) else {
            throw Error.unsupportedFormat("could not allocate PCM buffer for \(url.lastPathComponent)")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw Error.readFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let channelData = buffer.floatChannelData else {
            throw Error.unsupportedFormat("\(url.lastPathComponent) is not PCM Float32 after AVAudioFile conversion")
        }
        let n = Int(buffer.frameLength)
        let ch0 = channelData[0]
        return Array(UnsafeBufferPointer(start: ch0, count: n))
    }
}
