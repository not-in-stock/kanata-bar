#!/usr/bin/env bash
#
# Non-root self-test for kanata-bar-supervise (task 18 / 2b).
#
# Exercises the supervisor's core loop WITHOUT root or TCC: a fake `kanata`
# (a sleep loop) is launched via a temp spec, and we assert the supervisor
#   1. prints the child pid on stdout (the SudoLauncher.readPID contract),
#   2. stays up while the child runs,
#   3. reaps the child when the stop sentinel is deleted (explicit Stop), and
#   4. exits when the child dies on its own (validates Process.isRunning without
#      a run loop — the one empirical unknown in the port from the shell wrapper).
#
# Uses KANATA_BAR_SUPERVISE_SPEC (honored only when euid != 0) to avoid /etc, and
# SUDO_UID=$(id -u) so the sentinel resolves to THIS user's real cache path. It
# therefore refuses to run while the real app is up, so it can't stop a live kanata.
#
# Usage: scripts/supervise-selftest.sh [path-to-kanata-bar-supervise]

set -euo pipefail

BIN="${1:-.build/release/kanata-bar-supervise}"
if [ ! -x "$BIN" ]; then
  echo "supervise binary not found at: $BIN" >&2
  echo "build it first: swift build -c release" >&2
  exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

SENTINEL="$HOME/Library/Caches/com.kanata-bar/kanata-stop.sentinel"

if pgrep -x kanata-bar >/dev/null 2>&1; then
  echo "refusing to run: kanata-bar is running (shares the stop sentinel)" >&2
  exit 2
fi
if [ -e "$SENTINEL" ]; then
  echo "refusing to run: stop sentinel already exists ($SENTINEL)" >&2
  exit 2
fi

TMP="$(mktemp -d)"
SUP_PID=""
cleanup() {
  [ -n "$SUP_PID" ] && kill "$SUP_PID" 2>/dev/null || true
  # kill any stray fake kanata we spawned
  pkill -x kanata-fake 2>/dev/null || true
  rm -f "$SENTINEL" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Fake kanata — must be named `kanata` (the supervisor's basename guard). Runs as
# this user (no root needed). Renames its own argv0 so our pkill cleanup is precise.
FAKE_DIR="$TMP/pkg/bin"
mkdir -p "$FAKE_DIR"
cat > "$FAKE_DIR/kanata" <<'EOF'
#!/bin/sh
exec -a kanata-fake /bin/sh -c 'while :; do sleep 0.3; done'
EOF
chmod +x "$FAKE_DIR/kanata"

SPEC="$TMP/supervise.env"
cat > "$SPEC" <<EOF
KANATA_BIN=$FAKE_DIR/kanata
KANATA_CONFIG=$TMP/fake.kbd
KANATA_PORT=5829
EOF
: > "$TMP/fake.kbd"

run_supervisor() {
  mkdir -p "$(dirname "$SENTINEL")"
  : > "$SENTINEL"
  local out="$TMP/sup.out"
  : > "$out"
  SUDO_UID="$(id -u)" KANATA_BAR_SUPERVISE_SPEC="$SPEC" "$BIN" > "$out" 2>"$TMP/sup.err" &
  SUP_PID=$!
  # Read the pid line (with a timeout).
  local waited=0
  KPID=""
  while [ -z "$KPID" ] && [ "$waited" -lt 30 ]; do
    KPID="$(head -n1 "$out" 2>/dev/null | tr -dc '0-9')"
    if [ -z "$KPID" ]; then sleep 0.1; waited=$((waited + 1)); fi
  done
}

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "== test 1: pid output + sentinel-removal reap =="
run_supervisor
[ -n "$KPID" ] || fail "no pid printed on stdout (stderr: $(cat "$TMP/sup.err"))"
kill -0 "$KPID" 2>/dev/null || fail "printed pid $KPID is not alive"
echo "  supervisor printed child pid $KPID, child alive — ok"
# Supervisor must still be running while the child runs.
kill -0 "$SUP_PID" 2>/dev/null || fail "supervisor exited while child was alive"
# Explicit Stop: remove the sentinel → supervisor must reap the child and exit.
rm -f "$SENTINEL"
waited=0
while kill -0 "$KPID" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.1; waited=$((waited + 1)); done
kill -0 "$KPID" 2>/dev/null && fail "child $KPID survived sentinel removal"
wait "$SUP_PID" 2>/dev/null || true
echo "  sentinel removed → child reaped, supervisor exited — ok"

echo "== test 2: child-death detection =="
run_supervisor
[ -n "$KPID" ] || fail "no pid printed (run 2)"
# Kill the child directly → the supervisor's poll must notice and exit.
kill -KILL "$KPID" 2>/dev/null || true
waited=0
while kill -0 "$SUP_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.1; waited=$((waited + 1)); done
kill -0 "$SUP_PID" 2>/dev/null && fail "supervisor did not exit after child died (Process.isRunning stuck?)"
rm -f "$SENTINEL"
echo "  child killed → supervisor exited — ok"

echo "ALL PASS"
