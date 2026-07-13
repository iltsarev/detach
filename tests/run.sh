#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/detach"
DETACH="$ROOT/bin/detach"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-codex-test.XXXXXX")"
SOCKET="detach-codex-test-$$"
SESSION="detach-codex-integration"

run_codex() {
  "$SCRIPT" codex "$@"
}

cleanup() {
  if [ "${DETACH_CODEX_TEST_KEEP:-0}" = "1" ]; then
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

export DETACH_STATE_ROOT="$TMP_ROOT/detach-state"
export DETACH_CODEX_STATE_ROOT="$TMP_ROOT/state"
export DETACH_LOCKS_ROOT="$TMP_ROOT/locks"
export DETACH_INSTALL_STATE_ROOT="$TMP_ROOT/install-state"
export DETACH_CONFIG_ROOT="$TMP_ROOT/config"
export DETACH_AMPHETAMINE_STATE_ROOT="$TMP_ROOT/amphetamine-state"
export DETACH_TMUX_SOCKET="$SOCKET"
export DETACH_TMUX_CONFIG="$TMP_ROOT/tmux.conf"
export DETACH_CODEX_BIN="$ROOT/tests/fake-codex"
export DETACH_AMPHETAMINE=0
export DETACH_CODEX_CHECKPOINT_INTERVAL=1
export DETACH_CODEX_SYNC=0
export DETACH_CODEX_REQUIREMENTS_FILE="$TMP_ROOT/requirements.toml"
export CODEX_HOME="$TMP_ROOT/codex-home"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-home"
export DETACH_CLAUDE_STATE_ROOT="$TMP_ROOT/claude-state"
export FAKE_CODEX_ARGS_FILE="$TMP_ROOT/args.txt"
export FAKE_CODEX_SLEEP=4
export FAKE_CODEX_EXIT=7
export FAKE_CODEX_FOREIGN_FIRST=1
export FAKE_CODEX_INIT_DELAY=1
export TMUX_TMPDIR="/tmp/detach-codex-tmux-$$"
# The test owns a private tmux server. An outer Detach/tmux context must not
# influence how tmux resolves -L or make attach semantics switch clients.
unset TMUX TMUX_PANE DETACH_CORE_ENTRYPOINT DETACH_PROVIDER DETACH_PROGRAM
mkdir -p "$TMUX_TMPDIR" "$CODEX_HOME"
printf '%s\n' 'set -g base-index 1' 'set -g pane-base-index 1' >"$DETACH_TMUX_CONFIG"
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request"]' >"$DETACH_CODEX_REQUIREMENTS_FILE"

bash -n "$SCRIPT"
bash -n "$ROOT/bin/detach-core"
[ "$($SCRIPT __version)" = "$(<"$ROOT/VERSION")" ]
[ "$($SCRIPT config tmux-style)" = "detach" ]
[ "$(run_codex __session_color /fixtures/harness)" = "#0F766E" ]
mkdir -p "$DETACH_CONFIG_ROOT"
printf '%s\n' '# Detach settings' 'CUSTOM_SETTING=kept' 'AMPHETAMINE=1' \
  >"$DETACH_CONFIG_ROOT/config"
printf '%s' 'TMUX_STYLE=0' >>"$DETACH_CONFIG_ROOT/config"
[ "$($SCRIPT config tmux-style)" = "inherit" ]
printf '%s\n' '' 'TMUX_STYLE=1' >>"$DETACH_CONFIG_ROOT/config"
"$SCRIPT" config tmux-style inherit
[ "$($SCRIPT config tmux-style)" = "inherit" ]
grep -Fx CUSTOM_SETTING=kept "$DETACH_CONFIG_ROOT/config" >/dev/null
grep -Fx AMPHETAMINE=1 "$DETACH_CONFIG_ROOT/config" >/dev/null
[ "$(grep -Fxc TMUX_STYLE=0 "$DETACH_CONFIG_ROOT/config")" = "1" ]
if "$SCRIPT" config tmux-style unsupported >/dev/null 2>&1; then
  printf 'config unexpectedly accepted an unsupported tmux style\n' >&2
  exit 1
fi
mv "$DETACH_CONFIG_ROOT/config" "$DETACH_CONFIG_ROOT/config.real"
ln -s config.real "$DETACH_CONFIG_ROOT/config"
if "$SCRIPT" config tmux-style detach >/dev/null 2>&1; then
  printf 'config unexpectedly replaced a symlink\n' >&2
  exit 1
fi
rm "$DETACH_CONFIG_ROOT/config"
mv "$DETACH_CONFIG_ROOT/config.real" "$DETACH_CONFIG_ROOT/config"
"$SCRIPT" config tmux-style detach
[ "$($SCRIPT config tmux-style)" = "detach" ]
[ "$(DETACH_TMUX_STYLE=0 "$SCRIPT" config tmux-style)" = "inherit" ]
if DETACH_TMUX_STYLE=0 "$SCRIPT" config tmux-style detach >/dev/null 2>&1; then
  printf 'config unexpectedly changed a value owned by DETACH_TMUX_STYLE\n' >&2
  exit 1
fi

# Pre-feature managed sessions have no styling ownership marker and must not
# be modified when the shared setting changes.
legacy_session="detach-codex-legacy-style"
legacy_pane="$(tmux -L "$SOCKET" new-session -d -P -F '#{pane_id}' -s "$legacy_session" -n legacy)"
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" @detach 1
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" @detach_provider codex
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" @detach_cwd /fixtures/legacy
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" status off
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" status-style 'fg=colour10,bg=colour20'
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" status-left 'legacy user status'
tmux -L "$SOCKET" set-option -q -t "=$legacy_session:" status-left-length 37
legacy_style="$(tmux -L "$SOCKET" show-options -qv -t "=$legacy_session:" status-style)"
"$SCRIPT" config tmux-style inherit
"$SCRIPT" config tmux-style detach
[ -z "$(tmux -L "$SOCKET" show-options -qv -t "=$legacy_session:" @detach_tmux_style)" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$legacy_session:" status)" = "off" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$legacy_session:" status-style)" = "$legacy_style" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$legacy_session:" status-left)" = "legacy user status" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$legacy_session:" status-left-length)" = "37" ]
tmux -L "$SOCKET" kill-session -t "=$legacy_session"

# The installed layout exposes only detach on PATH. The frontend must still
# find its sibling core after resolving the public symlink.
install_root="$TMP_ROOT/install"
installed_version="$(<"$ROOT/VERSION")"
installed_payload="$install_root/libexec/detach/versions/$installed_version-test"
install -d "$install_root/bin" "$installed_payload"
install -m 0755 "$ROOT/bin/detach" "$ROOT/bin/detach-core" "$installed_payload/"
install -m 0644 "$ROOT/VERSION" "$installed_payload/VERSION"
installed_core="$(cd -P "$installed_payload" && pwd)/detach-core"
ln -s "$installed_payload/detach" "$install_root/bin/detach"
"$install_root/bin/detach" --help >/dev/null
[ "$("$install_root/bin/detach" __version)" = "$installed_version" ]
[ ! -e "$install_root/bin/detach-core" ]
if "$installed_payload/detach-core" >/dev/null 2>&1; then
  printf 'detach-core unexpectedly accepted direct invocation\n' >&2
  exit 1
fi
SCRIPT="$install_root/bin/detach"
DETACH="$SCRIPT"

marker="$TMP_ROOT/must-not-exist"
literal_prompt="spaces ; \$(touch $marker) * \"quotes\""
run_codex --name integration --detach -- "$literal_prompt"

sleep 2
tmux -L "$SOCKET" has-session -t "=$SESSION"
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_provider)" = "codex" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "running" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_tmux_style)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_style_snapshot)" = "1" ]
session_color="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_color)"
[[ "$session_color" =~ ^#[[:xdigit:]]{6}$ ]]
tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style | grep -F "bg=$session_color" >/dev/null
status_left="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left)"
printf '%s' "$status_left" | grep -F 'Detach | Codex | harness' | grep -F 'RUNNING' >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_cli_version)" = "$installed_version" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_core_path)" = "$installed_core" ]
first_worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
first_worker_pgid="$(ps -o pgid= -p "$first_worker_pid" | tr -d '[:space:]')"
grep -F -- "$literal_prompt" "$FAKE_CODEX_ARGS_FILE" >/dev/null
! grep -Fx -- '--ask-for-approval' "$FAKE_CODEX_ARGS_FILE" >/dev/null
[ ! -e "$marker" ]

