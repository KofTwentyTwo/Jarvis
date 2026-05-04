# Security Audit — 2026-05-04

## Verdict: CLEAN

For a personal-use, single-user macOS app the security posture is unusually solid. The Anthropic API key is handled correctly end-to-end (Keychain `WhenUnlockedThisDeviceOnly` + non-syncable, never on disk, never in the replay log, never in the menu-bar state dump, redacted from error envelopes via `Redact.swift` and `AgentOrchestrator` HI-01 scrubber). Entitlements are tight and bidirectionally enforced (`scripts/verify-entitlements.sh` has REQUIRED + FORBIDDEN lists for the main app and per-helper, runs at both pre- and post-codesign). MCP helpers are independently bundled and signed; only `mcp-applescript` carries `automation.apple-events`. Hardened Runtime is YES on Release; the Debug exemption is documented and limited to incremental-link dylibs that AMFI rejects. The webview boundary uses `WKScriptMessageHandlerWithReply` with hand-rolled `Codable` BusInbound (no free-form JSON dispatch), no `evaluateJavaScript` calls anywhere in production (gate green), tool-result content into the model is capped at 8 KB (`ToolResultPacker`) and wrapped in nonce-bracketed `<UNTRUSTED_CONTENT id="...">` tags with a load-bearing system-prompt directive (`UntrustedWrapper`), and child processes spawn through `ChildSpawnGate` which enforces `FD_CLOEXEC` + `minimalEnvironment = ["PATH": "/usr/bin:/bin"]`. The only LOW-severity items below are defense-in-depth on a personal Mac and don't change the verdict.

## Findings

### CRITICAL (secret leakage, privilege escalation, RCE)

None.

### HIGH (TCC/entitlement misalignment, attack surface widening)

None. Bidirectional entitlement verification (`scripts/verify-entitlements.sh:53-82` for main, `:130-183` per-helper) is the strongest guarantee here — adding a forbidden entitlement to any helper or the main app fails the post-codesign gate.

### MEDIUM (logging hygiene, validation gaps)

- **M1. `HybridSearch.searchFacts` logs the raw user query at debug level.** `packages/Memory/Sources/Memory/HybridSearch.swift:51` emits `logger.debug("searchFacts: query='\(query)' k=\(k) hits=\(refs.count) triggerTurnId=\(triggerTurnId)")`. T-06-05-03 ("voice transcript text never in logs") is honored in `packages/Voice/Sources/Voice/VoiceController.swift:381` but not extended to memory-tool inputs. The agent will issue `search_memory` queries derived from user turns, so the query string can include personal info ("Sarah's address", "my passwords for X"). Debug-level only, but the file rotating writer captures debug. Fix: log `hits=N triggerTurnId=…` and either omit `query` or hash it (parallel to the `Replay`/orchestrator turnId-only convention used in `App/AppDelegate.swift:1042-1044`).

### LOW (defense-in-depth, future-proofing)

- **L1. `WKContentWorld.page` is intentional but widens JS-side surface.** `packages/Bus/Sources/Bus/WebviewBridge.swift:86,106` defaults to `.page`; the comment in `WebviewBridgeOutboundTests.swift:80` notes the F-A2-01 fix. Page-world means any JS in the HUD bundle (and any future third-party content loaded into it — currently none) can observe `window.jarvisBus`. For a closed bundle that only loads our own React build this is acceptable; if the HUD ever embeds third-party content (analytics, OAuth iframes), reconsider isolating to `WKContentWorld.world(name:)`. Document the constraint in the bus README so a future change doesn't silently widen the attack surface.

- **L2. `~/Library/Application Support/Jarvis/replay.sqlite` is mode 0644.** `ls -la` on the live install shows `replay.sqlite` and `jarvis.db` as `rw-r--r--`. macOS umask default; on a single-user Mac with FileVault on, low practical risk. If this Mac ever gains a second account or is shared, full transcript history (and memory facts including PII) is readable by any local user. Defense-in-depth: when `ReplayLog`/`MemoryStore` create their SQLite files, set `kCFURLFileProtectionKey`-ish attributes or chmod 0600 immediately after open. SQLite's `-shm`/`-wal` siblings inherit umask too; chmod those as well.

