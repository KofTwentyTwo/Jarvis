import Foundation

/// Plan 07-05 / D-13 + D-18 — phrase detection for frame-attach trigger and
/// cloud-opt-in escape.
///
/// **CARDINAL INVARIANT (D-18):** `matchesCloudOptIn` is the ONLY function
/// in the entire codebase whose return value can flip `VisionRouter` to T3
/// (cloud egress). `VisionRouterCloudOptInGrepTests` enforces structurally
/// that no T3-bound code path bypasses this gate.
///
/// Match semantics: case-insensitive word-bounded contains. "Word-bounded"
/// here means the character before the match (if any) is non-alphanumeric
/// AND the character after the match (if any) is non-alphanumeric — so
/// `"send to opus"` matches `"Send To Opus."` but not `"send to opusxyz"`.
public enum EscalationPhraseDetector {

    /// D-18 cloud opt-in detection.
    public static func matchesCloudOptIn(
        _ text: String,
        config: VisionRouterConfig
    ) -> Bool {
        for phrase in config.cloudOptInPhrases {
            if wordBoundedContains(text, phrase: phrase) {
                return true
            }
        }
        return false
    }

    /// D-13 frame-attach phrase detection.
    public static func matchesFrameAttach(
        _ text: String,
        config: VisionRouterConfig
    ) -> Bool {
        for phrase in config.frameAttachPhrases {
            if wordBoundedContains(text, phrase: phrase) {
                return true
            }
        }
        return false
    }

    // MARK: - Word-bounded contains

    /// True if `phrase` appears in `text` (case-insensitively) with non-
    /// alphanumeric boundaries on both sides (or string-start/string-end).
    private static func wordBoundedContains(_ text: String, phrase: String) -> Bool {
        let lowerText = text.lowercased()
        let lowerPhrase = phrase.lowercased()
        // Iterate every match position.
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerPhrase, options: .literal, range: searchStart..<lowerText.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == lowerText.startIndex {
                beforeOK = true
            } else {
                let prev = lowerText[lowerText.index(before: range.lowerBound)]
                beforeOK = !prev.isLetter && !prev.isNumber
            }
            let afterOK: Bool
            if range.upperBound == lowerText.endIndex {
                afterOK = true
            } else {
                let next = lowerText[range.upperBound]
                afterOK = !next.isLetter && !next.isNumber
            }
            if beforeOK && afterOK {
                return true
            }
            // Advance past this hit to look for the next.
            searchStart = lowerText.index(after: range.lowerBound)
        }
        return false
    }
}