# Switching the public CLI while a worker is alive must not change that
# worker's resolved core path. New invocations get the upgraded payload.
upgraded_version="0.2.0"
upgraded_payload="$install_root/libexec/detach/versions/$upgraded_version-test"
install -d "$upgraded_payload"
install -m 0755 "$ROOT/bin/detach" "$ROOT/bin/detach-core" "$upgraded_payload/"
printf '%s\n' "$upgraded_version" >"$upgraded_payload/VERSION"
ln -s "$upgraded_payload/detach" "$install_root/bin/.detach-upgrade"
mv -f "$install_root/bin/.detach-upgrade" "$install_root/bin/detach"
[ "$("$SCRIPT" __version)" = "$upgraded_version" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_core_path)" = "$installed_core" ]

meta="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/meta.json"
checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint"
jq -e '.codex_session_id != null' "$meta" >/dev/null
jq -e --arg color "$session_color" '.session_color == $color' "$meta" >/dev/null
expected_id="$(jq -r '.codex_session_id' "$meta")"
[ "$expected_id" != "ffffffff-ffff-4fff-8fff-ffffffffffff" ]
rollout="$(jq -r '.rollout_path' "$meta")"
[ "$(sed -n '1p' "$rollout" | jq -r '.payload.originator')" = "detach_$(jq -r '.run_token' "$meta")" ]
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" | grep -F "$expected_id" >/dev/null
[ -s "$checkpoint/rollout.jsonl" ]
[ -s "$checkpoint/codex-state.sqlite" ]

