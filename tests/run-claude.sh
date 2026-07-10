#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/detach"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-detached-test.XXXXXX")"
SOCKET="claude-detached-test-$$"

cleanup() {
  if [ "${CLAUDE_DETACHED_TEST_KEEP:-0}" = "1" ]; then
    printf 'Preserved test state: %s (socket=%s, tmux_tmpdir=%s)\n' "$TMP_ROOT" "$SOCKET" "$TMUX_TMPDIR" >&2
  else
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMUX_TMPDIR"
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

export CLAUDE_DETACHED_STATE_ROOT="$TMP_ROOT/state"
export CODEX_DETACHED_STATE_ROOT="$TMP_ROOT/codex-state"
export DETACH_TMUX_SOCKET="$SOCKET"
export DETACH_TMUX_CONFIG="$TMP_ROOT/tmux.conf"
export CLAUDE_DETACHED_CLAUDE_BIN="$ROOT/tests/fake-claude"
export CODEX_DETACHED_CODEX_BIN="$ROOT/tests/fake-codex"
export CLAUDE_DETACHED_AMPHETAMINE=0
export CODEX_DETACHED_AMPHETAMINE=0
export CLAUDE_DETACHED_CHECKPOINT_INTERVAL=1
export CLAUDE_DETACHED_SYNC=0
export DETACH_LOCKS_ROOT="$TMP_ROOT/locks"
export DETACH_AMPHETAMINE_STATE_ROOT="$TMP_ROOT/amphetamine-state"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-home"
export CODEX_HOME="$TMP_ROOT/codex-home"
export FAKE_CLAUDE_ARGS_FILE="$TMP_ROOT/args.txt"
export FAKE_CODEX_ARGS_FILE="$TMP_ROOT/codex-args.txt"
export FAKE_CLAUDE_SLEEP=4
export FAKE_CLAUDE_EXIT=7
export TMUX_TMPDIR="/tmp/claude-detached-tmux-$$"
mkdir -p "$TMUX_TMPDIR" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
printf '%s\n' 'set -g base-index 1' 'set -g pane-base-index 1' >"$DETACH_TMUX_CONFIG"

bash -n "$SCRIPT"
bash -n "$ROOT/tests/fake-claude"

marker="$TMP_ROOT/must-not-exist"
literal_prompt="spaces ; \$(touch $marker) * \"quotes\""
mkdir -p "$TMP_ROOT/extra-a" "$TMP_ROOT/extra-b"
"$SCRIPT" claude --name integration --detach -- \
  --name display-name "$literal_prompt" --add-dir "$TMP_ROOT/extra-a" "$TMP_ROOT/extra-b"

sleep 2
grep -Fx -- "$literal_prompt" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- '--session-id' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- '--name' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- 'display-name' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$TMP_ROOT/extra-a" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$TMP_ROOT/extra-b" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- '--permission-mode' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- 'auto' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
! grep -Fx -- '--dangerously-skip-permissions' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
[ ! -e "$marker" ]

session_id="$(awk 'previous == "--session-id" { print; exit } { previous = $0 }' "$FAKE_CLAUDE_ARGS_FILE")"
[[ "$session_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]

meta_files=("$CLAUDE_DETACHED_STATE_ROOT"/sessions/*/meta.json)
[ "${#meta_files[@]}" -eq 1 ]
[ -f "${meta_files[0]}" ]
meta="${meta_files[0]}"
session="$(jq -r '.session_name' "$meta")"
session_dir="$(dirname "$meta")"
checkpoint="$session_dir/checkpoint"

tmux -L "$SOCKET" has-session -t "=$session"
"$SCRIPT" list | grep -F 'claude' | grep -F "$session" | grep -F "$session_id" >/dev/null
json_line="$("$SCRIPT" list --json | grep -F "\"session_name\":\"$session\"")"
printf '%s' "$json_line" | jq -e --arg id "$session_id" '
  .schema == 1 and .provider == "claude" and .effective_status == "running"
  and .agent_session_id == $id and (.project_dir | type == "string")' >/dev/null
if "$SCRIPT" codex --name cross-provider --detach -- 'must not run beside Claude'; then
  printf 'Codex unexpectedly started beside a running Claude task\n' >&2
  exit 1
fi
jq -e --arg id "$session_id" \
  '.provider == "claude" and .agent_session_id == $id' "$meta" >/dev/null
sqlite3 "$CODEX_HOME/state_5.sqlite" \
  'CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at_ms INTEGER, updated_at_ms INTEGER, source TEXT, thread_source TEXT, cwd TEXT);'
sqlite3 "$CODEX_HOME/state_5.sqlite" \
  "INSERT INTO threads (id, rollout_path, source, thread_source, cwd) VALUES ('$session_id', '/tmp/not-used.jsonl', 'cli', 'user', '$ROOT');"
if "$SCRIPT" resume --detach "$session_id"; then
  printf 'Universal resume accepted a UUID shared by both providers\n' >&2
  exit 1
fi
sqlite3 "$CODEX_HOME/state_5.sqlite" "DELETE FROM threads WHERE id = '$session_id';"
run_token="$(jq -r '.run_token' "$meta")"
"$SCRIPT" resume --detach "$session_id" | grep -F 'Already running:' >/dev/null
[ "$(jq -r '.run_token' "$meta")" = "$run_token" ]
[ -s "$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl" ]
[ -d "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/subagents" ]
[ -d "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/tool-results" ]
[ -d "$CLAUDE_CONFIG_DIR/file-history/$session_id" ]
[ -d "$CLAUDE_CONFIG_DIR/session-env/$session_id" ]
[ -d "$CLAUDE_CONFIG_DIR/tasks/$session_id" ]
[ -d "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}" ]
[ -d "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}" ]
[ -s "$checkpoint/transcript.jsonl" ]
jq -e -c . "$checkpoint/transcript.jsonl" >/dev/null
[ -s "$checkpoint/claude-session.tar" ]
tar -tf "$checkpoint/claude-session.tar" | grep -F './project-session/subagents/agent-fake.jsonl' >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F "./tasks/$session_id/task.json" >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F "./tasks/session-${session_id:0:8}/task.json" >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F "./teams/session-${session_id:0:8}/config.json" >/dev/null

sleep 4
jq -e '.status == "failed" and .exit_status == 7' "$meta" >/dev/null
"$SCRIPT" claude logs integration | grep -F 'fake Claude finished' >/dev/null

"$SCRIPT" claude stop integration
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null
jq -e '.status == "stopped" and .stopped_at != null' "$meta" >/dev/null

# Simulate losing primary metadata during a power failure. Recovery must use
# checkpoint metadata and resume the exact Claude session UUID.
checkpoint_meta_tmp="$checkpoint/meta.json.tmp-test"
jq '.status = "running" | .exit_status = null' "$checkpoint/meta.json" >"$checkpoint_meta_tmp"
mv "$checkpoint_meta_tmp" "$checkpoint/meta.json"
rm -f "$meta"
printf '{damaged transcript\n' >"$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl"
rm -rf \
  "$CLAUDE_CONFIG_DIR/projects/fake/$session_id" \
  "$CLAUDE_CONFIG_DIR/file-history/$session_id" \
  "$CLAUDE_CONFIG_DIR/session-env/$session_id" \
  "$CLAUDE_CONFIG_DIR/tasks/$session_id" \
  "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}" \
  "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}"

export FAKE_CLAUDE_SLEEP=20
export FAKE_CLAUDE_EXIT=0
export FAKE_CLAUDE_EXPECT_RESTORED=1
"$SCRIPT" claude recover --detach integration
sleep 1
grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$session_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- 'display-name' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$TMP_ROOT/extra-a" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$TMP_ROOT/extra-b" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
jq -e --arg id "$session_id" \
  '.provider == "claude" and .agent_session_id == $id' "$meta" >/dev/null
jq -e -c . "$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl" >/dev/null
[ -s "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/subagents/agent-fake.jsonl" ]
[ -s "$CLAUDE_CONFIG_DIR/file-history/$session_id/fake-file@v1" ]
[ -s "$CLAUDE_CONFIG_DIR/session-env/$session_id/environment" ]
[ -s "$CLAUDE_CONFIG_DIR/tasks/$session_id/task.json" ]
[ -s "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}/task.json" ]
[ -s "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}/config.json" ]

"$SCRIPT" claude stop integration
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null

# Recovery must also recreate the encoded project directory if it disappeared
# together with the live transcript.
rm -rf "$CLAUDE_CONFIG_DIR/projects/fake"
"$SCRIPT" claude recover --detach integration
sleep 1
"$SCRIPT" claude stop integration

# Universal resume must route a known Claude UUID back to the Claude provider.
rm -f \
  "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/subagents/agent-fake.jsonl" \
  "$CLAUDE_CONFIG_DIR/file-history/$session_id/fake-file@v1" \
  "$CLAUDE_CONFIG_DIR/session-env/$session_id/environment" \
  "$CLAUDE_CONFIG_DIR/tasks/$session_id/task.json" \
  "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}/task.json" \
  "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}/config.json"
other_cwd="$TMP_ROOT/other-cwd"
mkdir -p "$other_cwd"
(cd "$other_cwd" && "$SCRIPT" resume --detach "$session_id")
sleep 1
grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$session_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
jq -e --arg id "$session_id" \
  '.provider == "claude" and .agent_session_id == $id' "$meta" >/dev/null
"$SCRIPT" claude logs integration | grep -F "fake Claude started in $ROOT" >/dev/null
"$SCRIPT" claude stop integration

# A stale checkpoint for session A must not block session B when the same
# harness name is reused for an explicit resume.
second_id="11111111-2222-4333-8444-555555555555"
jq -cn --arg id "$second_id" --arg cwd "$ROOT" \
  '{type:"user", sessionId:$id, cwd:$cwd, message:{role:"user",content:"session B"}}' \
  >"$CLAUDE_CONFIG_DIR/projects/fake/$second_id.jsonl"
export FAKE_CLAUDE_EXPECT_RESTORED=0
"$SCRIPT" claude resume --name integration --detach "$second_id"
sleep 1
grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$second_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
"$SCRIPT" claude stop integration

printf '{truncated task\n' >"$CLAUDE_CONFIG_DIR/tasks/$second_id/task.json"
export FAKE_CLAUDE_EXPECT_RESTORED=1
"$SCRIPT" claude recover --detach integration
sleep 1
"$SCRIPT" claude stop integration
export FAKE_CLAUDE_EXPECT_RESTORED=0

mkdir -p "$CLAUDE_CONFIG_DIR/projects/copy"
cp -p "$CLAUDE_CONFIG_DIR/projects/fake/$second_id.jsonl" \
  "$CLAUDE_CONFIG_DIR/projects/copy/$second_id.jsonl"
if "$SCRIPT" claude resume --name duplicate --detach "$second_id"; then
  printf 'Claude resume accepted an ambiguous duplicate transcript\n' >&2
  exit 1
fi

outside="$TMP_ROOT/must-not-overwrite.jsonl"
printf 'outside sentinel\n' >"$outside"
unsafe_meta_tmp="$meta.unsafe.tmp"
jq --arg path "$outside" '.transcript_path = $path' "$meta" >"$unsafe_meta_tmp"
mv "$unsafe_meta_tmp" "$meta"
if "$SCRIPT" claude recover --detach integration; then
  printf 'Claude recover accepted an unsafe transcript path\n' >&2
  exit 1
fi
grep -Fx 'outside sentinel' "$outside" >/dev/null

# delete kills a retained pane and removes the session state.
export FAKE_CLAUDE_SLEEP=1
export FAKE_CLAUDE_EXIT=0
"$SCRIPT" claude --name integration --detach -- 'delete coverage'
sleep 3
tmux -L "$SOCKET" has-session -t "=$session"
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @codex_detached_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]
"$SCRIPT" claude delete --force integration
[ ! -d "$CLAUDE_DETACHED_STATE_ROOT/sessions/$session" ]
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null

printf 'Claude detach integration tests passed\n'
