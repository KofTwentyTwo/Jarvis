# Phase 1 — Deferred Items

Out-of-scope findings discovered during execution that are not fixed in-phase.

## From Plan 01-01 (scaffold)

### Semgrep: ATS public-key pinning not configured (CWE-296)

- **Discovered during:** Task 1 — Info.plist creation
- **Scope:** P1 scaffold is non-networking. The Info.plist `NSAppTransportSecurity` dict is absent; no pinning is configured.
- **Why deferred:**
  - P1 creates zero networking code. `AnthropicProvider` (the only TLS egress in v1) lands in P4; `OllamaProvider` binds to `127.0.0.1` only (validated by `OllamaConfig` decoder per AGENT-05).
  - Phase 1 threat register (T-01-01 through T-01-06) does not include TLS trust-chain attacks — all P1 threats are entitlement / codesign / bundle-layout scoped.
  - Public-key pinning against `api.anthropic.com` is a Rule-4 architectural decision (cert rotation maintenance cost vs. marginal security benefit over Apple's managed trust store in a single-user personal tool). If pursued, it would be a P4 or P8 decision with explicit user sign-off, not a P1 scaffold addition.
- **Action if we revisit:** Add `NSAppTransportSecurity` dict to `App/Info.plist` with `NSPinnedDomains` for `api.anthropic.com` when and if that policy is adopted. Reference: https://developer.apple.com/documentation/bundleresources/information_property_list/nsapptransportsecurity/nspinneddomains
