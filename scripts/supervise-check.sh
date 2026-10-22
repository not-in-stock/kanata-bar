#!/usr/bin/env bash
#
# Read-only verifier for the task-18/2b sudo digest rule. Installs NOTHING.
#
# Given an installed Kanata Bar.app, it prints:
#   • the exact path the app will invoke (resolving symlinks the way SudoLauncher
#     does — so on nix this collapses to the /nix/store path),
#   • that binary's sha256,
#   • the exact /etc/sudoers.d line the nix module should produce (space-escaped),
#   • a `visudo -c` syntax check of that line, and
#   • the exact `sudo -n …` command the app runs.
#
# Use it to eyeball that the rule's command path + hash match what the app invokes
# (the two top risks: the space in "Kanata Bar.app", and symlink resolution). To
# actually test matching, hand-install the printed rule (root), run the printed
# sudo command, then remove the rule — as in the F4 validation.
#
# Usage: scripts/supervise-check.sh [path-to-Kanata Bar.app] [user]

set -euo pipefail

APP="${1:-/Applications/Nix Apps/Kanata Bar.app}"
USER_NAME="${2:-$(id -un)}"

EXE="$APP/Contents/MacOS/kanata-bar"
if [ ! -e "$EXE" ]; then
  echo "app executable not found: $EXE" >&2
  echo "pass the .app path, e.g.: $0 'build/Kanata Bar.app'" >&2
  exit 2
fi

# Resolve symlinks like Foundation's resolvingSymlinksInPath(), then take the
# sibling supervise binary — exactly SudoLauncher.superviseBinaryPath.
RESOLVED_EXE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EXE")"
SUP="$(dirname "$RESOLVED_EXE")/kanata-bar-supervise"

if [ ! -x "$SUP" ]; then
  echo "supervise binary not found next to the app executable: $SUP" >&2
  echo "(older release without task-18/2b support?)" >&2
  exit 2
fi

HASH="$(/usr/bin/shasum -a 256 "$SUP" | /usr/bin/awk '{print $1}')"
ESC="$(printf '%s' "$SUP" | /usr/bin/sed 's/ /\\ /g')"
RULE="$USER_NAME ALL=(root) NOPASSWD: sha256:$HASH $ESC \"\""

echo "app executable      : $EXE"
echo "resolved (invoked)  : $RESOLVED_EXE"
echo "supervise binary    : $SUP"
echo "sha256              : $HASH"
echo
echo "sudoers rule (/etc/sudoers.d/kanata-bar-supervise):"
echo "  $RULE"
echo

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$RULE" > "$TMP"
if /usr/sbin/visudo -cf "$TMP" >/dev/null 2>&1; then
  echo "visudo -c           : OK"
else
  echo "visudo -c           : FAILED — rule is syntactically invalid" >&2
  /usr/sbin/visudo -cf "$TMP" || true
fi

echo
echo "app will invoke     : sudo -n \"$SUP\""
echo
echo "To test actual matching (installs a rule — REMOVE it after!):"
echo "  printf '%s\\n' '$RULE' | sudo tee /etc/sudoers.d/kanata-bar-supervise >/dev/null"
echo "  sudo chmod 0440 /etc/sudoers.d/kanata-bar-supervise && sudo visudo -c"
echo "  sudo -n '$SUP'   # should run with NO prompt and print a pid (Ctrl-C to stop)"
echo "  sudo rm /etc/sudoers.d/kanata-bar-supervise && sudo visudo -c"
