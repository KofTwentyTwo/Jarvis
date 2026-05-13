# Building Jarvis

This is the long-form build reference. The [README](README.md) has the quick
version; this file covers per-package test loops, the boundary-gate
linters, the webview workflow, and the opt-in real-hardware tests.

## Requirements

- **macOS 26 (Tahoe) or later** on Apple Silicon. `SpeechAnalyzer` is a
  Tahoe-only API; the agent loop, voice stack, and MLX TTS path all
  assume Apple Silicon.
- **Xcode 16+** (project is exercised against the Xcode 26 toolchain).
- **Swift Package Manager** for per-package test loops; **`xcodebuild`**
  for the app target.
- **`pnpm`** for the webview workspace.
- **Hardened Runtime entitlements** in `App/Jarvis.entitlements`:
  - `com.apple.security.cs.allow-jit` — required for WKWebView's
    JavaScriptCore JIT under Hardened Runtime. Without it the webview
    crashes in Release builds only.
  - `com.apple.developer.speech-recognition-assets` plus the matching
    `NSSpeechRecognitionAssetsUsageDescription` Info.plist key — required
    for on-device `SpeechAnalyzer` asset download.

Optional, only for the real-hardware tests:

- **Ollama** locally with `nomic-embed-text` + `qwen2.5-coder:32b`
  (memory regression corpus, Voice TTFA tests).
- **Orpheus MLX weights** (~6 GB) for tier-2 TTS time-to-first-audio
  measurement.
- **A real camera + Camera TCC grant** for the camera capture suite.

## Per-package SPM tests (default loop)

