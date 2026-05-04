# Keychain

Thin actor wrapper over `SecItem` for secrets (currently the Anthropic API key; any future secret routes through here).

## Key public types

| Type | Purpose |
|------|---------|
| `KeychainStore` (protocol) | Test seam — production = `SystemKeychainStore`, tests = `FakeKeychain` |
| `SystemKeychainStore` | Real `SecItem` actor wrapper |
| `KeychainItem` | Strong-typed key (account + service) |
| `KeychainError` | Errors propagated through construction chains, not swallowed |

## Depends on

(no internal Jarvis package dependencies — the leaf at the bottom of the graph).

## Used by

`packages/AgentCore` (`AnthropicAPIKeyProvider`), `packages/Config`, `App/AppDelegate`.

## Key invariants / contracts

- **Errors propagate.** `AnthropicAPIKeyProvider.make` throws on missing key (Track A fix — was previously swallowed).
- **No plaintext secrets in JSON or `UserDefaults`.** Everything sensitive goes through this package.
- **Fake taxonomy.** `FakeKeychain` is an in-memory dictionary-backed store with realistic behavior (Fake per CLAUDE.md §Test naming conventions).

## Tests

XCTest. Round-trip read/write/delete on `FakeKeychain`. Production `SystemKeychainStore` tests gated to skip in CI (require user-keychain access).

## Notable files

- `Sources/Keychain/KeychainStore.swift` — the protocol
- `Sources/Keychain/SystemKeychainStore.swift` — production
- `Sources/Keychain/KeychainItem.swift` — typed keys
- `Sources/Keychain/KeychainError.swift` — error union
