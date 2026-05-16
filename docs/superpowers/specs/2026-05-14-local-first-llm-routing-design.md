# Local-first LLM routing — design

**Status:** draft 2026-05-14, awaiting user approval
**Authors:** James + Claude (Opus 4.7)
**Scope:** flip the chat-turn provider default from Anthropic to local Ollama, with reactive escalation to Claude Opus on detectable Ollama failure.

## Goal

Default every conversation turn to local Ollama (`qwen2.5-coder:32b-instruct-q8_0`). Escalate to Anthropic Claude Opus 4.7 only when local fails in a way the runtime can detect. The user sees one coherent reply per turn, with a small badge if escalation fired.

## Why now

The codebase is already structurally ready:

- `LLMProvider` protocol is symmetric between Anthropic + Ollama (same `AsyncThrowingStream<LLMEvent>` shape, same `ToolChoice.none` semantics).
- `AgentOrchestrator` is already config-driven via `providerFactory(perTurn.resolvedProvider)` (line 311).
- A mid-conversation escalation hook already exists — line 793 retries on `streamTruncated` by calling `providerFactory(updated.resolvedProvider)`.
- Memory extraction is wired to Ollama separately and is not affected by chat-turn routing.

This is mostly a policy + UX change, not a new abstraction.

## Approach

Reactive fallback only. No predictive routing, no router-model classifier, no self-reported escalation tool. The orchestrator tries Ollama first; if it fails in one of an enumerated set of detectable ways, it retries the turn once on Anthropic, emits an escalation event for the HUD, and surfaces the answer to the user.

User picked this approach because:

1. The existing escalation hook is reactive — extending what's there beats inventing a new layer.
2. Reactive fallback produces evidence — every escalation is a real-world data point for any future predictive routing.
3. Zero added latency on the happy path; no extra LLM call to classify the turn.

## Spec

### 1. Default provider flip

- `default-config.json:9` changes from `"anthropic"` to `"ollama"`.
- `PerTurnSnapshot.provider` already exists as the policy carrier.
- Ollama target model is `qwen2.5-coder:32b-instruct-q8_0` (the tool-calling baseline pinned by `ModelID.qwen25coder32b`).
- Anthropic remains a first-class provider and remains selectable.

### 2. Escalation trigger taxonomy

The runtime fires escalation on, and only on, these detectable failure modes (closed enum `OllamaFailureKind`):

| Trigger | Detection |
|---|---|
| `streamTruncated` | Existing — already wired at `AgentOrchestrator.swift:793`. |
| `malformedToolCall` | `tool_calls` payload fails to decode against `ToolUseRequest`. Known Qwen 3.x footgun per CLAUDE.md. |
| `unknownTool` | Model invokes a tool name not in the registry. |
| `refusal` | `stopReason: .refusal` event arrives. |
| `connectionFailure` | URLSession error before any tokens received (Ollama down, port refused). |
| `emptyResponse` | `messageStop` with zero `textDelta` and zero `toolUseRequested`. |

Explicit non-triggers (do not escalate):

- Partial answer that "feels weak"
- Semantic hallucinations the runtime can't detect
- Tool that returned an error (tool failure ≠ model failure)
- Slow streaming (no SLA-based escalation)

These are quality problems the runtime cannot judge. Out of scope for this design.

### 3. Escalation contract

```swift
struct EscalationDecision: Sendable, Codable {
    let from: ProviderSelection           // .ollama
    let to: ProviderSelection             // .anthropic
    let reason: OllamaFailureKind
    let firedAt: Date
}
```

`AgentOrchestrator` enforces **at most one escalation per turn**. If the post-escalation Anthropic call also fails, the orchestrator surfaces the error to the user — it does not fall back further. (A second failure means the cloud provider is also down; pretending otherwise is dishonest.)

### 4. Bus event for the HUD badge

New outbound event:

```swift
case escalated(EscalationDecision)
```

Emitted once when fallback fires. HUD renders an unobtrusive badge inline with the affected message: "Escalated to Opus — Ollama returned malformed tool call" (or whichever `OllamaFailureKind` fired). The badge stays with that specific message; subsequent messages are visually clean.

The badge is HUD-side only — it does not affect the chat message content, persistence, or replay log shape.

### 5. Per-turn vs sticky

**Per-turn.** Next user message starts fresh on Ollama. Reasoning: one Ollama failure on a Python question doesn't mean the next "what time is it" should go to Opus.

User can manually pin a conversation to Anthropic via Settings. Manual pin overrides escalation logic; in that mode, no escalation badges fire because no escalation can fire.

### 6. Settings UX

Settings → Provider section gets one new control:

- **Provider preference:** `Local-first (recommended)` / `Anthropic only` / `Ollama only`
- `Local-first` is the new default; corresponds to `provider: "ollama"` plus escalation enabled.
- `Anthropic only` pins to Anthropic, escalation moot.
- `Ollama only` pins to Ollama AND disables escalation — Ollama failures surface as errors. Useful for hard-offline / privacy-strict mode.

The existing `default-config.json` `provider:` field continues to drive the runtime; new logic decides whether escalation is wired based on a sibling `escalationEnabled` field that defaults to `true` only when `provider == "ollama"`.

### 7. Testing

Three eval lanes added to the Harness package:

- **Reactive fallback fires correctly** — fixture: Ollama returns `malformedToolCall`; assert orchestrator switches to Anthropic mid-turn AND emits one `escalated` bus event.
- **Escalation budget honored** — fixture: Ollama fails AND Anthropic also fails on the same turn; assert orchestrator surfaces a structured error, does not loop, emits exactly one `escalated` event.
- **Pinned mode disables escalation** — config: `provider=ollama, escalationEnabled=false` + Ollama failure → surface error directly, zero `escalated` events.

No new fixture corpus needed; leverages existing `FixtureKind` cases in `MockLLMProvider`.

### 8. Non-goals

- No predictive routing.
- No "stream Anthropic continuing Ollama's partial output" — clean restart only.
- No automatic re-Ollama after Anthropic finishes — once escalated, the rest of the turn stays on Anthropic.
- No memory extraction changes; that pipeline is independent and stays on Ollama.
- No changes to non-chat surfaces (TTS, MCP, voice loop) — they have their own provider stories.
- No new GitHub issue label or milestone; this is a v0.5+ migration item that the user wants brought forward.

### 9. Effort estimate

Single PR, ~3-4 hours:

| Subtask | Estimate |
|---|---|
| `default-config.json` flip + Settings UI control | 30 min |
| Orchestrator escalation logic extension + budget tracking | 60 min |
| Bus event + HUD badge component | 60 min |
| Harness tests (3 lanes) | 60 min |
| Docs + comments | 15 min |

## Success criteria

- Default fresh-launch experience uses Ollama for chat turns.
- A turn that fails on Ollama via any `OllamaFailureKind` automatically retries on Anthropic and the user sees a single coherent reply with a badge.
- A turn that fails on both providers shows a structured error, not an infinite retry.
- A user with `Ollama only` mode sees the Ollama error directly with no escalation.
- All existing tests pass; three new escalation tests pass.
- Memory extraction is unaffected.
- The chat surface still streams tokens at acceptable latency (no perceptible regression).

## Open questions for the user

None blocking — design is concrete enough to implement. If anything below is wrong, push back before the spec is committed.

- Should the badge wording differ per `OllamaFailureKind`, or just say "Escalated to Opus"? Current design: differentiate, because the reason is small additional information that helps the user understand when Ollama is struggling.
- Should the orchestrator emit a single `bus.escalated` per turn, or stream per-attempt diagnostics? Current design: one per turn, keeps the bus contract simple.
