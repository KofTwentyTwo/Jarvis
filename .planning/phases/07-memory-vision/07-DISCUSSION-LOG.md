# Phase 7: Memory + Vision — Discussion Log

**Date:** 2026-04-27
**Mode:** Default (interactive, single-question turns)
**Areas selected:** all 4 of 4 presented

---

## Area 1 — Memory extraction scope & opt-in

**Q1.1:** When does memory extraction run?
- Options: Auto-extract every turn (Recommended) / Auto-extract per session / Explicit opt-in per turn / You decide
- **Selected:** Auto-extract every turn (mem0 default; researcher §7)

**Q1.2:** How does forgetting work?
- Options: Explicit forget tool (Recommended) / Supersede-only via re-stating / Both — forget tool + manual UI
- **Selected:** Explicit forget tool

**Q1.3:** What kinds of things does the extractor distill into facts?
- Options: Durable personal facts — broad (Recommended) / Project + scheduling only / Whitelist subjects / You decide
- **Selected:** Durable personal facts — broad

**Q1.4:** Do you want a private mode override?
- Options: Incognito turn flag (Recommended) / No override — trust the forget tool / Per-turn hotkey only
- **Selected:** No override — trust the forget tool

---

## Area 2 — Memory retrieval visibility

**Q2.1:** When the agent retrieves a stored fact via search_memory, is that visible to you?
- Options: Transparent — just the answer / DevOverlay row per retrieval (Recommended) / Inline citation in chat / Ring color shift during retrieval
- **Selected:** DevOverlay row per retrieval (symmetric with MEM-08 extraction surface)

**Q2.2:** When you ask explicitly, should that response render differently?
- Options: Same as any other answer (Recommended) / Show the raw fact + the agent's framing / Distinct chat-panel treatment
- **Selected:** Same as any other answer (conversational tone preserved)

**Q2.3:** Does search_memory search current session only or all stored facts?
- Options: All facts across all sessions (Recommended) / Default to current session, with flag for cross-session / Session-scoped only, no cross-session in P7
- **Selected:** All facts across all sessions (researcher Open Q #1 resolved)

**Q2.4:** Should P7 expose point-in-time recall as a separate MCP tool?
- Options: Keep internal in P7 (Recommended) / Expose search_memory_at_time tool now / Expose via a time parameter on search_memory
- **Selected:** Keep internal in P7 (defer to backlog)

---

## Area 3 — Webcam presence default state

**Q3.1:** What's the default state of the presence-detection toggle after Camera TCC is granted?
- Options: Off by default — opt in via Settings (Recommended) / On by default after first Camera TCC grant / Prompted on first launch / You decide
- **Selected:** On by default after first Camera TCC grant (Iron Man / ambient pattern; user override-of-recommendation)

**Q3.2:** What does presence detection actually affect (given VISION-03's hard ban on triggering)?
- Options: Context-prompt enrichment only (Recommended) / Context enrichment + HUD ring subtle indicator / Context + DevOverlay row per transition / All three
- **Selected:** Context enrichment + HUD ring subtle indicator (user override-of-recommendation; wanted ambient feedback)

**Q3.3:** How long absent before Jarvis considers you 'gone'?
- Options: 30 seconds (Recommended) / 5 minutes / Immediate (2-second debounce only) / You decide
- **Selected:** 5 minutes (user override-of-recommendation; generous threshold for long calls / brief departures)

**Q3.4:** Quick-toggle for presence detection?
- Options: Yes — menu-bar 'Disable Presence' toggle (Recommended) / Settings only — no menu-bar shortcut / Hotkey + menu-bar toggle
- **Selected:** Yes — menu-bar 'Disable Presence' toggle (mirrors Phase 6's MuteWakeWord pattern)

---

## Area 4 — Frame-attach trigger UX (single webcam frame to vision LLM)

**Q4.1:** How do you trigger 'capture a frame and send it to a vision model'?
- Options: Phrase detection + HUD button (Recommended) / Phrase detection only / HUD button only / Hotkey-bound capture
- **Selected:** Phrase detection + HUD button

**Q4.2:** Confirmation step before sending?
- Options: Always confirm (Recommended) / Confirm only on phrase trigger; HUD button is silent / Never confirm / Per-turn pre-flight indicator
- **Selected:** Always confirm (thumbnail + Send/Cancel for ~2s)

**Q4.3:** What happens to the frame data after the response?
- Options: Discard immediately (Recommended) / Persist with the turn / Persist by default, explicit-discard / Memory eligibility — fact extractor sees the frame description
- **Selected:** Discard immediately (privacy-pure)

**Q4.4 (initial routing question):** Where does the captured frame go for understanding?
- Options: Local-first via Ollama or MLX-VLM (Recommended) / Opus-first with local fallback flag / Both — automatic routing by intent / Local-only — no Opus path in P7
- **Selected:** Both — automatic routing by intent

**User pushback:** "search the web and look at the latest possible models. I think there are things better than qwen2.5 now in April of 2026."

→ Orchestrator ran four parallel WebSearch queries to refresh the vision-model landscape. Surfaced: Gemma 4 (April 2, 2026), Qwen 3.5 multimodal (February 16, 2026), Llama 4 Scout/Maverick/Behemoth status, Kimi-K2.5, vllm-mlx server. Established that Qwen 3.5 multimodal is NOT yet supported by Ollama as of March 2026 — vllm-mlx is the runtime for the bleeding-edge VLM tier.

**Q4.5 (refined routing):** Given the updated landscape, which routing shape do you want to lock?
- Options: B — Ollama (Gemma 4) + vllm-mlx (Qwen 3.5), Opus escape (Recommended) / A — Ollama-only with the freshest models / C — Single Gemma 4 default + Opus escape / D — Wait and re-research at plan time
- **Selected:** B — Ollama (Gemma 4) + vllm-mlx (Qwen 3.5), Opus escape

**Q4.6:** How does the system decide T1 (Gemma 4) vs T2 (Qwen 3.5)?
- Options: Always T1, escalate on low confidence (Recommended) / User-phrase escalation / Always T2 — just use the best local model / ContextBuilder phrase classifier
- **Selected:** Always T1, escalate on low confidence (auto-escalation; user perceives "one frame in, one good answer out")

---

## Wrap-up

**Q5:** Wrap up the discussion and write CONTEXT.md?
- Options: I'm ready for context / Explore more gray areas / More on Frame-attach
- **Selected:** I'm ready for context

---

## Notes on this session

- User picked all 4 presented gray areas. No areas dropped.
- User overrode researcher's recommendation on 4 of 18 single questions (Q3.1, Q3.2, Q3.3, Q4.4 → triggered the vision-routing pivot).
- The Q4.4 → Q4.5 pivot was substantial: extended `LLMProvider` to multimodal, added vllm-mlx as a localhost sidecar runtime, and shifted vision from "Opus-first cloud" (researcher's plan) to "local-first three-tier with Opus as explicit escape."
- Hardware context (M3 Mac Studio + M5 MacBook, both 128 GB, Ollama installed) directly shaped the routing decision and made the vllm-mlx sidecar tractable.
- No deferred ideas surfaced from the user during discussion (the deferred-ideas section in CONTEXT.md is sourced from the researcher's "out of scope" enumeration plus the inverse of the locked decisions).

---

*Discussion log generated by gsd-discuss-phase default mode, 2026-04-27.*