- **L3. AppleScript source from agent → `NSAppleScript.executeAndReturnError` runs verbatim.** `mcp-servers/mcp-applescript/Sources/mcp-applescript/MCPAppleScriptMain.swift:76-81` passes the agent-supplied `source` string straight into `runner.run(source:)`. There is no input sanitization — and there shouldn't be, because AppleScript is the language the tool is for. Defense lives at two layers: (a) `requiresConfirmation: true` (`App/MCP/MCPRuntimeWiring.swift:112,119`) routes every call through `ConfirmationBroker` → `ConfirmationPresenter` (a SwiftUI panel showing the script before execution), and (b) per-target Apple Events permission prompts on first use. Both are enforced. The risk: if a future change accidentally flips `requiresConfirmation: false` on `run_applescript`, prompt-injected AppleScript runs silently. Recommend a grep-gate (parallel to `check-no-evaluate-javascript.sh`) asserting `run_applescript` is registered with `requiresConfirmation: true` in `MCPRuntimeWiring.swift`.

- **L4. `argsPreview` sanitizer is byte-cap only — it does not redact secrets.** `App/MCP/MCPRuntimeWiring.swift:135-140` truncates to 256 bytes UTF-8 but doesn't run the args through `Redact.apply`. If a future tool is registered whose args legitimately include credential-shaped strings (an `aws_run` tool taking an access key, a `git_push` tool with a PAT), they reach the bus and the on-disk replay log unredacted. Today, the three tools are `get_time` / `get_clipboard` / `run_applescript` and none take credentials, so this is a future-proofing note. When registering a new tool, run its args through `Redact.apply` before bus emission and replay.

- **L5. JS `chatSubmit(text:)` payloads are not length-bounded at the bridge.** `packages/Bus/Sources/Bus/BusInbound.swift:53-55` decodes any-length string. The orchestrator's tokenizer will refuse multi-megabyte submissions naturally, but a malformed/abusive HUD-side caller could repeatedly post very large strings before WebKit's own message-size cap kicks in. Belt-and-braces: cap `text.count` at, say, 100 KB inside the `onInbound` handler and return `BusReply` error for oversize. Low-priority on a single-user app.

- **L6. `MissingT2Provider.stream(...)` returns a typed `VisionError.t2ProviderUnavailable` with no PII surface.** `packages/Vision/Sources/Vision/MissingT2Provider.swift:36,50` finishes the stream with the bare error case (no message, no user data). Clean — flagging only because the audit asked.

## Entitlements snapshot

Main app `App/Jarvis.Release.entitlements` carries exactly four keys:

- `com.apple.security.cs.allow-jit` — load-bearing for WKWebView's JavaScriptCore JIT under Hardened Runtime on Apple Silicon (CLAUDE.md flags this as "without it the webview crashes in Release builds only").
- `com.apple.developer.speech-recognition-assets` — required for macOS 26 Tahoe `SpeechAnalyzer` on-device asset download.
- `com.apple.security.device.audio-input` — Microphone TCC.
- `com.apple.security.device.camera` — Camera TCC.

Notable absences (all correct):

- No `com.apple.security.cs.allow-unsigned-executable-memory` — CLAUDE.md says "do NOT widen unless needed"; MLX / Orpheus do not need it.
- No `com.apple.security.automation.apple-events` on main — moved to `mcp-applescript` helper exclusively. Forbidden on main by `verify-entitlements.sh:75-77`.
- No `com.apple.security.get-task-allow` on Release — Debug-only (XCTest attach), forbidden on Release by `:81`.
- No `com.apple.security.cs.disable-library-validation`, no `com.apple.security.cs.disable-executable-page-protection`.

`App/Jarvis.Debug.entitlements` differs by adding `get-task-allow` (XCTest) and removing `speech-recognition-assets` (managed entitlement; AMFI rejects ad-hoc-signed Debug bundles carrying it). `verify-entitlements.sh` enforces both rules per-configuration.

Helpers:

- `mcp-servers/mcp-applescript/Support/mcp-applescript.entitlements` — `com.apple.security.automation.apple-events` only. The single privileged helper.
- `mcp-servers/mcp-clipboard/Support/mcp-clipboard.entitlements` — empty `<dict/>`. No entitlements needed (NSPasteboard is unrestricted).
- `mcp-servers/mcp-time/Support/mcp-time.entitlements` — empty `<dict/>`.

