# Wake-Hysteresis Corpus (OBS-04 pillar e)

This directory holds the labeled WAV corpus used by `jarvis-eval wake-corpus`
to compute wake-word False Accept Rate (FAR) and False Reject Rate (FRR)
against the production `OpenWakeWordSession`.

The corpus is **per-host**: it is recorded by the operator on the same
hardware Jarvis ships on so the FAR/FRR numbers reflect the operator's voice
and typical room background. The committed `labels.json` ships empty (`[]`);
the operator records clips before the first shipping-gate run.

## D-18 thresholds

The shipping gate enforces:

- **PASS:** `FAR <= 1.0/hr` AND `FRR <= 10.0%`
- **WARN:** `FAR > 0.5/hr` OR `FRR > 5.0%` (visible in output, does not block)

The runner short-circuits an empty corpus to `passed: false` with a
diagnostic — bare 0/0 ratios alone would otherwise pass the predicate.

## Recording protocol

### Format

- **Sample rate:** 16 kHz
- **Channels:** mono
- **Container:** `.wav` (PCM; AVAudioFile decodes to Float32 internally)
- **Duration:** 1–10 seconds per clip is typical; longer clips count more
  time toward FAR's "per hour" denominator

### Distribution

Target ~30 positive + ~30 negative clips, ~5 minutes total. Vary the
operator's voice volume, distance from the mic, and background:

**Positive clips** (label `positive` — contain "hey jarvis"):
- Clean, quiet
- "Hey Jarvis" with normal/loud/quiet/muffled enunciation
- Distance variations (1 ft, 3 ft, 6 ft from mic)
- One additional speaker if available (varied F0 helps generalization)

**Negative clips** (label `negative` — do NOT contain "hey jarvis"):
- Quiet desk silence (room tone)
- Background music
- Background conversation / podcast
- Kitchen / appliance noise
- Phonetically-near phrases ("hey there", "hey jacob", "hey driver", "OK
  Jarvis") that should NOT trigger
- Common false-positive sources for wake words: TV news, ad breaks

### Augmentation (optional)

Use `sox` or similar to synthesize additional negatives:

```bash
sox quiet.wav -p synth 1 pinknoise -r 16000 -c 1 pink-bg.wav
sox positive.wav reverb 50 reverb-positive.wav
```

Tag synthetic clips with `noiseProfile: "synthetic-pink"` (or similar) so
the report can break out FAR by noise profile.

### `labels.json` schema

```json
[
  {
    "id": "pos-quiet-01",
    "fileName": "pos-quiet-01.wav",
    "label": "positive",
    "durationSeconds": 2.3,
    "noiseProfile": "quiet"
  },
  {
    "id": "neg-music-01",
    "fileName": "neg-music-01.wav",
    "label": "negative",
    "durationSeconds": 8.1,
    "noiseProfile": "music-bg"
  }
]
```

## Seed sources

[openWakeWord](https://github.com/dscripka/openWakeWord) ships community TP
and TN clips that the operator can use as seeds before recording their own:
mixed-speaker positives + a long-form negative tail. License the seed set
under that project's terms and credit it in any redistributed corpus.

## Running

```bash
JARVIS_WAKE_MODEL_DIR=/path/to/openwakeword/models \
swift run --package-path packages/Harness jarvis-eval wake-corpus
```

The runner constructs the **production** `OpenWakeWordSession` (real ONNX
inference, manifest-gated SHA-256 verification). The `JARVIS_WAKE_MODEL_DIR`
env var must point to the directory containing `MANIFEST.json` plus
`melspectrogram.onnx`, `embedding_model.onnx`, and `hey_jarvis_v0.1.onnx`.
