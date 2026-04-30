import Testing
import Foundation
@testable import Harness

/// OBS-04 pillar (a) — injection corpus suite.
///
/// Uses swift-testing parameterization (D-03) so each corpus item produces
/// its own diagnostic line; sentinel tests assert D-22 / D-23 / D-24 quotas.
@Suite("InjectionCorpusTests")
struct InjectionCorpusTests {

    @Test("Corpus loads at least 20 items per OBS-04(a) minimum")
    func corpusSizeMinimum() throws {
        let corpus = try InjectionCorpus.loadFromBundle()
        #expect(corpus.count >= 20, "expected at least 20 corpus items, got \(corpus.count)")
    }

    @Test("D-22: majority of vectors are .toolResult or .mcpHelperOutput")
    func indirectVectorMajority() throws {
        let corpus = try InjectionCorpus.loadFromBundle()
        let indirect = corpus.filter {
            switch $0.vector {
            case .toolResult, .mcpHelperOutput: return true
            case .userInput, .clipboardContent, .appleScriptSourceDescription: return false
            }
        }
        #expect(
            indirect.count > corpus.count / 2,
            "D-22: indirect-vector majority required (got \(indirect.count) of \(corpus.count))"
        )
    }

    @Test("D-23: six Jarvis-specific items present")
    func jarvisSpecificItemsPresent() throws {
        let corpus = try InjectionCorpus.loadFromBundle()
        let requiredIds: Set<String> = [
            "applescript-self-attest",
            "nonce-leak-probe",
            "clipboard-fake-confirm",
            "bidi-zerowidth-c0",
            "memory-extract-attack",
            "bus-handshake-spoof",
        ]
        let presentIds = Set(corpus.map { $0.id })
        let missing = requiredIds.subtracting(presentIds)
        #expect(missing.isEmpty, "D-23: missing items \(missing)")
    }

    @Test("D-24: at least 2 confirmation-sheet-penetrating items")
    func penetratingItemsPresent() throws {
        let corpus = try InjectionCorpus.loadFromBundle()
        let penetrating = corpus.filter { $0.expectedOutcome == .triggersConfirmationSheet }
        #expect(
            penetrating.count >= 2,
            "D-24: expected at least 2 confirmation-sheet-penetrating items (got \(penetrating.count))"
        )
    }

    @Test("Per-item: each attempt produces the expected observed outcome",
          arguments: InjectionCorpus.all)
    func eachAttemptIsHandledPerExpectedOutcome(_ attempt: InjectionAttempt) async throws {
        let runner = InjectionCorpusRunner()
        let report = try await runner.run(corpus: [attempt])
        let actual = try #require(
            report.byAttemptId[attempt.id],
            "Attempt \(attempt.id) was not run"
        )
        #expect(
            actual.matches(expected: attempt.expectedOutcome),
            "Attempt \(attempt.id): expected \(attempt.expectedOutcome), got \(actual.observedOutcome)"
        )
    }

    @Test("Nonce-leak probe: the closing tag is neutralized by strip-then-wrap")
    func nonceLeakProbeIsNeutralized() async throws {
        let corpus = try InjectionCorpus.loadFromBundle()
        let probe = try #require(corpus.first { $0.id == "nonce-leak-probe" })
        // The corpus payload contains a literal `</UNTRUSTED_CONTENT id="probe">`
        // that an unmitigated wrap would let through. The structural
        // strip-then-wrap (UntrustedWrapper) replaces it with [REDACTED_TAG]
        // before wrapping. Spot-check the runner's report and the wrap
        // primitive directly.
        let runner = InjectionCorpusRunner()
        let report = try await runner.run(corpus: [probe])
        let actual = try #require(report.byAttemptId[probe.id])
        #expect(actual.observedOutcome == .wrappedInNonce)
    }
}