The per-helper FORBIDDEN lists in `verify-entitlements.sh:140-156` explicitly forbid `mcp-time` and `mcp-clipboard` from carrying `automation.apple-events`, `cs.allow-jit`, `audio-input`, `speech-recognition-assets`, `cs.allow-unsigned-executable-memory`. Adding any of those to a non-applescript helper fails the build.

`Info.plist` carries `NSSpeechRecognitionAssetsUsageDescription` and `NSAppleEventsUsageDescription` ("Jarvis uses AppleScript automation only after you approve each request in a confirmation dialog." — `App/Info.plist:30`).

## Today's churn — security review

22 commits across Tracks A/B/C/D + cleanup batch + linter. Per-commit security-relevant findings:

- `1f8e03e` Track A — `AnthropicAPIKeyProvider.make` propagates `KeychainError` instead of swallowing into `""`. **Net positive for security**: silent fallback was hiding a missing-key state behind a 401 error response from Anthropic; explicit propagation makes the failure mode legible. No new attack surface.
- `ee7f6d2` Track B-1..3 — voice models bundled at `Contents/Resources/Models/`. ONNX Runtime + Silero/openWakeWord; no entitlements added.
- `e9c0a34` Track B-4 — SpeechAnalyzer bridge. Already-entitled (`speech-recognition-assets`); no expansion.
- `61aed20` Track B-5, `c7f9ece` Track B-6, `bce725b` Track B-7 — audio graph, VAD, broadcaster fan-out. All in-process; no IPC, no persistence; T-06-05-03 (no PCM logging) preserved per VoiceController.swift:381.
- `7a5543a..19362f6` Track C — vision. Camera capture goes through TCC (`AVCaptureDevice.authorizationStatus`); jpegData lives in `ImageBlock`/replay only; no logging of image bytes (`packages/Vision/Sources/Vision/CameraCapture.swift:307` constructs the block; logging at `:79` records open status only).
- `75a10be..c3bd0a5` Track D — memory. `MemoryStore` writes go through SQLite; logging at `MemoryStore.swift:381,384` references `factId` only; `MemoryExtractionOrchestrator.swift:130,134` log error with no fact content; `App/AppDelegate.swift:1042-1044` explicitly notes T-06-05-03 and logs only `turnId`. The one drift is M1 above (`HybridSearch.swift:51` includes the raw query string).
- `c3bd0a5` `RememberBrutusEndToEndTests` — fixture is a non-PII fictional dog name + breed. No real-user PII checked into tests.
- `ad93dac` `MCPBusGatewayAdapter` — new code path bus-bound. Inputs (`toolUseId`, `name`, `argsPreview`, `previewOrError`) are produced by `ConfirmingToolDispatcher` which already routes args through the 256-byte sanitizer in `MCPRuntimeWiring.swift:135-140`. The SHA256 → UUID derivation in `MCPBusGatewayAdapter.swift:81-95` is one-way; no information leakage from the UUID back to the original toolUseId.
- `df6a4d2` `MissingT2Provider` — error contents reviewed (L6); clean.
- `5cd46c9` `check-no-leftover-stubs.sh` — passes on develop.
- `08125a4` test cleanup — no production code change.

No commit today widens an attack surface beyond what was already designed.

## Things that are actually good

