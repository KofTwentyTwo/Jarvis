import XCTest
@testable import Jarvis

final class HudStateEnumTests: XCTestCase {
    func test_allSevenCasesDefined() {
        let expected: Set<String> = [
            "idle",
            "listening",
            "thinking",
            "speaking",
            "awaitingConfirmation",
            "reconfiguring",
            "booting",
        ]
        let actual = Set(HudState.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(HudState.allCases.count, 7)
    }

    func test_voiceOverLabelNonEmptyForEveryCase() {
        for state in HudState.allCases {
            XCTAssertFalse(state.voiceOverLabel.isEmpty, "voiceOverLabel empty for \(state)")
        }
    }

    func test_voiceOverLabelsAreUnique() {
        let labels = HudState.allCases.map(\.voiceOverLabel)
        XCTAssertEqual(Set(labels).count, HudState.allCases.count)
    }

    func test_bootingAndReconfiguringLabelsMatchSpec() {
        XCTAssertEqual(HudState.booting.voiceOverLabel, "Jarvis, starting up")
        XCTAssertEqual(HudState.reconfiguring.voiceOverLabel, "Jarvis, reconfiguring audio")
    }

    func test_existingLabelsPreservedFromPhase1() {
        XCTAssertEqual(HudState.idle.voiceOverLabel, "Jarvis, idle")
        XCTAssertEqual(HudState.listening.voiceOverLabel, "Jarvis, listening")
        XCTAssertEqual(HudState.thinking.voiceOverLabel, "Jarvis, thinking")
        XCTAssertEqual(HudState.speaking.voiceOverLabel, "Jarvis, speaking")
        XCTAssertEqual(HudState.awaitingConfirmation.voiceOverLabel, "Jarvis, waiting for your confirmation")
    }

    func test_switchOnHudStateIsExhaustive() {
        // Compile-time contract: exhaustive switch with no `default:` compiles.
        // Running the closure once per case proves linkage.
        func describe(_ state: HudState) -> String {
            switch state {
            case .idle: return "idle"
            case .listening: return "listening"
            case .thinking: return "thinking"
            case .speaking: return "speaking"
            case .awaitingConfirmation: return "awaitingConfirmation"
            case .reconfiguring: return "reconfiguring"
            case .booting: return "booting"
            }
        }
        for state in HudState.allCases {
            XCTAssertFalse(describe(state).isEmpty)
        }
    }
}
