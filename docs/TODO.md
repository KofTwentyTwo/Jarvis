# TODO — DEPRECATED 2026-05-12

**All open work has migrated to GitHub Issues: https://github.com/KofTwentyTwo/Jarvis/issues**

New work: file an issue. New audit findings: file with label `audit-finding`. Migration phases: see `epic` issues.

Historical content of this file is preserved in git history (see `docs/TODO.md` at commit `8d94c1c` or earlier).

## Crosswalk — where former sections moved

### Migration to v1.0 API (M-0 .. M-7)

- M-0 (pre-migration gates) — [#4](https://github.com/KofTwentyTwo/Jarvis/issues/4)
- M-1 (Self surface) — [#5](https://github.com/KofTwentyTwo/Jarvis/issues/5)
- M-2 (Settings surface) — [#6](https://github.com/KofTwentyTwo/Jarvis/issues/6)
- M-3 (Diagnostics surface) — [#7](https://github.com/KofTwentyTwo/Jarvis/issues/7)
- M-4 (Memory surface) — [#8](https://github.com/KofTwentyTwo/Jarvis/issues/8)
- M-5 (Vision surface) — [#9](https://github.com/KofTwentyTwo/Jarvis/issues/9)
- M-6 (Voice surface) — [#10](https://github.com/KofTwentyTwo/Jarvis/issues/10)
- M-7 (Turn surface keystone) — [#11](https://github.com/KofTwentyTwo/Jarvis/issues/11)

### Carry-forward bugs

- B-01a, B-01b — CLOSED 2026-05-07 (substrate fixes shipped)
- B-02 — CLOSED 2026-05-11 (tactical patch `48ad8d6`)
- B-03 (HUD camera button) — [#48](https://github.com/KofTwentyTwo/Jarvis/issues/48)
- B-04 (voice input dead) — [#49](https://github.com/KofTwentyTwo/Jarvis/issues/49)
- B-05 (TTS silent) — [#50](https://github.com/KofTwentyTwo/Jarvis/issues/50)
- B-06 (chat auto-scroll) — [#51](https://github.com/KofTwentyTwo/Jarvis/issues/51)
- B-07 (Voice Log menu) — [#52](https://github.com/KofTwentyTwo/Jarvis/issues/52)
- B-08 (model paraphrase) — [#53](https://github.com/KofTwentyTwo/Jarvis/issues/53)

### Voice follow-ups

- B-7-followup (AudioLevelEmitter wiring) — [#54](https://github.com/KofTwentyTwo/Jarvis/issues/54)
- TTSInterruptTests.testI3 flake — [#55](https://github.com/KofTwentyTwo/Jarvis/issues/55)
- B-8 (Orpheus tier-2) — DEFERRED v1.1 per migration plan §10

### Track D (memory) — environment work

- D-5 (libsqlite3.dylib build) — [#56](https://github.com/KofTwentyTwo/Jarvis/issues/56)
- D-6 (vec0.dylib bundle) — [#57](https://github.com/KofTwentyTwo/Jarvis/issues/57) (likely closed via static linkage)
- D-7 (Ollama model baseline reconcile) — [#58](https://github.com/KofTwentyTwo/Jarvis/issues/58) (`nomic-embed-text` + `qwen3.6` already present)

### Audit findings — 2026-05-12 round

**Memory audit (8 findings):**
- M-1 facts_vec never written (CRITICAL) — [#12](https://github.com/KofTwentyTwo/Jarvis/issues/12)
- M-2 replay log poisoned (CRITICAL) — [#13](https://github.com/KofTwentyTwo/Jarvis/issues/13)
- M-3 search_memory missing from preamble (CRITICAL) — [#14](https://github.com/KofTwentyTwo/Jarvis/issues/14)
- M-4 source_turn_id stores FNV hash (HIGH) — [#15](https://github.com/KofTwentyTwo/Jarvis/issues/15)
- M-5 FTS5 punctuation crashes (HIGH) — [#16](https://github.com/KofTwentyTwo/Jarvis/issues/16)
- M-6 BootHealth probe misleading (MEDIUM) — [#17](https://github.com/KofTwentyTwo/Jarvis/issues/17)
- M-7 stale doc-comments (LOW) — [#19](https://github.com/KofTwentyTwo/Jarvis/issues/19)
- M-8 MemoryReplaySink fire-and-forget (LOW) — [#18](https://github.com/KofTwentyTwo/Jarvis/issues/18)

**MCP / agent audit (7 findings):**
- CRIT-1 turnIDResolver permanently nil — [#20](https://github.com/KofTwentyTwo/Jarvis/issues/20)
- CRIT-2 tool-result double-capped — [#21](https://github.com/KofTwentyTwo/Jarvis/issues/21)
- CRIT-3 MCPRuntime tools-count log undercounts — [#22](https://github.com/KofTwentyTwo/Jarvis/issues/22)
- HIGH-1 cache hints never trigger — [#23](https://github.com/KofTwentyTwo/Jarvis/issues/23)
- HIGH-2 assistant text dropped alongside tool_use — [#24](https://github.com/KofTwentyTwo/Jarvis/issues/24)
- MED-1 get_active_audio_route conditional registration — [#25](https://github.com/KofTwentyTwo/Jarvis/issues/25)
- MED-2 confirmation panel cross-Space — [#26](https://github.com/KofTwentyTwo/Jarvis/issues/26)
- LOW-1 toolCall args-revealed event — [#27](https://github.com/KofTwentyTwo/Jarvis/issues/27)

**Voice audit (12 findings):**
- P0-1 wake-word dies on rebuild — [#28](https://github.com/KofTwentyTwo/Jarvis/issues/28)
- P0-2 STT backend hard-coded — [#29](https://github.com/KofTwentyTwo/Jarvis/issues/29)
- P0-3 .ttsStopped only on barge-in — [#30](https://github.com/KofTwentyTwo/Jarvis/issues/30)
- P0-4 VoiceTTSAdapter.tierResolver dead — [#31](https://github.com/KofTwentyTwo/Jarvis/issues/31)
- P1-1 OpenWakeWordSession buffers unbounded — [#32](https://github.com/KofTwentyTwo/Jarvis/issues/32)
- P1-2 VoiceBootHealthProbe shallow — [#33](https://github.com/KofTwentyTwo/Jarvis/issues/33)
- P1-3 SileroVAD hidden state persists — [#34](https://github.com/KofTwentyTwo/Jarvis/issues/34)
- P1-4 voiceHudCont.finish() one-way — [#35](https://github.com/KofTwentyTwo/Jarvis/issues/35)
- P1-5 AgentHudIntent dormant — [#36](https://github.com/KofTwentyTwo/Jarvis/issues/36)
- P2-1 STTBackendSelector string mismatch — [#37](https://github.com/KofTwentyTwo/Jarvis/issues/37)
- P2-2 SpeechSynthDelegate overwrites continuation — [#38](https://github.com/KofTwentyTwo/Jarvis/issues/38)
- P2-3 whisperKitFallback dead — [#39](https://github.com/KofTwentyTwo/Jarvis/issues/39)

**Bus / HUD audit (8 findings):**
- S1 BridgeNavigationDelegate no didFail — [#40](https://github.com/KofTwentyTwo/Jarvis/issues/40)
- S1 MenuBarIconController.transition production-dead — [#41](https://github.com/KofTwentyTwo/Jarvis/issues/41)
- S1 DevOverlay hollow shell — [#42](https://github.com/KofTwentyTwo/Jarvis/issues/42)
- S2 sessionHistory dead-letter — [#43](https://github.com/KofTwentyTwo/Jarvis/issues/43)
- S2 audioLevel consumer no-op — [#44](https://github.com/KofTwentyTwo/Jarvis/issues/44)
- S2 JarvisBusWorld doc drift — [#45](https://github.com/KofTwentyTwo/Jarvis/issues/45)
- S3 stale webview bundle artifacts — [#46](https://github.com/KofTwentyTwo/Jarvis/issues/46)
- S3 audioLevel NaN encoding — [#47](https://github.com/KofTwentyTwo/Jarvis/issues/47)

**Vision audit (already filed 2026-05-12):**
- Vision T2 escalation always dies — [#1](https://github.com/KofTwentyTwo/Jarvis/issues/1)
- FrameAttachController leaks pendingFrame — [#2](https://github.com/KofTwentyTwo/Jarvis/issues/2)
- Mid-session camera TCC revoke not observed — [#3](https://github.com/KofTwentyTwo/Jarvis/issues/3)

### Loose ends / docs hygiene

- Flip Plan 10-02 AC-05 + author 10-02c-SUMMARY — [#59](https://github.com/KofTwentyTwo/Jarvis/issues/59)
- REQUIREMENTS.md traceability reconcile — [#60](https://github.com/KofTwentyTwo/Jarvis/issues/60)
- /gsd-validate-phase 1..9 retroactive sweep — [#61](https://github.com/KofTwentyTwo/Jarvis/issues/61)
- streamTruncated live verify — [#62](https://github.com/KofTwentyTwo/Jarvis/issues/62)
- stash@{0} triage — [#63](https://github.com/KofTwentyTwo/Jarvis/issues/63)

### Closed / shipped (no migration needed)

- B-01a, B-01b substrate fixes (2026-05-07)
- Track A text turn + animated rings (2026-05-04)
- Track B-1..7 voice foundations (2026-05-04)
- Track C-1..6 vision (2026-05-04)
- Track D-1..4 memory code-work (2026-05-04)
- Audit-2026-05-03 SYNTHESIS (closed)
- Audit-2026-05-04 P0-P2 + P3-18 closure (2026-05-04)
- Phase F2 linter (2026-05-04)
- Documentation sweep — README/ARCHITECTURE/CONTRIBUTING/per-package READMEs (2026-05-04)
- B-02 history-threading tactical patch (2026-05-11)
- Memory database real (vec0 static link, hard-fail boot, stats tool) (2026-05-11)
- Memory extractor model swap to qwen3.6 (2026-05-11)
