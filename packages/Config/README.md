# Config

Two-tier config snapshot model + JSON persistence. Trivial prefs go to `UserDefaults`; secrets go to `Keychain`; everything else lives here.

## Key public types

| Type | Purpose |
|------|---------|
| `LaunchSnapshot` | Read once at startup — provider selection, feature flags, logging level |
| `PerTurnSnapshot` | Read at every turn start — TTS, STT, AppleScript policy, confirmation policy, Ollama config |
| `ConfigStore` | The owning store (atomic snapshot reads + writes) |
| `ConfigLoader` | JSON read/write at `~/Library/Application Support/Jarvis/` |
| `SchemaMigrator` | Backward-compat migration on schema bump |
| `ProviderSelection` | `.anthropic` / `.ollama` toggle |
| `FeatureFlags` | Risky/in-development feature gates (no rebuild needed to flip) |
| `TTSConfig` / `STTConfig` / `OllamaConfig` | Per-subsystem tunables |
| `AppleScriptPolicy` | Per-target allowlist + confirmation requirements |
| `ConfirmationPolicy` | Per-tool confirmation rules |

## Depends on

`Keychain`, `Logging`. External: `swift-log`.

## Used by

`App/AppDelegate`, `packages/AgentCore` (orchestrator reads `PerTurnSnapshot`), `packages/Voice`, `packages/Memory`, `packages/Replay`.

## Key invariants / contracts

- **`LaunchSnapshot` is immutable per-process.** Writes go through `ConfigStore.update` and require a relaunch to apply (currently — could become live-reload later).
- **`PerTurnSnapshot` is read at the start of every turn.** Live-reload contract for everything except provider selection.
- **Secrets are NEVER written to JSON config.** API keys go to `Keychain` only.
- **Schema version on disk.** `SchemaMigrator` runs forward-only; downgrade is undefined.

## Tests

XCTest coverage for snapshot read/write round-trips, schema migration, default-value generation. No env-flag gates.

## Notable files

- `Sources/Config/ConfigStore.swift` — the owning store
- `Sources/Config/LaunchSnapshot.swift` — startup-only config
- `Sources/Config/PerTurnSnapshot.swift` — per-turn config
- `Sources/Config/SchemaMigrator.swift` — migration path
- `Sources/Config/ConfirmationPolicy.swift` — tool-confirmation rules
