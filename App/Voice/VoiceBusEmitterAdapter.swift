import Foundation
import Voice  // BusOutboundEmitter
import Bus    // OutboundBatcher

/// Production adapter bridging `Voice.BusOutboundEmitter` to `OutboundBatcher`.
/// Routes the ~30 Hz audio-level RMS values from `AudioLevelEmitter` into the
/// batcher so the HUD's RingMesh pulses with the mic level.
///
/// Phase 9 / Plan 4 / D-09: replaces `NullBusEmitterAdapter`.
struct VoiceBusEmitterAdapter: BusOutboundEmitter {
    let batcher: OutboundBatcher

    func postAudio(_ rms: Float) async {
        await batcher.postAudio(rms)
    }
}
