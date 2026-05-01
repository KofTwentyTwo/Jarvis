import Testing
import Foundation
@testable import Harness

/// OBS-04 pillar (e) tests — WakeHysteresisRunner D-18 thresholds.
///
/// Live full-pipeline tests (real ONNX session over real WAV) require
/// `JARVIS_WAKE_MODEL_DIR` and a non-empty operator-recorded corpus, so
/// they live behind that env gate. The tests below cover the empty-
/// corpus short-circuit + the D-18 PASS/WARN predicate at all four
/// canonical points.
@Suite("WakeHysteresisRunnerTests")
struct WakeHysteresisRunnerTests {

    // MARK: - Empty-corpus path

    @Test("Empty corpus returns passed:false with a recording-protocol diagnostic")
    func emptyCorpusReturnsDiagnostic() async throws {
        let runner = WakeHysteresisRunner()
        let report = try await runner.run(corpus: WakeHysteresisCorpus(clips: []))
        #expect(report.totalClips == 0)
        #expect(report.passed == false,
                "empty corpus must short-circuit `passed: false` — bare 0/0 thresholds otherwise pass")
        #expect(report.diagnostic != nil)
        let diag = report.diagnostic ?? ""
        #expect(diag.contains("empty"))
        #expect(diag.contains("README.md"),
                "diagnostic should route the operator to the recording protocol")
    }

    @Test("Seed corpus has both positive and negative clips")
    func seedCorpusHasBothLabels() throws {
        // Post-P8 deferral closeout populated the corpus with TTS-synthesized
        // clips (5 TP "Hey Jarvis" + 5 TN unrelated phrases) so the harness
        // exercises end-to-end inference instead of the empty diagnostic
        // path. Operators replace these with host-recorded clips per the
        // README protocol; the contract is BOTH labels present, not exact count.
        let corpus = try WakeHysteresisCorpus.loadFromBundle()
        #expect(!corpus.clips.isEmpty,
                "seed corpus ships TTS-synthesized clips; operator augments per-host")
        #expect(corpus.clips.contains { $0.label == .positive },
                "corpus must include at least one positive (Hey Jarvis) clip")
        #expect(corpus.clips.contains { $0.label == .negative },
                "corpus must include at least one negative clip")
    }

    // MARK: - D-18 PASS predicate

    @Test("PASS at FAR=0/hr FRR=4.76% (100 TP / 5 FN / 0 FP / 100 TN over 600s)")
    func d18PassAtTypicalCounts() {
        // 100 positives where 95 fired + 5 missed; 100 negatives where
        // none fired; 600 s of audio. FAR = 0/hr; FRR = 5/105 ≈ 4.76%.
        let report = makeMockReport(
            tp: 100, fn: 5, fp: 0, tn: 100,
            durationSeconds: 600
        )
        #expect(report.passed == true)
        #expect(report.warned == false)
    }

    // MARK: - D-18 FAIL boundary (FAR)

    @Test("FAIL at FAR=2.0/hr (2 FP over 3600s)")
    func d18FailWhenFARExceeds1() {
        let report = makeMockReport(
            tp: 10, fn: 0, fp: 2, tn: 10,
            durationSeconds: 3600
        )
        #expect(report.farPerHour == 2.0)
        #expect(report.passed == false,
                "FAR > 1.0/hr must fail per D-18")
    }

    // MARK: - D-18 FAIL boundary (FRR)

    @Test("FAIL at FRR=15% (3 FN over 20 positives)")
    func d18FailWhenFRRExceeds10() {
        let report = makeMockReport(
            tp: 17, fn: 3, fp: 0, tn: 10,
            durationSeconds: 600
        )
        #expect(abs(report.frrPercent - 15.0) < 0.001)
        #expect(report.passed == false,
                "FRR > 10% must fail per D-18")
    }

    // MARK: - D-18 WARN-only zone (passes but flags)

    @Test("WARN at FAR=0.6/hr (passes but warned=true)")
    func d18WarnZoneFAR() {
        // 0.6 FP/hr is between the 0.5 warn threshold and the 1.0 fail
        // threshold. We can't synthesize 0.6 FP literally from integer
        // counts, but 1 FP over 6000 s ≈ 0.6/hr is exactly the warn zone.
        let report = makeMockReport(
            tp: 30, fn: 0, fp: 1, tn: 30,
            durationSeconds: 6000
        )
        #expect(report.farPerHour > 0.5)
        #expect(report.farPerHour <= 1.0)
        #expect(report.passed == true)
        #expect(report.warned == true,
                "FAR > 0.5/hr but <= 1.0/hr must warn without failing")
    }

    @Test("WARN at FRR=7% (passes but warned=true)")
    func d18WarnZoneFRR() {
        // 7 / 100 = 7%, between 5% warn and 10% fail.
        let report = makeMockReport(
            tp: 93, fn: 7, fp: 0, tn: 50,
            durationSeconds: 600
        )
        #expect(abs(report.frrPercent - 7.0) < 0.001)
        #expect(report.passed == true)
        #expect(report.warned == true)
    }

    // MARK: - Helpers

    /// Construct a `WakeReport` directly with synthesized counts. Used to
    /// exercise the threshold predicate without needing real audio.
    private func makeMockReport(
        tp: Int, fn: Int, fp: Int, tn: Int,
        durationSeconds: Double
    ) -> WakeHysteresisRunner.WakeReport {
        let frrDenom = max(1, tp + fn)
        let frr = Double(fn) / Double(frrDenom) * 100.0
        let hours = durationSeconds / 3600.0
        let far = hours > 0 ? Double(fp) / hours : 0
        return WakeHysteresisRunner.WakeReport(
            totalClips: tp + fn + fp + tn,
            totalDurationSeconds: durationSeconds,
            truePositives: tp,
            falseNegatives: fn,
            falsePositives: fp,
            trueNegatives: tn,
            farPerHour: far,
            frrPercent: frr,
            diagnostic: nil,
            pipelineStatus: .ok,
            performanceStatus: .pass,
            isSyntheticCorpus: false
        )
    }

    // MARK: - PIPELINE / PERFORMANCE distinction

    @Test("Synthetic-only corpus is recognised as seed scaffolding")
    func syntheticCorpusDetection() {
        let synth = WakeHysteresisCorpus(clips: [
            WakeClip(id: "s1", fileName: "s1.wav", label: .positive,
                     durationSeconds: 1.0, noiseProfile: "synthetic-pink"),
            WakeClip(id: "s2", fileName: "s2.wav", label: .negative,
                     durationSeconds: 1.0, noiseProfile: "synthetic-tts"),
        ])
        #expect(WakeHysteresisRunner.isAllSynthetic(synth))

        let mixed = WakeHysteresisCorpus(clips: [
            WakeClip(id: "s1", fileName: "s1.wav", label: .positive,
                     durationSeconds: 1.0, noiseProfile: "synthetic-pink"),
            WakeClip(id: "r1", fileName: "r1.wav", label: .positive,
                     durationSeconds: 1.0, noiseProfile: "quiet"),
        ])
        #expect(!WakeHysteresisRunner.isAllSynthetic(mixed))

        // Empty corpus → `true` so the empty-corpus branch reports
        // PIPELINE NOT WIRED + PERFORMANCE PENDING (the strict diagnostic).
        #expect(WakeHysteresisRunner.isAllSynthetic(WakeHysteresisCorpus(clips: [])))
    }
}
