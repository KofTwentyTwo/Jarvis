import XCTest
@testable import Jarvis
@testable import Voice

/// Coverage for the three voice watchdog probes added in
/// audit-2026-05-12 P1-2 / Issue #33. Each probe distinguishes "voice
/// plumbed" from "voice will actually work" — the prior
/// `VoiceBootHealthProbe` reported `ok` even after wake-word died
/// (P0-1) or TTS was never wired.
final class VoiceWatchdogProbesTests: XCTestCase {

    // MARK: - WakeWordBootHealthProbe

    /// W1: nil isArmed (DAG never installed) → `.unknown` soft.
    func test_W1_wakeWord_nilDAG_isUnknownSoft() async {
        let probe = WakeWordBootHealthProbe(isArmed: { nil })
        let outcome = await probe.probe()
        switch outcome.status {
        case .unknown(_, let severity):
            XCTAssertEqual(severity, .soft, "DAG-never-installed must be soft severity")
        default:
            XCTFail("expected .unknown for nil DAG, got \(outcome.status)")
        }
    }

    /// W2: armed feed → `.ok`.
    func test_W2_wakeWord_armed_isOk() async {
        let probe = WakeWordBootHealthProbe(isArmed: { true })
        let outcome = await probe.probe()
        switch outcome.status {
        case .ok:
            break
        default:
            XCTFail("expected .ok for armed feed, got \(outcome.status)")
        }
    }

    /// W3 (Issue #33 regression): DAG installed but feed not armed →
    /// `.failed` loud. This is the canonical post-P0-1 silent-death
    /// scenario the watchdog must catch.
    func test_W3_wakeWord_notArmed_isFailedLoud() async {
        let probe = WakeWordBootHealthProbe(isArmed: { false })
        let outcome = await probe.probe()
        switch outcome.status {
        case .failed(_, let severity):
            XCTAssertEqual(severity, .loud, "DAG-dead must be loud severity")
        default:
            XCTFail("expected .failed for dead DAG, got \(outcome.status). Evidence: \(outcome.evidence)")
        }
    }

    // MARK: - TTSBootHealthProbe

    /// T1: engine wired → `.ok`.
    func test_T1_tts_engineAlive_isOk() async {
        let probe = TTSBootHealthProbe(engineAlive: { true })
        let outcome = await probe.probe()
        switch outcome.status {
        case .ok:
            break
        default:
            XCTFail("expected .ok for live engine, got \(outcome.status)")
        }
    }

    /// T2 (Issue #33 regression): engine nil (dormant adapter) →
    /// `.degraded` loud. Pre-Track-B-3, `VoiceTTSAdapter(engine: nil)`
    /// was the production state and synth calls no-op'd silently. The
    /// watchdog must surface that today.
    func test_T2_tts_engineNil_isDegradedLoud() async {
        let probe = TTSBootHealthProbe(engineAlive: { false })
        let outcome = await probe.probe()
        switch outcome.status {
        case .degraded(_, let severity):
            XCTAssertEqual(severity, .loud, "dormant TTS must be loud severity")
        default:
            XCTFail("expected .degraded for nil engine, got \(outcome.status)")
        }
    }

    // MARK: - STTBootHealthProbe

    /// S1: STT probe runs and produces some outcome. The exact status
    /// depends on the host's `SFSpeechRecognizer` authorization state;
    /// we just assert the probe doesn't crash and produces evidence.
    func test_S1_stt_probeRunsWithoutCrash() async {
        let probe = STTBootHealthProbe()
        let outcome = await probe.probe()
        XCTAssertFalse(outcome.evidence.isEmpty, "STT probe must produce evidence")
    }
}
