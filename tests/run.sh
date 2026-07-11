#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/detach"
DETACH="$ROOT/bin/detach"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-detached-test.XXXXXX")"
SOCKET="codex-detached-test-$$"
SESSION="codex-detached-integration"

run_codex() {
  "$SCRIPT" codex "$@"
}

cleanup() {
  if [ "${CODEX_DETACHED_TEST_KEEP:-0}" = "1" ]; then
    printf 'Preserved test state: %s (socket=%s, tmux_tmpdir=%s)\n' "$TMP_ROOT" "$SOCKET" "$TMUX_TMPDIR" >&2
  else
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMUX_TMPDIR"
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

process_group_exists() {
  ps -axo pgid= | awk -v pgid="$1" '$1 == pgid { found = 1 } END { exit(found ? 0 : 1) }'
}

wait_for_process_group_exit() {
  local pgid="$1"
  local attempts=0
  while process_group_exists "$pgid" && [ "$attempts" -lt 50 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  ! process_group_exists "$pgid"
}

export CODEX_DETACHED_STATE_ROOT="$TMP_ROOT/state"
export DETACH_LOCKS_ROOT="$TMP_ROOT/locks"
export DETACH_AMPHETAMINE_STATE_ROOT="$TMP_ROOT/amphetamine-state"
export CODEX_DETACHED_TMUX_SOCKET="$SOCKET"
export CODEX_DETACHED_TMUX_CONFIG="$TMP_ROOT/tmux.conf"
export CODEX_DETACHED_CODEX_BIN="$ROOT/tests/fake-codex"
export CODEX_DETACHED_AMPHETAMINE=0
export CODEX_DETACHED_CHECKPOINT_INTERVAL=1
export CODEX_DETACHED_SYNC=0
export CODEX_DETACHED_REQUIREMENTS_FILE="$TMP_ROOT/requirements.toml"
export CODEX_HOME="$TMP_ROOT/codex-home"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-home"
export CLAUDE_DETACHED_STATE_ROOT="$TMP_ROOT/claude-state"
export FAKE_CODEX_ARGS_FILE="$TMP_ROOT/args.txt"
export FAKE_CODEX_SLEEP=4
export FAKE_CODEX_EXIT=7
export FAKE_CODEX_FOREIGN_FIRST=1
export FAKE_CODEX_INIT_DELAY=1
export TMUX_TMPDIR="/tmp/cdt-tmux-$$"
mkdir -p "$TMUX_TMPDIR" "$CODEX_HOME"
printf '%s\n' 'set -g base-index 1' 'set -g pane-base-index 1' >"$CODEX_DETACHED_TMUX_CONFIG"
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request"]' >"$CODEX_DETACHED_REQUIREMENTS_FILE"

bash -n "$SCRIPT"
bash -n "$ROOT/bin/detach-core"

# The installed layout exposes only detach on PATH. The frontend must still
# find its sibling core after resolving the public symlink.
install_root="$TMP_ROOT/install"
install -d "$install_root/bin" "$install_root/libexec/detach"
install -m 0755 "$ROOT/bin/detach" "$ROOT/bin/detach-core" "$install_root/libexec/detach/"
ln -s ../libexec/detach/detach "$install_root/bin/detach"
"$install_root/bin/detach" --help >/dev/null
[ ! -e "$install_root/bin/detach-core" ]
if "$install_root/libexec/detach/detach-core" >/dev/null 2>&1; then
  printf 'detach-core unexpectedly accepted direct invocation\n' >&2
  exit 1
fi

marker="$TMP_ROOT/must-not-exist"
literal_prompt="spaces ; \$(touch $marker) * \"quotes\""
run_codex --name integration --detach -- "$literal_prompt"

sleep 2
tmux -L "$SOCKET" has-session -t "=$SESSION"
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" >/dev/null
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @codex_detached_pane_id)"
first_worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
first_worker_pgid="$(ps -o pgid= -p "$first_worker_pid" | tr -d '[:space:]')"
grep -F -- "$literal_prompt" "$FAKE_CODEX_ARGS_FILE" >/dev/null
! grep -Fx -- '--ask-for-approval' "$FAKE_CODEX_ARGS_FILE" >/dev/null
[ ! -e "$marker" ]

meta="$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION/meta.json"
checkpoint="$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION/checkpoint"
jq -e '.codex_session_id != null' "$meta" >/dev/null
expected_id="$(jq -r '.codex_session_id' "$meta")"
[ "$expected_id" != "ffffffff-ffff-4fff-8fff-ffffffffffff" ]
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" | grep -F "$expected_id" >/dev/null
[ -s "$checkpoint/rollout.jsonl" ]
[ -s "$checkpoint/codex-state.sqlite" ]

sleep 4
[ -f "$checkpoint/pane.txt" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @codex_detached_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead_status}')" = "7" ]
wait_for_process_group_exit "$first_worker_pgid"
jq -e '.status == "failed" and .exit_status == 7' "$meta" >/dev/null
run_codex logs integration | grep -F 'fake Codex finished' >/dev/null

run_codex stop integration
! tmux -L "$SOCKET" has-session -t "=$SESSION" 2>/dev/null
jq -e '.status == "stopped" and .stopped_at != null' "$meta" >/dev/null

# Simulate losing the primary metadata in a power failure. Auto-recovery must
# use the checkpoint metadata and resume the exact saved UUID.
checkpoint_meta_tmp="$checkpoint/meta.json.tmp-test"
jq '.status = "running"' "$checkpoint/meta.json" >"$checkpoint_meta_tmp"
mv "$checkpoint_meta_tmp" "$checkpoint/meta.json"
rm -f "$meta"

export FAKE_CODEX_SLEEP=20
export FAKE_CODEX_EXIT=0
export FAKE_CODEX_FOREIGN_FIRST=0
run_codex recover --detach integration
sleep 1
grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
grep -Fx "$expected_id" "$FAKE_CODEX_ARGS_FILE" >/dev/null
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @codex_detached_pane_id)"
worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
worker_pgid="$(ps -o pgid= -p "$worker_pid" | tr -d '[:space:]')"