sleep 4
[ -f "$checkpoint/pane.txt" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead_status}')" = "7" ]
wait_for_process_group_exit "$first_worker_pgid"
jq -e '.status == "failed" and .exit_status == 7' "$meta" >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "failed" ]
failed_style="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style)"
printf '%s' "$failed_style" | grep -F "bg=$session_color" >/dev/null
tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left | \
  grep -F 'bg=#B91C1C' | grep -F 'FAILED' >/dev/null
"$DETACH" config tmux-style inherit
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_tmux_style)" = "0" ]
[ -z "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_style_snapshot)" ]
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" status off
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" status-style 'fg=colour11,bg=colour21'
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" status-left 'user sentinel status'
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" status-left-length 41
sentinel_style="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style)"
"$DETACH" config tmux-style detach
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_tmux_style)" = "1" ]
tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left | grep -F 'FAILED' >/dev/null
"$DETACH" config tmux-style inherit
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status)" = "off" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style)" = "$sentinel_style" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left)" = "user sentinel status" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left-length)" = "41" ]
[ -z "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_style_snapshot)" ]
"$DETACH" config tmux-style detach
tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left | grep -F 'FAILED' >/dev/null
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
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
worker_pgid="$(ps -o pgid= -p "$worker_pid" | tr -d '[:space:]')"

run_codex stop integration
! kill -0 "$worker_pid" 2>/dev/null
wait_for_process_group_exit "$worker_pgid"
jq -e '.status == "stopped" and .stopped_at != null' "$meta" >/dev/null

