/// Errors thrown by STT providers.
public enum STTError: Error, Sendable {
    /// The requested STT backend is not available on this OS version or configuration.
    case backendUnavailable(String)

    /// The `com.apple.developer.speech-recognition-assets` entitlement is missing or
    /// the on-device speech recognition assets could not be downloaded.
    ///
    /// AUDIT-R2-S5: This entitlement is load-bearing for SpeechAnalyzer on macOS 26 Tahoe.
    /// Verify via `scripts/probe-speech-assets.sh` at scaffold-time.
    case assetMissing

    /// The final transcript could not be produced (e.g. the analyzer threw during finish()).
    case finalizationFailed(underlying: Error)
}