run_codex stop integration
! kill -0 "$worker_pid" 2>/dev/null
wait_for_process_group_exit "$worker_pgid"
jq -e '.status == "stopped" and .stopped_at != null' "$meta" >/dev/null

# A fresh run with the same name must never inherit the previous run's UUID.
[ -s "$checkpoint/rollout.jsonl" ]
export FAKE_CODEX_INIT_DELAY=5
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request", "never"]' >"$CODEX_DETACHED_REQUIREMENTS_FILE"
run_codex --name integration --detach -- 'start a new thread'
sleep 1
[ "$(grep -Fxc -- '--ask-for-approval' "$FAKE_CODEX_ARGS_FILE")" = "1" ]
[ "$(grep -Fxc -- 'never' "$FAKE_CODEX_ARGS_FILE")" = "1" ]
[ ! -e "$checkpoint/rollout.jsonl" ]
[ ! -e "$checkpoint/meta.json" ]
fresh_run_token="$(jq -r '.run_token' "$meta")"
if run_codex --name integration --detach -- 'must not replace a running task'; then
  printf 'new default start unexpectedly replaced a running task\n' >&2
  exit 1
fi
[ "$(jq -r '.run_token' "$meta")" = "$fresh_run_token" ]
run_codex stop integration

# Explicit resume follows Codex semantics and accepts the exact thread UUID.
export FAKE_CODEX_INIT_DELAY=0
export FAKE_CODEX_SLEEP=1
expected_rollout="$(sqlite3 "$CODEX_HOME/state_5.sqlite" "SELECT rollout_path FROM threads WHERE id = '$expected_id';")"
cp -p "$expected_rollout" "$checkpoint/rollout.jsonl"
printf '{damaged rollout\n' >"$expected_rollout"
uppercase_id="$(printf '%s' "$expected_id" | tr '[:lower:]' '[:upper:]')"
other_cwd="$TMP_ROOT/other-cwd"
mkdir -p "$other_cwd"
(cd "$other_cwd" && "$DETACH" resume --name integration --detach "$uppercase_id")
sleep 2
grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
grep -Fx "$expected_id" "$FAKE_CODEX_ARGS_FILE" >/dev/null
jq -e --arg id "$expected_id" '.codex_session_id == $id' "$meta" >/dev/null
completed_run_token="$(jq -r '.run_token' "$meta")"
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @codex_detached_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]

