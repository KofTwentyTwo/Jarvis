# Feature Research

**Domain:** Personal, always-on macOS AI assistant (Iron Man "Jarvis"-style) — single user, single machine, deeply OS-integrated, voice + vision + ambient HUD.
**Researched:** 2026-04-21
**Confidence:** HIGH on mechanical UX conventions (voice latency targets, streaming chat patterns, wake-word hygiene, MCP tool landscape, observability). MEDIUM on cinematic-HUD conventions (the genre is niche — mostly hobbyist replicas and film-VFX retrospectives, not a product category). HIGH on anti-features (the consumer voice-assistant decade has a well-documented failure catalog).

---

## Scope Anchor

The user's chosen v1 scope (from `.planning/PROJECT.md` "Active" requirements) is:

1. Week-one skeleton — menu-bar host, transparent floating window, hotkey, WKWebView + R3F, message bus, LLM orchestrator with `Anthropic`/`Ollama` providers, three starter MCP tools (`get_time`, `get_clipboard`, `run_applescript`).
2. Full voice loop — openWakeWord `hey_jarvis` + Silero VAD, SpeechAnalyzer STT (WhisperKit fallback), AVSpeechSynthesizer (tier-1) + Orpheus via `mlx-audio-swift` (tier-2).
3. Vision first pass — webcam feed, Vision-framework face/presence detection, optional single-frame attach to Opus turn.
4. Memory first pass — SQLite + FTS5 + sqlite-vec, `nomic-embed-text` embeddings, mem0-style ADD/UPDATE/NOOP extraction via local Qwen 2.5-Coder 32B, temporal `valid_from`/`valid_to`.
5. Dev/observability — debug overlay, replay log, eval harness (15 scenarios), feature flags, structured logs.

Everything in FEATURES.md is indexed against this scope. The **Prioritization Matrix** at the bottom maps every feature to v1 / v1.x / v2.

---

## Feature Landscape

### Table Stakes (Users Expect These)

A 2026 user who has spent any time with ChatGPT Advanced Voice Mode, Superwhisper, Siri, Raycast AI, or a MacWhisper-style menu-bar tool comes to a Jarvis-style product with a specific set of expectations. Missing any of these reads as "toy" or "broken":

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Global hotkey summon/dismiss | Every Mac-native AI tool (Raycast, Superwhisper, Apple AI, Motive) has one. Cmd+Space muscle memory demands it. | LOW | Already in v1. Ship **unset** by default (R2 S8) — `Cmd+Shift+J` collides with Chrome/Slack/VS Code. Prompt on first launch with shortcut recorder. |
| Menu-bar presence (always visible, click to open, shows state) | It's how "ambient" gets signaled on macOS. Users expect a single icon that subtly reflects agent state. | LOW | In v1. Consider a subtle icon-state swap (solid/outline/filled) for idle/listening/speaking. |
| Text-chat fallback with streamed tokens | Voice fails in coffee shops, on calls, with flaky mics. Every voice-first product ships text-chat too; it's non-negotiable. | LOW | In v1. Single-turn input + streamed response. |
| Tool-call visibility (not hidden) | 2026 agent-UI convention (LangChain Agent Chat UI, AG-UI, DeepAgents, Superset): tool invocations render as expandable cards showing name, args, status (pending/running/complete/failed), result. Hiding tool calls makes the agent feel opaque and untrustworthy. | MEDIUM | In v1 as HUD state ring + chat-panel tool cards. The "ring color/pulse shift on tool call" convention the brief captures is necessary but not sufficient — add an expandable chat-panel card for post-hoc inspection. |
| Confirmation for destructive actions | Any tool that runs shell / AppleScript / filesystem mutations requires an explicit confirmation step per-call. Users who've been bitten (or read the headlines) won't use it otherwise. | MEDIUM | In v1. **Native** `NSAlert`/`NSPanel` sheet, not webview (R2 Sec3 / R3-S3 / AUDIT-R1 H-Sec3). Nested modal event loops are banned — they park MainActor and block barge-in. |
| Wake word + push-to-talk parity | Wake word alone is fragile. Users expect a keyboard fallback to start listening (push-to-talk) for noisy environments, quiet rooms where they don't want to say the phrase out loud, and anti-false-accept paranoia. | LOW | v1 has hotkey; extend to hold-to-talk variant (hold hotkey, speak, release → submit). |
| Visible listening indicator | If the mic is hot, the user needs an unambiguous affordance telling them so. Unclear "is it listening?" is the top UX complaint on every voice assistant. | LOW | Already in v1 via ring state machine. Augment with menu-bar icon tint. |
| Clean cancel/stop (barge-in) | 2026 standard since ChatGPT Advanced Voice Mode: user starts speaking mid-reply, the agent shuts up immediately. Anything else feels like 2015 Siri. | HIGH | In v1 via `cancelAndSubmit` + VoiceController TTS interrupt sequence (R2 V4). The "click/pop + stale sample self-trigger" pitfall is live. |
| Conversation history, browsable | "What did we decide earlier?" is a daily query. Without history the product is a glorified one-shot prompt box. | MEDIUM | In v1 via replay log; needs a chat-panel history view. |
| Explicit "not listening" affordance | Users need a single gesture/shortcut to mute the wake word (privacy moments, phone calls, screen shares). This is a 2026 table-stakes privacy expectation, not a differentiator. | LOW | Add to v1 menu-bar UI. Toggle "Mute wake word" that cleanly disarms openWakeWord + VAD. Persist across restarts; show clearly in menu-bar icon. |
| Low-latency voice response | Sub-500 ms time-to-first-audio from end-of-user-speech is the 2026 bar (Cartesia Sonic 3 at 40 ms, Orpheus at 187 ms TTFB, Kokoro at 97 ms are the reference points). Anything over ~800 ms feels laggy. | HIGH | In v1 with tier-2 TTS. Target 150–250 ms TTFA for Orpheus per CLAUDE.md, plus STT + LLM-first-token time. Budget audits matter. |
| Streaming chat tokens | Non-streaming = immediate "feels old." Every 2026 agent UI streams tokens. | LOW | In v1. |
| Token/context awareness exposed somewhere | Users who've hit context limits on other tools want to see how full their window is. | LOW | In v1 via DevOverlay. |
| Secrets not in plaintext | Any tool that touches an API key needs Keychain-grade storage. Users who've been burned won't ship their key into a JSON file. | LOW | In v1. API keys via Keychain; native SwiftUI `SecureField` sheet for entry, not a webview field (R2 Sec3). |
| Granular TCC permission prompting | macOS Tahoe expects per-capability prompts; surprise-prompts at odd moments feel like malware. | LOW | In v1 via incremental TCC strategy — prompt when capability is first used, graceful denial surface. |