# A fresh run with the same name must never inherit the previous run's UUID.
[ -s "$checkpoint/rollout.jsonl" ]
export FAKE_CODEX_INIT_DELAY=5
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request", "never"]' >"$DETACH_CODEX_REQUIREMENTS_FILE"
run_codex --name integration --detach -- 'start a new thread'
sleep 1
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_cli_version)" = "$upgraded_version" ]
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
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "completed" ]
completed_style="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style)"
[ "$completed_style" != "$failed_style" ]
! printf '%s' "$completed_style" | grep -F "bg=$session_color" >/dev/null

# A normal start replaces a completed retained pane with a fresh Codex thread.
export FAKE_CODEX_INIT_DELAY=5
run_codex --name integration --detach -- 'replace the completed thread'
sleep 1
[ "$(jq -r '.run_token' "$meta")" != "$completed_run_token" ]
grep -Fx 'replace the completed thread' "$FAKE_CODEX_ARGS_FILE" >/dev/null
! grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
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
  and (.session_color | test("^#[0-9A-Fa-f]{6}$"))
  and has("model") and has("context_used_tokens") and has("context_window")
  and .agent_turn_state == "working" and (.agent_turn_id | type == "string")' >/dev/null
turn_rollout="$(jq -r '.transcript_path' "$meta")"
turn_id="$(printf '%s' "$json_line" | jq -r '.agent_turn_id')"
jq -cn --arg turn_id "$turn_id" '
  {timestamp:"2099-01-01T00:10:00Z",type:"event_msg",
   payload:{type:"task_complete",turn_id:$turn_id}}' >>"$turn_rollout"
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$json_line" | jq -e --arg turn_id "$turn_id" '
  .effective_status == "running" and .agent_turn_state == "waiting"
  and .agent_turn_id == $turn_id' >/dev/null
run_codex list --json | jq -es 'length > 0 and all(.schema == 1)' | grep -qx true
run_codex stop integration
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$json_line" | jq -e '
  .effective_status == "stopped" and .meta_status == "stopped"' >/dev/null
legacy_meta="$meta.tmp-legacy-color"
jq 'del(.session_color)' "$meta" >"$legacy_meta"
mv "$legacy_meta" "$meta"
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$json_line" | jq -e --arg color "$session_color" '.session_color == $color' >/dev/null
invalid_color_meta="$meta.tmp-invalid-color"
jq '.session_color = "not-a-color"' "$meta" >"$invalid_color_meta"
mv "$invalid_color_meta" "$meta"
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$json_line" | jq -e '.session_color == null' >/dev/null
# Restore a valid identity before collision coverage so the foreign-session
# safety assertion does not pass merely because the saved value is malformed.
valid_color_meta="$meta.tmp-valid-color"
jq --arg color "$session_color" '.session_color = $color' "$meta" >"$valid_color_meta"
mv "$valid_color_meta" "$meta"

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
[ ! -d "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION" ]
! tmux -L "$SOCKET" has-session -t "=$SESSION" 2>/dev/null
! run_codex list --json | grep -F "\"session_name\":\"$SESSION\"" >/dev/null

# The destructive phase must repeat the ownership check under its lock. An
# unmanaged retained pane that appears after the outer check must survive.
mkdir -p "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION"
printf 'foreign sentinel\n' >"$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/sentinel"
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
collision_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
printf '%s' "$collision_json" | jq -e \
  '.effective_status == "collision" and has("session_color") and .session_color == null' >/dev/null
if run_codex __delete_locked "$SESSION"; then
  printf 'locked delete unexpectedly removed an unmanaged tmux session\n' >&2
  exit 1
fi
tmux -L "$SOCKET" has-session -t "=$SESSION"
grep -Fx 'foreign sentinel' "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/sentinel" >/dev/null
tmux -L "$SOCKET" kill-session -t "=$SESSION"
rm -rf "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION"

printf 'Codex detach integration tests passed\n'
