#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/detach"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-amphetamine.XXXXXX")"
TMUX_TMPDIR="/tmp/detach-amp-tmux-$$"
SOCKET="detach-amphetamine-$$"
SESSION="detach-codex-amphetamine-smoke"

run_codex() {
  "$SCRIPT" codex "$@"
}

export DETACH_STATE_ROOT="$TMP_ROOT/detach-state"
export DETACH_CODEX_STATE_ROOT="$TMP_ROOT/state"
export DETACH_LOCKS_ROOT="$TMP_ROOT/locks"
export DETACH_AMPHETAMINE_STATE_ROOT="$TMP_ROOT/amphetamine-state"
export DETACH_TMUX_SOCKET="$SOCKET"
export DETACH_CODEX_BIN="$ROOT/tests/fake-codex"
export DETACH_CODEX_CHECKPOINT_INTERVAL=1
export DETACH_CODEX_SYNC=0
export CODEX_HOME="$TMP_ROOT/codex-home"
export FAKE_CODEX_ARGS_FILE="$TMP_ROOT/args.txt"
export FAKE_CODEX_SLEEP=4
export FAKE_CODEX_EXIT=0
export TMUX_TMPDIR

cleanup() {
  run_codex stop amphetamine-smoke >/dev/null 2>&1 || true
  run_codex stop amphetamine-reconcile >/dev/null 2>&1 || true
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMUX_TMPDIR" "$TMP_ROOT"
}
trap cleanup EXIT

if [ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "true" ]; then
  printf 'Refusing to replace an active Amphetamine session.\n' >&2
  exit 1
fi

mkdir -p "$TMUX_TMPDIR" "$CODEX_HOME"

run_codex --name amphetamine-smoke --detach -- 'Amphetamine smoke test'
sleep 2

[ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "true" ]
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to closed display mode enabled')" = "true" ]
pmset -g live | grep -Eq 'SleepDisabled"?[[:space:]]*(=[[:space:]]*)?(Yes|1)([[:space:]]|$)'

sleep 5
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "false" ]
! pmset -g live | grep -Eq 'SleepDisabled"?[[:space:]]*(=[[:space:]]*)?(Yes|1)([[:space:]]|$)'

# A stale Power Protect flag after a crash must be repaired without Amphetamine.
jq -n '{owned: true, pending: false}' >"$DETACH_AMPHETAMINE_STATE_ROOT/owner.json"
sudo -n pmset -a disablesleep 1
pmset -g live | grep -Eq 'SleepDisabled"?[[:space:]]*(=[[:space:]]*)?(Yes|1)([[:space:]]|$)'
run_codex __reconcile_amphetamine
[ ! -e "$DETACH_AMPHETAMINE_STATE_ROOT/owner.json" ]
! pmset -g live | grep -Eq 'SleepDisabled"?[[:space:]]*(=[[:space:]]*)?(Yes|1)([[:space:]]|$)'

tmux -L "$SOCKET" set-environment -g FAKE_CODEX_SLEEP 20
run_codex --name amphetamine-reconcile --detach -- 'Amphetamine reconcile test'
sleep 2
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "true" ]
jq -e '.tmux_socket_path | startswith("/")' "$DETACH_AMPHETAMINE_STATE_ROOT/leases/"*.json >/dev/null
osascript -e 'tell application id "com.if.Amphetamine" to end session' >/dev/null

attempts=0
while [ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "true" ] && [ "$attempts" -lt 8 ]; do
  attempts=$((attempts + 1))
  sleep 1
done
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "false" ]

env -u TMUX_TMPDIR "$SCRIPT" __reconcile_amphetamine
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "true" ]
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to closed display mode enabled')" = "true" ]
pmset -g live | grep -Eq 'SleepDisabled"?[[:space:]]*(=[[:space:]]*)?(Yes|1)([[:space:]]|$)'

run_codex stop amphetamine-reconcile >/dev/null
[ "$(osascript -e 'tell application id "com.if.Amphetamine" to session is active')" = "false" ]
! pmset -g live | grep -Eq 'SleepDisabled"?[[:space:]]*(=[[:space:]]*)?(Yes|1)([[:space:]]|$)'

printf 'Amphetamine Closed-Display Mode smoke test passed\n'
