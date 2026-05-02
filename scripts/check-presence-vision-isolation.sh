#!/usr/bin/env bash
# VISION-03 architectural-boundary guard.
#
# Three layers, each independently fatal:
#
# 1. packages/Vision/Package.swift must NOT depend on Voice or
#    AgentOrchestrator (the SPM-graph half of the boundary).
# 2. No Swift source under packages/Vision/Sources/ may import Voice or
#    AgentOrchestrator, nor reference TTSEngine / TTSEngineActor /
#    AgentOrchestrator.runTurn / cancelAndSubmit.
# 3. Any file in App/ that holds a reference to PresenceSignalBus must
#    not, in the same file, also reference TTSEngine* or AgentOrchestrator
#    submit paths. Layer 3 is the loosest — a future refactor in App/ that
#    subscribes to presence and forwards into TTS is the catastrophic
#    VISION-03 failure mode.
#
# Comment-only lines (after the file:lineno: prefix is stripped) are
# tolerated so docstrings explaining the rule do not trip the gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Layer 1: Vision package SPM dependencies. The plan body's regex covered
# only the precise xcodegen `package(path: "../Voice")` form. We strip
# comment lines first so docstrings about the rule do not match.
LAYER1_HITS=$(sed -E 's|//.*$||' packages/Vision/Package.swift \
    | grep -E 'package\(path:[[:space:]]*"\.\./Voice"\)|product\(name:[[:space:]]*"AgentOrchestrator"' || true)
if [[ -n "$LAYER1_HITS" ]]; then
    echo "VISION-03 violation (Layer 1): Vision/Package.swift depends on Voice or AgentOrchestrator." >&2
    echo "$LAYER1_HITS" >&2
    exit 1
fi

# Layer 2: forbidden imports / type references inside Vision sources.
LAYER2_HITS=$(grep -rnE '^[[:space:]]*import[[:space:]]+(Voice|AgentOrchestrator)\b|TTSEngine|TTSEngineActor|AgentOrchestrator\.runTurn|cancelAndSubmit' \
    packages/Vision/Sources/ --include='*.swift' 2>/dev/null \
    | sed -E 's|^[^:]+:[0-9]+:||' \
    | grep -vE '^[[:space:]]*(//|\*|/\*)' \
    | grep -E '^[[:space:]]*import[[:space:]]+(Voice|AgentOrchestrator)\b|TTSEngine|TTSEngineActor|AgentOrchestrator\.runTurn|cancelAndSubmit' || true)
if [[ -n "$LAYER2_HITS" ]]; then
    echo "VISION-03 violation (Layer 2): forbidden import or type reference in Vision sources:" >&2
    echo "$LAYER2_HITS" >&2
    exit 1
fi

# Layer 3: in any App/ file that holds a PresenceSignalBus reference, no
# co-located forbidden-token hit (per file). Strip comment-only lines
# before evaluating co-occurrence; AppDelegate.swift legitimately holds
# both PresenceSignalBus AND VoiceController references but never feeds
# presence into the TTS or runTurn paths.
#
# Plan 09-04 adjustment: `cancelAndSubmit` was previously forbidden, but Plan 4
# legitimately adds chat-panel barge-in handlers (`handleChatCancelAndSubmit`)
# that call `orchestrator.cancelAndSubmit(.text(...))`. These call sites are
# in inbound-bus handlers, NOT in presence-subscriber paths. The architectural
# invariant — presence enrichment lives OUTSIDE UntrustedWrapper.composeSystemPrompt
# (SEC-06) — is enforced in AgentOrchestrator.runTurn itself and verified by
# AgentOrchestratorPresenceEnrichmentTests. The structural Layer 3 check
# retains TTSEngine* and AgentOrchestrator.runTurn (private symbol) as
# tripwires.
APP_PRESENCE_FILES=$(grep -rl 'PresenceSignalBus\b' App/ --include='*.swift' 2>/dev/null || true)
for f in $APP_PRESENCE_FILES; do
    FORBIDDEN=$(sed -E 's|^[[:space:]]*//.*$||' "$f" \
        | grep -E 'TTSEngine|TTSEngineActor|AgentOrchestrator\.runTurn' || true)
    if [[ -n "$FORBIDDEN" ]]; then
        echo "VISION-03 violation (Layer 3): file references both PresenceSignalBus AND a forbidden TTS/runTurn token: $f" >&2
        echo "$FORBIDDEN" >&2
        exit 1
    fi
done

exit 0
