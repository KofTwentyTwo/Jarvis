import XCTest
@testable import JarvisVision

/// Plan 07-05 / Task 5 — phrase detector for D-18 cloud opt-in and D-13
/// frame-attach trigger phrases.
final class EscalationPhraseDetectorTests: XCTestCase {

    private let cfg = VisionRouterConfig.default

    // MARK: - Cloud opt-in (D-18) — exact matches

    func testCloudOptInMatchesAllConfiguredPhrases() {
        let phrases = [
            "send to opus",
            "use cloud",
            "use opus",
            "send to claude",
        ]
        for p in phrases {
            XCTAssertTrue(
                EscalationPhraseDetector.matchesCloudOptIn(p, config: cfg),
                "should match: \(p)"
            )
        }
    }

    func testCloudOptInMatchesCaseInsensitively() {
        XCTAssertTrue(EscalationPhraseDetector.matchesCloudOptIn("Send To Opus.", config: cfg))
        XCTAssertTrue(EscalationPhraseDetector.matchesCloudOptIn("USE CLOUD please", config: cfg))
        XCTAssertTrue(EscalationPhraseDetector.matchesCloudOptIn("Could you SEND TO CLAUDE?", config: cfg))
    }

    func testCloudOptInDoesNotMatchNearMisses() {
        // "send to my friend" contains "send to" but not "send to opus"
        XCTAssertFalse(EscalationPhraseDetector.matchesCloudOptIn("send to my friend", config: cfg))
        // "opus the dog" mentions opus but not as part of the escape phrase
        XCTAssertFalse(EscalationPhraseDetector.matchesCloudOptIn("opus the dog is barking", config: cfg))
        // "use opus orchestra" — "use opus" appears but boundary check prevents
        // false positive when followed by alphanumeric
        XCTAssertFalse(EscalationPhraseDetector.matchesCloudOptIn("send to opusxyz tonight", config: cfg))
    }

    // MARK: - Frame attach (D-13) — exact matches

    func testFrameAttachMatchesAllConfiguredPhrases() {
        let phrases = [
            "can you see this",
            "what am i looking at",
            "show this to jarvis",
            "what's on my screen",
            "what is on my screen",
        ]
        for p in phrases {
            XCTAssertTrue(
                EscalationPhraseDetector.matchesFrameAttach(p, config: cfg),
                "should match: \(p)"
            )
        }
    }

    func testFrameAttachMatchesCaseInsensitively() {
        XCTAssertTrue(EscalationPhraseDetector.matchesFrameAttach("Can You See This?", config: cfg))
        XCTAssertTrue(EscalationPhraseDetector.matchesFrameAttach("What Am I Looking At, Jarvis?", config: cfg))
    }

    func testFrameAttachDoesNotMatchNearMisses() {
        // "I can see why" contains "can see" but not the trigger phrase
        XCTAssertFalse(EscalationPhraseDetector.matchesFrameAttach("I can see why you said that", config: cfg))
    }
}
