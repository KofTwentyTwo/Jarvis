#!/usr/bin/env bash
# Phase 9 / Plan 4 / WARNING-5: install order LOCKED in AppDelegate.swift.
#
# vision → agent → voice. Asserts the literal Task spawn lines for the three
# install subsystems appear in that strict order in applicationWillFinishLaunching.
#
# - vision must finish before agent because installAgent's orchestrator
#   constructor takes self.visionRouter (Plan 2) + the broadcaster's
#   frame-attach release subscriber needs frameAttachController.
# - agent must finish before voice because installVoice's adapters require
#   self.agentOrchestrator + self.turnTranscriptStore (both constructed in
#   installAgent — Plan 1 / Plan 4).
#
# In addition, voiceInstallTask MUST await agentInstallTask?.value before
# calling installVoice — otherwise the install order can race even though
# the spawn-line ordering is correct.
set -euo pipefail

ROOT="${1:-$(pwd)}"
file="$ROOT/App/AppDelegate.swift"

if [ ! -f "$file" ]; then
  echo "FAIL: $file not found"
  exit 1
fi

vision_line=$(grep -n 'visionInstallTask = Task' "$file" | head -1 | cut -d: -f1 || true)
agent_line=$(grep -n 'agentInstallTask = Task' "$file" | head -1 | cut -d: -f1 || true)
voice_line=$(grep -n 'voiceInstallTask = Task' "$file" | head -1 | cut -d: -f1 || true)

if [ -z "$vision_line" ] || [ -z "$agent_line" ] || [ -z "$voice_line" ]; then
  echo "FAIL: install order tokens missing in $file"
  echo "  vision: ${vision_line:-MISSING}"
  echo "  agent:  ${agent_line:-MISSING}"
  echo "  voice:  ${voice_line:-MISSING}"
  exit 1
fi

if [ "$vision_line" -lt "$agent_line" ] && [ "$agent_line" -lt "$voice_line" ]; then
  # Spawn-order is correct. Now verify voiceInstallTask awaits agentInstallTask
  # (a strictly stronger guarantee than just the spawn-line ordering).
  if ! grep -qE 'await\s+self\?\.\s*agentInstallTask\?\.\s*value' "$file"; then
    echo "FAIL: voiceInstallTask does not await agentInstallTask?.value — install can race"
    exit 1
  fi
  echo "PASS: install order is vision($vision_line) → agent($agent_line) → voice($voice_line); voice awaits agent"
  exit 0
fi

echo "FAIL: install order violated. vision=$vision_line agent=$agent_line voice=$voice_line"
exit 1
