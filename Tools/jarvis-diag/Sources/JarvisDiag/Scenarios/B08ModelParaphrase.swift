// B08ModelParaphrase.swift
//
// Reproduces and dissolves B-08: get_self_state returns claude-opus-4-7
// correctly but Claude paraphrases as "Opus 4.5". Soft-failure boundary (LLM
// output is probabilistic), but the structural contract (modelDisplayName field
// + tool-result label) lowers the floor.
//
// Pre-fix (B08-repro): submit "what model are you"; sample tokenStreamed text;
// expect "4.5" substring observed across multiple paraphrase prompts.
//
// Post-fix (B08-fix): selfStateChanged.modelDisplayName == "Claude Opus 4.7";
// get_self_state tool result includes "model_display_name": "Claude Opus 4.7";
// "Opus 4.5" substring count ≤ 0 across 5 paraphrase prompts (probabilistic).
//
// Modes: both — paraphrase output is observable on either transport.
// Scenario IDs: B08-repro, B08-fix, Sf-001.

import Foundation

public enum B08ModelParaphrase {

    /// B08-repro — captures the substring leak today.
    public static let repro = Scenario(
        id: "B08-repro",
        title: "B-08 reproduction: 'Opus 4.5' substring leaks in assistant text",
        body: { harness in
            // IMPL outline:
            //   for prompt in ["what model are you", "tell me your model name", ...]
            //     submit; collect tokenStreamed.text; concat
            //   substringCount = total occurrences of "4.5"
            //   pre-fix expectation: substringCount > 0 across 5 prompts (high probability)
            fatalError("not implemented — IMPL: B-08 reproduction")
        }
    )

    /// B08-fix — structural-contract assertion; soft probabilistic gate.
    public static let fix = Scenario(
        id: "B08-fix",
        title: "B-08 dissolution: modelDisplayName populated; '4.5' substring suppressed",
        body: { harness in
            // IMPL outline:
            //   self_ = await harness.selfSurface.getSelfState()
            //   assert self_.modelId == "claude-opus-4-7"
            //   assert self_.modelDisplayName == "Claude Opus 4.7"
            //   stateDump = await harness.diagnostics.getStateDump()
            //   assert stateDump.fields["modelDisplayNameInjected"] == true
            //   sample 5 paraphrase prompts; assert "4.5" substring count == 0 (soft)
            fatalError("not implemented — IMPL: B-08 fix (Sf-001 + structural)")
        }
    )
}