- **`scripts/verify-entitlements.sh` is bidirectional.** REQUIRED + FORBIDDEN lists for both the main app and each known helper, with a default-deny `*) echo "unknown helper"; return 1` arm so a new helper can't be smuggled in without the verifier learning about it. Configuration-aware (Debug vs Release rules differ correctly). Strips XML comments before grep so a `<!-- com.apple.security.cs.allow-jit -->` prose comment can't satisfy a naive grep. Verifies BOTH source-side entitlements (`--pre-codesign`) AND signed entitlements via `codesign -d --entitlements - --xml` (`--post-codesign`). Self-tested by `scripts/test-verify-entitlements.sh`. This is the single biggest force-multiplier in the codebase.
- **`AnthropicAPIKeyProvider.make` (`packages/AgentCore/Sources/AnthropicProvider/AnthropicAPIKeyProvider.swift:30-37`)** — single-line wrapper that re-throws `KeychainError`. Eliminates the silent-empty-string footgun. Backed by `AnthropicAPIKeyProviderTests` (`packages/AgentCore/Tests/AnthropicProviderTests/AnthropicAPIKeyProviderTests.swift:96-99`).
- **`SystemKeychainStore` (`packages/Keychain/Sources/Keychain/SystemKeychainStore.swift:7-43`)** — pins every write to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAttrSynchronizable = false`. Comment explains the legacy-keychain caveat (the attribute is accepted on write but not readback-queryable on file-based keychain).
- **`copyStateDump()` (`App/AppDelegate.swift:1979-1996`)** — writes ONLY boolean presence indicators (`apiKeyStored: Bool`) to the clipboard. The API-key value never lands in a local variable or pasteboard. Backed by `AppDelegateWiringTests:113-153` which sets a recognizable plaintext value and asserts the pasteboard does not contain `sk-ant-`.
- **`Redact.apply` (`packages/Logging/Sources/JarvisLogging/Redact.swift:11-23`)** — single regex with five branches (Anthropic / Bearer / OpenAI sk- / AWS / GitHub PAT), branch order matters and is documented. Backed by `RedactTests` including the specific regression where branch 3 would have matched `sk-ant-` first leaving the prefix visible.
- **`UntrustedWrapper` (`packages/AgentCore/Sources/AgentCore/UntrustedWrapper.swift`)** — strips `</?UNTRUSTED_CONTENT[^>]*>` BEFORE wrapping (correct order; reversed would let attacker tags leak through). Case-sensitive uppercase wrapper means a `<untrusted_content>` injection can't close it. The `composeSystemPrompt` directive is the load-bearing instruction; the wrapper alone is decoration without it. Per-turn nonce makes wrapper injection one-shot useless.
- **`ToolResultPacker.modelFacingCapBytes = 8 * 1024` (`packages/AgentCore/Sources/AgentCore/ToolResultPacker.swift:16`)** — caps model-facing tool results at 8 KB while routing the full blob to ReplayLog (no observability loss). Truncation marker text appended for legibility.
- **`ChildSpawnGate` (`packages/MCP/Sources/JarvisChildSpawn/ChildSpawnGate.swift`)** — `FD_CLOEXEC` sweep with developer-owned-vs-system path classification, Debug fatalError on the developer-owned path so regressions are loud at the open site. `minimalEnvironment = ["PATH": "/usr/bin:/bin"]` constant; `VllmMlxSidecarSpawnTests` asserts byte-for-byte equality.
- **`scripts/check-corpus-secrets.sh`** — five-pattern grep across `Corpora/`, plus SQLite-aware scanning (`sqlite3 -readonly` to dump tool_call rows; falls back to grep on the raw bytes when sqlite3 isn't available) for replay session files. D-07 contract.
- **`scripts/check-no-evaluate-javascript.sh`** — pre-build gate forbidding `.evaluateJavaScript(` in production Swift. Skips test directories explicitly. Currently green; only `callAsyncJavaScript(_:arguments:in:contentWorld:)` with a typed `payload` argument is allowed. The single production call site is `WebviewBridge.sendRaw` (`packages/Bus/Sources/Bus/WebviewBridge.swift:183-193`).
- **`BusInbound` is a hand-rolled discriminator-Codable enum** (`packages/Bus/Sources/Bus/BusInbound.swift:42-61`). No free-form `[String: Any]` JSON dispatch to Swift handlers; unknown discriminator → decode error → JS sees `Promise.reject`. Adding a case without a matching `init(from:)` arm is a compile error (no `default` branch).
- **`requiresConfirmation: true`** on `run_applescript` AND on the `mcp-applescript` MCPClient registration — defense in depth at both layers (`App/MCP/MCPRuntimeWiring.swift:112,119`). The HUD confirmation panel comment explicitly notes "DO NOT route confirmation through the webview — bus / JS surface is the wrong trust boundary" (`packages/MCP/Sources/MCP/ConfirmationPresenter.swift:9`).
- **HI-01 credential scrubber** (`packages/AgentCore/Sources/AgentOrchestrator/AgentOrchestrator.swift:631,668,691`) wraps both the success and error envelopes from the LLM transport — a malformed `x-api-key` header value can't echo back through `OrchestratorEvent.error` to the bus.
