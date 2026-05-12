# Security Policy

## Reporting a vulnerability

Jarvis is a personal-use macOS application; the threat model assumes a
single trusted user. The most likely security-relevant surfaces are:

- **AppleScript automation** — gated behind a per-call HUD confirmation
  (`requiresConfirmation: true`); enforced by
  `scripts/check-applescript-confirmation.sh`.
- **Anthropic API key storage** — macOS Keychain only; never plaintext.
- **Ollama loopback enforcement** — `OllamaConfig` rejects non-loopback
  hosts at config load (AGENT-05 in CLAUDE.md).
- **Hardened Runtime + JIT entitlement** — required for WKWebView
  JavaScriptCore on Apple Silicon.

If you find a vulnerability, report it privately:

- Email: jmaes@dmdbrands.com
- GitHub Security Advisory: <https://github.com/KofTwentyTwo/Jarvis/security/advisories/new>

Please do NOT open a public issue for security reports. Allow up to 7 days
for an acknowledgement.

## Supported versions

Only `develop` is supported. Tagged releases are not yet a thing for this
project.