### Differentiators (Competitive Advantage)

These are where this project diverges from the ChatGPT-on-macOS / Superwhisper / Raycast-AI crowd. They're what make it "Jarvis" rather than "another chat wrapper with voice":

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Cinematic R3F particle-ring HUD | Nothing else on Mac does this. Apple AI / Motive / Menu AI all ship bog-standard SwiftUI panes. A reactive, shader-driven HUD is the singular visual signature. | HIGH | In v1 (one ring, four states). The film-Jarvis UX literature (Jayse Hansen portfolio, Sci-fi Interfaces, scifiinterfaces.com) consistently describes Jarvis as **radial, expanding on demand, receding when idle** — the one-ring skeleton is the right v1 move. |
| Fully local voice stack (no cloud STT/TTS) | ChatGPT Advanced Voice sends every utterance to OpenAI. This product never does. That's a privacy posture none of the big-name assistants match. | HIGH | In v1. The local-only constraint is the differentiator; users who care about this care *a lot*. |
| In-process Orpheus TTS (no Python sidecar) | `mlx-audio-swift` eliminates the Python-sidecar tax that plagues Kokoro/Coqui/Piper setups. Cold-start is instant, no separate process, no venv drift. | MEDIUM | In v1 behind feature flag. Orpheus output format probe at startup (R3-V3) is the gotcha. |
| Model-agnostic from day one (Opus ↔ Ollama toggle) | Most "personal AI assistants" lock you to one cloud provider. Apple AI hardcodes seven, but none let you swap to a local Qwen. First-class `LLMProvider` protocol with real parity means "cheap/offline/private" isn't a second-class path. | MEDIUM | In v1. Know-good local baseline is `qwen2.5-coder:32b` via Ollama `/api/chat` (CLAUDE.md pins this). |
| MCP-native tool system | MCP is the 2026 industry-standard; this product adopts it natively, not as an afterthought adapter. Every capability becomes a permission-gated, isolated sidecar. | HIGH | In v1 (three starter tools). Nested `.app` helper bundle pattern (R2 S2/S3) gives per-helper TCC identity — significant beyond what the `steipete/macos-automator-mcp` and `joshrutkowski/applescript-mcp` crowd ship today. |
| On-device presence/face awareness | The agent knows when you walk back to the desk. "Welcome back" is a moment the big assistants can't do — their cloud architecture makes it too invasive to even try. | MEDIUM | v1 first pass per PROJECT.md (Vision framework face detection). **Critical privacy guardrail**: presence signal must never auto-unmute the mic, auto-invoke a tool, or auto-speak. It's a *signal* the agent can react to in-dialogue ("good to see you back"), not a trigger. See anti-features below. |
| Ambient "it's just there" presence | Menu-bar + borderless transparent always-on-top HUD + optional persistent ring visible in a corner. This is the Core-Value framing in PROJECT.md: *ambient presence*, not chatbot-with-voice. | MEDIUM | v1 ships the summon/dismiss version. v1.x can add an "ambient corner mode" where the ring stays visible at 10% opacity, pulses when listening, on top of all apps. This is the cinematic differentiator. |
| In-process memory with temporal validity | Siri has no persistent memory; ChatGPT has memory but it's cloud-only and global (no temporal supersession). The mem0 ADD/UPDATE/NOOP + `valid_from`/`valid_to` pattern (Zep/Graphiti-style) means "Sarah works at Acme" can be superseded by "Sarah now works at Beta Corp" without either being deleted — fully on-device. | HIGH | In v1 first pass. Mem0 itself **does not** ship temporal validity (researched 2026-04-21); this implementation borrows Graphiti's model. Don't call it "mem0-compatible" — call it mem0-style extraction on a temporal store. |
| "Forget this" explicit control | Users who adopt memory want a rollback lever. "Forget what I just told you about Sarah" should work. | MEDIUM | v1.x. Needs a small memory-control tool or chat-time intent recognition + a dedicated MCP tool (`memory_forget(fact_id \| pattern)`). Pair with a "show me what you remember about X" path. |
| Full conversation replay with deterministic re-run | Every turn (user input, LLM output, tool calls, tool results) goes to SQLite. A `jarvis replay <file>` reproduces a prior session through the real pipeline. This is debug gold; it's also what makes the eval harness meaningful. | MEDIUM | In v1 per CLAUDE.md NFRs. The `replayToModel(row)` single-entry helper (R3-Sec11) is what keeps replay safe. |
| Eval harness tied into replay | 15–25 hand-written scenarios re-run after significant changes, with `MockLLMProvider` playing the recorded `LLMEvent` stream for `replay-roundtrip` tests (R3-B12). Byte-equality modulo IDs/timestamps. Nothing else in the personal-assistant space ships this. | MEDIUM | In v1 per CLAUDE.md NFRs. |
| Dev-overlay with per-turn latency breakdown | Wake-to-first-token, first-token-to-end-of-stream, tool-call times, TTS first-audio latency, tokens in/out. Users building this product are debugging it daily. | MEDIUM | In v1. Toggle-able (users who aren't debugging don't want to see it). |
| Feature flags for risky tools | Every risky capability (Orpheus, WhisperKit fallback, screen capture in v2, AppleScript allowlists post-v1) gates behind a flag the user can toggle without rebuild. | LOW | In v1 per CLAUDE.md. Security-relevant flags require app restart (R2 Sec6) — this is itself a differentiator against the "hot-swap everything" crowd that Home Assistant voice shipped. |

