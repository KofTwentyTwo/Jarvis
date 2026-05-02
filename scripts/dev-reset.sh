#!/usr/bin/env bash
#
# dev-reset.sh — wipe all Jarvis local state so the next launch is a fresh
# first-run install. Useful while iterating on the onboarding wizard, TCC
# prompts, hotkey binding, etc.
#
# What this removes:
#   1. Any running Jarvis process
#   2. ~/Library/Application Support/Jarvis/   (config.json, jarvis.db, replay.sqlite)
#   3. ~/Library/Logs/Jarvis/                  (rotating bus/system/mcp logs)
#   4. ~/Library/WebKit/<bundle-id>/           (WKWebView site data)
#   5. ~/Library/Caches/<bundle-id>/           (WKWebView caches)
#   6. ~/Library/Saved Application State/<bundle-id>.savedState/
#   7. UserDefaults for the bundle             (defaults delete)
#   8. Keychain entries (Anthropic API key)    (security delete-generic-password)
#   9. TCC permissions for the bundle          (tccutil reset All)
#
# What this does NOT touch:
#   - The .app bundle itself (that's the build's job)
#   - Source code, planning docs, anything in the repo
#   - Other apps' state
#
# Usage:
#   scripts/dev-reset.sh              # dry-run — show what would be removed
#   scripts/dev-reset.sh --yes        # actually do it
#   scripts/dev-reset.sh -y           # short form
#   scripts/dev-reset.sh --yes --quiet # no per-step output
#
# Bundle id is derived from the built Info.plist so it stays correct if the
# id ever changes. Falls back to a hardcoded list of known historical ids.
set -euo pipefail

# ---------------------------------------------------------------- args
APPLY=false
QUIET=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) APPLY=true ;;
        --quiet|-q) QUIET=true ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

say() { [ "$QUIET" = "true" ] || echo "$@"; }
heading() { [ "$QUIET" = "true" ] || echo "═══ $* ═══"; }

# --------------------------------------------------- bundle id discovery
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_IDS=()

# Try to read the live built bundle's id first.
for plist in \
    "$REPO/build/Build/Products/Debug/Jarvis.app/Contents/Info.plist" \
    "$REPO/build/Build/Products/Release/Jarvis.app/Contents/Info.plist" \
    "$HOME/Library/Developer/Xcode/DerivedData/Jarvis-"*"/Build/Products/Debug/Jarvis.app/Contents/Info.plist"
do
    if [ -f "$plist" ]; then
        bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)
        if [ -n "$bid" ]; then
            BUNDLE_IDS+=("$bid")
        fi
    fi
done

# Always include the historical ids that have been used in this project so
# we clean up cruft from old builds even if no current Info.plist exists.
BUNDLE_IDS+=("com.koftwentytwo.jarvis" "com.kingsrook.jarvis")

# Deduplicate
BUNDLE_IDS=($(printf '%s\n' "${BUNDLE_IDS[@]}" | sort -u))

heading "Targets"
say "  Bundle ids: ${BUNDLE_IDS[*]}"
say "  Mode:       $([ "$APPLY" = "true" ] && echo APPLY || echo DRY-RUN)"
say ""

# Helpers — print intent (always) but only act when APPLY=true.
remove_path() {
    local p="$1"
    if [ -e "$p" ] || [ -L "$p" ]; then
        say "  rm -rf $p"
        if [ "$APPLY" = "true" ]; then
            rm -rf "$p"
        fi
    fi
}

run_cmd() {
    say "  $*"
    if [ "$APPLY" = "true" ]; then
        "$@" 2>&1 | sed 's/^/      /' || true
    fi
}

# ---------------------------------------------------------------- 1. processes
heading "Stop running Jarvis"
if pgrep -f "Jarvis.app/Contents/MacOS/Jarvis" >/dev/null 2>&1; then
    say "  pkill -f Jarvis.app/Contents/MacOS/Jarvis"
    if [ "$APPLY" = "true" ]; then
        pkill -f "Jarvis.app/Contents/MacOS/Jarvis" || true
        # Give launchd a beat to mark the app dead so subsequent launches are clean.
        sleep 1
    fi
else
    say "  (no running Jarvis process)"
fi
say ""

# ---------------------------------------------------- 2. app support + logs
heading "Application Support / Logs"
remove_path "$HOME/Library/Application Support/Jarvis"
remove_path "$HOME/Library/Logs/Jarvis"
say ""

# --------------------------------------------------- 3+4+5+6+7. per-bundle state
heading "Per-bundle state"
for bid in "${BUNDLE_IDS[@]}"; do
    say "[$bid]"
    remove_path "$HOME/Library/WebKit/$bid"
    remove_path "$HOME/Library/Caches/$bid"
    remove_path "$HOME/Library/Saved Application State/$bid.savedState"
    remove_path "$HOME/Library/HTTPStorages/$bid"
    remove_path "$HOME/Library/HTTPStorages/$bid.binarycookies"
    remove_path "$HOME/Library/Preferences/$bid.plist"
    if /usr/bin/defaults read "$bid" >/dev/null 2>&1; then
        run_cmd /usr/bin/defaults delete "$bid"
    fi
done
say ""

# ---------------------------------------------------------------- 8. Keychain
heading "Keychain"
# Only the Anthropic API key is stored. Use `security delete-generic-password`
# with both -s (service) and -a (account) to scope precisely.
for bid in "${BUNDLE_IDS[@]}"; do
    if security find-generic-password -s "$bid" -a "anthropic" >/dev/null 2>&1; then
        say "  security delete-generic-password -s '$bid' -a 'anthropic'"
        if [ "$APPLY" = "true" ]; then
            security delete-generic-password -s "$bid" -a "anthropic" 2>/dev/null || true
        fi
    fi
done
say ""

# ---------------------------------------------------------------- 9. TCC
heading "TCC permissions"
# tccutil reset All <bundle-id> wipes Microphone, Camera, Screen Recording,
# Accessibility, Input Monitoring, Automation, etc. for that bundle. The
# user will be re-prompted for each on next launch.
for bid in "${BUNDLE_IDS[@]}"; do
    say "  tccutil reset All $bid"
    if [ "$APPLY" = "true" ]; then
        # tccutil exits 0 even when the bundle has no TCC entries — fine.
        tccutil reset All "$bid" 2>/dev/null || true
    fi
done
say ""

# ---------------------------------------------------------------- footer
heading "Done"
if [ "$APPLY" = "true" ]; then
    say "Reset complete. Next launch will be a fresh first-run install."
    say "Build + launch:   scripts/check-app-builds.sh && open build/Build/Products/Debug/Jarvis.app"
else
    say "Dry run only — re-run with --yes to actually remove the items above."
fi
