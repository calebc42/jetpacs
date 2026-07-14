#!/usr/bin/env bash
#
# Deploy the jetpacs foundation bundle — and any Tier-1 app bundles — to
# the connected Android device. The bash sibling of deploy.ps1, for
# Linux/macOS (or WSL) where emacs and adb are on PATH directly.
#
# Default: rebuild jetpacs-core.el from emacs/core/*.el, then adb-push it
# (plus every extra path given) to /sdcard/Documents/jetpacs/. Termux is not
# debuggable, so adb cannot write into /data/data/com.termux directly —
# the starter init (docs/starter-init.el) adopts newer staged bundles
# from /sdcard/Documents/jetpacs (the shared onboarding + deploy slot) at
# Emacs startup, newest copy wins.
#
# App bundles are not built here — each app repo builds its own. Pass
# the built file:
#
#   ./deploy.sh                                    # foundation only
#   ./deploy.sh ~/pkb/projects/Glasspane/glasspane.el   # + the Glasspane app
#   ./deploy.sh emacs/apps/jetpacs-hello.el        # + the hello demo
#   ./deploy.sh --ssh --apk ~/pkb/projects/Glasspane/glasspane.el
#
# --ssh pushes straight into Termux's ~/.emacs.d/elisp/ over Termux sshd
# (no staging or restart-adopt). One-time setup inside Termux:
#   pkg install openssh && passwd && sshd
# Optional passwordless push: append ~/.ssh/id_ed25519.pub to Termux's
# ~/.ssh/authorized_keys. sshd must be running when you deploy.
# --apk also builds + installs the companion APK (gradlew installDebug).

set -euo pipefail

use_ssh=0
use_apk=0
bundles=()
for arg in "$@"; do
  case "$arg" in
    --ssh) use_ssh=1 ;;
    --apk) use_apk=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) bundles+=("$arg") ;;
  esac
done

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo '-- Rebuilding jetpacs-core.el from emacs/core/*.el ...'
emacs --batch -l "$repo/emacs/build-bundle.el"

# The push set: the foundation bundle plus whatever apps were passed in.
files=("$repo/jetpacs-core.el")
for b in "${bundles[@]:-}"; do
  [ -z "$b" ] && continue
  [ -f "$b" ] || { echo "Bundle not found: $b" >&2; exit 1; }
  files+=("$b")
done

echo '-- Checking device ...'
adb get-state >/dev/null

if [ "$use_ssh" -eq 1 ]; then
  echo '-- Pushing directly into Termux home via sshd (port 8022) ...'
  adb forward tcp:8022 tcp:8022 >/dev/null
  ssh -p 8022 termux@127.0.0.1 'mkdir -p .emacs.d/elisp'
  for f in "${files[@]}"; do
    scp -P 8022 "$f" "termux@127.0.0.1:.emacs.d/elisp/$(basename "$f")"
    echo "   Installed ~/.emacs.d/elisp/$(basename "$f")"
  done
  echo '   Reload or restart Emacs to pick the bundles up.'
else
  echo '-- Staging to /sdcard/Documents/jetpacs (adopted by init.el on Emacs restart) ...'
  adb shell mkdir -p /sdcard/Documents/jetpacs
  for f in "${files[@]}"; do
    adb push "$f" "/sdcard/Documents/jetpacs/$(basename "$f")"
  done
  echo '   Staged. Restart Emacs on the device (or eval the adopt snippet) to pick them up.'
fi

if [ "$use_apk" -eq 1 ]; then
  echo '-- Building + installing companion APK ...'
  "$repo/gradlew" installDebug
fi

echo 'Deploy complete.'
