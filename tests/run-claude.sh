#!/bin/bash

set -eu
set -o pipefail
set -E

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
PROJECT_LABEL="${ROOT##*/}"
SCRIPT="$ROOT/bin/detach"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-claude-test.XXXXXX")"
TEST_INSTALL_STATE_ROOT="/tmp/detach-claude-install-state-$$"
TMUX_SOCKET_ROOT="$TEST_INSTALL_STATE_ROOT/tmux"
SOCKET="detach-claude-test-$$"
SOCKET_PATH="$TMUX_SOCKET_ROOT/$SOCKET.sock"
ARTIFACT_DIR="${DETACH_PROVIDER_TEST_ARTIFACT_DIR:-}"
FAILURE_LINE=""
FAILURE_COMMAND=""
CLAUDE_TEST_PART="${DETACH_CLAUDE_TEST_PART:-all}"

case "$CLAUDE_TEST_PART" in
  all|session|lifecycle|lifecycle-guardrails|recovery-guardrails|recovery|history) ;;
  *)
    printf 'unknown Claude test part: %s\n' "$CLAUDE_TEST_PART" >&2
    exit 2
    ;;
esac

claude_part_selected() {
  [ "$CLAUDE_TEST_PART" = all ] || [ "$CLAUDE_TEST_PART" = "$1" ] || {
    [ "$CLAUDE_TEST_PART" = lifecycle-guardrails ] && [ "$1" = lifecycle ] ||
    [ "$CLAUDE_TEST_PART" = session ] && {
      case "$1" in lifecycle|recovery) return 0 ;; esac
      return 1
    }
  }
}

claude_scenario_event() {
  [ "${DETACH_QUALITY_PARTITIONED_PROVIDER:-0}" = 1 ] || \
    "$ROOT/scripts/quality-scenarios" event "$1" "$2"
}

if [ -n "${DETACH_TEST_STATE_BIN:-}" ]; then
  STATE_HELPER="$DETACH_TEST_STATE_BIN"
else
  STATE_HELPER="$(swift build --disable-sandbox --package-path "$ROOT/app" --product detach-state --show-bin-path)/detach-state"
  swift build --disable-sandbox --package-path "$ROOT/app" --product detach-state >/dev/null
fi
[ -x "$STATE_HELPER" ] || {
  printf 'detach-state test helper is missing: %s\n' "$STATE_HELPER" >&2
  exit 1
}
TMUX_TEST_BIN="${DETACH_TEST_TMUX_BIN:-}"
[ -x "$TMUX_TEST_BIN" ] || {
  printf 'DETACH_TEST_TMUX_BIN must name an executable bundled tmux binary\n' >&2
  exit 1
}

tmux_socket_path_for_label() {
  printf '%s/%s.sock\n' "$TMUX_SOCKET_ROOT" "$1"
}

# Keep the test call sites readable while guaranteeing that every tmux command
# uses the explicit bundled executable and an absolute, per-test socket path.
tmux() {
  local label

  if [ "${1:-}" = "-L" ]; then
    [ "$#" -ge 2 ] || return 2
    label="$2"
    shift 2
    "$TMUX_TEST_BIN" -S "$(tmux_socket_path_for_label "$label")" "$@"
    return
  fi
  "$TMUX_TEST_BIN" "$@"
}