SPM tests are the fast path — they run offline, in seconds, and cover the
bulk of behavior. The app target is excluded from `swift test` (see
[App target](#app-target) below).

```bash
swift test --package-path packages/AgentCore
swift test --package-path packages/Bus
swift test --package-path packages/Config
swift test --package-path packages/DevOverlay
swift test --package-path packages/Harness
swift test --package-path packages/Keychain
swift test --package-path packages/Logging
swift test --package-path packages/MCP
swift test --package-path packages/Memory
swift test --package-path packages/Replay
swift test --package-path packages/Shell
swift test --package-path packages/Vision
swift test --package-path packages/Voice
swift test --package-path packages/VoiceLog
```

Single-test filter:

```bash
swift test --package-path packages/<Pkg> --filter <SuiteName>/<testName>
```

## App target

`swift test` does not compile the app target on Xcode 26 — the xctest
harness is upstream-broken on ad-hoc Debug bundles. Use the wrapper, which
drives `xcodebuild build -configuration Debug`:

```bash
bash scripts/check-app-builds.sh
```

This is the canonical "does the app compile?" gate. Run it before every
push.

## Webview (HUD bundle)

Production build (what gets stamped into the app):

```bash
bash scripts/build-webview.sh
```

Dev loop (Vite, hot reload, talks to the Swift host's bridge when the app
is also running):

```bash
cd webview && pnpm install && pnpm --filter @jarvis/hud dev
```

Webview unit tests (vitest):

```bash
cd webview && pnpm --filter @jarvis/hud test
```

## Boundary-gate linters

Eighteen grep-based scripts enforce architectural invariants the type
system can't. Each one encodes a *why* the structure is what it is — most
came from a wired-but-dead bug being root-caused into "this isolation
needs to be a gate, not a convention".

Run them all before pushing:

```bash
for s in scripts/check-*.sh; do bash "$s" || break; done
```

| Script | What it enforces |
|--------|------------------|
| `check-app-builds.sh` | The app target compiles under `xcodebuild`. |
| `check-applescript-confirmation.sh` | AppleScript tool calls route through the HUD-confirmation prompt. |
| `check-bus-harness-parity.sh` | The harness mocks match the live Bus protocol shape. |
| `check-bus-protocol-version.sh` | The Bus protocol version is pinned consistently across Swift + TS. |
| `check-corpus-secrets.sh` | No secrets (API keys, tokens) leak into the eval corpus. |
| `check-embedding-dim-literal.sh` | The 768-dim embedding constant is pinned in one place. |
| `check-install-order.sh` | The `AppDelegate` install DAG awaits subsystems in the correct order. |
| `check-no-evaluate-javascript.sh` | Nothing outside the Bus calls `evaluateJavaScript` on the webview. |
| `check-no-leftover-stubs.sh` | No "TODO stub" placeholders remain in shipped code. |
| `check-no-modal-presentation.sh` | No `.sheet` / `.alert` modals — HUD-native UI only. |
| `check-no-null-voice-adapters.sh` | Voice adapters are never wired to a null implementation. |
| `check-orchestrator-events-single-consumer.sh` | The orchestrator event stream has exactly one consumer (the broadcaster). |
| `check-presence-bus-no-tts-orchestrator.sh` | The presence bus does not call into TTS or the orchestrator. |
| `check-presence-vision-isolation.sh` | The presence subsystem does not import Vision internals. |
| `check-single-memory-mutated-emit.sh` | Exactly one path emits `memory.mutated`. |
| `check-single-memory-used-emit.sh` | Exactly one path emits `memory.used`. |
| `check-single-writer-hudstate.sh` | Exactly one writer for `HUDState`. |
| `check-vision-isolation.sh` | Vision does not import AgentCore / Voice / Memory internals. |

Codesign + entitlement verification (run as Xcode build phases, also
useful manually):

```bash
bash scripts/verify-entitlements.sh --pre-codesign
bash scripts/verify-entitlements.sh --post-codesign
bash scripts/verify-codesign-settings.sh
```

## Real-hardware / real-network env-flag tests

These are skipped in the default loop because they need external
resources. Run them interactively when you change the affected subsystem.

```bash
JARVIS_REAL_MODELS=1 swift test --package-path packages/Memory \
  --filter MemoryRegressionCorpusTests
# Requires: local Ollama serving nomic-embed-text + qwen2.5-coder:32b,
#           and a loadable vec0.dylib bundled into the test target.

JARVIS_REAL_CAMERA=1 swift test --package-path packages/Vision \
  --filter CameraCaptureRealHardwareTests
# Requires: a real AVCaptureDevice with .authorized TCC.

JARVIS_REAL_MODELS=1 swift test --package-path packages/Voice \
  --filter OrpheusTTFATests
# Requires: ~6 GB Orpheus weights pulled.
# Produces an empirical time-to-first-audio measurement.
```

The eval harness — Anthropic + local-model matrix, corpus in
`.planning/evals/` — is pinned to `qwen2.5-coder:32b` for the local-model
lane.

## CI/CD

GitHub Actions is the canonical CI surface. Five workflows live in
`.github/workflows/`:

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `ci.yml` | PR + push to `develop`/`main`/`rc/*`/`release/*` | Boundary gates, webview (pnpm), 14 SPM packages (matrix), app target (xcodebuild), tag publish |
| `codeql.yml` | PR + push + weekly cron | Static analysis for Swift + JavaScript/TypeScript |
| `semgrep.yml` | PR + push + weekly cron | Rule-based scan (`p/default`, `p/swift`, `p/typescript`, `p/secrets`) |
| `dependency-review.yml` | PR touching `package.json` / `pnpm-lock.yaml` / `Package.swift` / `Package.resolved` | Blocks high-severity vulns + license violations |
| `release.yml` | Push of `v*` tag | Creates a GitHub Release with auto-generated changelog |

### Branch + tag conventions

- **`feature/*`, `fix/*`** — open a PR against `develop`. CI runs full
  build + test + scan; no tagging.
- **`develop`** — integration trunk. Every push runs full CI and publishes a
  pre-release tag `v0.X.Y-dev.<run_number>`.
- **`rc/*` / `release/*`** — release candidates. Tag `v0.X.Y-rc.N` (N auto-
  increments from existing tags).
- **`main`** — production. Only updated via PR from `rc/*` or `release/*`.
  Push to `main` produces a final tag `v0.X.Y` and a GitHub Release.

Versioning bumps follow Conventional Commits since the previous final tag:

- `feat:` → minor bump
- `fix:` → patch bump
- `feat!:` or `BREAKING CHANGE:` footer → major bump

When no tags exist yet, the seed version is `v0.1.0` (current roadmap
target).

### Failed boundary gate?

Each script in `scripts/check-*.sh` encodes an architectural invariant. The
table in [Boundary-gate linters](#boundary-gate-linters) above explains
what each one enforces. To reproduce locally:

```bash
bash scripts/check-<name>.sh
```

The script's header comments explain the "why" behind the check and point
at the relevant audit finding or bug.

### Opting into real-hardware tests

The real-hardware suites (`JARVIS_REAL_MODELS=1`, `JARVIS_REAL_CAMERA=1`)
need local Ollama and a real camera, so they don't run on GitHub-hosted
runners. To run them in CI:

1. Register a self-hosted macOS runner with `Ollama` + the necessary
   models + camera TCC grants.
2. Trigger `ci.yml` via the Actions tab → "Run workflow" → set
   `run_real_hardware` to `true`.

The `real-hardware` job is gated on `runs-on: [self-hosted, macOS]` and
only fires for `workflow_dispatch` events with the input set.

### Required repo secrets (optional)

- `SEMGREP_APP_TOKEN` — only needed if you want findings posted to
  Semgrep Cloud. Without it, scans still run with public rules and the
  workflow log shows results inline.

`GITHUB_TOKEN` is provided automatically by Actions; no setup needed.

## Cross-references

- [README](README.md) — project overview and quick-start.
- [ARCHITECTURE.md](ARCHITECTURE.md) — subsystem deep dives.
- [CONTRIBUTING.md](CONTRIBUTING.md) — dev workflow and commit conventions.
- [CLAUDE.md](CLAUDE.md) — settled architectural decisions and AI-agent
  collaboration conventions; the canonical reference for command lists.
