import AVFoundation
import Foundation

// MARK: - AVSpeechSynth
//
// Tier-1 TTS wrapper around `AVSpeechSynthesizer`.
//
// VOICE-05 invariants:
//   1. The `AVSpeechSynthesizer` instance is a STORED PROPERTY (not re-created
//      per utterance). Re-creating the synthesizer mid-utterance causes the
//      previous utterance to finish on the old instance, leaking memory and
//      producing overlapping speech. (Pitfall §5)
//   2. The delegate is also stored so it isn't deallocated mid-utterance.
//   3. `stopSpeaking(at: .immediate)` is called BEFORE every new `speak` call
//      to prevent queue buildup on rapid-fire calls. (VOICE-05 rapid-fire guard)
//
// Design note: `AVSpeechSynth` is `@unchecked Sendable` because
// `AVSpeechSynthesizer` is not `Sendable` in the Swift 6 strict concurrency
// model. All access is serialized via the delegate's continuation mechanism
// (one active continuation at a time).

public final class AVSpeechSynth: @unchecked Sendable {

    // MARK: - Stored synthesizer (Pitfall §5: must NOT be local or weak)

    private let synth: AVSpeechSynthesizer

    // MARK: - Stored delegate (Pitfall §5: must NOT be local or weak)

    private let delegate: SpeechSynthDelegate

    // MARK: - Test seam

    /// Callback invoked each time `stopSpeaking(at:.immediate)` is called.
    /// Used by tests to count rapid-fire guard invocations (A2).
    public var onStop: (@Sendable () -> Void)?

    // MARK: - Init

    /// Creates a `AVSpeechSynth` with a fresh synthesizer and delegate.
    public init() {
        let d = SpeechSynthDelegate()
        self.synth = AVSpeechSynthesizer()
        self.delegate = d
        self.synth.delegate = d
    }

    // MARK: - Public API

    /// Speak `text` with an optional `voice`.
    ///
    /// Calls `stopSpeaking(at: .immediate)` before queueing the new utterance
    /// to prevent overlapping / queue buildup on rapid-fire calls (VOICE-05).
    ///
    /// Awaits until the utterance finishes or is cancelled.
    public func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async {
        // VOICE-05 rapid-fire guard: cancel any in-flight utterance first.
        synth.stopSpeaking(at: .immediate)
        onStop?()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.setPendingContinuation(continuation)
            synth.speak(utterance)
        }
    }

    /// Synchronously stop the current utterance.
    public func stop() {
        synth.stopSpeaking(at: .immediate)
        onStop?()
    }
}

// MARK: - SpeechSynthDelegate (stored object — must outlive utterances)

/// AVSpeechSynthesizerDelegate conformer that resumes the waiting continuation.
///
/// Stored on `AVSpeechSynth` (not local to `speak`) so it is not deallocated
/// mid-utterance. This is the key guard against Pitfall §5.
final class SpeechSynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func setPendingContinuation(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        continuation = c
        lock.unlock()
    }

    // Called when the utterance finishes naturally.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    // Called when the utterance is cancelled (e.g. via stopSpeaking(at:.immediate)).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didCancel utterance: AVSpeechUtterance) {
        resume()
    }

    private func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