# Mirrors blend_session_color in detach-core so the tint contract is pinned
# independently of the implementation.
expected_tint() {
  local color="$1"
  local percent="$2"

  printf '#%02X%02X%02X' \
    $(( (16#${color:1:2} * percent + 32 * (100 - percent)) / 100 )) \
    $(( (16#${color:3:2} * percent + 32 * (100 - percent)) / 100 )) \
    $(( (16#${color:5:2} * percent + 43 * (100 - percent)) / 100 ))
}

preserve_failure_diagnostics() {
  local status="$1" source
  [ "$status" -ne 0 ] && [ -n "$ARTIFACT_DIR" ] || return 0
  case "$ARTIFACT_DIR" in /*) ;; *) printf 'Claude artifact directory must be absolute\n' >&2; return 0 ;; esac
  [ ! -e "$ARTIFACT_DIR" ] || [ -d "$ARTIFACT_DIR" ] && [ ! -L "$ARTIFACT_DIR" ] || return 0
  mkdir -p "$ARTIFACT_DIR"
  chmod 0700 "$ARTIFACT_DIR"
  for source in args.txt codex-args.txt power-args.txt power-releases.txt; do
    [ -f "$TMP_ROOT/$source" ] && [ ! -L "$TMP_ROOT/$source" ] || continue
    install -m 0600 "$TMP_ROOT/$source" "$ARTIFACT_DIR/$source"
  done
  {
    printf 'schema\t1\nexit_status\t%s\n' "$status"
    printf 'failure_line\t%s\n' "${FAILURE_LINE:--}"
    printf 'socket_root_present\t%s\n' "$([ -d "$TMUX_SOCKET_ROOT" ] && printf true || printf false)"
    printf 'socket_present\t%s\n' "$([ -S "$SOCKET_PATH" ] && printf true || printf false)"
    printf 'temporary_state_present\t%s\n' "$([ -d "$TMP_ROOT" ] && printf true || printf false)"
  } >"$ARTIFACT_DIR/diagnostics.tsv"
  chmod 0600 "$ARTIFACT_DIR/diagnostics.tsv"
  if [ -n "$FAILURE_COMMAND" ]; then
    printf '%s\n' "$FAILURE_COMMAND" >"$ARTIFACT_DIR/failure-command.txt"
    chmod 0600 "$ARTIFACT_DIR/failure-command.txt"
  fi
  find "$TMP_ROOT" -maxdepth 3 -type f -print 2>/dev/null | \
    sed "s#^$TMP_ROOT#TMP_ROOT#" | LC_ALL=C sort >"$ARTIFACT_DIR/file-inventory.txt"
  chmod 0600 "$ARTIFACT_DIR/file-inventory.txt"
  [ -z "$FAILURE_LINE" ] || printf 'Claude test failed at line %s\n' "$FAILURE_LINE" >&2
  printf 'Claude diagnostics preserved at %s\n' "$ARTIFACT_DIR" >&2
}

record_failure() {
  local status="$?"
  FAILURE_LINE="$1"
  FAILURE_COMMAND="$2"
  return "$status"
}

cleanup() {
  local status="${1:-0}"
  trap - ERR
  preserve_failure_diagnostics "$status"
  if [ "${DETACH_CLAUDE_TEST_KEEP:-0}" = "1" ]; then
    printf 'Preserved test state: %s (socket=%s, tmux_tmpdir=%s)\n' "$TMP_ROOT" "$SOCKET_PATH" "${TMUX_TMPDIR:-unset}" >&2
  else
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    [ -z "${TMUX_TMPDIR:-}" ] || rm -rf "$TMUX_TMPDIR"
    rm -rf "$TEST_INSTALL_STATE_ROOT"
    rm -rf "$TMP_ROOT"
  fi
}
trap 'record_failure "$LINENO" "$BASH_COMMAND"' ERR
trap 'cleanup $?' EXIT

export DETACH_STATE_ROOT="$TMP_ROOT/detach-state"
export DETACH_STATE_BIN="$STATE_HELPER"
FAKE_POWER_BIN="$TMP_ROOT/fake-detach-power"
export FAKE_POWER_ARGS_FILE="$TMP_ROOT/power-args.txt"
export FAKE_POWER_RELEASES_FILE="$TMP_ROOT/power-releases.txt"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then' \
  '  printf '\''{"schema":1,"state":"%s","helper_reachable":true}\n'\'' "${FAKE_POWER_STATE:-protected}"' \
  '  exit 0' \
  'fi' \
  'if [ "${1:-}" = release ]; then' \
  '  printf '\''%s\n'\'' "$*" >>"$FAKE_POWER_RELEASES_FILE"' \
  '  exit 0' \
  'fi' \
  'if [ "${1:-}" = run ]; then' \
  '  printf '\''%s\n'\'' "$@" >"$FAKE_POWER_ARGS_FILE"' \
  '  ready_file=' \
  '  pid_file=' \
  '  shift' \
  '  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do' \
  '    if [ "$1" = --ready-file ]; then ready_file="$2"; shift 2; continue; fi' \
  '    if [ "$1" = --pid-file ]; then pid_file="$2"; shift 2; continue; fi' \
  '    shift' \
  '  done' \
  '  [ "${1:-}" = -- ] || exit 2' \
  '  [ "${FAKE_POWER_FAIL_RUN:-0}" != 1 ] || exit 1' \
  '  [ -z "$ready_file" ] || : >"$ready_file"' \
  '  [ -z "$pid_file" ] || printf '\''%s\n'\'' "$$" >"$pid_file"' \
  '  shift' \
  '  exec "$@"' \
  'fi' \
  'exit 2' >"$FAKE_POWER_BIN"
chmod 0755 "$FAKE_POWER_BIN"
FAKE_GIT_BIN_DIR="$TMP_ROOT/fake-bin"
export FAKE_GIT_MARKER="$TMP_ROOT/ambient-git-was-invoked"
export FAKE_CLAUDE_EXIT_GATE="$TMP_ROOT/allow-initial-claude-exit"
mkdir -p "$FAKE_GIT_BIN_DIR"
printf '%s\n' \
  '#!/bin/bash' \
  ': >"$FAKE_GIT_MARKER"' \
  'exit 99' >"$FAKE_GIT_BIN_DIR/git"
chmod 0755 "$FAKE_GIT_BIN_DIR/git"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${1:-}" = detach-test-live ]; then' \
  '  while [ ! -e "$FAKE_CLAUDE_EXIT_GATE" ]; do /bin/sleep 0.1; done' \
  '  exit 0' \
  'fi' \
  'exec /bin/sleep "$@"' >"$FAKE_GIT_BIN_DIR/sleep"
chmod 0755 "$FAKE_GIT_BIN_DIR/sleep"
export PATH="$FAKE_GIT_BIN_DIR:$PATH"
export DETACH_POWER_BIN="$FAKE_POWER_BIN"
export DETACH_TMUX_BIN="$TMUX_TEST_BIN"
export DETACH_CLAUDE_STATE_ROOT="$TMP_ROOT/state"
export DETACH_CODEX_STATE_ROOT="$TMP_ROOT/codex-state"
export DETACH_TMUX_SOCKET_PATH="$SOCKET_PATH"
export DETACH_TMUX_CONFIG="$TMP_ROOT/tmux.conf"
export DETACH_CLAUDE_BIN="$ROOT/tests/fake-claude"
export DETACH_CODEX_BIN="$ROOT/tests/fake-codex"
export DETACH_CLAUDE_CHECKPOINT_INTERVAL=1
export DETACH_HEALTH_HEARTBEAT_INTERVAL=1
export DETACH_IDLE_HEALTH_HEARTBEAT_INTERVAL=2
export DETACH_HEALTH_HEARTBEAT_STALE=4
export DETACH_CLAUDE_SYNC=0
export DETACH_LOCKS_ROOT="$TMP_ROOT/locks"
export DETACH_INSTALL_STATE_ROOT="$TEST_INSTALL_STATE_ROOT"
export DETACH_CONFIG_ROOT="$TMP_ROOT/config"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-home"
CLAUDE_CONFIG_REAL_DIR="$TMP_ROOT/claude-home-real"
export CODEX_HOME="$TMP_ROOT/codex-home"
export FAKE_CLAUDE_ARGS_FILE="$TMP_ROOT/args.txt"
export FAKE_CLAUDE_READY_FILE="$TMP_ROOT/claude-ready"
export FAKE_CODEX_ARGS_FILE="$TMP_ROOT/codex-args.txt"
export FAKE_CLAUDE_SLEEP=detach-test-live
export FAKE_CLAUDE_EXIT=7
export TMUX_TMPDIR="/tmp/detach-claude-tmux-$$"
unset TMUX TMUX_PANE DETACH_CORE_ENTRYPOINT DETACH_PROVIDER DETACH_PROGRAM
unset DETACH_TMUX_SOCKET
mkdir -p "$TMUX_TMPDIR" "$TMUX_SOCKET_ROOT" "$CLAUDE_CONFIG_REAL_DIR" "$CODEX_HOME"
ln -s "$CLAUDE_CONFIG_REAL_DIR" "$CLAUDE_CONFIG_DIR"
printf '%s\n' 'set -g base-index 1' 'set -g pane-base-index 1' >"$DETACH_TMUX_CONFIG"

test_sqlite() {
  sqlite3 -cmd '.timeout 5000' "$@"
}

reset_fake_claude_ready() {
  rm -f "$FAKE_CLAUDE_READY_FILE"
}

wait_for_fake_claude_ready() {
  local attempts=0

  while [ ! -e "$FAKE_CLAUDE_READY_FILE" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || {
      printf 'fake Claude did not finish initialization within 5 seconds\n' >&2
      return 1
    }
    sleep 0.05
  done
}

wait_for_file_text() {
  local file="$1" text="$2" attempts=0
  while [ "$attempts" -lt 100 ]; do
    if [ -f "$file" ] && grep -Fx -- "$text" "$file" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'timed out waiting for %s in %s\n' "$text" "$file" >&2
  return 1
}

wait_for_tmux_option() {
  local session="$1" option="$2" expected="$3" attempts=0 actual=""
  while [ "$attempts" -lt 80 ]; do
    actual="$(tmux -L "$SOCKET" show-options -qv -t "=$session:" "$option" 2>/dev/null || true)"
    [ "$actual" != "$expected" ] || return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'timed out waiting for %s %s=%s (actual=%s)\n' \
    "$session" "$option" "$expected" "$actual" >&2
  return 1
}

wait_for_tmux_option_text() {
  local session="$1" option="$2" expected="$3" attempts=0 actual=""
  while [ "$attempts" -lt 80 ]; do
    actual="$(tmux -L "$SOCKET" show-options -qv -t "=$session:" "$option" 2>/dev/null || true)"
    if printf '%s' "$actual" | grep -F "$expected" >/dev/null; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'timed out waiting for %s %s to contain %s (actual=%s)\n' \
    "$session" "$option" "$expected" "$actual" >&2
  return 1
}

human_label='Rev (ai)'
human_digest="$(printf '%s' "$human_label" | shasum -a 256 | \
  awk '{print substr($1, 1, 12)}')"
human_session="detach-claude-Rev-ai-$human_digest"

bootstrap_claude_checkpoint() {
  mkdir -p "$TMP_ROOT/extra-a" "$TMP_ROOT/extra-b"
  export FAKE_CLAUDE_SLEEP=20
  export FAKE_CLAUDE_EXIT=0
  export FAKE_CLAUDE_EXPECT_RESTORED=0
  reset_fake_claude_ready
  "$SCRIPT" claude --name "$human_label" --detach -- \
    --name display-name 'checkpoint fixture' \
    --add-dir "$TMP_ROOT/extra-a" "$TMP_ROOT/extra-b"
  wait_for_fake_claude_ready
  session_id="$(awk 'previous == "--session-id" { print; exit } { previous = $0 }' \
    "$FAKE_CLAUDE_ARGS_FILE")"
  meta="$DETACH_CLAUDE_STATE_ROOT/sessions/$human_session/meta.json"
  session="$human_session"
  session_dir="$(dirname "$meta")"
  checkpoint="$session_dir/checkpoint"
  attempts=0
  while { [ ! -s "$checkpoint/transcript.jsonl" ] || \
          [ ! -s "$checkpoint/claude-session.tar" ]; } && \
        [ "$attempts" -lt 100 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  [ -s "$checkpoint/transcript.jsonl" ]
  [ -s "$checkpoint/claude-session.tar" ]
  "$SCRIPT" claude stop "$human_label"
}

if claude_part_selected lifecycle; then

bash -n "$SCRIPT"
bash -n "$ROOT/tests/fake-claude"
[ "$($SCRIPT __version)" = "$(<"$ROOT/VERSION")" ]
[ "$($SCRIPT config tmux-style)" = "detach" ]
[ "$("$SCRIPT" claude __session_color /fixtures/harness)" = "#C2410C" ]

# Color allocation is shared across providers. A path-derived collision walks
# to the next free hue, an existing unique identity remains stable, and only a
# fully occupied palette permits a duplicate.
color_cwd=/fixtures/shared-color
preferred_color="$("$SCRIPT" claude __session_color "$color_cwd")"
codex_color_sessions="$DETACH_CODEX_STATE_ROOT/sessions"
claude_color_sessions="$DETACH_CLAUDE_STATE_ROOT/sessions"
mkdir -p "$codex_color_sessions/taken" "$claude_color_sessions/current"
"$STATE_HELPER" meta create "$codex_color_sessions/taken/meta.json" \
  --integer schema 1 --string session_name taken --string session_color "$preferred_color"
allocated_color="$("$SCRIPT" claude __allocate_session_color "$color_cwd")"
[ "$allocated_color" != "$preferred_color" ]
"$STATE_HELPER" meta create "$claude_color_sessions/current/meta.json" \
  --integer schema 1 --string session_name current --string session_color "$allocated_color"
[ "$("$SCRIPT" claude __allocate_session_color "$color_cwd" current)" = "$allocated_color" ]
mkdir -p "$claude_color_sessions/duplicate-current"
"$STATE_HELPER" meta create "$claude_color_sessions/duplicate-current/meta.json" \
  --integer schema 1 --string session_name duplicate-current --string session_color "$preferred_color"
migrated_color="$("$SCRIPT" claude __allocate_session_color "$color_cwd" duplicate-current)"
[ "$migrated_color" != "$preferred_color" ]
[ "$migrated_color" != "$allocated_color" ]

palette=( '#C2410C' '#4D7C0F' '#15803D' '#0D9488' '#0369A1' '#1D4ED8' '#6D28D9' '#A21CAF' )
color_index=0
for color in "${palette[@]}"; do
  color_dir="$codex_color_sessions/palette-$color_index"
  mkdir -p "$color_dir"
  "$STATE_HELPER" meta create "$color_dir/meta.json" \
    --integer schema 1 --string session_name "palette-$color_index" --string session_color "$color"
  color_index=$((color_index + 1))
done
[ "$("$SCRIPT" claude __allocate_session_color "$color_cwd")" = "$preferred_color" ]
rm -rf "$codex_color_sessions" "$claude_color_sessions"

# A full finished history must not exhaust colors for current tasks. Allocation
# remains shared across providers, so simultaneous Codex and Claude tasks get
# different hues even when all eight colors occur in retained history.
color_index=0
for color in "${palette[@]}"; do
  color_dir="$codex_color_sessions/finished-$color_index"
  mkdir -p "$color_dir"
  "$STATE_HELPER" meta create "$color_dir/meta.json" \
    --integer schema 1 --string session_name "finished-$color_index" \
    --string status completed --string session_color "$color"
  color_index=$((color_index + 1))
done
current_claude_color="$("$SCRIPT" claude __allocate_session_color "$color_cwd")"
mkdir -p "$claude_color_sessions/current-claude"
"$STATE_HELPER" meta create "$claude_color_sessions/current-claude/meta.json" \
  --integer schema 1 --string session_name current-claude --string status running \
  --string session_color "$current_claude_color"
current_codex_color="$("$SCRIPT" codex __allocate_session_color "$color_cwd")"
[ "$current_codex_color" != "$current_claude_color" ]
rm -rf "$codex_color_sessions" "$claude_color_sessions"

marker="$TMP_ROOT/must-not-exist"
literal_prompt="spaces ; \$(touch $marker) * \"quotes\""
mkdir -p "$TMP_ROOT/extra-a" "$TMP_ROOT/extra-b"
# The display label stays out of tmux and filesystem identifiers, remains
# usable for every lifecycle command, and survives resume/recovery.
claude_scenario_event begin SC-SESSION-CREATE-CLAUDE
claude_scenario_event begin SC-SESSION-PERSIST-CLAUDE
claude_scenario_event begin SC-SESSION-RECOVER-CLAUDE
claude_scenario_event begin SC-SESSION-STOP-CLAUDE
claude_scenario_event begin SC-SESSION-DELETE-CLAUDE
reset_fake_claude_ready
LC_ALL=C "$SCRIPT" claude --name "$human_label" --detach -- \
  --name display-name "$literal_prompt" --add-dir "$TMP_ROOT/extra-a" "$TMP_ROOT/extra-b"

wait_for_fake_claude_ready
wait_for_tmux_option "$human_session" @detach_status running
wait_for_tmux_option "$human_session" set-titles on
LC_ALL=C.UTF-8 wait_for_tmux_option \
  "$human_session" set-titles-string "Detach · $PROJECT_LABEL"
wait_for_tmux_option_text "$human_session" status-left RUNNING
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

meta_files=("$DETACH_CLAUDE_STATE_ROOT"/sessions/*/meta.json)
[ "${#meta_files[@]}" -eq 1 ]
[ -f "${meta_files[0]}" ]
meta="${meta_files[0]}"
session="$("$STATE_HELPER" meta get "$meta" session_name)"
[ "$session" = "$human_session" ]
[ "$("$STATE_HELPER" meta get "$meta" display_name)" = "$human_label" ]
"$SCRIPT" claude status "$human_label" | \
  grep -F "Name:           $human_label" >/dev/null
claude_scenario_event pass SC-SESSION-CREATE-CLAUDE
session_dir="$(dirname "$meta")"
checkpoint="$session_dir/checkpoint"

# Universal resume must route a known live Claude UUID back to Claude without
# replacing its run token.
run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
"$SCRIPT" resume --detach "$session_id" | grep -F 'Already running:' >/dev/null
[ "$("$STATE_HELPER" meta get "$meta" run_token)" = "$run_token" ]

tmux -L "$SOCKET" has-session -t "=$session"
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @detach)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @detach_provider)" = "claude" ]
live_pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @detach_pane_id)"
# The start command (and therefore its creator process) has returned, yet the
# private tmux server and provider worker continue without an attached client.
[ "$(tmux -L "$SOCKET" display-message -p -t "$live_pane_id" '#{pane_dead}')" = "0" ]
[ "$(tmux -L "$SOCKET" show-options -qv -w -t "$live_pane_id" remain-on-exit)" = off ]
[ "$(tmux -L "$SOCKET" show-options -qv -p -t "$live_pane_id" remain-on-exit)" = on ]
claude_scenario_event pass SC-SESSION-PERSIST-CLAUDE
session_color="$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @detach_color)"
[[ "$session_color" =~ ^#[[:xdigit:]]{6}$ ]]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @detach_status)" = "running" ]
# Tinted style: the whole strip carries a dense blend of the session color,
# the solid edge stays pure, power on the right side of the status line.
tmux -L "$SOCKET" show-options -qv -t "=$session:" status-style | \
  grep -F "bg=$(expected_tint "$session_color" 55)" >/dev/null
tmux -L "$SOCKET" show-options -qv -t "=$session:" status-left | \
  grep -F "bg=$session_color" >/dev/null
tmux -L "$SOCKET" show-options -qv -t "=$session:" status-left | \
  grep -F 'Claude' | grep -F "$PROJECT_LABEL" | grep -F 'RUNNING' >/dev/null
tmux -L "$SOCKET" show-options -qv -t "=$session:" status-right | \
  grep -F 'MAC AWAKE' >/dev/null
# The shared private-server input contract applies to Claude sessions too.
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$session:" mouse)" = "on" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$session:" @detach_copy_type_through)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -sqv extended-keys)" = "always" ]
[ "$(tmux -L "$SOCKET" show-options -sqv @detach_extended_keys)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -sv terminal-features | grep -Fxc -- '*:extkeys')" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -sv terminal-features | grep -Fxc -- '*:hyperlinks')" = "1" ]
tmux -L "$SOCKET" list-keys -T root | grep -F 'S-Enter' | \
  grep -F 'send-keys M-Enter' >/dev/null
grep -Fx -- 'run' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--session' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$session" "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--run-token' "$FAKE_POWER_ARGS_FILE" >/dev/null
"$SCRIPT" list | grep -F 'claude' | grep -F "$session" | grep -F "$session_id" >/dev/null
mkdir -p "$TMP_ROOT/unrelated-tmux-tmpdir"
TMUX_TMPDIR="$TMP_ROOT/unrelated-tmux-tmpdir" \
  "$SCRIPT" list | grep -F 'claude' | grep -F "$session" | grep -F "$session_id" >/dev/null

# Exercise cross-provider routing while the fake Claude worker is definitely
# live; the later metadata and checkpoint assertions intentionally do more IO.
if "$SCRIPT" codex --name cross-provider --detach -- 'must not run beside Claude'; then
  printf 'Codex unexpectedly started beside a running Claude task\n' >&2
  exit 1
fi
"$STATE_HELPER" meta matches "$meta" claude "$session_id"
test_sqlite "$CODEX_HOME/state_5.sqlite" \
  'CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at_ms INTEGER, updated_at_ms INTEGER, source TEXT, thread_source TEXT, cwd TEXT);'

# A filename alone is not evidence of a Claude session. A truncated/foreign
# file whose UUID belongs to Codex must not create false cross-provider
# ambiguity before the stricter context resolver gets a chance to run.
codex_only_id="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/foreign"
printf '{truncated claude transcript\n' \
  >"$CLAUDE_CONFIG_DIR/projects/foreign/$codex_only_id.jsonl"
test_sqlite "$CODEX_HOME/state_5.sqlite" \
  "INSERT INTO threads (id, rollout_path, source, thread_source, cwd) VALUES ('$codex_only_id', '/tmp/codex-only.jsonl', 'cli', 'user', '$TMP_ROOT');"
"$SCRIPT" codex __has_session_id "$codex_only_id"
if "$SCRIPT" claude __has_session_id "$codex_only_id"; then
  printf 'Claude accepted a UUID based only on an invalid transcript filename\n' >&2
  exit 1
fi
test_sqlite "$CODEX_HOME/state_5.sqlite" "DELETE FROM threads WHERE id = '$codex_only_id';"
rm -f "$CLAUDE_CONFIG_DIR/projects/foreign/$codex_only_id.jsonl"

test_sqlite "$CODEX_HOME/state_5.sqlite" \
  "INSERT INTO threads (id, rollout_path, source, thread_source, cwd) VALUES ('$session_id', '/tmp/not-used.jsonl', 'cli', 'user', '$ROOT');"
if "$SCRIPT" resume --detach "$session_id"; then
  printf 'Cross-provider resume accepted a UUID shared by both providers\n' >&2
  exit 1
fi
test_sqlite "$CODEX_HOME/state_5.sqlite" "DELETE FROM threads WHERE id = '$session_id';"

require_session_json() {
  local output line
  output="$("$SCRIPT" list --json)" || {
    printf 'detach list --json failed while validating the live Claude session\n' >&2
    return 1
  }
  line="$(printf '%s\n' "$output" | grep -F "\"session_name\":\"$session\"")" || {
    printf 'detach list --json omitted the live Claude session:\n%s\n' "$output" >&2
    return 1
  }
  printf '%s\n' "$line"
}

json_line="$(require_session_json)"
assert_json_field() {
  local field="$1" expected="$2" actual
  actual="$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin "$field")" || {
    printf 'could not read %s from Claude list JSON: %s\n' "$field" "$json_line" >&2
    return 1
  }
  [ "$actual" = "$expected" ] || {
    printf 'unexpected Claude list field %s: expected %s, got %s\n' \
      "$field" "$expected" "$actual" >&2
    return 1
  }
}

assert_json_field schema 1
assert_json_field provider claude
assert_json_field effective_status running
assert_json_field agent_session_id "$session_id"
[ -n "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin project_dir)" ] || {
  printf 'Claude list JSON has an empty project_dir: %s\n' "$json_line" >&2
  exit 1
}
assert_json_field session_color "$session_color"
assert_json_field power_protection_state protected
printf '%s' "$json_line" | grep -F '"model":' | grep -F '"context_used_tokens":' | \
  grep -F '"context_window":' >/dev/null || {
    printf 'Claude list JSON omitted context fields: %s\n' "$json_line" >&2
    exit 1
  }
assert_json_field agent_turn_state working
assert_json_field agent_turn_id "$session_id"
transcript="$("$STATE_HELPER" meta get "$meta" transcript_path)"
power_activity="$DETACH_CLAUDE_STATE_ROOT/sessions/$session/power-activity-$("$STATE_HELPER" meta get "$meta" run_token)"
power_activity_source="$DETACH_CLAUDE_STATE_ROOT/sessions/$session/power-activity-source-$("$STATE_HELPER" meta get "$meta" run_token)"
wait_for_file_text "$power_activity" working
grep -Fx -- '--activity-file' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$power_activity" "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--activity-source-file' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$power_activity_source" "$FAKE_POWER_ARGS_FILE" >/dev/null
printf '{"type":"user","isSidechain":false,"isMeta":false,"sessionId":"%s","message":{"role":"user","content":[{"type":"tool_result"}]},"uuid":"tool-result-event","timestamp":"2099-01-01T00:02:00.000Z"}\n' \
  "$session_id" >>"$transcript"
printf '{"type":"assistant","isSidechain":false,"sessionId":"%s","message":{"role":"assistant","stop_reason":"end_turn","id":"message-1"},"uuid":"assistant-chunk-1","timestamp":"2099-01-01T00:03:00.000Z"}\n' \
  "$session_id" >>"$transcript"
printf '{"type":"assistant","isSidechain":false,"sessionId":"%s","message":{"role":"assistant","stop_reason":"end_turn","id":"message-1"},"uuid":"assistant-chunk-2","timestamp":"2099-01-01T00:03:01.000Z"}\n' \
  "$session_id" >>"$transcript"
json_line="$("$SCRIPT" list --json | grep -F "\"session_name\":\"$session\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin display_name)" = \
  "$human_label" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "working" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "$session_id" ]
printf '{"type":"system","subtype":"turn_duration","isSidechain":false,"sessionId":"%s","uuid":"turn-duration-1","timestamp":"2099-01-01T00:03:02.000Z"}\n' \
  "$session_id" >>"$transcript"
json_line="$("$SCRIPT" list --json | grep -F "\"session_name\":\"$session\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = "running" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "waiting" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "turn-duration-1" ]
wait_for_file_text "$power_activity" waiting
[ -s "$power_activity_source" ]
printf '{"type":"user","isSidechain":false,"isMeta":false,"sessionId":"%s","message":{"role":"user","content":"continue"},"uuid":"turn-after-idle","timestamp":"2099-01-01T00:03:03.000Z"}\n' \
  "$session_id" >>"$transcript"
wait_for_file_text "$power_activity" working
json_line="$("$SCRIPT" list --json | grep -F "\"session_name\":\"$session\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "working" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "turn-after-idle" ]
[ -s "$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl" ]
[ -d "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/subagents" ]
[ -d "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/tool-results" ]
[ -d "$CLAUDE_CONFIG_DIR/file-history/$session_id" ]
[ -d "$CLAUDE_CONFIG_DIR/session-env/$session_id" ]
[ -d "$CLAUDE_CONFIG_DIR/tasks/$session_id" ]
[ -d "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}" ]
[ -d "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}" ]
# Claude can hard-link a tool result from provider-managed scratch storage.
# Checkpoint staging must turn it into an independent regular file while the
# archive and restore paths keep their strict no-hard-link contract.
hardlink_source="$TMP_ROOT/provider-tool-result"
hardlink_result="$CLAUDE_CONFIG_DIR/projects/fake/$session_id/tool-results/hardlinked.txt"
printf 'hard-linked tool result\n' >"$hardlink_source"
ln "$hardlink_source" "$hardlink_result"
[ "$(stat -f '%l' "$hardlink_result")" = 2 ]
attempts=0
while [ ! -s "$checkpoint/transcript.jsonl" ] || \
    [ ! -s "$checkpoint/claude-session.tar" ] || \
    ! tar -tf "$checkpoint/claude-session.tar" 2>/dev/null | \
      grep -F './project-session/tool-results/hardlinked.txt' >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || {
    printf 'Claude checkpoint was not published within 10 seconds: %s\n' \
      "$checkpoint" >&2
    exit 1
  }
  sleep 0.1
done
[ -s "$checkpoint/transcript.jsonl" ]
"$STATE_HELPER" jsonl validate claude "$checkpoint/transcript.jsonl" "$session_id"
[ -s "$checkpoint/claude-session.tar" ]
tar -tf "$checkpoint/claude-session.tar" | grep -F './project-session/subagents/agent-fake.jsonl' >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F './project-session/tool-results/hardlinked.txt' >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F "./tasks/$session_id/task.json" >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F "./tasks/session-${session_id:0:8}/task.json" >/dev/null
tar -tf "$checkpoint/claude-session.tar" | grep -F "./teams/session-${session_id:0:8}/config.json" >/dev/null
hardlink_extract="$TMP_ROOT/hardlink-checkpoint-extract"
mkdir -p "$hardlink_extract"
tar -xf "$checkpoint/claude-session.tar" -C "$hardlink_extract"
grep -Fx 'hard-linked tool result' \
  "$hardlink_extract/project-session/tool-results/hardlinked.txt" >/dev/null
[ "$(stat -f '%l' "$hardlink_extract/project-session/tool-results/hardlinked.txt")" = 1 ]
[ ! -e "$FAKE_GIT_MARKER" ]

: >"$FAKE_CLAUDE_EXIT_GATE"
attempts=0
while [ "$("$STATE_HELPER" meta get "$meta" status)" != "failed" ] && \
    [ "$attempts" -lt 300 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$("$STATE_HELPER" meta get "$meta" status)" = "failed" ]
[ "$("$STATE_HELPER" meta get "$meta" exit_status)" = "7" ]
attempts=0
while :; do
  failed_tmux_status="$(tmux -L "$SOCKET" show-options -qv \
    -t "=$session:" @detach_status 2>/dev/null || true)"
  [ "$failed_tmux_status" != "failed" ] || break
  attempts=$((attempts + 1))
  [ "$attempts" -lt 50 ] || {
    printf 'Claude tmux status did not publish failed: %s\n' \
      "$failed_tmux_status" >&2
    exit 1
  }
  sleep 0.1
done
attempts=0
while :; do
  failed_status_left="$(tmux -L "$SOCKET" show-options -qv -t "=$session:" status-left 2>/dev/null || true)"
  if printf '%s' "$failed_status_left" | grep -F 'FAILED' >/dev/null; then
    break
  fi
  attempts=$((attempts + 1))
  [ "$attempts" -lt 50 ] || {
    printf 'Claude status line did not publish FAILED: %s\n' "$failed_status_left" >&2
    exit 1
  }
  sleep 0.1
done
printf '%s' "$failed_status_left" | grep -F 'bg=#B91C1C' >/dev/null
"$SCRIPT" claude logs "$human_label" | grep -F 'fake Claude finished' >/dev/null

stopped_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
"$SCRIPT" claude stop "$human_label"
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null
[ "$("$STATE_HELPER" meta get "$meta" status)" = "stopped" ]
[ -n "$("$STATE_HELPER" meta get "$meta" stopped_at)" ]
grep -Fx "release --session $session --run-token $stopped_run_token" \
  "$FAKE_POWER_RELEASES_FILE" >/dev/null
claude_scenario_event pass SC-SESSION-STOP-CLAUDE

[ -s "$checkpoint/transcript.jsonl" ]
resume_checkpoint_before="$(cksum "$checkpoint/transcript.jsonl")"
if FAKE_POWER_FAIL_RUN=1 \
  "$SCRIPT" resume --detach "$session_id"; then
  printf 'resume unexpectedly passed a failed worker readiness handshake\n' >&2
  exit 1
fi
[ -s "$checkpoint/transcript.jsonl" ] || {
  printf 'failed resume deleted the last Claude checkpoint transcript\n' >&2
  exit 1
}
[ "$(cksum "$checkpoint/transcript.jsonl")" = "$resume_checkpoint_before" ]
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null

if [ "$CLAUDE_TEST_PART" = lifecycle ]; then
  "$SCRIPT" claude delete --force "$human_label"
fi
fi

# Simulate losing primary metadata during a power failure. Recovery must use
# checkpoint metadata and resume the exact Claude session UUID.
if claude_part_selected recovery || [ "$CLAUDE_TEST_PART" = recovery-guardrails ] || \
   [ "$CLAUDE_TEST_PART" = lifecycle-guardrails ]; then
case "$CLAUDE_TEST_PART" in
recovery|recovery-guardrails)
  bootstrap_claude_checkpoint
  ;;
esac
"$STATE_HELPER" meta patch "$checkpoint/meta.json" --string status running --null exit_status
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

# CLAUDE_CONFIG_DIR itself may be a symlink, but no descendant on a restore
# destination may be one. Recovery must validate every destination before it
# replaces even the transcript, and it must never write through that symlink.
if [ "$CLAUDE_TEST_PART" = all ] || [ "$CLAUDE_TEST_PART" = session ] || \
   [ "$CLAUDE_TEST_PART" = recovery-guardrails ] || \
   [ "$CLAUDE_TEST_PART" = lifecycle-guardrails ]; then
unsafe_claude_outside="$TMP_ROOT/unsafe-claude-restore-target"
mkdir -p "$unsafe_claude_outside"
printf 'outside sentinel\n' >"$unsafe_claude_outside/sentinel"
rmdir "$CLAUDE_CONFIG_DIR/file-history"
ln -s "$unsafe_claude_outside" "$CLAUDE_CONFIG_DIR/file-history"
if "$SCRIPT" claude recover --detach "$human_label"; then
  printf 'Claude recover accepted a symlink below its canonical config root\n' >&2
  exit 1
fi
grep -Fx '{damaged transcript' \
  "$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl" >/dev/null
grep -Fx 'outside sentinel' "$unsafe_claude_outside/sentinel" >/dev/null
[ ! -e "$unsafe_claude_outside/$session_id" ]
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null
rm "$CLAUDE_CONFIG_DIR/file-history"
mkdir -p "$CLAUDE_CONFIG_DIR/file-history"

# Archive extraction accepts only regular files and directories. A special
# entry must be rejected before the transcript or any companion is changed.
good_claude_archive="$checkpoint/claude-session.tar.good-test"
malicious_claude_stage="$TMP_ROOT/malicious-claude-archive"
cp -p "$checkpoint/claude-session.tar" "$good_claude_archive"
mkdir -p "$malicious_claude_stage"
tar -xf "$good_claude_archive" -C "$malicious_claude_stage"
mkfifo "$malicious_claude_stage/restore-pipe"
tar -cf "$checkpoint/claude-session.tar" -C "$malicious_claude_stage" .
if "$SCRIPT" claude recover --detach "$human_label"; then
  printf 'Claude recover accepted a special entry in its checkpoint archive\n' >&2
  exit 1
fi
grep -Fx '{damaged transcript' \
  "$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl" >/dev/null
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null
mv -f "$good_claude_archive" "$checkpoint/claude-session.tar"
rm -rf "$malicious_claude_stage"
fi

if [ "$CLAUDE_TEST_PART" != recovery-guardrails ] && \
   [ "$CLAUDE_TEST_PART" != lifecycle-guardrails ]; then

# Stable publish siblings make an interrupted directory replacement
# recoverable. `.old` is rolled back first and `.tmp` is discarded safely;
# the matching checkpoint is then published without leaving either behind.
stale_restore_destination="$CLAUDE_CONFIG_REAL_DIR/file-history/$session_id"
mkdir -p \
  "$stale_restore_destination.detach.old" \
  "$stale_restore_destination.detach.tmp"
printf 'previous live tree\n' >"$stale_restore_destination.detach.old/sentinel"
printf 'incomplete new tree\n' >"$stale_restore_destination.detach.tmp/sentinel"

reset_fake_claude_ready
"$SCRIPT" claude recover --detach "$human_label"
wait_for_fake_claude_ready
[ "$("$STATE_HELPER" meta get "$meta" display_name)" = "$human_label" ]
grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$session_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- 'display-name' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$TMP_ROOT/extra-a" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$TMP_ROOT/extra-b" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
"$STATE_HELPER" meta matches "$meta" claude "$session_id"
"$STATE_HELPER" jsonl validate claude \
  "$CLAUDE_CONFIG_DIR/projects/fake/$session_id.jsonl" "$session_id"
[ -s "$CLAUDE_CONFIG_DIR/projects/fake/$session_id/subagents/agent-fake.jsonl" ]
[ -s "$CLAUDE_CONFIG_DIR/file-history/$session_id/fake-file@v1" ]
[ ! -e "$stale_restore_destination.detach.old" ]
[ ! -e "$stale_restore_destination.detach.tmp" ]
[ -s "$CLAUDE_CONFIG_DIR/session-env/$session_id/environment" ]
[ -s "$CLAUDE_CONFIG_DIR/tasks/$session_id/task.json" ]
[ -s "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}/task.json" ]
[ -s "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}/config.json" ]
claude_scenario_event pass SC-SESSION-RECOVER-CLAUDE

"$SCRIPT" claude stop "$human_label"
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null

# Universal resume must route a known Claude UUID back to Claude. It must also
# recreate the encoded project directory and all companion artifacts from the
# checkpoint before Claude starts.
rm -rf "$CLAUDE_CONFIG_DIR/projects/fake"
rm -f \
  "$CLAUDE_CONFIG_DIR/file-history/$session_id/fake-file@v1" \
  "$CLAUDE_CONFIG_DIR/session-env/$session_id/environment" \
  "$CLAUDE_CONFIG_DIR/tasks/$session_id/task.json" \
  "$CLAUDE_CONFIG_DIR/tasks/session-${session_id:0:8}/task.json" \
  "$CLAUDE_CONFIG_DIR/teams/session-${session_id:0:8}/config.json"
other_cwd="$TMP_ROOT/other-cwd"
mkdir -p "$other_cwd"
reset_fake_claude_ready
(cd "$other_cwd" && "$SCRIPT" resume --detach "$session_id")
wait_for_fake_claude_ready
grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$session_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
"$STATE_HELPER" meta matches "$meta" claude "$session_id"
"$SCRIPT" claude logs "$human_label" | grep -F "fake Claude started in $ROOT" >/dev/null
"$SCRIPT" claude stop "$human_label"

# A stale checkpoint for session A must not block session B when the same
# harness name is reused for an explicit resume.
second_id="11111111-2222-4333-8444-555555555555"
printf '{"type":"user","sessionId":"%s","cwd":"%s","message":{"role":"user","content":"session B"}}\n' \
  "$second_id" "$ROOT" >"$CLAUDE_CONFIG_DIR/projects/fake/$second_id.jsonl"
export FAKE_CLAUDE_EXPECT_RESTORED=0
reset_fake_claude_ready
"$SCRIPT" claude resume --name "$human_label" --detach "$second_id"
wait_for_fake_claude_ready
grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$second_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
"$SCRIPT" claude stop "$human_label"

printf '{truncated task\n' >"$CLAUDE_CONFIG_DIR/tasks/$second_id/task.json"
export FAKE_CLAUDE_EXPECT_RESTORED=1
reset_fake_claude_ready
"$SCRIPT" claude recover --detach "$human_label"
wait_for_fake_claude_ready
"$SCRIPT" claude stop "$human_label"
export FAKE_CLAUDE_EXPECT_RESTORED=0
if [ "$CLAUDE_TEST_PART" = all ]; then
  default_history_fixture="$TMP_ROOT/default-claude-history-fixture"
  cp -Rp "$DETACH_CLAUDE_STATE_ROOT/sessions/$session" "$default_history_fixture"
fi

mkdir -p "$CLAUDE_CONFIG_DIR/projects/copy"
cp -p "$CLAUDE_CONFIG_DIR/projects/fake/$second_id.jsonl" \
  "$CLAUDE_CONFIG_DIR/projects/copy/$second_id.jsonl"
if "$SCRIPT" claude resume --name duplicate --detach "$second_id"; then
  printf 'Claude resume accepted an ambiguous duplicate transcript\n' >&2
  exit 1
fi

outside="$TMP_ROOT/must-not-overwrite.jsonl"
printf 'outside sentinel\n' >"$outside"
"$STATE_HELPER" meta patch "$meta" --string transcript_path "$outside"
if "$SCRIPT" claude recover --detach "$human_label"; then
  printf 'Claude recover accepted an unsafe transcript path\n' >&2
  exit 1
fi
grep -Fx 'outside sentinel' "$outside" >/dev/null

"$SCRIPT" claude delete --force "$human_label"
[ ! -d "$DETACH_CLAUDE_STATE_ROOT/sessions/$session" ]
! tmux -L "$SOCKET" has-session -t "=$session" 2>/dev/null
fi
fi

if claude_part_selected history; then
if [ "$CLAUDE_TEST_PART" = history ]; then
  bootstrap_claude_checkpoint
  default_history_fixture="$TMP_ROOT/default-claude-history-fixture"
  cp -Rp "$DETACH_CLAUDE_STATE_ROOT/sessions/$session" "$default_history_fixture"
  "$SCRIPT" claude delete --force "$human_label"
fi

# A wrapper-owned Claude UUID with no transcript (welcome screen, then stop)
# must resume with --session-id instead of failing as "not found".
empty_label='Empty resume'
export FAKE_CLAUDE_SLEEP=20
export FAKE_CLAUDE_EXIT=0
export FAKE_CLAUDE_EXPECT_RESTORED=0
reset_fake_claude_ready
empty_output="$("$SCRIPT" claude --name "$empty_label" --detach -- 'empty resume')"
wait_for_fake_claude_ready
empty_session="$(printf '%s\n' "$empty_output" | awk '/^Started / { print $2; exit }')"
empty_meta="$DETACH_CLAUDE_STATE_ROOT/sessions/$empty_session/meta.json"
empty_id="$("$STATE_HELPER" meta get "$empty_meta" agent_session_id)"
[[ "$empty_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
"$SCRIPT" claude stop "$empty_label"
! tmux -L "$SOCKET" has-session -t "=$empty_session" 2>/dev/null
rm -rf \
  "$CLAUDE_CONFIG_DIR/projects/fake/$empty_id.jsonl" \
  "$CLAUDE_CONFIG_DIR/projects/fake/$empty_id"
rm -f \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$empty_session/checkpoint/claude-session.tar" \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$empty_session/checkpoint/transcript.jsonl"
"$STATE_HELPER" meta patch "$empty_meta" --null transcript_path --null last_checkpoint_at
reset_fake_claude_ready
"$SCRIPT" resume --detach "$empty_id"
wait_for_fake_claude_ready
grep -Fx -- '--session-id' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
! grep -Fx -- '--resume' "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
grep -Fx -- "$empty_id" "$FAKE_CLAUDE_ARGS_FILE" >/dev/null
"$STATE_HELPER" meta matches "$empty_meta" claude "$empty_id"
"$SCRIPT" claude stop "$empty_label"

# A present invalid transcript must fail closed and must not start Claude.
printf '{truncated claude transcript\n' \
  >"$CLAUDE_CONFIG_DIR/projects/fake/$empty_id.jsonl"
"$STATE_HELPER" meta patch "$empty_meta" \
  --string transcript_path "$CLAUDE_CONFIG_DIR/projects/fake/$empty_id.jsonl"
rm -f \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$empty_session/checkpoint/claude-session.tar" \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$empty_session/checkpoint/transcript.jsonl"
reset_fake_claude_ready
: >"$FAKE_CLAUDE_ARGS_FILE"
if "$SCRIPT" resume --detach "$empty_id"; then
  printf 'Resume started Claude from a present invalid transcript\n' >&2
  exit 1
fi
[ ! -s "$FAKE_CLAUDE_ARGS_FILE" ]
! tmux -L "$SOCKET" has-session -t "=$empty_session" 2>/dev/null
"$SCRIPT" claude delete --force "$empty_label"
[ ! -d "$DETACH_CLAUDE_STATE_ROOT/sessions/$empty_session" ]

# Claude uses the same default history-series contract as Codex: a completed
# run remains intact while the next fresh conversation receives a new slot.
default_slug="$(basename "$ROOT" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '-' | \
  sed 's/^-*//; s/-*$//')"
[ -n "$default_slug" ] || default_slug=project
default_slug="${default_slug:0:24}"
default_digest="$(printf '%s' "$ROOT" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
default_session="detach-claude-$default_slug-$default_digest"
default_meta="$DETACH_CLAUDE_STATE_ROOT/sessions/$default_session/meta.json"
cp -Rp "$default_history_fixture" \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$default_session"
for historical_meta in "$default_meta" \
    "$DETACH_CLAUDE_STATE_ROOT/sessions/$default_session/checkpoint/meta.json"; do
  [ -f "$historical_meta" ] || continue
  "$STATE_HELPER" meta patch "$historical_meta" \
    --string session_name "$default_session" \
    --string project_dir "$ROOT" \
    --string default_session_base "$default_session" \
    --null display_name \
    --string status completed
done
[ -s "$DETACH_CLAUDE_STATE_ROOT/sessions/$default_session/checkpoint/claude-session.tar" ]
first_default_token="$("$STATE_HELPER" meta get "$default_meta" run_token)"
first_default_checkpoint_hash="$(shasum -a 256 \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$default_session/checkpoint/claude-session.tar" | awk '{print $1}')"

# The successor exits only after an observable event. Its retained pane then
# supplies delete coverage without a separate start/stop lifecycle.
export FAKE_CLAUDE_EXIT_GATE="$TMP_ROOT/allow-default-claude-exit"
export FAKE_CLAUDE_SLEEP=detach-test-live
export FAKE_CLAUDE_EXIT=0
reset_fake_claude_ready
second_default_output="$("$SCRIPT" claude --detach -- 'second default history')"
wait_for_fake_claude_ready
: >"$FAKE_CLAUDE_EXIT_GATE"
second_default_session="$(printf '%s\n' "$second_default_output" | \
  awk '/^Started / { print $2; exit }')"
[ "$second_default_session" = "$default_session-r000000000001" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$second_default_session:" \
  @detach_default_session_base)" = "$default_session" ]
[ "$("$STATE_HELPER" meta get "$default_meta" run_token)" = "$first_default_token" ]
[ "$(shasum -a 256 \
  "$DETACH_CLAUDE_STATE_ROOT/sessions/$default_session/checkpoint/claude-session.tar" | awk '{print $1}')" = \
  "$first_default_checkpoint_hash" ]
second_default_pane="$(tmux -L "$SOCKET" show-options -qv \
  -t "=$second_default_session:" @detach_pane_id)"
attempts=0
while [ "$(tmux -L "$SOCKET" display-message -p \
    -t "$second_default_pane" '#{pane_dead}')" != "1" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || {
    printf 'fake Claude pane did not exit within 5 seconds\n' >&2
    exit 1
  }
  sleep 0.05
done
"$SCRIPT" claude delete --force "$default_session"
"$SCRIPT" claude delete --force "$second_default_session"
[ ! -e "$FAKE_GIT_MARKER" ]

claude_scenario_event pass SC-SESSION-DELETE-CLAUDE
fi
printf 'Claude detach integration tests passed (%s)\n' "$CLAUDE_TEST_PART"