### Anti-Features (Commonly Requested, Often Problematic)

The entire consumer voice-assistant decade is a catalog of features that sound good and create problems. This list is opinionated:

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Cloud TTS/STT (ElevenLabs, OpenAI Whisper cloud, Cartesia) | "Better quality, easier to integrate." | Breaks the privacy posture that's the whole point of this product. Voice data off-device means someone else gets to train on your conversations. Amazon Echo's 2018 "sent a conversation to a random contact" incident is the class of failure. User constraint is explicit: no cloud TTS/STT, ever. | Tier-1 AVSpeechSynthesizer + tier-2 Orpheus via `mlx-audio-swift`. Tier-3 Kokoro only if Orpheus proves insufficient (adds Python sidecar — avoid). |
| Presence-triggered auto-speak ("Welcome back, sir") | Cinematic. Feels like Jarvis-the-film. | **Privacy landmine.** Presence detection + auto-speech means the product talks to you when other people are in the room. It also means your webcam is always making recording-adjacent decisions. If the signal misfires (siblings, partners, delivery drivers), it's creepy. This is the single most common trap in "cinematic" voice-assistant design. | Presence is an **input signal** the agent can use in-dialogue, never a trigger. If the user is already speaking or has the HUD summoned, a "welcome back" is warranted; if the HUD is dismissed, presence silently updates state, nothing more. |
| Always-speaking "ambient commentary" | Feels immersive. Film Jarvis makes offhand remarks. | Notification fatigue is the #1 reason users disable voice features. Cortana died of this. Users turn the product off within a week. | Agent speaks only when: (1) responding to a user turn, (2) a tool they invoked returned, (3) they explicitly opted into a scheduled briefing. Unsolicited speech is banned. |
| Real-time screen-content narration (what you're looking at) | "It's like the HUD in the movie!" | Invasive, battery-eating, privacy-nightmare, and Opus-4.7-context-expensive (frames → ~35% token inflation per CLAUDE.md Opus tokenizer note). ScreenCaptureKit TCC prompt re-issues weekly from Sequoia forward. | On-demand screen capture in v2 ("look at my screen and tell me what I'm looking at"), never passive narration. |
| Cloud-synced memory across devices | "I have a laptop and a desktop." | The moment memory leaves the machine, every other piece of the privacy posture is theater. iCloud sync invalidates the "nothing user-sensitive ever leaves the machine" frame. | Local-first; explicitly deferred per PROJECT.md Out of Scope. If multi-device becomes real, it's a user-driven explicit export/import, not silent sync. |
| Automatic app-launch based on inferred intent | "Open Spotify when I sit down at my desk." | Side effects at wrong times are worse than missing side effects. The agent should propose, not execute, ambient actions. Same class of anti-pattern as notification fatigue. | If the user wants this, they build a Shortcut/AppleScript and ask Jarvis to run it explicitly. |
| AppleScript "skip confirmation allowlist" | "I run the same AppleScripts constantly; this is annoying." | Substring blocklists and regex allowlists are trivially bypassed (string concat, `run script`, `load script`, homoglyphs — R2 Sec2 condemned these). Every "narrow allowlist" in practice invites a regex; regex re-opens the bypass. | **No skip-allowlist in v1** (R3-Sec6). Every `run_applescript` invocation requires the confirmation checkbox. OSA-level AST matching can be revisited post-v1 — but only as a hardening, never as a UX convenience. |
| Multi-user / multi-tenant support | "What if my partner wants to use it?" | Sprawls the threat model from "nothing weird from the LLM" to authentication, authorization, per-user memory partitioning, per-user voice enrollment — an entirely different product. | Single-user locked per PROJECT.md. A second user installs their own instance. |
| Fully hands-free "continuous conversation" without wake word | "Why do I have to say 'Hey Jarvis' every time?" | Users don't want the mic always-hot-and-transmitting mid-conversation after the first turn — it captures everything said in the room for the length of the session. ChatGPT Advanced Voice has gone back and forth on this with user pushback. | Wake word for session-start; during active turn, the mic is naturally hot for barge-in; the session **closes** after a timeout of silence, not stays open forever. Session length budget is a UX knob, not "infinite." |
| LLM deciding what to remember silently | "The memory system should learn automatically." | Users need to see and edit what's being stored about them. Silent memory is a black box users stop trusting after the first wrong fact. | mem0-style extraction runs with an explicit "memory updated" affordance (chat-panel callout or DevOverlay entry); any fact is inspectable via "what do you remember about X"; any fact is removable via "forget X". |
| Unified command bar / launcher (Raycast-style) | "I already use Raycast; why isn't Jarvis my launcher?" | Conflates two products. Raycast is great at what it does. Launching apps via a command bar is not what makes this "Jarvis." | Jarvis has a chat surface and a voice surface, not a command palette. Users who want a launcher use Raycast *and* Jarvis. |
| Vision-model "look at my face and infer my mood" | Cinematic. Emotional computing is seductive. | State-of-the-art emotion detection is unreliable + frequently culturally biased + edges into surveillance. Users don't want it (researched behavior in every "smart mirror" study). | Face **presence** detection is fine and useful (walked in/out). Face *interpretation* is out of scope. |
| Always-on window (full-screen HUD occluding work) | "Immersion!" | No one can actually work with a holographic overlay blocking their IDE. Film Jarvis is fiction. | Summon/dismiss as default. v1.x optional ambient-corner mode (small, edge-pinned, 10% opacity, expandable on interaction). |
| Speaking long responses out loud in full | "I asked a question; read me the answer." | A 400-word response spoken at 180 wpm is 2+ minutes the user can't skim. Frustrating. | Short-form answers are spoken in full. Long-form answers get a one-sentence spoken summary ("I've put the full answer in the chat — want me to read it?") with the full text in the chat panel. Keep this as a v1.x behavior flag; don't ship default without testing. |

---

## Feature Dependencies

```
Summon/dismiss HUD (hotkey + transparent window)
    └── requires ──> Swift menu-bar host + WKWebView mount
                          └── requires ──> Hardened Runtime + allow-jit entitlement

R3F particle ring (state machine: idle/listening/thinking/speaking/awaitingConfirmation/booting/reconfiguring)
    └── requires ──> Swift↔JS typed message bus (Codable + type discriminator)
                          └── requires ──> HudStateCoordinator (@MainActor single writer)

Streaming chat (tokens + tool-call cards)
    └── requires ──> AgentOrchestrator streaming events
    └── requires ──> WebviewBridge OutboundBatcher @ ~30 Hz

Tool-call cards in chat
    └── requires ──> LLMEvent.toolUseRequested/toolCallStart/toolCallEnd
    └── enhances ──> HUD ring color shift on tool call

Confirmation UI for destructive tools
    └── requires ──> ConfirmationBroker (non-blocking sheet on dedicated NSPanel)
    └── conflicts with ──> Blocking modal presentation (parks MainActor, breaks barge-in)

Wake word listening
    └── requires ──> openWakeWord + Silero VAD + AEC-enabled input graph
    └── requires ──> Input Monitoring TCC grant
    └── enhances ──> Push-to-talk (shared audio graph)

Barge-in
    └── requires ──> Wake word active during TTS playback
    └── requires ──> TTS interrupt sequence (cancel → fade → stop → tts_stopped event)
    └── requires ──> AgentOrchestrator.cancelAndSubmit (single atomic entry)

Tier-2 TTS (Orpheus)
    └── requires ──> Tier-1 TTS (AVSpeechSynthesizer) working first
    └── requires ──> Orpheus output-format probe at startup (R3-V3)
    └── requires ──> allow-jit entitlement (MLX Metal)
    └── enhances ──> Sub-250 ms time-to-first-audio target

Vision (presence/face)
    └── requires ──> Camera TCC grant
    └── requires ──> AVFoundation capture session
    └── conflicts with ──> "Auto-speak on presence detection" (anti-feature)

Memory (mem0-style + temporal)
    └── requires ──> SQLite + FTS5 + sqlite-vec
    └── requires ──> Ollama + nomic-embed-text + qwen2.5-coder:32b
    └── requires ──> Replay log (turn history for extraction input)
    └── enhances ──> "What do you remember about X" query path
    └── enables ──> "Forget this" tool

Replay log
    └── requires ──> AgentOrchestrator semantic events stream
    └── requires ──> SQLite writer actor + bounded AsyncChannel
    └── enables ──> Memory extraction, eval harness, DevOverlay, replayToModel()

Eval harness
    └── requires ──> Replay log
    └── requires ──> MockLLMProvider (feeds recorded LLMEvent sequence)
    └── requires ──> TurnSource.eval (R3-A10)

DevOverlay
    └── requires ──> AgentOrchestrator semantic events
    └── requires ──> Per-turn timing instrumentation

MCP tools (all)
    └── requires ──> MCPClient actor + per-server restart mutex
    └── requires ──> Nested Contents/Helpers/mcp-<name>.app/ layout
    └── requires ──> Per-helper entitlements (mcp-applescript is the only one with automation.apple-events)

run_applescript
    └── requires ──> AppleScript MCP server
    └── requires ──> Confirmation UI
    └── requires ──> AEDeterminePermissionToAutomateTarget preflight
    └── requires ──> mcp-applescript.entitlements (NOT main app — R3-S5)

get_clipboard
    └── requires ──> Clipboard MCP server
    └── requires ──> File-URL refusal policy (R3-Sec5)

Ambient "corner mode" (persistent ring at low opacity)
    └── requires ──> Summon/dismiss working
    └── requires ──> NSWindow level/opacity manipulation
    └── enhances ──> "It's just there" Core Value framing
```

### Dependency Notes

- **Tool-call cards require streaming events**: The AG-UI/LangChain convention (TOOL_CALL_START / TOOL_CALL_END with parent message binding) is what makes "expandable cards" work. The Swift orchestrator already emits `toolCallStart`/`toolCallEnd` per `docs/PLAN-week-one.md` §Thread model — the chat UI just needs to bind cards to these.
- **Barge-in requires wake word stays hot during TTS**: If the mic closes while TTS plays, barge-in is impossible. This is the whole reason `isVoiceProcessingEnabled = true` matters (AEC) — to prevent the speaker output from self-triggering the wake-word detector. The R2 V4 TTS-interrupt sequence (cancel → 10 ms fade → stop → publish `.ttsStopped`) is what makes the `speaking → listening` transition clean.
- **Memory extraction depends on replay log**: Mem0's ADD/UPDATE/NOOP pattern is executed *after the turn*, reading from the turn history. Without a replay log, the extractor has no input. This is why replay log is v1, not v1.x.
- **Ambient corner mode conflicts with most existing launcher/palette tools**: If Jarvis tries to be a command palette and a HUD and a chat pane, each surface fights the others. Keep v1 to summon/dismiss + menu-bar; add ambient corner mode only after the core loop is validated.
- **Eval harness depends on replay log**: The `replay-roundtrip` oracle (R3-B12) literally replays recorded LLMEvent streams through `MockLLMProvider`. No replay log ⇒ no eval harness of the kind CLAUDE.md describes.
- **Vision "enhances" rather than "requires" dialogue**: The Core Value is ambient presence. Vision makes the agent feel ambient-aware, but the voice loop is fully functional without it. Treat vision as a presence *signal* not a dialogue *gate*.

---

## MVP Definition

### Launch With (v1) — aligned to PROJECT.md "Active"

Minimum set to validate "is this actually Jarvis or is it a chatbot with a glow filter":

- [x] Summon/dismiss HUD (menu-bar + hotkey + transparent window) — **essential** for ambient presence
- [x] R3F single particle ring with four+two states (idle / listening / thinking / speaking + booting + awaitingConfirmation) — **essential** for the cinematic signature
- [x] Typed message bus, HUD state single-writer — **essential** for correctness
- [x] LLMProvider with Anthropic (Opus 4.7) + Ollama (Qwen 2.5-Coder 32B) — **essential** for the "not locked to one provider" differentiator
- [x] Three MCP tools (`get_time`, `get_clipboard`, `run_applescript`) — **essential** to prove the MCP integration works end-to-end
- [x] Native confirmation UI for AppleScript — **essential** for safety
- [x] Wake word (openWakeWord + Silero VAD) — **essential** for "always-on voice"
- [x] STT primary (SpeechAnalyzer) + fallback (WhisperKit) behind flag — **essential**
- [x] TTS tier-1 (AVSpeechSynthesizer) — **essential** (instant, reliable, free)
- [x] TTS tier-2 (Orpheus via `mlx-audio-swift`) behind flag — **essential** for the sub-250 ms TTFA differentiator
- [x] Text-chat fallback with streamed tokens — **essential** (voice isn't always appropriate)
- [x] Tool-call cards in chat panel — **essential** per 2026 agent-UI convention
- [x] Mute-wake-word control (menu-bar toggle) — **add to active reqs** — standard privacy affordance, missing from PROJECT.md
- [x] Push-to-talk (hold-hotkey-to-talk) variant — **add to active reqs** — wake-word has too much variance to ship without keyboard fallback
- [x] Vision first pass (face/presence detection) as a **signal only**, not a trigger — per PROJECT.md
- [x] Memory first pass (SQLite + FTS5 + sqlite-vec + mem0-style extraction + temporal validity) — per PROJECT.md
- [x] DevOverlay (agent state, last 5 tool calls, token count, latency breakdown) — per CLAUDE.md NFRs
- [x] Replay log (SQLite) + `jarvis replay` command — per CLAUDE.md NFRs
- [x] Eval harness (15 scenarios, command-line) — per CLAUDE.md NFRs
- [x] Feature flags (runtime toggles; security-relevant ones require restart) — per CLAUDE.md NFRs
- [x] Structured logs (agent/tools/UI/system channels) — per CLAUDE.md NFRs
- [x] Keychain-stored secrets + native SwiftUI `SecureField` entry — per CLAUDE.md + R2 Sec3

**Two additions called out for REQUIREMENTS.md:** "Mute wake word" menu-bar toggle and "push-to-talk" hotkey variant are both table stakes the Active requirements list in PROJECT.md doesn't yet name explicitly. They're low-complexity and address live UX pitfalls.

### Add After Validation (v1.x)

- [ ] Conversation history browser in chat panel — **trigger**: after v1 replay log is stable, surface history as a scrollable pane (not just a replay-from-CLI affordance)
- [ ] "What do you remember about X" memory query path — **trigger**: after memory extraction is stable
- [ ] `memory_forget` MCP tool — **trigger**: same; pairs with the remember-query
- [ ] Long-answer summarization flow ("I put the full answer in chat — want me to read it?") — **trigger**: after users complain about listening-to-wall-of-text, if they do
- [ ] Ambient corner mode (persistent low-opacity ring in screen corner, expand on interaction) — **trigger**: after v1 summon/dismiss is stable and the Core Value "ambient presence" framing warrants deeper expression
- [ ] Memory-updated affordance (toast or chat callout when a fact is extracted) — **trigger**: when users start missing "what did you just learn about me?"
- [ ] Broader MCP tool set (calendar via Apple Native Apps MCP pattern, music via AppleScript Music, notifications via `osascript display notification`) — **trigger**: v1 tool-loop is solid; each tool ships behind its own flag
- [ ] Shortcut-recorder default hotkey on first launch (R2 S8) if not already in week-one — **trigger**: first collision complaint
- [ ] Menu-bar icon that reflects agent state (idle/listening/speaking) — **trigger**: if users ask "is it listening?" without the HUD summoned
- [ ] Turn replay playback through live pipeline (beyond `replay-roundtrip` eval oracle) — **trigger**: when debugging long sessions becomes painful
- [ ] Per-tool cost/latency dashboards in DevOverlay — **trigger**: after Opus 4.7 billing reality sets in

### Future Consideration (v2+) — per PROJECT.md Out of Scope

- [ ] Screen capture / ScreenCaptureKit — **defer** per PROJECT.md; big TCC surface, significant scope, not needed to prove the loop
- [ ] Multi-panel holographic HUD (weather tile, calendar-next-up tile, task-list tile, etc.) — **defer** per PROJECT.md; single ring validates the rendering pipeline first
- [ ] Browser automation (Chrome DevTools Protocol MCP, or `osascript` Chrome tabs) — **defer**; heavy additional attack surface
- [ ] Multi-device iCloud sync for memory — **defer** per PROJECT.md; local-first until single-machine proves out
- [ ] Post-v1 AppleScript OSA-AST allowlist — **defer**; skip-allowlist regex was explicitly condemned (R3-Sec6)
- [ ] Kokoro-82M tier-3 TTS — **defer** per CLAUDE.md; only if Orpheus proves insufficient (Python sidecar tax)
- [ ] Scheduled briefings ("morning brief at 8 AM") — **defer**; wanders toward unsolicited-speech anti-feature unless explicitly scoped
- [ ] Llama 4 with `llama4_pythonic` parser as a third LLMProvider — **defer**; not yet trusted per CLAUDE.md
- [ ] Second-model AppleScript audit (local Ollama evaluates proposed script before confirmation) — **defer**; post-week-one per R3-Sec10

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Summon/dismiss HUD | HIGH | LOW | P1 |
| Menu-bar presence | HIGH | LOW | P1 |
| R3F particle ring (state machine) | HIGH (differentiator) | HIGH | P1 |
| Message bus + HUD single-writer | HIGH (correctness) | MEDIUM | P1 |
| LLMProvider + Anthropic + Ollama parity | HIGH (differentiator) | MEDIUM | P1 |
| Three starter MCP tools | MEDIUM | MEDIUM | P1 |
| Native confirmation UI | HIGH (safety) | MEDIUM | P1 |
| Wake word + VAD | HIGH | HIGH | P1 |
| STT primary + fallback | HIGH | MEDIUM | P1 |
| TTS tier-1 (AVSpeech) | HIGH | LOW | P1 |
| TTS tier-2 (Orpheus) | HIGH (differentiator) | HIGH | P1 (flagged) |
| Text-chat fallback with streaming | HIGH | LOW | P1 |
| Tool-call cards | HIGH | MEDIUM | P1 |
| Mute-wake-word toggle | HIGH (privacy) | LOW | P1 (**new; add to Active reqs**) |
| Push-to-talk variant | MEDIUM | LOW | P1 (**new; add to Active reqs**) |
| Vision first pass (presence only) | MEDIUM | MEDIUM | P1 |
| Memory first pass (mem0 + temporal) | HIGH (differentiator) | HIGH | P1 |
| DevOverlay | HIGH (dev ergonomics) | MEDIUM | P1 |
| Replay log | HIGH (enables eval + memory) | MEDIUM | P1 |
| Eval harness | HIGH (dev ergonomics) | MEDIUM | P1 |
| Feature flags | MEDIUM | LOW | P1 |
| Structured logs | MEDIUM | LOW | P1 |
| Keychain secrets + SecureField entry | HIGH (safety) | LOW | P1 |
| "What do you remember about X" | MEDIUM | MEDIUM | P2 |
| `memory_forget` tool | MEDIUM | MEDIUM | P2 |
| Conversation history browser | MEDIUM | MEDIUM | P2 |
| Long-answer summarization flow | MEDIUM | LOW | P2 |
| Ambient corner mode | HIGH (Core Value) | MEDIUM | P2 |
| Memory-updated affordance | MEDIUM | LOW | P2 |
| Broader MCP tool catalog | HIGH | MEDIUM–HIGH | P2 |
| Menu-bar icon state reflection | MEDIUM | LOW | P2 |
| Per-tool cost/latency dashboards | MEDIUM | LOW | P2 |
| Screen capture (ScreenCaptureKit) | HIGH | HIGH | P3 (v2) |
| Multi-panel holographic HUD | MEDIUM (cinematic) | HIGH | P3 (v2) |
| Browser automation tool | MEDIUM | HIGH | P3 (v2) |
| Multi-device sync | LOW (user is single-machine) | HIGH | P3 (v2) |
| Kokoro tier-3 TTS | LOW (Orpheus covers) | MEDIUM (Python sidecar) | P3 (v2) |
| Scheduled briefings | LOW (anti-feature risk) | MEDIUM | P3 (v2) |
| Second-model AppleScript audit | MEDIUM (hardening) | MEDIUM | P3 (post-v1) |
| **Presence-triggered auto-speak** | — | — | **ANTI (never)** |
| **Cloud TTS/STT** | — | — | **ANTI (never)** |
| **AppleScript skip-allowlist** | — | — | **ANTI (until AST matching exists)** |
| **Always-speaking ambient commentary** | — | — | **ANTI (never)** |
| **Silent memory updates** | — | — | **ANTI (always show)** |
| **Fully hands-free continuous conversation** | — | — | **ANTI (session-scoped only)** |

**Priority key:**
- **P1**: Must ship for v1 (the "usable Jarvis" milestone)
- **P2**: v1.x — add incrementally once v1 is stable and the feature has a real user pull
- **P3**: v2+ — deferred per PROJECT.md Out of Scope
- **ANTI**: Do not build. Reconsider only with explicit rationale.

---

## Competitor Feature Analysis

This is less "competitors" than "adjacent tools" — no one else is building a private, local-voice, LLM-brained, cinematic-HUD personal assistant on macOS at this price point. The closest shipping products fall into three buckets: menu-bar LLM wrappers, voice-transcription tools, and hobbyist Jarvis replicas.

| Feature | Apple AI / Motive / Menu AI (menu-bar LLM wrappers) | Superwhisper / MacWhisper (voice-transcription) | ChatGPT Advanced Voice | Home Assistant Voice + `hey_jarvis` (hobbyist) | Our Approach |
|---------|--------------------------------------------------|--------------------------------------------|------------------------|----------------------------------------------|--------------|
| Voice in | — (text only) | Local Whisper | Cloud (OpenAI) | Local (openWakeWord + Whisper) | Local (openWakeWord + SpeechAnalyzer, WhisperKit fallback) |
| Voice out | — | — | Cloud TTS | Local (Piper) or cloud | Local (AVSpeech + Orpheus tier) |
| Wake word | — | — | — (push-to-talk) | `hey_jarvis` via openWakeWord | `hey_jarvis` via openWakeWord + Silero VAD |
| LLM | Chooses from many clouds | (not LLM-native) | OpenAI only | Configurable LLM backend | Opus 4.7 primary + Ollama first-class |
| Visual | Plain chat window | Transcript overlay | Plain chat pane | Terminal / HA dashboards | R3F cinematic HUD + chat pane |
| Tool system | None / basic shortcuts | None | OpenAI function-calling | Home Assistant integrations (smart-home focus) | MCP (industry-standard, extensible) |
| Memory | Cloud ChatGPT-style / none | None | Cloud ChatGPT memory | None | Local SQLite + temporal validity + mem0-style |
| Confirmation for destructive actions | N/A | N/A | Tool-call approval flow | Per-integration | Native `NSAlert`/`NSPanel` sheet, per-call |
| Ambient presence | Menu bar only | Menu bar + dictation window | — (launcher) | Home dashboard | Menu bar + summonable HUD + (v1.x) corner mode |
| Privacy posture | Sends to chosen cloud LLM | Local option | Cloud everything | Local | Local-only voice + memory; LLM is the only optional cloud hop |
| Dev ergonomics | None / basic logs | None | — | Partial (HA logs) | DevOverlay, replay, eval harness, feature flags |

**The gap we fill:** No one in 2026 is shipping *ambient* + *local-voice* + *cinematic-HUD* + *MCP-native-tools* + *LLM-brained* as a single product on macOS. Apple AI / Motive are chat wrappers. Superwhisper is a dictation tool. ChatGPT Voice is cloud. Home Assistant is smart-home-focused and hobbyist. The brief's "Jarvis" framing is genuinely underserved.

---

## Sources

### Wake-word + voice UX
- [Picovoice wake-word guide, 2026](https://picovoice.ai/blog/complete-guide-to-wake-word/) — industry benchmarks (Porcupine <5% FRR @ 1 FA/10h)
- [openWakeWord `hey_jarvis` model docs](https://github.com/dscripka/openWakeWord/blob/main/docs/models/hey_jarvis.md) — VAD gating via Silero, `vad_threshold` parameter
- [openWakeWord README](https://github.com/dscripka/openWakeWord) — 97%+ TPR / <1 FA/hr across six keywords
- [Home Assistant "Hey Jarvis" reliability issue](https://github.com/esphome/home-assistant-voice-pe/issues/401) — real-world "Hey Jarvis" variability (1-2/10 vs. 9/10 for other wake words)
- [Sensory 2026 Custom Wake Words guide](https://sensory.com/custom-wake-words-branded-voice-ux-guide-2026/) — 3–4 syllable recommendation
- [Barge-In for Voice Agents guide (orga-ai)](https://orga-ai.com/blog/blog-barge-in-voice-agents-guide) — barge-in framed as must-have for natural conversation
- [ChatGPT Advanced Voice Mode interruption complaints](https://community.openai.com/t/feature-request-advanced-voice-mode-keeps-interrupting-me/962909) — real-world UX pushback on over-eager interruption

### TTS latency + quality benchmarks
- [Inworld 2026 TTS API benchmarks](https://inworld.ai/resources/best-voice-ai-tts-apis-for-real-time-voice-agents-2026-benchmarks)
- [kveeky / VoiceAI Pulse real-time TTS benchmarks](https://kveeky.com/news/real-time-tts-api-benchmarks-ai-call-center-agents) — Orpheus 187 ms TTFB, Kokoro 97 ms, Cartesia Sonic 3 40 ms
- [BentoML open-source TTS roundup 2026](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models) — Kokoro 82M rankings
- [Deepgram streaming TTS latency guide](https://deepgram.com/learn/streaming-tts-latency-accuracy-tradeoff)
- [Camb.ai real-time TTS guide 2026](https://www.camb.ai/blog-post/real-time-tts-api-for-low-latency-speech-streaming)

### Memory (mem0 + temporal)
- [Mem0 "State of AI Agent Memory 2026"](https://mem0.ai/blog/state-of-ai-agent-memory-2026)
- [Mem0 vs Zep/Graphiti comparison](https://vectorize.io/articles/mem0-vs-zep) — key finding: Mem0 has no native temporal model; Zep does via `valid_from`/`valid_to`/`invalid_at`
- [Mem0 core-concepts memory types](https://docs.mem0.ai/core-concepts/memory-types)
- [Mem0 timestamp parameter added Feb 2026](https://github.com/mem0ai/mem0) — v1.0.4 backfill support
- [Mem0 memory decay and lifecycle policies](https://mem0.ai/blog/ai-memory-layer-guide)

### Agent UI / streaming chat conventions
- [AG-UI Protocol (standardized agent UI events)](https://medium.com/@codewithrashid/ag-ui-the-missing-piece-of-the-ai-agent-stack-186bb15d1357) — TOOL_CALL_START/END, text-delta per token
- [LangChain Agent Chat UI docs](https://docs.langchain.com/oss/python/langchain/ui) — collapsible tool-call cards, tool-lifecycle rendering
- [Inference.sh UI guide (streaming + collapsible tool panels)](https://inference.sh/blog/guides/shadcn-registry)
- [Agent UI essay — BrightCoding 2026](https://www.blog.brightcoding.dev/2026/03/26/agent-ui-the-essential-chat-interface-for-ai-agents)

### macOS MCP landscape
- [`joshrutkowski/applescript-mcp`](https://github.com/joshrutkowski/applescript-mcp) — reference AppleScript MCP server
- [`steipete/macos-automator-mcp`](https://github.com/steipete/macos-automator-mcp) — JXA + AppleScript MCP; knowledge-base pattern
- [`Dhravya/apple-mcp`](https://github.com/Dhravya/apple-mcp) — Contacts/Notes/Messages/Mail/Reminders/Calendar/Maps via native tools
- [Michael Tsai roundup — MCP tools for Mac (2025-06)](https://mjtsai.com/blog/2025/06/03/model-context-protocol-mcp-tools-for-mac/)

### macOS personal-assistant adjacents (competitor analysis)
- [Motive — menu-bar personal AI agent](https://motivework.app/) — 18 providers incl. Ollama/LM Studio
- [Apple AI (bunnysayzz)](https://dev.to/bunnysayzz/meet-apple-ai-a-native-menu-bar-ai-assistant-built-for-mac-users-1bj8) — always-on-top chat, multi-provider
- [Superwhisper](https://superwhisper.com/) — voice-to-text, local + cloud, Raycast integration
- [Raycast Store: Superwhisper extension](https://www.raycast.com/nchudleigh/superwhisper)
- [Priler/jarvis (Rust offline voice assistant)](https://github.com/Priler/jarvis) — hobbyist reference

### Vision / presence
- [Apple Vision framework documentation](https://developer.apple.com/documentation/vision) — macOS support confirmed, on-device
- [Apple ML Research — on-device face detection](https://machinelearning.apple.com/research/face-detection)
- [Vision framework tracking the user's face in real time](https://developer.apple.com/documentation/Vision/tracking-the-user-s-face-in-real-time)

### Cinematic HUD references
- [Jayse Hansen — Iron Man HUD designer portfolio](https://jayse.tv/v2/?portfolio=hud-2-2) — primary source on film-Jarvis UI language
- [Sci-fi Interfaces — Iron HUD tag](https://scifiinterfaces.com/tag/iron-hud/?order=asc) — deep analysis of Jarvis interaction patterns (radial, expand-on-demand)
- [VFXBlog oral history of Iron Man HUD](https://vfxblog.com/ironman/)
- [Ruben D. Galvan — Redesigning the JARVIS UX (Minimalist)](https://medium.com/fictional-products-for-fictional-worlds/redesigning-the-jarvis-ux-a-minimalist-approach-to-a-genius-system-208b39113e8d)
- [Piyush P — Iron Man HUD cognitive clarity essay](https://medium.com/design-bootcamp/the-iron-man-hud-designing-for-cognitive-clarity-in-a-generative-ui-world-c4d262b7c279)

### Agent observability
- [OpenTelemetry for AI Systems (Uptrace, 2026)](https://uptrace.dev/blog/opentelemetry-ai-systems)
- [AgentOps.ai](https://www.agentops.ai/) — rewind/replay with point-in-time precision
- [Agent Observability 2026 guide (digitalapplied)](https://www.digitalapplied.com/blog/agent-observability-2026-evals-traces-cost-guide)
- [Sentry AI agent observability](https://blog.sentry.io/ai-agent-observability-developers-guide-to-agent-monitoring/)

### Privacy / anti-features
- [TermsFeed voice assistant privacy issues](https://www.termsfeed.com/blog/voice-assistants-privacy-issues/)
- [ScienceDirect survey — security and privacy in voice assistants](https://www.sciencedirect.com/science/article/pii/S0167404823003589)
- [TrueAIValues always-on listening risks](https://trueaivalues.com/ai-values/privacy-and-consent/voice-assistants-and-always-on-listening-risks/)
- [UCSD SenSys '20 — speech privacy against voice assistants (MicShield)](https://xyzhang.ucsd.edu/papers/KSun_SenSys20_MicShield.pdf) — empirical unintentional-activation corpus

---

## Open Questions for REQUIREMENTS.md to Resolve

1. **Ambient corner mode timing.** Core Value is "ambient presence." v1 ships summon/dismiss only. Is corner-mode a P2 v1.x add (recommended — builds on v1 infra) or does it need to ship in v1 for the Core Value to be credibly delivered? Proposed answer: v1 ships summon/dismiss, v1.x promotes corner-mode to the next feature pulled forward (cheap win, high Core-Value leverage).
2. **Menu-bar icon state reflection.** Not called out in PROJECT.md Active requirements but is a ~1-day feature with HIGH privacy value (users can see "is Jarvis listening?" without summoning the HUD). Recommend promoting to v1.
3. **Mute-wake-word toggle and push-to-talk.** Not called out explicitly in PROJECT.md. Both are table stakes and cheap. Recommend adding to v1 Active requirements.
4. **"Memory updated" user-facing affordance.** PROJECT.md has memory extraction but no user-facing affordance for when a fact lands. Without it, the "silent memory is a trust sink" anti-feature leaks into v1. Recommend v1.x addition; could ship in v1 as a simple DevOverlay row.
5. **Long-answer spoken summarization behavior.** Currently unspecified; users will quickly hit the "reading the whole 400-word answer out loud" pain. Probably v1.x once baseline UX is confirmed; flag as a known gap.

---

*Feature research for: Personal macOS AI assistant (Iron Man "Jarvis"-style)*
*Researched: 2026-04-21*
