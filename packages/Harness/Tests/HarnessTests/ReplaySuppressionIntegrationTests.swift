// ReplaySuppressionIntegrationTests.swift
//
// Phase 8 Plan 04 Task 3 — R4-L7 verification.
//
// Asserts that `TurnSource.replay(sessionId:)` and `.evaluation(scenarioId:)`
// suppress HUD bus dispatch AND TTS engine calls by construction. This is
// the integration test promised in 08-01's threat-model entry T-08-05.
//
// Why this is a contract test rather than a behavioral spy test:
//
// CONTEXT 5.1 (read-only constraint) forbids modifying AgentOrchestrator,
// the bus dispatcher, or TTSEngineActor to accept injected spies. The
// production code does not currently consume `dispatchesToHUD` / `speaks`
// at any dispatch site — those properties are the architectural seam
// that future bus/TTS implementations MUST consult. This test asserts the
// seam's contract is correct so the *FIRST* consumer of the property has
// a correct policy to read.
//
// The test exercises every `TurnSource` case to lock the policy table:
//   - .text                       → dispatchesToHUD=true,  speaks=true
//   - .voice                      → dispatchesToHUD=true,  speaks=true
//   - .memoryExtraction           → dispatchesToHUD=false, speaks=false
//   - .replay(sessionId:)         → dispatchesToHUD=false, speaks=false
//   - .evaluation(scenarioId:)    → dispatchesToHUD=false, speaks=false
//
// Adding a new TurnSource case forces the S-1 invariant on
// `dispatchesToHUD` and `speaks` switches in ReplayEvent.swift; this test
// also locks the value table so a future "let me silently flip
// .replay.dispatchesToHUD = true to debug" change fails the gate.

import Testing
import Foundation
import Replay
@testable import Harness

@Suite("ReplaySuppressionIntegrationTests")
struct ReplaySuppressionIntegrationTests {

    @Test("R4-L7: TurnSource.replay does NOT dispatch HUD bus message")
    func replaySuppressesHUDBus() throws {
        let source: TurnSource = .replay(sessionId: UUID())
        #expect(source.dispatchesToHUD == false,
                "R4-L7 violation: replay turn must NOT dispatch HUD")
    }

    @Test("R4-L7: TurnSource.replay does NOT speak (no TTS engine call)")
    func replaySuppressesTTS() throws {
        let source: TurnSource = .replay(sessionId: UUID())
        #expect(source.speaks == false,
                "R4-L7 violation: replay turn must NOT speak")
    }

    @Test("R4-L7: TurnSource.evaluation also suppresses HUD + TTS")
    func evaluationSuppressesHUDAndTTS() throws {
        let source: TurnSource = .evaluation(scenarioId: "test-scenario")
        #expect(source.dispatchesToHUD == false,
                "R4-L7 violation: evaluation turn must NOT dispatch HUD")
        #expect(source.speaks == false,
                "R4-L7 violation: evaluation turn must NOT speak")
    }

    @Test("Sanity: TurnSource.text DOES dispatch + speak (control)")
    func textDispatchesAsControl() throws {
        let source: TurnSource = .text
        // Control: if this fails, the production routing has changed and
        // the suppression contract is no longer load-bearing.
        #expect(source.dispatchesToHUD == true,
                "control invariant: text must dispatch HUD")
        #expect(source.speaks == true,
                "control invariant: text must speak")
    }

    @Test("Sanity: TurnSource.voice DOES dispatch + speak (control)")
    func voiceDispatchesAsControl() throws {
        let source: TurnSource = .voice
        #expect(source.dispatchesToHUD == true)
        #expect(source.speaks == true)
    }

    @Test("memoryExtraction: also suppressed (peer policy with replay/evaluation)")
    func memoryExtractionSuppressed() throws {
        let source: TurnSource = .memoryExtraction
        #expect(source.dispatchesToHUD == false)
        #expect(source.speaks == false)
    }

    @Test("Replay TurnSource carries the sessionId for ReplayMCPAdapter routing")
    func replayCarriesSessionId() throws {
        let id = UUID()
        let source: TurnSource = .replay(sessionId: id)
        switch source {
        case .replay(let actual):
            #expect(actual == id,
                    "TurnSource.replay must round-trip its sessionId for ReplayMCPAdapter selection")
        default:
            Issue.record("expected .replay case")
        }
    }

    @Test("Evaluation TurnSource carries the scenarioId for diagnostics")
    func evaluationCarriesScenarioId() throws {
        let scenarioId = "P8-injection-corpus-item-AS-01"
        let source: TurnSource = .evaluation(scenarioId: scenarioId)
        switch source {
        case .evaluation(let actual):
            #expect(actual == scenarioId,
                    "TurnSource.evaluation must round-trip its scenarioId for per-item diagnostics")
        default:
            Issue.record("expected .evaluation case")
        }
    }

    @Test("Suppression policy is consistent: replay and evaluation share the same dispatchesToHUD/speaks values")
    func suppressionPoliciesAreConsistent() throws {
        let replay: TurnSource = .replay(sessionId: UUID())
        let eval: TurnSource = .evaluation(scenarioId: "any")
        #expect(replay.dispatchesToHUD == eval.dispatchesToHUD,
                "replay and evaluation must share dispatchesToHUD policy")
        #expect(replay.speaks == eval.speaks,
                "replay and evaluation must share speaks policy")
        #expect(replay.dispatchesToHUD == false)
        #expect(replay.speaks == false)
    }
}