# A normal start replaces a completed retained pane with a fresh Codex thread.
export FAKE_CODEX_INIT_DELAY=5
run_codex --name integration --detach -- 'replace the completed thread'
sleep 1
[ "$(jq -r '.run_token' "$meta")" != "$completed_run_token" ]
grep -Fx 'replace the completed thread' "$FAKE_CODEX_ARGS_FILE" >/dev/null
! grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @codex_detached_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "0" ]
run_codex stop integration

# list --json exposes machine-readable session state.
export FAKE_CODEX_INIT_DELAY=0
export FAKE_CODEX_SLEEP=20
export FAKE_CODEX_EXIT=0
run_codex --name integration --detach -- 'json coverage'
sleep 1
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$json_line" | jq -e '
  .schema == 1 and .provider == "codex" and .name == "integration"
  and .effective_status == "running" and (.project_dir | type == "string")
  and (.created_at | type == "string") and .exit_status == null
  and has("model") and has("context_used_tokens") and has("context_window")' >/dev/null
run_codex list --json | jq -es 'length > 0 and all(.schema == 1)' | grep -qx true
run_codex stop integration
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$json_line" | jq -e '
  .effective_status == "stopped" and .meta_status == "stopped"' >/dev/null

# delete refuses a live session and removes a stopped one.
run_codex --name integration --detach -- 'delete refusal coverage'
sleep 1
if run_codex delete --force integration; then
  printf 'delete unexpectedly removed a running session\n' >&2
  exit 1
fi
tmux -L "$SOCKET" has-session -t "=$SESSION"
run_codex stop integration
run_codex delete --force integration
[ ! -d "$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION" ]
! tmux -L "$SOCKET" has-session -t "=$SESSION" 2>/dev/null
! run_codex list --json | grep -F "\"session_name\":\"$SESSION\"" >/dev/null

# The destructive phase must repeat the ownership check under its lock. An
# unmanaged retained pane that appears after the outer check must survive.
mkdir -p "$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION"
printf 'foreign sentinel\n' >"$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION/sentinel"
foreign_pane="$(tmux -L "$SOCKET" new-session -d -P -F '#{pane_id}' -s "$SESSION" -n foreign)"
tmux -L "$SOCKET" set-option -q -w -t "$foreign_pane" remain-on-exit on
tmux -L "$SOCKET" send-keys -t "$foreign_pane" 'exit' Enter
attempts=0
while [ "$(tmux -L "$SOCKET" display-message -p -t "$foreign_pane" '#{pane_dead}')" != "1" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 40 ] || {
    printf 'unmanaged test pane did not exit\n' >&2
    exit 1
  }
  sleep 0.05
done
if run_codex __delete_locked "$SESSION"; then
  printf 'locked delete unexpectedly removed an unmanaged tmux session\n' >&2
  exit 1
fi
tmux -L "$SOCKET" has-session -t "=$SESSION"
grep -Fx 'foreign sentinel' "$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION/sentinel" >/dev/null
tmux -L "$SOCKET" kill-session -t "=$SESSION"
rm -rf "$CODEX_DETACHED_STATE_ROOT/sessions/$SESSION"

printf 'Codex detach integration tests passed\n'
