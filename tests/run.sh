#!/bin/bash

set -eu
set -o pipefail
set -E

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
PROJECT_LABEL="${ROOT##*/}"
SCRIPT="$ROOT/bin/detach"
DETACH="$ROOT/bin/detach"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-codex-test.XXXXXX")"
TEST_INSTALL_STATE_ROOT="/tmp/detach-codex-install-state-$$"
TMUX_SOCKET_ROOT="$TEST_INSTALL_STATE_ROOT/tmux"
SOCKET="detach-codex-test-$$"
CWD_SOCKET="detach-codex-cwd-test-$$"
OUTER_SOCKET="detach-codex-outer-test-$$"
SOCKET_PATH="$TMUX_SOCKET_ROOT/$SOCKET.sock"
CWD_SOCKET_PATH="$TMUX_SOCKET_ROOT/$CWD_SOCKET.sock"
OUTER_SOCKET_PATH="$TMUX_SOCKET_ROOT/$OUTER_SOCKET.sock"
SESSION="detach-codex-integration"
ARTIFACT_DIR="${DETACH_PROVIDER_TEST_ARTIFACT_DIR:-}"
FAILURE_LINE=""
FAILURE_COMMAND=""
CODEX_TEST_PART="${DETACH_CODEX_TEST_PART:-all}"

case "$CODEX_TEST_PART" in
  all|guardrails|preflight|configuration|lifecycle-recovery|resume-identity|lifecycle|recovery|restart|resume|identity|delete|crash|history) ;;
  *)
    printf 'unknown Codex test part: %s\n' "$CODEX_TEST_PART" >&2
    exit 2
    ;;
esac

codex_part_selected() {
  [ "$CODEX_TEST_PART" = all ] || [ "$CODEX_TEST_PART" = "$1" ] || {
    [ "$CODEX_TEST_PART" = preflight ] && {
      [ "$1" = history ] || [ "$1" = configuration ]
    } ||
    [ "$CODEX_TEST_PART" = recovery ] && [ "$1" = restart ] ||
    [ "$CODEX_TEST_PART" = guardrails ] && {
      case "$1" in preflight|crash|history) return 0 ;; esac
      return 1
    } ||
    [ "$CODEX_TEST_PART" = lifecycle-recovery ] && {
      case "$1" in configuration|lifecycle|recovery|restart) return 0 ;; esac
      return 1
    } ||
    [ "$CODEX_TEST_PART" = resume-identity ] && {
      case "$1" in resume|identity|delete) return 0 ;; esac
      return 1
    }
  }
}

codex_scenario_event() {
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
integer_boundary_file="$TMP_ROOT/integer-boundary.json"
printf '%s\n' \
  '{"maximum":9223372036854775807,"above":9223372036854775808}' \
  >"$integer_boundary_file"
[ "$("$STATE_HELPER" meta get "$integer_boundary_file" maximum)" = 9223372036854775807 ]
boundary_output="$("$STATE_HELPER" meta get "$integer_boundary_file" above)" || {
  printf 'detach-state trapped or failed on Int.max + 1\n' >&2
  exit 1
}
[ -n "$boundary_output" ] || {
  printf 'detach-state discarded the out-of-range JSON number\n' >&2
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

run_codex() {
  "$SCRIPT" codex "$@"
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
  case "$ARTIFACT_DIR" in /*) ;; *) printf 'Codex artifact directory must be absolute\n' >&2; return 0 ;; esac
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
  [ -z "$FAILURE_LINE" ] || printf 'Codex test failed at line %s\n' "$FAILURE_LINE" >&2
  printf 'Codex diagnostics preserved at %s\n' "$ARTIFACT_DIR" >&2
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
  if [ "${DETACH_CODEX_TEST_KEEP:-0}" = "1" ]; then
    printf 'Preserved test state: %s (socket=%s, tmux_tmpdir=%s)\n' "$TMP_ROOT" "$SOCKET_PATH" "${TMUX_TMPDIR:-unset}" >&2
  else
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    tmux -L "$CWD_SOCKET" kill-server >/dev/null 2>&1 || true
    tmux -L "$OUTER_SOCKET" kill-server >/dev/null 2>&1 || true
    [ -z "${TMUX_TMPDIR:-}" ] || rm -rf "$TMUX_TMPDIR"
    rm -rf "$TEST_INSTALL_STATE_ROOT"
    rm -rf "$TMP_ROOT"
  fi
}
trap 'record_failure "$LINENO" "$BASH_COMMAND"' ERR
trap 'cleanup $?' EXIT

process_group_exists() {
  ps -axo pgid= | awk -v pgid="$1" '$1 == pgid { found = 1 } END { exit(found ? 0 : 1) }'
}

signal_process_group_members() {
  local signal="$1"
  local pgid="$2"
  local excluded_pid="${3:-}"
  local pid
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    /bin/kill "-$signal" "$pid" 2>/dev/null || true
  done < <(ps -axo pid=,pgid= | \
    awk -v pgid="$pgid" -v excluded="$excluded_pid" \
      '$2 == pgid && $1 != excluded { print $1 }')
}

wait_for_process_group_stopped() {
  local pgid="$1"
  local excluded_pid="$2"
  local attempts=0
  while [ "$attempts" -lt 50 ]; do
    signal_process_group_members STOP "$pgid" "$excluded_pid"
    if ps -axo pid=,pgid=,stat= | \
      awk -v pgid="$pgid" -v excluded="$excluded_pid" '
      $2 == pgid && $1 != excluded {
        found = 1
        if ($3 !~ /^[TZ]/) active = 1
      }
      END { exit(found && !active ? 0 : 1) }
    '; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.05
  done
  printf 'timed out waiting for process group %s to stop\n' "$pgid" >&2
  ps -axo pid=,ppid=,pgid=,stat=,command= | \
    awk -v pgid="$pgid" '$3 == pgid { print }' >&2
  return 1
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

wait_for_process_group_id() {
  local pid="$1" pgid="" attempts=0
  while [ "$attempts" -lt 50 ]; do
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$pgid" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$pgid"; return 0 ;;
    esac
    attempts=$((attempts + 1))
    sleep 0.05
  done
  printf 'timed out waiting for process group of PID %s\n' "$pid" >&2
  return 1
}

wait_for_pane_text() {
  local socket="$1"
  local pane="$2"
  local expected="$3"
  local attempts=0
  while [ "$attempts" -lt 80 ]; do
    if tmux -L "$socket" capture-pane -p -t "$pane" -S -100 2>/dev/null | \
       grep -F "$expected" >/dev/null; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'pane %s did not contain expected text: %s\n' "$pane" "$expected" >&2
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

wait_for_pane_dead() {
  local pane="$1" attempts=0 actual=""
  while [ "$attempts" -lt 80 ]; do
    actual="$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{pane_dead}' 2>/dev/null || true)"
    [ "$actual" != "1" ] || return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'timed out waiting for pane %s to become dead (actual=%s)\n' \
    "$pane" "$actual" >&2
  return 1
}

wait_for_file_text() {
  local file="$1" text="$2" attempts=0
  while [ "$attempts" -lt 80 ]; do
    if [ -f "$file" ] && grep -F -- "$text" "$file" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  printf 'timed out waiting for %s in %s\n' "$text" "$file" >&2
  return 1
}

require_file_line() {
  local file="$1" expected="$2"
  grep -Fx -- "$expected" "$file" >/dev/null || {
    printf 'missing exact line %s in %s; contents:\n' "$expected" "$file" >&2
    sed -n '1,80p' "$file" >&2
    return 1
  }
}

export DETACH_STATE_ROOT="$TMP_ROOT/detach-state"
export DETACH_STATE_BIN="$STATE_HELPER"
FAKE_POWER_BIN="$TMP_ROOT/fake-detach-power"
FAKE_ENV_BIN="$TMP_ROOT/fake-env"
export FAKE_ENV_ARGS_FILE="$TMP_ROOT/env-args.txt"
export FAKE_POWER_ARGS_FILE="$TMP_ROOT/power-args.txt"
export FAKE_POWER_STATUS_FILE="$TMP_ROOT/power-status.txt"
export FAKE_POWER_RELEASES_FILE="$TMP_ROOT/power-releases.txt"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then' \
  '  printf '\''%s\n'\'' "$*" >>"$FAKE_POWER_STATUS_FILE"' \
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
printf '%s\n' \
  '#!/bin/bash' \
  'printf '\''%s\n'\'' "$@" >"$FAKE_ENV_ARGS_FILE"' \
  'exit 0' >"$FAKE_ENV_BIN"
chmod 0755 "$FAKE_ENV_BIN"
FAKE_CODEX_LONG_BIN="$TMP_ROOT/fake-codex-long"
printf '%s\n' \
  '#!/bin/bash' \
  "trap '' HUP" \
  'export FAKE_CODEX_INIT_DELAY=0' \
  'export FAKE_CODEX_SLEEP=20' \
  'export FAKE_CODEX_EXIT=0' \
  "exec \"$ROOT/tests/fake-codex\" \"\$@\"" >"$FAKE_CODEX_LONG_BIN"
chmod 0755 "$FAKE_CODEX_LONG_BIN"
FAKE_GIT_BIN_DIR="$TMP_ROOT/fake-bin"
export FAKE_GIT_MARKER="$TMP_ROOT/ambient-git-was-invoked"
mkdir -p "$FAKE_GIT_BIN_DIR"
printf '%s\n' \
  '#!/bin/bash' \
  ': >"$FAKE_GIT_MARKER"' \
  'exit 99' >"$FAKE_GIT_BIN_DIR/git"
chmod 0755 "$FAKE_GIT_BIN_DIR/git"
export PATH="$FAKE_GIT_BIN_DIR:$PATH"
export DETACH_POWER_BIN="$FAKE_POWER_BIN"
export DETACH_TMUX_BIN="$TMUX_TEST_BIN"
export DETACH_CODEX_STATE_ROOT="$TMP_ROOT/state"
export DETACH_LOCKS_ROOT="$TMP_ROOT/locks"
export DETACH_INSTALL_STATE_ROOT="$TEST_INSTALL_STATE_ROOT"
export DETACH_CONFIG_ROOT="$TMP_ROOT/config"
export DETACH_TMUX_SOCKET_PATH="$SOCKET_PATH"
export DETACH_TMUX_CONFIG="$TMP_ROOT/tmux.conf"
export DETACH_CODEX_BIN="$ROOT/tests/fake-codex"
export DETACH_CODEX_CHECKPOINT_INTERVAL=1
export DETACH_HEALTH_HEARTBEAT_INTERVAL=1
export DETACH_IDLE_HEALTH_HEARTBEAT_INTERVAL=2
export DETACH_HEALTH_HEARTBEAT_STALE=4
export DETACH_CODEX_SYNC=0
export DETACH_CODEX_REQUIREMENTS_FILE="$TMP_ROOT/requirements.toml"
export CODEX_HOME="$TMP_ROOT/codex-home"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-home"
export DETACH_CLAUDE_STATE_ROOT="$TMP_ROOT/claude-state"
export FAKE_CODEX_ARGS_FILE="$TMP_ROOT/args.txt"
export FAKE_CODEX_SLEEP=4
export FAKE_CODEX_EXIT=7
export FAKE_CODEX_FOREIGN_FIRST=1
export FAKE_CODEX_INIT_DELAY=0.1
export TMUX_TMPDIR="/tmp/detach-codex-tmux-$$"
# The test owns a private tmux server. An outer Detach/tmux context must not
# influence the absolute Detach socket or make attach semantics switch clients.
unset TMUX TMUX_PANE DETACH_CORE_ENTRYPOINT DETACH_PROVIDER DETACH_PROGRAM
unset DETACH_TMUX_SOCKET
mkdir -p "$TMUX_TMPDIR" "$TMUX_SOCKET_ROOT" "$CODEX_HOME"
printf '%s\n' \
  'set -g base-index 1' \
  'set -g pane-base-index 1' \
  'bind-key -T copy-mode a send-keys -X cursor-left' \
  >"$DETACH_TMUX_CONFIG"
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request"]' >"$DETACH_CODEX_REQUIREMENTS_FILE"

test_sqlite() {
  sqlite3 -cmd '.timeout 5000' "$@"
}

if codex_part_selected preflight; then
  bash -n "$SCRIPT"
  bash -n "$ROOT/bin/detach-core"
  [ "$($SCRIPT __version)" = "$(<"$ROOT/VERSION")" ]

  : >"$FAKE_POWER_STATUS_FILE"
  "$DETACH" list --json >/dev/null
  [ "$(wc -l <"$FAKE_POWER_STATUS_FILE" | tr -d '[:space:]')" = 1 ]
  grep -Fx 'status --json --quick' "$FAKE_POWER_STATUS_FILE" >/dev/null

  # The public JSON list overlaps independent provider reads but must publish
  # complete records in Codex-then-Claude order and remove its private files.
  public_list_tmp="$TMP_ROOT/public-list-tmp"
  public_codex_root="$TMP_ROOT/public-list-codex"
  public_claude_root="$TMP_ROOT/public-list-claude"
  public_list_state_wrapper="$TMP_ROOT/public-list-state"
  public_list_started="$TMP_ROOT/public-list-started"
  mkdir -p \
    "$public_list_tmp" \
    "$public_codex_root/sessions/detach-codex-public-order" \
    "$public_claude_root/sessions/detach-claude-public-order"
  "$STATE_HELPER" meta create \
    "$public_codex_root/sessions/detach-codex-public-order/meta.json" \
    --integer schema 1 \
    --string session_name detach-codex-public-order \
    --string project_dir "$ROOT" \
    --string status stopped
  "$STATE_HELPER" meta create \
    "$public_claude_root/sessions/detach-claude-public-order/meta.json" \
    --integer schema 1 \
    --string session_name detach-claude-public-order \
    --string project_dir "$ROOT" \
    --string status stopped
  printf '%s\n' \
    '#!/bin/bash' \
    'set -u' \
    'if [ "${1:-} ${2:-}" = "meta snapshots" ]; then' \
    '  printf "started\n" >>"$DETACH_PARALLEL_LIST_STARTED"' \
    '  attempts=0' \
    '  while [ "$attempts" -lt 200 ]; do' \
    '    [ "$(wc -l <"$DETACH_PARALLEL_LIST_STARTED" | tr -d "[:space:]")" -ge 2 ] && break' \
    '    sleep 0.01' \
    '    attempts=$((attempts + 1))' \
    '  done' \
    '  [ "$attempts" -lt 200 ] || exit 91' \
    'fi' \
    'exec "$DETACH_PARALLEL_LIST_STATE_HELPER" "$@"' \
    >"$public_list_state_wrapper"
  chmod 0755 "$public_list_state_wrapper"
  public_list_output="$(
    TMPDIR="$public_list_tmp" \
    DETACH_CODEX_STATE_ROOT="$public_codex_root" \
    DETACH_CLAUDE_STATE_ROOT="$public_claude_root" \
    DETACH_STATE_BIN="$public_list_state_wrapper" \
    DETACH_PARALLEL_LIST_STARTED="$public_list_started" \
    DETACH_PARALLEL_LIST_STATE_HELPER="$STATE_HELPER" \
    DETACH_POWER_BIN=/usr/bin/false \
      "$DETACH" list --json
  )"
  [ "$(wc -l <"$public_list_started" | tr -d '[:space:]')" = 2 ]
  [ "$(printf '%s\n' "$public_list_output" | sed -n '1p' | \
    "$STATE_HELPER" meta get /dev/stdin provider)" = codex ]
  [ "$(printf '%s\n' "$public_list_output" | sed -n '2p' | \
    "$STATE_HELPER" meta get /dev/stdin provider)" = claude ]
  [ "$(printf '%s\n' "$public_list_output" | sed -n '1p' | \
    "$STATE_HELPER" meta get /dev/stdin effective_status)" = stopped ]
  [ "$(printf '%s\n' "$public_list_output" | sed -n '1p' | \
    "$STATE_HELPER" meta get /dev/stdin health_reason)" = finished ]
  [ -z "$(find "$public_list_tmp" -mindepth 1 -print -quit)" ]

  # A caller can terminate the public frontend by PID (for example during app
  # cancellation). Its cleanup must terminate the two exact provider jobs, not
  # only the background shell functions that launched them.
  cancel_list_payload="$TMP_ROOT/cancel-list-payload"
  cancel_list_pids="$TMP_ROOT/cancel-list-pids"
  mkdir -p "$cancel_list_payload"
  : >"$cancel_list_pids"
  install -m 0755 "$ROOT/bin/detach" "$cancel_list_payload/detach"
  printf '%s\n' \
    '#!/bin/bash' \
    '[ "${DETACH_CORE_ENTRYPOINT:-}" = 1 ] || exit 2' \
    'printf '\''%s\n'\'' "$$" >>"$DETACH_CANCEL_LIST_PIDS"' \
    'trap '\''exit 0'\'' HUP INT TERM' \
    'while :; do sleep 0.05; done' \
    >"$cancel_list_payload/detach-core"
  chmod 0755 "$cancel_list_payload/detach-core"
  DETACH_CANCEL_LIST_PIDS="$cancel_list_pids" \
  DETACH_POWER_BIN=/usr/bin/false \
    "$cancel_list_payload/detach" list --json >/dev/null 2>&1 &
  cancel_list_frontend_pid=$!
  attempts=0
  while [ "$(wc -l <"$cancel_list_pids" 2>/dev/null || printf 0)" -lt 2 ] && \
        [ "$attempts" -lt 100 ]; do
    attempts=$((attempts + 1))
    sleep 0.01
  done
  [ "$attempts" -lt 100 ]
  kill -TERM "$cancel_list_frontend_pid"
  wait "$cancel_list_frontend_pid" 2>/dev/null || true
  cancel_list_survivors=""
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    cancel_list_survivors=""
    while IFS= read -r cancel_list_pid; do
      kill -0 "$cancel_list_pid" 2>/dev/null && \
        cancel_list_survivors="$cancel_list_survivors $cancel_list_pid"
    done <"$cancel_list_pids"
    [ -n "$cancel_list_survivors" ] || break
    attempts=$((attempts + 1))
    sleep 0.01
  done
  if [ -n "$cancel_list_survivors" ]; then
    for cancel_list_pid in $cancel_list_survivors; do
      kill -KILL "$cancel_list_pid" 2>/dev/null || true
    done
    printf 'public list cancellation left provider jobs alive:%s\n' \
      "$cancel_list_survivors" >&2
    exit 1
  fi

  # The app's long-lived source must be the public CLI, backed by one native
  # process. Prove lifecycle and transcript writes produce leading/trailing
  # typed hints on a normal user-data volume (FSEvents excludes some temporary
  # filesystem implementations).
  (
    event_root="$ROOT/app/build/session-events-$$"
    event_output="$event_root/events.jsonl"
    event_pid=""
    cleanup_event_probe() {
      [ -z "$event_pid" ] || kill "$event_pid" 2>/dev/null || true
      [ -z "$event_pid" ] || wait "$event_pid" 2>/dev/null || true
      rm -rf "$event_root"
    }
    trap cleanup_event_probe EXIT
    event_session="detach-codex-event"
    event_managed_transcript="$event_root/codex/sessions/managed.jsonl"
    mkdir -p \
      "$event_root/state/codex/sessions/$event_session" \
      "$event_root/codex/sessions"
    touch "$event_managed_transcript"
    "$STATE_HELPER" meta create \
      "$event_root/state/codex/sessions/$event_session/meta.json" \
      --integer schema 1 \
      --string session_name "$event_session" \
      --string project_dir "$event_root/project" \
      --string transcript_path "$event_managed_transcript"
    # The watcher reads managed metadata from the explicit provider state
    # roots, so a relocated provider root must be named like the runtime does.
    DETACH_STATE_ROOT="$event_root/state" \
    DETACH_CODEX_STATE_ROOT="$event_root/state/codex" \
    DETACH_CLAUDE_STATE_ROOT="$event_root/state/claude" \
    CODEX_HOME="$event_root/codex" \
    CLAUDE_CONFIG_DIR="$event_root/claude" \
      "$SCRIPT" watch --json >"$event_output" &
    event_pid=$!
    wait_for_file_text "$event_output" '"event":"ready"'
    "$STATE_HELPER" events publish "$event_root/state"
    wait_for_file_text "$event_output" '"event":"changed"'
    touch "$event_root/codex/sessions/unmanaged.jsonl"
    sleep 0.3
    [ "$(grep -c '"event":"changed"' "$event_output")" -eq 1 ]
    touch "$event_managed_transcript"
    event_attempts=0
    while [ "$event_attempts" -lt 80 ] && \
          [ "$(grep -c '"event":"changed"' "$event_output" 2>/dev/null || true)" -lt 3 ]; do
      event_attempts=$((event_attempts + 1))
      sleep 0.05
    done
    [ "$(grep -c '"event":"changed"' "$event_output")" -ge 3 ]

    claude_event_session="detach-claude-event"
    claude_event_transcript="$event_root/claude/projects/managed.jsonl"
    mkdir -p \
      "$event_root/state/claude/sessions/$claude_event_session" \
      "$event_root/claude/projects"
    touch "$claude_event_transcript"
    "$STATE_HELPER" meta create \
      "$event_root/state/claude/sessions/$claude_event_session/meta.json" \
      --integer schema 1 \
      --string session_name "$claude_event_session" \
      --string project_dir "$event_root/project" \
      --string transcript_path "$claude_event_transcript"
    "$STATE_HELPER" events publish "$event_root/state"
    event_attempts=0
    while [ "$event_attempts" -lt 80 ] && \
          [ "$(grep -c '"event":"changed"' "$event_output" 2>/dev/null || true)" -lt 4 ]; do
      event_attempts=$((event_attempts + 1))
      sleep 0.05
    done
    sleep 0.1
    touch "$claude_event_transcript"
    event_attempts=0
    while [ "$event_attempts" -lt 80 ] && \
          [ "$(grep -c '"event":"changed"' "$event_output" 2>/dev/null || true)" -lt 6 ]; do
      event_attempts=$((event_attempts + 1))
      sleep 0.05
    done
    [ "$(grep -c '"event":"changed"' "$event_output")" -ge 6 ]
  )

  heartbeat_source="$(sed -n \
    '/^runtime_heartbeat_locked() {/,/^runtime_heartbeat_once() {/p' \
    "$ROOT/bin/detach-core")"
  printf '%s\n' "$heartbeat_source" | \
    grep -F 'state_update_meta_for_run_without_event' >/dev/null
  state_mutation_source="$(sed -n \
    '/^state_update_meta() {/,/^state_update_meta_without_event() {/p' \
    "$ROOT/bin/detach-core")"
  printf '%s\n' "$state_mutation_source" | \
    grep -F 'publish_session_event' >/dev/null
  start_source="$(sed -n \
    '/^start_tmux_session() {/,/^running_session_for_project() {/p' \
    "$ROOT/bin/detach-core")"
  printf '%s\n' "$start_source" | sed -n '1,/respawn-pane -k/p' | \
    grep -F 'publish_session_event' >/dev/null
  printf '%s\n' "$start_source" | sed -n '1,/respawn-pane -k/p' | \
    grep -F 'install_session_event_hook' >/dev/null
  # The pane-died hook string crosses tmux quoting and `sh -c`. Paths with
  # spaces are common; characters either layer could reinterpret are refused.
  hook_command="$(
    DETACH_CORE_ENTRYPOINT=1 \
    DETACH_PROVIDER=codex \
    DETACH_STATE_BIN='/Volumes/User Data/libexec/detach-state' \
    DETACH_STATE_ROOT='/Volumes/User Data/state' \
      "$ROOT/bin/detach-core" __session_event_hook_command
  )"
  [ "$hook_command" = "run-shell -b \"'/Volumes/User Data/libexec/detach-state' events publish '/Volumes/User Data/state' >/dev/null 2>&1 || true\"" ]
  if DETACH_CORE_ENTRYPOINT=1 \
     DETACH_PROVIDER=codex \
     DETACH_STATE_BIN='/tmp/$HOME/detach-state' \
     DETACH_STATE_ROOT='/tmp/state' \
       "$ROOT/bin/detach-core" __session_event_hook_command >/dev/null; then
    printf 'hook command accepted an unsafe path\n' >&2
    exit 1
  fi
  # The cleanup checkpoint must not wake the app while the provider is gone
  # and the worker is still alive; the status write that follows publishes.
  worker_cleanup_source="$(sed -n \
    '/^  worker_cleanup() {/,/^  trap worker_cleanup EXIT/p' \
    "$ROOT/bin/detach-core")"
  printf '%s\n' "$worker_cleanup_source" | \
    grep -F 'DETACH_SUPPRESS_SESSION_EVENT=1 checkpoint_once' >/dev/null
  delete_source="$(sed -n \
    '/^delete_locked() {/,/^restore_rollout_if_needed() {/p' \
    "$ROOT/bin/detach-core")"
  printf '%s\n' "$delete_source" | \
    grep -F 'publish_session_event' >/dev/null

if FAKE_POWER_STATE=unavailable run_codex --name power-preflight --detach -- \
  'must not start without power protection' >/dev/null 2>&1; then
  printf 'start unexpectedly passed an unavailable power preflight\n' >&2
  exit 1
fi
! tmux -L "$SOCKET" has-session -t '=detach-codex-power-preflight' 2>/dev/null

readiness_output=""
if readiness_output="$(OPENAI_API_KEY=detach-test-openai-key \
  ANTHROPIC_API_KEY=detach-test-anthropic-key \
  FAKE_POWER_FAIL_RUN=1 \
  run_codex --name worker-readiness --detach -- \
    'must not claim a start before the lease is ready' 2>&1)"; then
  printf 'start unexpectedly passed a failed worker readiness handshake\n' >&2
  exit 1
fi
if printf '%s\n' "$readiness_output" | grep -F 'Started ' >/dev/null; then
  printf 'failed worker readiness handshake printed a false Started message\n' >&2
  exit 1
fi
! tmux -L "$SOCKET" has-session -t '=detach-codex-worker-readiness' 2>/dev/null
[ ! -e "$DETACH_CODEX_STATE_ROOT/sessions/detach-codex-worker-readiness/tmux-environment.bin" ] || {
  printf 'failed start retained a credential-bearing tmux environment scratch file\n' >&2
  exit 1
}
if grep -F 'tmux_environment_args >' "$ROOT/bin/detach-core" >/dev/null; then
  printf 'runtime still writes tmux environment arguments to disk\n' >&2
  exit 1
fi
if FAKE_POWER_STATE=low_battery run_codex --name power-preflight --detach -- \
  'must not start at low battery' >/dev/null 2>&1; then
  printf 'start unexpectedly passed the low-battery power preflight\n' >&2
  exit 1
fi
! tmux -L "$SOCKET" has-session -t '=detach-codex-power-preflight' 2>/dev/null
if FAKE_POWER_STATE=temperature run_codex --name power-preflight --detach -- \
  'must not start during thermal safety' >/dev/null 2>&1; then
  printf 'start unexpectedly passed the temperature power preflight\n' >&2
  exit 1
fi
! tmux -L "$SOCKET" has-session -t '=detach-codex-power-preflight' 2>/dev/null

# A tmux server keeps the cwd from which it was first daemonized. Simulate an
# unmounted project behind an already-running server, then prove Detach repairs
# the worker cwd before the provider starts.
poisoned_cwd="$TMP_ROOT/poisoned-cwd"
healthy_cwd="$TMP_ROOT/healthy-cwd"
mkdir -p "$poisoned_cwd" "$healthy_cwd"
(cd "$poisoned_cwd" && \
  tmux -L "$CWD_SOCKET" -f "$DETACH_TMUX_CONFIG" new-session -d -s poisoned-cwd 'sleep 30')
rmdir "$poisoned_cwd"
(cd "$healthy_cwd" && DETACH_TMUX_SOCKET_PATH="$CWD_SOCKET_PATH" \
  "$SCRIPT" codex --name cwd-repair --detach -- 'repair a stale tmux cwd')
cwd_session="detach-codex-cwd-repair"
tmux -L "$CWD_SOCKET" has-session -t "=$cwd_session"
cwd_pane="$(tmux -L "$CWD_SOCKET" show-options -qv -t "=$cwd_session:" @detach_pane_id)"
wait_for_pane_text "$CWD_SOCKET" "$cwd_pane" 'fake Codex started'
[ "$(tmux -L "$CWD_SOCKET" display-message -p -t "$cwd_pane" '#{pane_current_path}')" = \
  "$(cd -P "$healthy_cwd" && pwd)" ]
(cd "$healthy_cwd" && DETACH_TMUX_SOCKET_PATH="$CWD_SOCKET_PATH" \
  "$SCRIPT" codex stop cwd-repair)
tmux -L "$CWD_SOCKET" kill-server >/dev/null 2>&1 || true
(cd "$healthy_cwd" && DETACH_TMUX_SOCKET_PATH="$CWD_SOCKET_PATH" \
  "$SCRIPT" codex delete --force cwd-repair)

# When Detach creates the tmux server itself, its daemon cwd must remain valid
# after the first project disappears so unrelated panes can still honor -c.
removable_cwd="$TMP_ROOT/removable-cwd"
next_cwd="$TMP_ROOT/next-cwd"
mkdir -p "$removable_cwd" "$next_cwd"
(cd "$removable_cwd" && DETACH_TMUX_SOCKET_PATH="$CWD_SOCKET_PATH" \
  "$SCRIPT" codex --name cwd-anchor --detach -- 'anchor the tmux server')
anchor_session="detach-codex-cwd-anchor"
anchor_pane="$(tmux -L "$CWD_SOCKET" show-options -qv -t "=$anchor_session:" @detach_pane_id)"
wait_for_pane_text "$CWD_SOCKET" "$anchor_pane" 'fake Codex started'
rmdir "$removable_cwd"
probe_pane="$(tmux -L "$CWD_SOCKET" new-session -d -P -F '#{pane_id}' \
  -s cwd-probe -c "$next_cwd" 'sleep 30')"
[ "$(tmux -L "$CWD_SOCKET" display-message -p -t "$probe_pane" '#{pane_current_path}')" = \
  "$(cd -P "$next_cwd" && pwd)" ]
(cd "$next_cwd" && DETACH_TMUX_SOCKET_PATH="$CWD_SOCKET_PATH" \
  "$SCRIPT" codex stop cwd-anchor)
tmux -L "$CWD_SOCKET" kill-server >/dev/null 2>&1 || true
(cd "$next_cwd" && DETACH_TMUX_SOCKET_PATH="$CWD_SOCKET_PATH" \
  "$SCRIPT" codex delete --force cwd-anchor)

[ "$($SCRIPT config tmux-style)" = "detach" ]
[ "$(run_codex __session_color /fixtures/harness)" = "#1D4ED8" ]
fi

# A repository marker is enough to canonicalize a nested project. Detach must
# not execute ambient git (which can prompt for Xcode Command Line Tools on a
# clean Mac) either while resolving the project root or while checkpointing.
if codex_part_selected configuration; then
marker_repository="$TMP_ROOT/marker-repository"
marker_repository_nested="$marker_repository/sources/nested"
human_label='Rev (ai)'
human_digest="$(printf '%s' "$human_label" | shasum -a 256 | \
  awk '{print substr($1, 1, 12)}')"
mkdir -p "$marker_repository/.git" "$marker_repository_nested"
(cd "$marker_repository_nested" && \
  FAKE_CODEX_INIT_DELAY=0 FAKE_CODEX_SLEEP=20 FAKE_CODEX_EXIT=0 \
  "$SCRIPT" codex --name "$human_label" --detach -- 'marker repository coverage')
marker_session="detach-codex-Rev-ai-$human_digest"
marker_meta="$DETACH_CODEX_STATE_ROOT/sessions/$marker_session/meta.json"
marker_repository_real="$(cd -P "$marker_repository" && pwd)"
[ "$("$STATE_HELPER" meta get "$marker_meta" project_dir)" = "$marker_repository_real" ]
[ "$("$STATE_HELPER" meta get "$marker_meta" display_name)" = "$human_label" ]
marker_json="$(run_codex list --json | grep -F "\"session_name\":\"$marker_session\"")"
[ "$(printf '%s' "$marker_json" | "$STATE_HELPER" meta get /dev/stdin display_name)" = \
  "$human_label" ]
run_codex status "$human_label" | grep -F "Name:           $human_label" >/dev/null
marker_checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$marker_session/checkpoint/worktree-status.txt"
attempts=0
while [ ! -f "$marker_checkpoint" ] && [ "$attempts" -lt 30 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -f "$marker_checkpoint" ]
grep -Fx "repository-root: $marker_repository_real" "$marker_checkpoint" >/dev/null
[ ! -e "$FAKE_GIT_MARKER" ]
run_codex stop "$human_label"
run_codex delete --force "$human_label"

mkdir -p "$DETACH_CONFIG_ROOT"
printf '%s\n' '# Detach settings' 'CUSTOM_SETTING=kept' 'LEGACY_SETTING=kept' \
  >"$DETACH_CONFIG_ROOT/config"
printf '%s' 'TMUX_STYLE=0' >>"$DETACH_CONFIG_ROOT/config"
[ "$($SCRIPT config tmux-style)" = "inherit" ]
printf '%s\n' '' 'TMUX_STYLE=1' >>"$DETACH_CONFIG_ROOT/config"
"$SCRIPT" config tmux-style inherit
[ "$($SCRIPT config tmux-style)" = "inherit" ]
grep -Fx CUSTOM_SETTING=kept "$DETACH_CONFIG_ROOT/config" >/dev/null
grep -Fx LEGACY_SETTING=kept "$DETACH_CONFIG_ROOT/config" >/dev/null
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
fi

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

bootstrap_codex_checkpoint() {
  export FAKE_CODEX_SLEEP=20
  export FAKE_CODEX_EXIT=0
  export FAKE_CODEX_FOREIGN_FIRST=0
  export FAKE_CODEX_INIT_DELAY=0.1
  run_codex --name integration --detach -- 'recovery fixture'
  wait_for_tmux_option "$SESSION" @detach_status running
  meta="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/meta.json"
  checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint"
  session_color="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_color)"
  attempts=0
  while { [ ! -s "$checkpoint/rollout.jsonl" ] || \
          [ ! -s "$checkpoint/codex-state.sqlite" ]; } && \
        [ "$attempts" -lt 80 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
  done
  [ -s "$checkpoint/rollout.jsonl" ]
  [ -s "$checkpoint/.detach-jsonl-validation.json" ]
  [ -s "$checkpoint/codex-state.sqlite" ]
  ! find "$checkpoint" -maxdepth 1 \
    \( -name 'codex-state.sqlite.tmp.*-shm' -o \
       -name 'codex-state.sqlite.tmp.*-wal' \) -print -quit | grep -q .
  expected_id="$("$STATE_HELPER" meta get "$meta" codex_session_id)"
  [ -n "$expected_id" ]
  run_codex stop integration
  upgraded_version="0.2.0"
  upgraded_payload="$install_root/libexec/detach/versions/$upgraded_version-test"
  install -d "$upgraded_payload"
  install -m 0755 "$ROOT/bin/detach" "$ROOT/bin/detach-core" "$upgraded_payload/"
  printf '%s\n' "$upgraded_version" >"$upgraded_payload/VERSION"
  ln -s "$upgraded_payload/detach" "$install_root/bin/.detach-upgrade"
  mv -f "$install_root/bin/.detach-upgrade" "$install_root/bin/detach"
  failed_style="bg=$(expected_tint '#B91C1C' 55)"
}

if codex_part_selected lifecycle; then
  marker="$TMP_ROOT/must-not-exist"
  literal_prompt="spaces ; \$(touch $marker) * \"quotes\""
  export FAKE_CODEX_SLEEP=12
  integration_release="$TMP_ROOT/integration-provider-release"
  export FAKE_CODEX_RELEASE_FILE="$integration_release"
  codex_scenario_event begin SC-SESSION-CREATE-CODEX
  codex_scenario_event begin SC-SESSION-PERSIST-CODEX
  codex_scenario_event begin SC-SESSION-RECOVER-CODEX
  codex_scenario_event begin SC-SESSION-STOP-CODEX
  codex_scenario_event begin SC-SESSION-DELETE-CODEX
  LC_ALL=C run_codex --name integration --detach -- "$literal_prompt"

wait_for_tmux_option "$SESSION" @detach_status running
wait_for_tmux_option "$SESSION" set-titles on
LC_ALL=C.UTF-8 wait_for_tmux_option \
  "$SESSION" set-titles-string "Detach · $PROJECT_LABEL"
wait_for_tmux_option_text "$SESSION" status-left RUNNING
tmux -L "$SOCKET" has-session -t "=$SESSION"
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" >/dev/null
codex_scenario_event pass SC-SESSION-CREATE-CODEX
mkdir -p "$TMP_ROOT/unrelated-tmux-tmpdir"
TMUX_TMPDIR="$TMP_ROOT/unrelated-tmux-tmpdir" \
  "$DETACH" list | grep -F 'codex' | grep -F "$SESSION" >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_provider)" = "codex" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
meta="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/meta.json"
# Stop must persist intent for the exact run before its first signal. Inject a
# state write failure and prove the live pane and metadata remain unchanged.
stop_state_wrapper="$TMP_ROOT/stop-state-wrapper"
stop_state_failure="$TMP_ROOT/stop-state-failure"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ -f "$DETACH_STOP_STATE_FAILURE" ] && [ "${1:-}" = meta ] && [ "${2:-}" = patch ]; then' \
  '  case " $* " in *" stop_requested_at "*) exit 91 ;; esac' \
  'fi' \
  'exec "$DETACH_STOP_STATE_DELEGATE" "$@"' \
  >"$stop_state_wrapper"
chmod 0755 "$stop_state_wrapper"
: >"$stop_state_failure"
if DETACH_STATE_BIN="$stop_state_wrapper" \
   DETACH_STOP_STATE_FAILURE="$stop_state_failure" \
   DETACH_STOP_STATE_DELEGATE="$STATE_HELPER" \
   run_codex stop integration >/dev/null 2>&1; then
  printf 'Stop unexpectedly signaled a run without durable intent\n' >&2
  exit 1
fi
tmux -L "$SOCKET" has-session -t "=$SESSION"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "0" ]
[ -z "$("$STATE_HELPER" meta get "$meta" stop_requested_at)" ]
rm "$stop_state_failure"
# The creator CLI has already exited. The tmux server and worker must remain
# alive without an attached client (the same lifecycle as closing Terminal or
# Detach.app after starting a session).
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "0" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "running" ]
[ "$(tmux -L "$SOCKET" show-options -qv -w -t "$pane_id" remain-on-exit)" = off ]
[ "$(tmux -L "$SOCKET" show-options -qv -p -t "$pane_id" remain-on-exit)" = on ]
codex_scenario_event pass SC-SESSION-PERSIST-CODEX
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_tmux_style)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_style_snapshot)" = "1" ]
session_color="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_color)"
[[ "$session_color" =~ ^#[[:xdigit:]]{6}$ ]]
# Tinted style: the whole strip carries a dense blend of the session color,
# the solid edge stays pure, power on the right side of the status line.
tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style | \
  grep -F "bg=$(expected_tint "$session_color" 55)" >/dev/null
status_left="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-left)"
printf '%s' "$status_left" | grep -F "bg=$session_color" >/dev/null
printf '%s' "$status_left" | grep -F 'Detach' | grep -F 'Codex' | \
  grep -F "$PROJECT_LABEL" | grep -F 'RUNNING' >/dev/null
tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-right | \
  grep -F 'MAC AWAKE' >/dev/null
# Mouse input: wheel scrolling stays one line per step and selections land in
# the macOS clipboard through the Detach-owned server's copy-command.
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" mouse)" = "on" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_copy_type_through)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -sqv copy-command)" = "/usr/bin/pbcopy" ]
tmux -L "$SOCKET" list-keys -T copy-mode | grep -F 'WheelUpPane' | \
  grep -F 'scroll-up' >/dev/null
# Selections copy through the clipboard but keep the highlight and stay in
# copy-mode (no snap to the bottom); a plain click clears the leftover highlight.
tmux -L "$SOCKET" list-keys -T copy-mode-vi | grep -F 'MouseDragEnd1Pane' | \
  grep -F 'copy-pipe-no-clear' >/dev/null
tmux -L "$SOCKET" list-keys -T copy-mode | grep -F 'MouseDragEnd1Pane' | \
  grep -F 'copy-pipe-no-clear' >/dev/null
! tmux -L "$SOCKET" list-keys -T copy-mode | grep -F 'MouseDragEnd1Pane' | \
  grep -F 'copy-pipe-and-cancel' >/dev/null
tmux -L "$SOCKET" list-keys -T copy-mode | grep -F 'MouseDown1Pane' | \
  grep -F 'clear-selection' >/dev/null
tmux -L "$SOCKET" list-keys -T copy-mode-vi | grep -F 'MouseDown1Pane' | \
  grep -F 'clear-selection' >/dev/null
# Type-through: a printable key cancels copy-mode and is delivered literally to
# the pane. Representative keys, including the escaping-sensitive punctuation and
# cyrillic, must be bound in both copy-mode tables.
for type_through_table in copy-mode copy-mode-vi; do
  # tmux renders non-ASCII key names as `_` in the release workflow's C locale.
  # Ask only this textual key-table assertion for deterministic UTF-8 output.
  type_through_keys="$(LC_ALL=C.UTF-8 tmux -L "$SOCKET" list-keys -T "$type_through_table")"
  for type_through_key in \
    'a ' 'q ' '\; ' "\\' " '\" ' '\\ ' '\$ ' 'Space ' 'Enter ' 'BSpace ' 'я '; do
    printf '%s' "$type_through_keys" | \
      grep -F "$type_through_table $type_through_key" | \
      grep -F 'send-keys -X cancel' | \
      grep -F "switch-client -T detach-$type_through_table-original" >/dev/null || {
        printf 'type-through binding missing for [%s] in %s\n' \
          "$type_through_key" "$type_through_table" >&2
        exit 1
      }
  done
done
# The fallback tables retain ordinary copy-mode commands for sessions that turn
# managed mouse input off; wrappers can delegate without a tmux restart.
tmux -L "$SOCKET" list-keys -T detach-copy-mode-original | grep -F ' q ' | \
  grep -F 'send-keys -X cancel' >/dev/null
tmux -L "$SOCKET" list-keys -T detach-copy-mode-original | grep -F ' a ' | \
  grep -F 'send-keys -X cursor-left' >/dev/null
tmux -L "$SOCKET" list-keys -T detach-copy-mode-vi-original | grep -F 'Space ' | \
  grep -F 'begin-selection' >/dev/null
# Extended keys reach the pane by default, and both passthrough terminal-features
# are advertised exactly once even after repeated server configuration.
[ "$(tmux -L "$SOCKET" show-options -sqv extended-keys)" = "always" ]
[ "$(tmux -L "$SOCKET" show-options -sqv @detach_extended_keys)" = "1" ]
tmux -L "$SOCKET" list-keys -T root | grep -F 'S-Enter' | \
  grep -F 'send-keys M-Enter' | grep -F 'detach-root-original' >/dev/null
tmux -L "$SOCKET" list-keys -T detach-root-original | grep -F 'S-Enter' | \
  grep -F 'send-keys Enter' >/dev/null
# Exercise the actual client → tmux → raw-pane path. CSI-u Shift+Return must
# arrive as the provider-compatible Option+Return bytes (Escape, carriage
# return), rather than collapsing to ordinary Return as it did without the
# managed root binding.
shift_return_session="detach-shift-return-probe"
shift_return_bytes="$TMP_ROOT/shift-return.bytes"
tmux -L "$SOCKET" new-session -d -s "$shift_return_session" \
  "/bin/sh -c 'stty raw -echo; /bin/dd bs=1 count=2 of=\"$shift_return_bytes\" 2>/dev/null'"
{
  /bin/sleep 0.5
  printf '\033[13;2u'
} | TERM=xterm-256color /usr/bin/perl -e 'alarm 6; exec @ARGV' \
  /usr/bin/script -q /dev/null \
  "$TMUX_TEST_BIN" -S "$SOCKET_PATH" attach-session -t "=$shift_return_session" \
  >/dev/null
[ "$(od -An -tx1 "$shift_return_bytes" | tr -d '[:space:]')" = "1b0d" ]
[ "$(tmux -L "$SOCKET" show-options -sv terminal-features | grep -Fxc -- '*:extkeys')" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -sv terminal-features | grep -Fxc -- '*:hyperlinks')" = "1" ]
# Re-run the server configuration through a real attach. Attaching without a
# controlling terminal fails after tmux_configure_server has already run, so the
# terminal-features must still appear exactly once.
run_codex attach integration </dev/null >/dev/null 2>&1 || true
[ "$(tmux -L "$SOCKET" show-options -sv terminal-features | grep -Fxc -- '*:extkeys')" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -sv terminal-features | grep -Fxc -- '*:hyperlinks')" = "1" ]
grep -Fx -- 'run' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--session' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$SESSION" "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--run-token' "$FAKE_POWER_ARGS_FILE" >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_cli_version)" = "$installed_version" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_core_path)" = "$installed_core" ]
first_worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
first_worker_pgid="$(wait_for_process_group_id "$first_worker_pid")"
health_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = running ]
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin ownership_proven)" = true ]
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin cleanup_eligible)" = false ]
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin worker_pid)" = "$first_worker_pid" ]
provider_pid="$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin provider_pid)"
case "$provider_pid" in ''|*[!0-9]*) printf 'provider PID is missing from health JSON\n' >&2; exit 1 ;; esac
process_group_exists "$first_worker_pgid"

# A stale observer or checkpoint must not call a live long provider turn hung.
health_meta="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/meta.json"
run_token="$("$STATE_HELPER" meta get "$health_meta" run_token)"
if ! wait_for_process_group_stopped "$first_worker_pgid" "$first_worker_pid"; then
  signal_process_group_members CONT "$first_worker_pgid" "$first_worker_pid"
  exit 1
fi
stale_snapshot_status=0
"$STATE_HELPER" meta patch "$health_meta" --run-token "$run_token" \
  --integer worker_heartbeat_epoch 1 \
  --string worker_heartbeat_at '1970-01-01T00:00:01Z' || stale_snapshot_status=$?
if [ "$stale_snapshot_status" -eq 0 ]; then
  tmux -L "$SOCKET" set-option -q -t "=$SESSION:" @detach_heartbeat_epoch 1 || \
    stale_snapshot_status=$?
fi
if [ "$stale_snapshot_status" -eq 0 ]; then
  health_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")" || \
    stale_snapshot_status=$?
fi
if [ "$stale_snapshot_status" -eq 0 ]; then
  stale_effective_status="$(printf '%s' "$health_json" | \
    "$STATE_HELPER" meta get /dev/stdin effective_status)" || stale_snapshot_status=$?
  stale_health_reason="$(printf '%s' "$health_json" | \
    "$STATE_HELPER" meta get /dev/stdin health_reason)" || stale_snapshot_status=$?
fi
signal_process_group_members CONT "$first_worker_pgid" "$first_worker_pid"
[ "$stale_snapshot_status" -eq 0 ]
[ "$stale_effective_status" = running ]
[ "$stale_health_reason" = heartbeat_stale ]

# A mismatched run-token blocks cleanup and PID assumptions, but never makes
# Detach signal or delete the still managed pane.
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" @detach_run_token stale-token
health_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = corrupt ]
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" = run_token_mismatch ]
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin cleanup_eligible)" = false ]
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" @detach_run_token "$run_token"
heartbeat_epoch="$(date '+%s')"
"$STATE_HELPER" meta patch "$health_meta" --run-token "$run_token" \
  --integer worker_heartbeat_epoch "$heartbeat_epoch" \
  --string worker_heartbeat_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" @detach_heartbeat_epoch "$heartbeat_epoch"

reconcile_plan="$("$DETACH" reconcile --dry-run --json)"
[ "$(printf '%s' "$reconcile_plan" | "$STATE_HELPER" meta get /dev/stdin dry_run)" = true ]
! printf '%s' "$reconcile_plan" | grep -F "$SESSION" >/dev/null
grep -F -- "$literal_prompt" "$FAKE_CODEX_ARGS_FILE" >/dev/null
! grep -Fx -- '--ask-for-approval' "$FAKE_CODEX_ARGS_FILE" >/dev/null
[ ! -e "$marker" ]

# A client in an unrelated tmux server cannot switch-client into Detach's
# private server. It must instead start a nested client with tmux identity
# variables removed, leaving the provider session on the private server.
target_socket_path="$(tmux -L "$SOCKET" display-message -p -t "=$SESSION:" '#{socket_path}')"
TMUX="$TMP_ROOT/foreign-tmux.sock,123,0" TMUX_PANE=%99 \
  DETACH_ENV_BIN="$FAKE_ENV_BIN" "$DETACH" codex attach integration
[ "$(sed -n '1p' "$FAKE_ENV_ARGS_FILE")" = -u ]
[ "$(sed -n '2p' "$FAKE_ENV_ARGS_FILE")" = TMUX ]
[ "$(sed -n '3p' "$FAKE_ENV_ARGS_FILE")" = -u ]
[ "$(sed -n '4p' "$FAKE_ENV_ARGS_FILE")" = TMUX_PANE ]
grep -Fx -- 'attach-session' "$FAKE_ENV_ARGS_FILE" >/dev/null
grep -Fx -- "=$SESSION" "$FAKE_ENV_ARGS_FILE" >/dev/null
! grep -Fx -- 'switch-client' "$FAKE_ENV_ARGS_FILE" >/dev/null
grep -Fx -- '-S' "$FAKE_ENV_ARGS_FILE" >/dev/null
grep -Fx -- "$SOCKET_PATH" "$FAKE_ENV_ARGS_FILE" >/dev/null
[ -n "$target_socket_path" ]
tmux -L "$SOCKET" has-session -t "=$SESSION"

# Exercise the same path end-to-end with two real tmux servers. The outer pane
# launches a nested client on the Detach server; detaching that client returns
# to the outer shell without killing the managed session.
nested_returned="$TMP_ROOT/nested-attach-returned"
outer_session=foreign-outer
outer_pane="$(tmux -L "$OUTER_SOCKET" new-session -d -P -F '#{pane_id}' \
  -s "$outer_session" -x 120 -y 30)"
tmux -L "$OUTER_SOCKET" send-keys -l -t "$outer_pane" -- \
  "$DETACH codex attach integration; printf returned >'$nested_returned'"
tmux -L "$OUTER_SOCKET" send-keys -t "$outer_pane" C-m
attempts=0
while ! tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
    grep -Fx "$SESSION" >/dev/null && [ "$attempts" -lt 100 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
if ! tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
    grep -Fx "$SESSION" >/dev/null; then
  printf 'nested attach client did not appear within 10 seconds\n' >&2
  tmux -L "$SOCKET" list-clients -F '#{client_pid} #{client_session}' >&2 || true
  exit 1
fi
tmux -L "$OUTER_SOCKET" send-keys -t "$outer_pane" C-b d
attempts=0
while [ ! -f "$nested_returned" ] && [ "$attempts" -lt 50 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -f "$nested_returned" ]
! tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
  grep -Fx "$SESSION" >/dev/null
tmux -L "$SOCKET" has-session -t "=$SESSION"
tmux -L "$OUTER_SOCKET" has-session -t "=$outer_session"
tmux -L "$OUTER_SOCKET" kill-server >/dev/null 2>&1 || true

# SwiftTerm closes the in-app attach client with SIGTERM. Attach through the
# public CLI on a real PTY, terminate that client, and prove the managed
# session, worker, and provider survive.
TERM=xterm-256color /usr/bin/script -q /dev/null \
  "$DETACH" codex attach --terminal-features sync integration >/dev/null 2>&1 &
attach_client_wrapper=$!
attempts=0
while ! tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
    grep -Fx "$SESSION" >/dev/null && [ "$attempts" -lt 100 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
if ! tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
    grep -Fx "$SESSION" >/dev/null; then
  printf 'PTY attach client did not appear within 10 seconds\n' >&2
  tmux -L "$SOCKET" list-clients -F '#{client_pid} #{client_session}' >&2 || true
  exit 1
fi
attach_client_pid="$(tmux -L "$SOCKET" list-clients \
  -F '#{client_pid} #{client_session}' | \
  awk -v session="$SESSION" '$2 == session { print $1 }')"
case "$attach_client_pid" in
  ''|*[!0-9]*) printf 'attach client PID is missing\n' >&2; exit 1 ;;
esac
client_features="$(tmux -L "$SOCKET" list-clients \
  -F '#{client_pid}|#{client_termfeatures}' | \
  awk -F '|' -v pid="$attach_client_pid" '$1 == pid { print $2 }')"
case ",$client_features," in *,sync,*) ;; *)
  printf 'in-app attach client did not advertise synchronized output: %s\n' \
    "$client_features" >&2
  exit 1
  ;;
esac

# The app keeps this exact visible client and asks the public runtime to move
# it between live managed sessions. PID and expected source bind the request;
# a stale source or PID cannot affect another client.
switch_target="detach-codex-client-switch-target"
switch_target_pane="$(tmux -L "$SOCKET" new-session -d -P -F '#{pane_id}' \
  -s "$switch_target" '/bin/sleep 30')"
tmux -L "$SOCKET" set-option -q -t "=$switch_target:" @detach 1
tmux -L "$SOCKET" set-option -q -t "=$switch_target:" @detach_provider codex
tmux -L "$SOCKET" set-option -q -t "=$switch_target:" \
  @detach_pane_id "$switch_target_pane"
if "$DETACH" client switch --pid "$attach_client_pid" \
    --from detach-codex-wrong-source --to "$switch_target" \
    --provider codex >/dev/null 2>&1; then
  printf 'client switch accepted a stale source session\n' >&2
  exit 1
fi
[ "$(tmux -L "$SOCKET" list-clients -F '#{client_pid}|#{client_session}' | \
  awk -F '|' -v pid="$attach_client_pid" '$1 == pid { print $2 }')" = "$SESSION" ]
"$DETACH" client switch --pid "$attach_client_pid" \
  --from "$SESSION" --to "$switch_target" --provider codex
[ "$(tmux -L "$SOCKET" list-clients -F '#{client_pid}|#{client_session}' | \
  awk -F '|' -v pid="$attach_client_pid" '$1 == pid { print $2 }')" = "$switch_target" ]
"$DETACH" client switch --pid "$attach_client_pid" \
  --from "$switch_target" --to "$SESSION" --provider codex
[ "$(tmux -L "$SOCKET" list-clients -F '#{client_pid}|#{client_session}' | \
  awk -F '|' -v pid="$attach_client_pid" '$1 == pid { print $2 }')" = "$SESSION" ]
tmux -L "$SOCKET" kill-session -t "=$switch_target"
kill -TERM "$attach_client_pid"
attempts=0
while tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
    grep -Fx "$SESSION" >/dev/null && [ "$attempts" -lt 50 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
! tmux -L "$SOCKET" list-clients -F '#{client_session}' 2>/dev/null | \
  grep -Fx "$SESSION" >/dev/null
wait "$attach_client_wrapper" 2>/dev/null || true
tmux -L "$SOCKET" has-session -t "=$SESSION"
kill -0 "$first_worker_pid"
kill -0 "$provider_pid"
attach_closed_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$attach_closed_json" | \
  "$STATE_HELPER" meta get /dev/stdin effective_status)" = running ]
[ "$(printf '%s' "$attach_closed_json" | \
  "$STATE_HELPER" meta get /dev/stdin worker_pid)" = "$first_worker_pid" ]
[ "$(printf '%s' "$attach_closed_json" | \
  "$STATE_HELPER" meta get /dev/stdin provider_pid)" = "$provider_pid" ]

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
expected_id="$("$STATE_HELPER" meta get "$meta" codex_session_id)"
[ -n "$expected_id" ]
[ "$("$STATE_HELPER" meta get "$meta" session_color)" = "$session_color" ]
[ "$expected_id" != "ffffffff-ffff-4fff-8fff-ffffffffffff" ]
rollout="$("$STATE_HELPER" meta get "$meta" rollout_path)"
[ "$("$STATE_HELPER" jsonl first "$rollout" payload.originator)" = \
  "detach_$("$STATE_HELPER" meta get "$meta" run_token)" ]
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" | grep -F "$expected_id" >/dev/null
[ -s "$checkpoint/rollout.jsonl" ]
[ -s "$checkpoint/codex-state.sqlite" ]

: >"$integration_release"
unset FAKE_CODEX_RELEASE_FILE
attempts=0
while [ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "0" ] && \
      [ "$attempts" -lt 160 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -f "$checkpoint/pane.txt" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead_status}')" = "7" ]
wait_for_process_group_exit "$first_worker_pgid"
[ "$("$STATE_HELPER" meta get "$meta" status)" = "failed" ]
[ "$("$STATE_HELPER" meta get "$meta" exit_status)" = "7" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "failed" ]
failed_style="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style)"
printf '%s' "$failed_style" | grep -F "bg=$(expected_tint '#B91C1C' 55)" >/dev/null
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

# The mouse toggle owns only Detach sessions and round-trips through the
# same locked config as the style toggle.
[ "$("$DETACH" config tmux-mouse)" = "on" ]
"$DETACH" config tmux-mouse off
[ "$("$DETACH" config tmux-mouse)" = "off" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" mouse)" = "off" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_copy_type_through)" = "0" ]
# The managed wrappers remain installed but now delegate to the saved original
# table, making the toggle immediately reversible.
tmux -L "$SOCKET" list-keys -T copy-mode | grep -F ' q ' | \
  grep -F 'detach-copy-mode-original' >/dev/null
"$DETACH" config tmux-mouse on
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" mouse)" = "on" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_copy_type_through)" = "1" ]

# The extended-keys toggle round-trips through the same locked config, defaults
# to on (server option `always`), and flips the live server option both ways.
[ "$("$DETACH" config tmux-extended-keys)" = "on" ]
"$DETACH" config tmux-extended-keys off
[ "$("$DETACH" config tmux-extended-keys)" = "off" ]
[ "$(tmux -L "$SOCKET" show-options -sqv extended-keys)" = "off" ]
[ "$(tmux -L "$SOCKET" show-options -sqv @detach_extended_keys)" = "0" ]
"$DETACH" config tmux-extended-keys on
[ "$("$DETACH" config tmux-extended-keys)" = "on" ]
[ "$(tmux -L "$SOCKET" show-options -sqv extended-keys)" = "always" ]
[ "$(tmux -L "$SOCKET" show-options -sqv @detach_extended_keys)" = "1" ]
if "$DETACH" config tmux-extended-keys sideways >/dev/null 2>&1; then
  printf 'config unexpectedly accepted an unsupported extended-keys value\n' >&2
  exit 1
fi
# A live environment override owns the value; config must refuse to persist one.
[ "$(DETACH_TMUX_EXTENDED_KEYS=0 "$DETACH" config tmux-extended-keys)" = "off" ]
if DETACH_TMUX_EXTENDED_KEYS=0 "$DETACH" config tmux-extended-keys on >/dev/null 2>&1; then
  printf 'config unexpectedly changed a value owned by DETACH_TMUX_EXTENDED_KEYS\n' >&2
  exit 1
fi

run_codex logs integration | grep -F 'fake Codex finished' >/dev/null

stopped_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
run_codex stop integration
! tmux -L "$SOCKET" has-session -t "=$SESSION" 2>/dev/null
[ "$("$STATE_HELPER" meta get "$meta" status)" = "stopped" ]
[ -n "$("$STATE_HELPER" meta get "$meta" stopped_at)" ]
# Stop records its intent in typed state before it signals the runtime, and
# the list carries it, so an `interrupted` window is never read as a crash.
[ -n "$("$STATE_HELPER" meta get "$meta" stop_requested_at)" ]
run_codex list --json | grep -F "\"session_name\":\"$SESSION\"" | \
  grep -F '"stop_requested_at":"' >/dev/null
grep -Fx "release --session $SESSION --run-token $stopped_run_token" \
  "$FAKE_POWER_RELEASES_FILE" >/dev/null
codex_scenario_event pass SC-SESSION-STOP-CODEX

if [ "$CODEX_TEST_PART" = lifecycle ]; then
  run_codex delete --force integration
fi
fi

# Simulate losing the primary metadata in a power failure. Auto-recovery must
# use the checkpoint metadata and resume the exact saved UUID.
if codex_part_selected recovery; then
if [ "$CODEX_TEST_PART" = recovery ]; then
  bootstrap_codex_checkpoint
fi
"$STATE_HELPER" meta patch "$checkpoint/meta.json" --string status running
rm -f "$meta"

export FAKE_CODEX_SLEEP=20
export FAKE_CODEX_EXIT=0
export FAKE_CODEX_FOREIGN_FIRST=0
if ! run_codex recover --detach integration; then
  printf 'recover command returned a failure after starting the session\n' >&2
  exit 1
fi
wait_for_file_text "$FAKE_CODEX_ARGS_FILE" resume
require_file_line "$FAKE_CODEX_ARGS_FILE" resume
require_file_line "$FAKE_CODEX_ARGS_FILE" "$expected_id"
# A new run under the same name starts without the previous Stop intent.
[ -z "$("$STATE_HELPER" meta get "$meta" stop_requested_at)" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ -n "$pane_id" ] || { printf 'recovered session is missing its pane ID\n' >&2; exit 1; }
worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
case "$worker_pid" in
  ''|*[!0-9]*) printf 'recovered pane has invalid worker PID: %s\n' "$worker_pid" >&2; exit 1 ;;
esac
worker_pgid="$(wait_for_process_group_id "$worker_pid")"
codex_scenario_event pass SC-SESSION-RECOVER-CODEX

run_codex stop integration
! kill -0 "$worker_pid" 2>/dev/null
wait_for_process_group_exit "$worker_pgid"
[ "$("$STATE_HELPER" meta get "$meta" status)" = "stopped" ]
[ -n "$("$STATE_HELPER" meta get "$meta" stopped_at)" ]

if [ "$CODEX_TEST_PART" = recovery ]; then
  run_codex delete --force integration
fi
fi

if codex_part_selected restart; then
if [ "$CODEX_TEST_PART" = recovery ] || [ "$CODEX_TEST_PART" = restart ]; then
  bootstrap_codex_checkpoint
fi

# A fresh run with the same name must never inherit the previous run's UUID.
[ -s "$checkpoint/rollout.jsonl" ]
previous_lifecycle_id="$("$STATE_HELPER" meta get "$meta" lifecycle_id)"
[ -n "$previous_lifecycle_id" ]
export FAKE_CODEX_INIT_DELAY=5
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request", "never"]' >"$DETACH_CODEX_REQUIREMENTS_FILE"
run_codex --name integration --detach -- 'start a new thread'
wait_for_file_text "$FAKE_CODEX_ARGS_FILE" 'start a new thread'
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_cli_version)" = "$upgraded_version" ]
[ "$(grep -Fxc -- '--ask-for-approval' "$FAKE_CODEX_ARGS_FILE")" = "1" ]
[ "$(grep -Fxc -- 'never' "$FAKE_CODEX_ARGS_FILE")" = "1" ]
[ ! -e "$checkpoint/rollout.jsonl" ]
[ ! -e "$checkpoint/.detach-jsonl-validation.json" ]
[ ! -e "$checkpoint/meta.json" ]
fresh_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
fresh_lifecycle_id="$("$STATE_HELPER" meta get "$meta" lifecycle_id)"
[ -n "$fresh_lifecycle_id" ]
[ "$fresh_lifecycle_id" != "$previous_lifecycle_id" ]
[ "$fresh_lifecycle_id" != "$fresh_run_token" ]
if run_codex --name integration --detach -- 'must not replace a running task'; then
  printf 'new default start unexpectedly replaced a running task\n' >&2
  exit 1
fi
[ "$("$STATE_HELPER" meta get "$meta" run_token)" = "$fresh_run_token" ]
run_codex stop integration

if [ "$CODEX_TEST_PART" != all ]; then
  run_codex delete --force integration
fi
fi

if codex_part_selected resume; then
if [ "$CODEX_TEST_PART" = all ] || \
   [ "$CODEX_TEST_PART" = resume ] || \
   [ "$CODEX_TEST_PART" = resume-identity ]; then
  bootstrap_codex_checkpoint
fi

# Explicit resume follows Codex semantics and accepts the exact thread UUID.
export FAKE_CODEX_INIT_DELAY=0
export FAKE_CODEX_SLEEP=1
expected_rollout="$("$STATE_HELPER" meta get "$meta" transcript_path)"
[ -n "$expected_rollout" ]
[ -f "$expected_rollout" ]
cp -p "$expected_rollout" "$checkpoint/rollout.jsonl"
printf '{damaged rollout\n' >"$expected_rollout"
uppercase_id="$(printf '%s' "$expected_id" | tr '[:lower:]' '[:upper:]')"
other_cwd="$TMP_ROOT/other-cwd"
mkdir -p "$other_cwd"
# Capture the event token before resume. On a fast host, the worker can record
# `completed`, exit, and run the pane-died hook before the status poll below
# returns. A baseline taken after that poll would wait for a nonexistent extra
# event.
status_hint="$(cat "$DETACH_STATE_ROOT/session-change")"
(cd "$other_cwd" && "$DETACH" resume --name integration --detach "$uppercase_id")
wait_for_tmux_option "$SESSION" @detach_status completed
grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
grep -Fx "$expected_id" "$FAKE_CODEX_ARGS_FILE" >/dev/null
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$expected_id" ]
completed_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
wait_for_pane_dead "$pane_id"
hint_attempts=0
while [ "$hint_attempts" -lt 100 ] && \
      [ "$(cat "$DETACH_STATE_ROOT/session-change")" = "$status_hint" ]; do
  hint_attempts=$((hint_attempts + 1))
  sleep 0.05
done
[ "$(cat "$DETACH_STATE_ROOT/session-change")" != "$status_hint" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "completed" ]
completed_style="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" status-style)"
[ "$completed_style" != "$failed_style" ]
! printf '%s' "$completed_style" | grep -F "bg=$session_color" >/dev/null

# A normal start replaces a completed retained pane with a fresh Codex thread.
export FAKE_CODEX_INIT_DELAY=5
run_codex --name integration --detach -- 'replace the completed thread'
attempts=0
while [ "$("$STATE_HELPER" meta get "$meta" run_token)" = "$completed_run_token" ] && \
      [ "$attempts" -lt 30 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$("$STATE_HELPER" meta get "$meta" run_token)" != "$completed_run_token" ]
grep -Fx 'replace the completed thread' "$FAKE_CODEX_ARGS_FILE" >/dev/null
! grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "0" ]
run_codex stop integration

# list --json exposes machine-readable session state.
export FAKE_CODEX_INIT_DELAY=0
export FAKE_CODEX_SLEEP=60
export FAKE_CODEX_EXIT=0
run_codex --name integration --detach -- 'json coverage'
wait_for_tmux_option "$SESSION" @detach_status running
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin schema)" = "1" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin provider)" = "codex" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin name)" = "integration" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = "running" ]
[ -n "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin project_dir)" ]
[ -n "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin created_at)" ]
[ -n "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin lifecycle_id)" ]
[ -z "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin exit_status)" ]
[[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin session_color)" =~ ^#[[:xdigit:]]{6}$ ]]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin power_protection_state)" = "protected" ]
printf '%s' "$json_line" | grep -F '"model":' | grep -F '"context_used_tokens":' | \
  grep -F '"context_window":' >/dev/null
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "working" ]
turn_rollout="$("$STATE_HELPER" meta get "$meta" transcript_path)"
turn_id="$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)"
[ -n "$turn_id" ]
power_activity="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/power-activity-$("$STATE_HELPER" meta get "$meta" run_token)"
power_activity_source="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/power-activity-source-$("$STATE_HELPER" meta get "$meta" run_token)"
wait_for_file_text "$power_activity" working
grep -Fx -- '--activity-file' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$power_activity" "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--activity-source-file' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$power_activity_source" "$FAKE_POWER_ARGS_FILE" >/dev/null
printf '{"timestamp":"2099-01-01T00:10:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"%s"}}\n' \
  "$turn_id" >>"$turn_rollout"
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = "running" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "waiting" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "$turn_id" ]
wait_for_file_text "$power_activity" waiting
[ -s "$power_activity_source" ]
printf '%s\n' \
  '{"timestamp":"2099-01-01T00:10:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-after-idle"}}' \
  >>"$turn_rollout"
wait_for_file_text "$power_activity" working
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "working" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "turn-after-idle" ]

if [ "$CODEX_TEST_PART" = resume ]; then
  run_codex stop integration
  run_codex delete --force integration
fi
fi

# Codex /clear opens a successor thread inside the same provider process.
# Discovery must rebind identity, turn state, and checkpoints to the newest
# run-owned thread, refuse a creation-time tie, ignore subagent threads, and
# consume superseded ids so the next switch is unambiguous again.
if codex_part_selected identity; then
if [ "$CODEX_TEST_PART" = identity ]; then
  export FAKE_CODEX_SLEEP=60
  export FAKE_CODEX_EXIT=0
  export FAKE_CODEX_FOREIGN_FIRST=0
  export FAKE_CODEX_INIT_DELAY=0.1
  run_codex --name integration --detach -- 'identity fixture'
  wait_for_tmux_option "$SESSION" @detach_status running
  meta="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/meta.json"
  checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint"
  session_color="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_color)"
  json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
  turn_rollout="$("$STATE_HELPER" meta get "$meta" transcript_path)"
  turn_id="$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)"
fi
switch_project_dir="$("$STATE_HELPER" meta get "$meta" project_dir)"
switch_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
pre_switch_id="$("$STATE_HELPER" meta get "$meta" codex_session_id)"
[ -n "$pre_switch_id" ]
switch_base_ms="$(($(date '+%s') * 1000))"
write_switch_rollout() {
  local switch_id="$1"
  local switch_source="$2"
  local switch_turn="$3"
  local switch_rollout="$CODEX_HOME/sessions/2099/01/01/rollout-test-$switch_id.jsonl"

  printf '{"timestamp":"2099-01-01T00:20:00Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"detach_%s"}}\n' \
    "$switch_id" "$switch_project_dir" "$switch_run_token" >"$switch_rollout"
  printf '{"timestamp":"2099-01-01T00:20:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"%s"}}\n' \
    "$switch_turn" >>"$switch_rollout"
  printf '%s\n' "$switch_rollout"
}

switch_thread() {
  local switch_id="$1"
  local switch_ms="$2"
  local switch_source="$3"
  local switch_turn="$4"
  local switch_rollout

  switch_rollout="$(write_switch_rollout \
    "$switch_id" "$switch_source" "$switch_turn")"
  test_sqlite "$CODEX_HOME/state_5.sqlite" \
    "INSERT OR REPLACE INTO threads (id, rollout_path, created_at_ms, updated_at_ms, source, thread_source, cwd) \
     VALUES ('$switch_id', '${switch_rollout//\'/\'\'}', $switch_ms, $switch_ms, 'cli', '$switch_source', '${switch_project_dir//\'/\'\'}');"
}

switch_thread_pair() {
  local first_id="$1"
  local first_ms="$2"
  local first_source="$3"
  local first_turn="$4"
  local second_id="$5"
  local second_ms="$6"
  local second_source="$7"
  local second_turn="$8"
  local first_rollout
  local second_rollout

  first_rollout="$(write_switch_rollout \
    "$first_id" "$first_source" "$first_turn")"
  second_rollout="$(write_switch_rollout \
    "$second_id" "$second_source" "$second_turn")"
  test_sqlite "$CODEX_HOME/state_5.sqlite" \
    "BEGIN IMMEDIATE; \
     INSERT OR REPLACE INTO threads (id, rollout_path, created_at_ms, updated_at_ms, source, thread_source, cwd) \
     VALUES ('$first_id', '${first_rollout//\'/\'\'}', $first_ms, $first_ms, 'cli', '$first_source', '${switch_project_dir//\'/\'\'}'); \
     INSERT OR REPLACE INTO threads (id, rollout_path, created_at_ms, updated_at_ms, source, thread_source, cwd) \
     VALUES ('$second_id', '${second_rollout//\'/\'\'}', $second_ms, $second_ms, 'cli', '$second_source', '${switch_project_dir//\'/\'\'}'); \
     COMMIT;"
}
switch_a="22222222-2222-7222-8222-222222222222"
switch_b="33333333-3333-7333-8333-333333333333"
switch_subagent="44444444-4444-7444-8444-444444444444"
switch_thread_pair \
  "$switch_a" "$((switch_base_ms + 1000))" user clear-turn-a \
  "$switch_b" "$((switch_base_ms + 1000))" user clear-turn-b
switch_thread "$switch_subagent" "$((switch_base_ms + 5000))" subagent clear-turn-subagent
wait_for_file_text "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" \
  'ambiguous Codex thread switch'
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$pre_switch_id" ]
grep -F 'ambiguous Codex thread switch' \
  "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" >/dev/null
test_sqlite "$CODEX_HOME/state_5.sqlite" "DELETE FROM threads WHERE id = '$switch_b';"
rm -f "$CODEX_HOME/sessions/2099/01/01/rollout-test-$switch_b.jsonl"
attempts=0
while [ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" != "$switch_a" ] && \
      [ "$attempts" -lt 80 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$switch_a" ]
[ "$("$STATE_HELPER" meta get "$meta" agent_session_id)" = "$switch_a" ]
[ "$("$STATE_HELPER" meta get "$meta" transcript_path)" = \
  "$CODEX_HOME/sessions/2099/01/01/rollout-test-$switch_a.jsonl" ]
grep -Fqx "$pre_switch_id" \
  "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/known-thread-ids.txt"
grep -F 'rebound Codex session identity' \
  "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" >/dev/null
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "working" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "clear-turn-a" ]
attempts=0
while ! grep -F 'clear-turn-a' "$checkpoint/rollout.jsonl" >/dev/null 2>&1 && \
      [ "$attempts" -lt 80 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
grep -F 'clear-turn-a' "$checkpoint/rollout.jsonl" >/dev/null

# A second switch with two visible successors must pick the newest, record the
# superseded candidate in known-thread-ids.txt, and keep later switches
# unambiguous.
switch_c="55555555-5555-7555-8555-555555555555"
switch_d="66666666-6666-7666-8666-666666666666"
switch_thread_pair \
  "$switch_c" "$((switch_base_ms + 10000))" user clear-turn-c \
  "$switch_d" "$((switch_base_ms + 11000))" user clear-turn-d
attempts=0
while [ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" != "$switch_d" ] && \
      [ "$attempts" -lt 80 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$switch_d" ]
grep -Fqx "$switch_a" "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/known-thread-ids.txt"
grep -Fqx "$switch_c" "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/known-thread-ids.txt"

# A run-owned thread that surfaces late but is older than the current binding
# must never rebind identity backward.
switch_old="77777777-7777-7777-8777-777777777777"
switch_thread "$switch_old" "$((switch_base_ms + 2000))" user clear-turn-old
wait_for_file_text "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" \
  'refusing Codex thread switch'
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$switch_d" ]
grep -F 'refusing Codex thread switch' \
  "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" >/dev/null

while IFS= read -r list_line; do
  [ "$(printf '%s' "$list_line" | "$STATE_HELPER" meta get /dev/stdin schema)" = "1" ]
done < <(run_codex list --json)
run_codex stop integration
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = "stopped" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin meta_status)" = "stopped" ]
# A null legacy identity uses the stable provider/project fallback. The
# occupancy-aware allocation is only persisted while writing metadata.
"$STATE_HELPER" meta patch "$meta" --null session_color
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
legacy_project_dir="$("$STATE_HELPER" meta get "$meta" project_dir)"
legacy_fallback_color="$(run_codex __session_color "$legacy_project_dir")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin session_color)" = "$legacy_fallback_color" ]
"$STATE_HELPER" meta patch "$meta" --string session_color not-a-color
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ -z "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin session_color)" ]
printf '%s' "$json_line" | grep -F '"session_color":null' >/dev/null
# Restore a valid identity before collision coverage so the foreign-session
# safety assertion does not pass merely because the saved value is malformed.
"$STATE_HELPER" meta patch "$meta" --string session_color "$session_color"

# Delete refuses a live session and removes a stopped one. The fine-grained
# local layout gives its intentional held-lock wait a separate parallel lane.
fi

if codex_part_selected delete; then
run_codex --name integration --detach -- 'delete refusal coverage'
wait_for_tmux_option "$SESSION" @detach_status running
live_storage_plan="$("$DETACH" storage cleanup --dry-run --json)"
! printf '%s' "$live_storage_plan" | grep -F "\"session_name\":\"$SESSION\"" >/dev/null
if "$DETACH" storage cleanup --dry-run --json --session "$SESSION" >/dev/null 2>&1; then
  printf 'storage cleanup unexpectedly planned a running session\n' >&2
  exit 1
fi
if run_codex delete --force integration; then
  printf 'delete unexpectedly removed a running session\n' >&2
  exit 1
fi
tmux -L "$SOCKET" has-session -t "=$SESSION"
run_codex stop integration
storage_report="$("$DETACH" storage --json)"
[ "$(printf '%s' "$storage_report" | "$STATE_HELPER" meta get /dev/stdin schema)" = 1 ]
printf '%s' "$storage_report" | grep -F "\"session_name\":\"$SESSION\"" >/dev/null
storage_plan="$("$DETACH" storage cleanup --dry-run --json --session "$SESSION")"
[ "$(printf '%s' "$storage_plan" | "$STATE_HELPER" meta get /dev/stdin dry_run)" = true ]
printf '%s' "$storage_plan" | grep -F "\"session_name\":\"$SESSION\"" >/dev/null
external_storage="$TMP_ROOT/provider-storage-sentinel"
mkdir -p "$external_storage"
printf 'provider data\n' >"$external_storage/keep"
ln -s "$external_storage" "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint/external"
storage_report="$("$DETACH" storage --json)"
printf '%s' "$storage_report" | grep -F '"symlink_count":1' >/dev/null
checkpoint_lock="$DETACH_LOCKS_ROOT/checkpoint-$SESSION.lock"
checkpoint_ready="$TMP_ROOT/checkpoint-lock-ready"
/usr/bin/lockf -k "$checkpoint_lock" /bin/sh -c \
  'touch "$1"; sleep 12; test -d "$2"' sh \
  "$checkpoint_ready" "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION" &
checkpoint_holder=$!
attempts=0
while [ ! -f "$checkpoint_ready" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 40 ] || {
    printf 'checkpoint lock holder did not start\n' >&2
    exit 1
  }
  sleep 0.05
done
run_codex delete --force integration
wait "$checkpoint_holder"
[ ! -d "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION" ]
[ "$(<"$external_storage/keep")" = 'provider data' ]
! tmux -L "$SOCKET" has-session -t "=$SESSION" 2>/dev/null
! run_codex list --json | grep -F "\"session_name\":\"$SESSION\"" >/dev/null
codex_scenario_event pass SC-SESSION-DELETE-CODEX

# A managed tmux session whose state directory was removed by hand is a
# tmux-only remnant. Delete must still remove the remnant instead of dying
# on the missing directory.
remnant_name=delete-remnant
remnant_session=detach-codex-delete-remnant
FAKE_CODEX_INIT_DELAY=0 FAKE_CODEX_SLEEP=1 FAKE_CODEX_EXIT=0 \
  run_codex --name "$remnant_name" --detach -- 'tmux-only remnant delete coverage'
remnant_pane="$(tmux -L "$SOCKET" show-options -qv -t "=$remnant_session:" @detach_pane_id)"
wait_for_pane_dead "$remnant_pane"
tmux -L "$SOCKET" has-session -t "=$remnant_session"
rm -rf "$DETACH_CODEX_STATE_ROOT/sessions/$remnant_session"
run_codex delete --force "$remnant_name"
! tmux -L "$SOCKET" has-session -t "=$remnant_session" 2>/dev/null

# A delete that cannot remove every byte must fail loudly instead of
# printing a misleading success over leftover state.
stubborn_name=delete-stubborn
stubborn_session=detach-codex-delete-stubborn
FAKE_CODEX_INIT_DELAY=0 FAKE_CODEX_SLEEP=1 FAKE_CODEX_EXIT=0 \
  run_codex --name "$stubborn_name" --detach -- 'partial delete failure coverage'
stubborn_pane="$(tmux -L "$SOCKET" show-options -qv -t "=$stubborn_session:" @detach_pane_id)"
wait_for_pane_dead "$stubborn_pane"
stubborn_dir="$DETACH_CODEX_STATE_ROOT/sessions/$stubborn_session"
mkdir -p "$stubborn_dir/nested"
printf 'undeletable\n' >"$stubborn_dir/nested/keep"
chmod 0555 "$stubborn_dir/nested"
if run_codex delete --force "$stubborn_name" >"$TMP_ROOT/delete-stubborn.out" 2>&1; then
  printf 'delete unexpectedly succeeded over an undeletable nested file\n' >&2
  exit 1
fi
grep -F 'could not completely remove session state' "$TMP_ROOT/delete-stubborn.out" >/dev/null
! grep -F "Deleted $stubborn_session" "$TMP_ROOT/delete-stubborn.out" >/dev/null
grep -Fx 'undeletable' "$stubborn_dir/nested/keep" >/dev/null
chmod 0755 "$stubborn_dir/nested"
rm -rf "$stubborn_dir"
! tmux -L "$SOCKET" has-session -t "=$stubborn_session" 2>/dev/null

# Stop resolves the pane process group through /bin/ps. A failing ps first
# on PATH must not replace it: a single-pid fallback TERM would leave the
# HUP-ignoring provider running after kill-session and fail the stop, while
# the revalidated group TERM still stops the whole managed group cleanly.
stop_signal_source="$(sed -n '/^stop_session() {/,/^delete_session() {/p' \
  "$ROOT/bin/detach-core")"
[ "$(printf '%s\n' "$stop_signal_source" | \
  grep -c 'signal_managed_pane_group .* TERM')" = 1 ]
[ "$(printf '%s\n' "$stop_signal_source" | \
  grep -c 'signal_managed_pane_group .* KILL')" = 1 ]
! printf '%s\n' "$stop_signal_source" | \
  grep -E 'kill[[:space:]]+-(TERM|KILL)' >/dev/null
shadow_name=delete-stop-shadow-ps
shadow_session=detach-codex-delete-stop-shadow-ps
shadow_bin="$TMP_ROOT/shadow-bin"
mkdir -p "$shadow_bin"
printf '%s\n' '#!/bin/bash' 'exit 1' >"$shadow_bin/ps"
chmod 0755 "$shadow_bin/ps"
DETACH_CODEX_BIN="$FAKE_CODEX_LONG_BIN" \
  run_codex --name "$shadow_name" --detach -- 'stop PATH ps coverage'
wait_for_tmux_option "$shadow_session" @detach_status running
PATH="$shadow_bin:$PATH" run_codex stop "$shadow_name"
! tmux -L "$SOCKET" has-session -t "=$shadow_session" 2>/dev/null
[ "$("$STATE_HELPER" meta get \
  "$DETACH_CODEX_STATE_ROOT/sessions/$shadow_session/meta.json" status)" = stopped ]
run_codex delete --force "$shadow_name"

# Freeze the worker after Start, then request Stop. The process-group TERM
# removes the provider while the stopped worker cannot publish final metadata.
# This holds the exact UI-visible transition long enough to assert that durable
# Stop intent keeps it out of Problems without authorizing an early action.
stop_transition_name=stop-transition
stop_transition_session=detach-codex-stop-transition
DETACH_CODEX_BIN="$FAKE_CODEX_LONG_BIN" \
  run_codex --name "$stop_transition_name" --detach -- 'Stop transition health coverage'
wait_for_tmux_option "$stop_transition_session" @detach_status running
stop_transition_meta="$DETACH_CODEX_STATE_ROOT/sessions/$stop_transition_session/meta.json"
stop_transition_worker="$("$STATE_HELPER" meta get "$stop_transition_meta" worker_pid)"
kill -STOP "$stop_transition_worker"
run_codex stop "$stop_transition_name" >"$TMP_ROOT/stop-transition.out" 2>&1 &
stop_transition_pid=$!
stop_transition_json=""
attempts=0
while [ "$attempts" -lt 80 ]; do
  candidate_json="$(run_codex list --json | \
    grep -F "\"session_name\":\"$stop_transition_session\"")"
  candidate_reason="$(printf '%s' "$candidate_json" | \
    "$STATE_HELPER" meta get /dev/stdin health_reason)"
  case "$candidate_reason" in
    finished|provider_process_lost)
      stop_transition_json="$candidate_json"
      break
      ;;
  esac
  attempts=$((attempts + 1))
  sleep 0.1
done
kill -CONT "$stop_transition_worker" 2>/dev/null || true
wait "$stop_transition_pid"
[ -n "$stop_transition_json" ]
[ "$(printf '%s' "$stop_transition_json" | \
  "$STATE_HELPER" meta get /dev/stdin effective_status)" = interrupted ]
[ "$(printf '%s' "$stop_transition_json" | \
  "$STATE_HELPER" meta get /dev/stdin health_reason)" = finished ]
[ "$(printf '%s' "$stop_transition_json" | \
  "$STATE_HELPER" meta get /dev/stdin cleanup_eligible)" = false ]
[ -n "$(printf '%s' "$stop_transition_json" | \
  "$STATE_HELPER" meta get /dev/stdin stop_requested_at)" ]
printf '%s' "$stop_transition_json" | grep -F '"health_actions":[]' >/dev/null
[ "$("$STATE_HELPER" meta get "$stop_transition_meta" status)" = stopped ]
run_codex delete --force "$stop_transition_name"

# A start holds the install lock through its readiness wait (up to 35
# seconds). Scale lockf deadlines by 10 for this check so the regression stays
# discriminating without adding 35 seconds to every Codex test run.
install_lock_ready="$TMP_ROOT/install-lock-ready"
scaled_install_lockf="$TMP_ROOT/scaled-install-lockf"
printf '%s\n' \
  '#!/bin/bash' \
  'set -eu' \
  '[ "$1" = -k ] && [ "$2" = -t ]' \
  'timeout=$((($3 + 9) / 10))' \
  'shift 3' \
  'exec /usr/bin/lockf -k -t "$timeout" "$@"' >"$scaled_install_lockf"
chmod 0755 "$scaled_install_lockf"
/usr/bin/lockf -k "$TEST_INSTALL_STATE_ROOT/install.lock" /bin/sh -c \
  'touch "$1"; sleep 3.5' sh "$install_lock_ready" &
install_holder=$!
attempts=0
while [ ! -f "$install_lock_ready" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 40 ] || {
    printf 'install lock holder did not start\n' >&2
    exit 1
  }
  sleep 0.05
done
DETACH_LOCKF_BIN="$scaled_install_lockf" "$SCRIPT" config tmux-mouse off
wait "$install_holder"
[ "$("$SCRIPT" config tmux-mouse)" = "off" ]
"$SCRIPT" config tmux-mouse on
[ "$("$SCRIPT" config tmux-mouse)" = "on" ]
fi

# Killing the worker can leave its provider alive in a retained pane. Detach
# must expose that uncertainty, refuse every state-changing action, and keep
# the session out of both cleanup plans until the whole managed process group
# is gone.
if codex_part_selected crash; then
worker_crash_name=health-worker-crash
worker_crash_session=detach-codex-health-worker-crash
DETACH_CODEX_BIN="$FAKE_CODEX_LONG_BIN" \
  run_codex --name "$worker_crash_name" --detach -- 'worker crash health coverage'
worker_crash_meta="$DETACH_CODEX_STATE_ROOT/sessions/$worker_crash_session/meta.json"
worker_crash_checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$worker_crash_session/checkpoint/rollout.jsonl"
attempts=0
while { [ ! -s "$worker_crash_checkpoint" ] || \
        [ -z "$("$STATE_HELPER" meta get "$worker_crash_meta" agent_session_id 2>/dev/null || true)" ]; } && \
      [ "$attempts" -lt 80 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -s "$worker_crash_checkpoint" ]
[ -s "$(dirname "$worker_crash_checkpoint")/.detach-jsonl-validation.json" ]
worker_crash_pane="$(tmux -L "$SOCKET" show-options -qv \
  -t "=$worker_crash_session:" @detach_pane_id)"
worker_crash_pid="$("$STATE_HELPER" meta get "$worker_crash_meta" worker_pid)"
worker_crash_provider_pid="$("$STATE_HELPER" meta get "$worker_crash_meta" provider_pid)"
worker_crash_pgid="$(wait_for_process_group_id "$worker_crash_pid")"
kill -KILL "$worker_crash_pid"
attempts=0
while [ "$(tmux -L "$SOCKET" display-message -p -t "$worker_crash_pane" '#{pane_dead}')" != "1" ] && \
      [ "$attempts" -lt 80 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$(tmux -L "$SOCKET" display-message -p -t "$worker_crash_pane" '#{pane_dead}')" = "1" ]
kill -0 "$worker_crash_provider_pid"
worker_crash_json="$(run_codex list --json | \
  grep -F "\"session_name\":\"$worker_crash_session\"")"
[ "$(printf '%s' "$worker_crash_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = hung ]
[ "$(printf '%s' "$worker_crash_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" = \
  runtime_process_without_tmux ]
[ "$(printf '%s' "$worker_crash_json" | "$STATE_HELPER" meta get /dev/stdin cleanup_eligible)" = false ]
printf '%s' "$worker_crash_json" | grep -F '"health_actions":[]' >/dev/null
if run_codex stop "$worker_crash_name" >/dev/null 2>&1; then
  printf 'stop unexpectedly changed state while a provider survived its worker\n' >&2
  exit 1
fi
if run_codex recover --detach "$worker_crash_name" >/dev/null 2>&1; then
  printf 'recover unexpectedly started over a surviving provider\n' >&2
  exit 1
fi
if run_codex delete --force "$worker_crash_name" >/dev/null 2>&1; then
  printf 'delete unexpectedly removed state for a surviving provider\n' >&2
  exit 1
fi
if run_codex --name "$worker_crash_name" --detach -- \
    'must not start over a surviving provider' >/dev/null 2>&1; then
  printf 'start unexpectedly replaced state for a surviving provider\n' >&2
  exit 1
fi
kill -0 "$worker_crash_provider_pid"
! "$DETACH" reconcile --dry-run --json | grep -F "$worker_crash_session" >/dev/null
! "$DETACH" cleanup --dry-run --json | grep -F "$worker_crash_session" >/dev/null

kill -KILL -- "-$worker_crash_pgid"
wait_for_process_group_exit "$worker_crash_pgid"
attempts=0
worker_crash_status=""
while [ "$attempts" -lt 80 ]; do
  worker_crash_json="$(run_codex list --json | \
    grep -F "\"session_name\":\"$worker_crash_session\"")"
  worker_crash_status="$(printf '%s' "$worker_crash_json" | \
    "$STATE_HELPER" meta get /dev/stdin effective_status)"
  [ "$worker_crash_status" != hung ] && break
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$worker_crash_status" = recoverable ]
[ "$(printf '%s' "$worker_crash_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" = \
  recoverable_checkpoint ]
worker_reconcile_plan="$("$DETACH" reconcile --dry-run --json)"
printf '%s' "$worker_reconcile_plan" | grep -F "$worker_crash_session" | \
  grep -F 'remove_dead_tmux_and_mark_recoverable' >/dev/null

# stop/recover/delete share a per-session operation lock. A real race may end
# in any one of their valid terminal states, but never in deleted live state or
# an unowned runtime hidden behind stale metadata.
run_codex recover --detach "$worker_crash_name" >"$TMP_ROOT/race-recover.out" 2>&1 &
race_recover_pid=$!
run_codex stop "$worker_crash_name" >"$TMP_ROOT/race-stop.out" 2>&1 &
race_stop_pid=$!
run_codex delete --force "$worker_crash_name" >"$TMP_ROOT/race-delete.out" 2>&1 &
race_delete_pid=$!
wait "$race_recover_pid" || true
wait "$race_stop_pid" || true
wait "$race_delete_pid" || true
if [ -d "$DETACH_CODEX_STATE_ROOT/sessions/$worker_crash_session" ]; then
  worker_crash_json="$(run_codex list --json | \
    grep -F "\"session_name\":\"$worker_crash_session\"")"
  [ "$(printf '%s' "$worker_crash_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" != \
    runtime_process_without_tmux ]
  if tmux -L "$SOCKET" has-session -t "=$worker_crash_session" 2>/dev/null && \
     [ "$(tmux -L "$SOCKET" display-message -p -t "=$worker_crash_session:" '#{pane_dead}')" = "0" ]; then
    run_codex stop "$worker_crash_name"
  fi
  run_codex delete --force "$worker_crash_name"
else
  ! tmux -L "$SOCKET" has-session -t "=$worker_crash_session" 2>/dev/null
fi

# If the provider itself crashes, the still-owned worker records an
# interrupted terminal state and leaves a deletable retained pane.
provider_crash_name=health-provider-crash
provider_crash_session=detach-codex-health-provider-crash
DETACH_CODEX_BIN="$FAKE_CODEX_LONG_BIN" \
  run_codex --name "$provider_crash_name" --detach -- 'provider crash health coverage'
provider_crash_meta="$DETACH_CODEX_STATE_ROOT/sessions/$provider_crash_session/meta.json"
provider_crash_pane="$(tmux -L "$SOCKET" show-options -qv \
  -t "=$provider_crash_session:" @detach_pane_id)"
provider_crash_worker="$("$STATE_HELPER" meta get "$provider_crash_meta" worker_pid)"
provider_crash_provider="$("$STATE_HELPER" meta get "$provider_crash_meta" provider_pid)"
provider_crash_pgid="$(wait_for_process_group_id "$provider_crash_worker")"
kill -KILL "$provider_crash_provider"
attempts=0
while { [ "$(tmux -L "$SOCKET" display-message -p -t "$provider_crash_pane" '#{pane_dead}')" != "1" ] || \
        [ -z "$("$STATE_HELPER" meta get "$provider_crash_meta" exit_status 2>/dev/null || true)" ]; } && \
      [ "$attempts" -lt 100 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ "$("$STATE_HELPER" meta get "$provider_crash_meta" status)" = interrupted ]
[ "$("$STATE_HELPER" meta get "$provider_crash_meta" exit_status)" = 137 ]
provider_crash_json="$(run_codex list --json | \
  grep -F "\"session_name\":\"$provider_crash_session\"")"
[ "$(printf '%s' "$provider_crash_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = interrupted ]
[ "$(printf '%s' "$provider_crash_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" = pane_exited ]
run_codex delete --force "$provider_crash_name"
kill -KILL -- "-$provider_crash_pgid" 2>/dev/null || true
wait_for_process_group_exit "$provider_crash_pgid"

# The destructive phase must repeat the ownership check under its lock. An
# unmanaged retained pane that appears after the outer check must survive.
mkdir -p "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION"
printf 'foreign sentinel\n' >"$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/sentinel"
foreign_pane="$(tmux -L "$SOCKET" new-session -d -P -F '#{pane_id}' -s "$SESSION" -n foreign)"
tmux -L "$SOCKET" set-option -q -w -t "$foreign_pane" remain-on-exit on
tmux -L "$SOCKET" send-keys -t "$foreign_pane" 'exit' Enter
wait_for_pane_dead "$foreign_pane"
collision_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$collision_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = "collision" ]
[ -z "$(printf '%s' "$collision_json" | "$STATE_HELPER" meta get /dev/stdin session_color)" ]
printf '%s' "$collision_json" | grep -F '"session_color":null' >/dev/null
if run_codex __delete_locked "$SESSION"; then
  printf 'locked delete unexpectedly removed an unmanaged tmux session\n' >&2
  exit 1
fi
tmux -L "$SOCKET" has-session -t "=$SESSION"
grep -Fx 'foreign sentinel' "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/sentinel" >/dev/null
tmux -L "$SOCKET" kill-session -t "=$SESSION"
rm -rf "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION"

# Abrupt tmux-server loss is treated like worker loss: while the frozen
# managed process group still exists, no action is authorized. Once those
# exact recorded processes are gone, the validated checkpoint is recoverable.
tmux_loss_name=health-tmux-loss
tmux_loss_session=detach-codex-health-tmux-loss
DETACH_CODEX_BIN="$FAKE_CODEX_LONG_BIN" \
  run_codex --name "$tmux_loss_name" --detach -- 'tmux server loss health coverage'
tmux_loss_meta="$DETACH_CODEX_STATE_ROOT/sessions/$tmux_loss_session/meta.json"
tmux_loss_checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$tmux_loss_session/checkpoint/rollout.jsonl"
attempts=0
while [ ! -s "$tmux_loss_checkpoint" ] && [ "$attempts" -lt 80 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -s "$tmux_loss_checkpoint" ]
tmux_loss_worker="$("$STATE_HELPER" meta get "$tmux_loss_meta" worker_pid)"
tmux_loss_provider="$("$STATE_HELPER" meta get "$tmux_loss_meta" provider_pid)"
tmux_loss_pgid="$(wait_for_process_group_id "$tmux_loss_worker")"
tmux_server_pid="$(tmux -L "$SOCKET" display-message -p '#{pid}')"
kill -STOP -- "-$tmux_loss_pgid"
kill -KILL "$tmux_server_pid"
attempts=0
while tmux -L "$SOCKET" has-session -t "=$tmux_loss_session" 2>/dev/null && \
      [ "$attempts" -lt 40 ]; do
  attempts=$((attempts + 1))
  sleep 0.05
done
kill -0 "$tmux_loss_worker"
kill -0 "$tmux_loss_provider"
tmux_loss_json="$(run_codex list --json | \
  grep -F "\"session_name\":\"$tmux_loss_session\"")"
[ "$(printf '%s' "$tmux_loss_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = hung ]
[ "$(printf '%s' "$tmux_loss_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" = \
  runtime_process_without_tmux ]
if run_codex stop "$tmux_loss_name" >/dev/null 2>&1 || \
   run_codex recover --detach "$tmux_loss_name" >/dev/null 2>&1 || \
   run_codex delete --force "$tmux_loss_name" >/dev/null 2>&1; then
  printf 'state-changing action unexpectedly accepted live runtime after tmux loss\n' >&2
  exit 1
fi
kill -KILL -- "-$tmux_loss_pgid"
wait_for_process_group_exit "$tmux_loss_pgid"
tmux_loss_json="$(run_codex list --json | \
  grep -F "\"session_name\":\"$tmux_loss_session\"")"
[ "$(printf '%s' "$tmux_loss_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = recoverable ]
[ "$(printf '%s' "$tmux_loss_json" | "$STATE_HELPER" meta get /dev/stdin reconcile_action)" = \
  mark_recoverable ]
run_codex delete --force "$tmux_loss_name"
fi

# Default-history allocation is provider-root independent. Claude exercises
# full preservation below in its integration; keep the Codex lane's mirror
# bounded to exact monotonic slot selection.
if codex_part_selected history; then
default_slug="$(basename "$ROOT" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '-' | \
  sed 's/^-*//; s/-*$//')"
[ -n "$default_slug" ] || default_slug=project
default_slug="${default_slug:0:24}"
default_digest="$(printf '%s' "$ROOT" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
default_session="detach-codex-$default_slug-$default_digest"
mkdir -p "$DETACH_CODEX_STATE_ROOT/sessions/$default_session"
[ "$(run_codex __allocate_default_session_name "$default_session")" = \
  "$default_session-r000000000001" ]
mkdir -p "$DETACH_CODEX_STATE_ROOT/sessions/$default_session-r000000000001"
[ "$(run_codex __allocate_default_session_name "$default_session")" = \
  "$default_session-r000000000002" ]
rmdir "$DETACH_CODEX_STATE_ROOT/sessions/$default_session-r000000000001"
rmdir "$DETACH_CODEX_STATE_ROOT/sessions/$default_session"

# Listing saved histories must remain below the app's five-second deadline as
# state grows. The second read uses cached summaries for one 300 KiB transcript
# per row. Count helper launches as a deterministic guard against restoring the
# former per-field subprocess fan-out, and retain a wall-clock ceiling.
list_scale_root="$TMP_ROOT/list-scale-state"
list_scale_output="$TMP_ROOT/list-scale.jsonl"
list_scale_invocations="$TMP_ROOT/list-scale-invocations.txt"
list_scale_wrapper="$TMP_ROOT/list-scale-detach-state"
list_scale_tmux_invocations="$TMP_ROOT/list-scale-tmux-invocations.txt"
list_scale_tmux_wrapper="$TMP_ROOT/list-scale-tmux"
list_scale_transcript="$TMP_ROOT/list-scale-transcript.jsonl"
list_scale_live_sessions=()
mkdir -p "$list_scale_root/sessions"
dd if=/dev/zero of="$list_scale_transcript" bs=1024 count=300 >/dev/null 2>&1
printf '\n%s\n' '{"payload":{"model":"gpt-scale"}}' >>"$list_scale_transcript"
list_scale_index=1
while [ "$list_scale_index" -le 25 ]; do
  list_scale_session="detach-codex-list-scale-$list_scale_index"
  list_scale_dir="$list_scale_root/sessions/$list_scale_session"
  mkdir -p "$list_scale_dir"
  "$STATE_HELPER" meta create "$list_scale_dir/meta.json" \
    --integer schema 1 \
    --string session_name "$list_scale_session" \
    --string project_dir "$ROOT" \
    --string status stopped \
    --string transcript_path "$list_scale_transcript"
  if [ "$list_scale_index" -le 3 ]; then
    tmux -L "$SOCKET" new-session -d -s "$list_scale_session" /bin/sleep 30
    tmux -L "$SOCKET" set-option -q -t "=$list_scale_session:" @detach 1
    tmux -L "$SOCKET" set-option -q -t "=$list_scale_session:" @detach_provider codex
    list_scale_live_sessions+=( "$list_scale_session" )
  fi
  list_scale_index=$((list_scale_index + 1))
done
printf '%s\n' \
  '#!/bin/bash' \
  'printf x\\n >>"$DETACH_LIST_SCALE_INVOCATIONS"' \
  'exec "$DETACH_LIST_SCALE_STATE_HELPER" "$@"' >"$list_scale_wrapper"
chmod 0755 "$list_scale_wrapper"
printf '%s\n' \
  '#!/bin/bash' \
  'printf x\\n >>"$DETACH_LIST_SCALE_TMUX_INVOCATIONS"' \
  'exec "$DETACH_LIST_SCALE_TMUX_HELPER" "$@"' >"$list_scale_tmux_wrapper"
chmod 0755 "$list_scale_tmux_wrapper"
SECONDS=0
DETACH_CODEX_STATE_ROOT="$list_scale_root" \
DETACH_STATE_BIN="$list_scale_wrapper" \
DETACH_LIST_SCALE_STATE_HELPER="$STATE_HELPER" \
DETACH_LIST_SCALE_INVOCATIONS="$list_scale_invocations" \
DETACH_POWER_BIN=/usr/bin/false \
DETACH_TMUX_BIN="$list_scale_tmux_wrapper" \
DETACH_LIST_SCALE_TMUX_HELPER="$TMUX_TEST_BIN" \
DETACH_LIST_SCALE_TMUX_INVOCATIONS="$list_scale_tmux_invocations" \
DETACH_TMUX_SOCKET_PATH="$SOCKET_PATH" \
  "$SCRIPT" codex list --json >"$list_scale_output"
list_scale_elapsed="$SECONDS"
[ "$(wc -l <"$list_scale_output" | tr -d '[:space:]')" = 25 ]
[ "$(grep -Fc '"model":"gpt-scale"' "$list_scale_output")" = 25 ]
[ "$(wc -l <"$list_scale_invocations" | tr -d '[:space:]')" -le 5 ] || {
  printf 'list restored per-field state helper fan-out\n' >&2
  exit 1
}
[ "$(wc -l <"$list_scale_tmux_invocations" | tr -d '[:space:]')" = 1 ] || {
  printf 'list did not use one batched tmux snapshot\n' >&2
  exit 1
}
[ "$(find "$list_scale_root/sessions" -name .transcript-summary-cache.json -type f | \
  wc -l | tr -d '[:space:]')" = 25 ]
[ "$list_scale_elapsed" -lt 5 ] || {
  printf 'cold 25-session list exceeded the app deadline: %ss\n' "$list_scale_elapsed" >&2
  exit 1
}
: >"$list_scale_invocations"
: >"$list_scale_tmux_invocations"
SECONDS=0
DETACH_CODEX_STATE_ROOT="$list_scale_root" \
DETACH_STATE_BIN="$list_scale_wrapper" \
DETACH_LIST_SCALE_STATE_HELPER="$STATE_HELPER" \
DETACH_LIST_SCALE_INVOCATIONS="$list_scale_invocations" \
DETACH_POWER_BIN=/usr/bin/false \
DETACH_TMUX_BIN="$list_scale_tmux_wrapper" \
DETACH_LIST_SCALE_TMUX_HELPER="$TMUX_TEST_BIN" \
DETACH_LIST_SCALE_TMUX_INVOCATIONS="$list_scale_tmux_invocations" \
DETACH_TMUX_SOCKET_PATH="$SOCKET_PATH" \
  "$SCRIPT" codex list --json >"$list_scale_output"
list_scale_hot_elapsed="$SECONDS"
[ "$(wc -l <"$list_scale_output" | tr -d '[:space:]')" = 25 ]
[ "$(wc -l <"$list_scale_invocations" | tr -d '[:space:]')" -le 5 ]
[ "$(wc -l <"$list_scale_tmux_invocations" | tr -d '[:space:]')" = 1 ]
[ "$list_scale_hot_elapsed" -lt 5 ] || {
  printf 'cached 25-session list exceeded the app deadline: %ss\n' \
    "$list_scale_hot_elapsed" >&2
  exit 1
}
for list_scale_session in "${list_scale_live_sessions[@]}"; do
  tmux -L "$SOCKET" kill-session -t "=$list_scale_session"
done

# Public read paths must reject state-root redirection before creating or
# traversing sessions in an unrelated directory.
unsafe_provider_link="$TMP_ROOT/unsafe-provider-link"
unsafe_provider_target="$TMP_ROOT/unsafe-provider-target"
mkdir -p "$unsafe_provider_target"
printf 'do not touch\n' >"$unsafe_provider_target/sentinel"
ln -s "$unsafe_provider_target" "$unsafe_provider_link"
if DETACH_CODEX_STATE_ROOT="$unsafe_provider_link" run_codex list --json >/dev/null 2>&1; then
  printf 'list unexpectedly accepted a symlinked provider state root\n' >&2
  exit 1
fi
grep -Fx 'do not touch' "$unsafe_provider_target/sentinel" >/dev/null
[ ! -e "$unsafe_provider_target/sessions" ]

unsafe_list_state="$TMP_ROOT/unsafe-list-state"
unsafe_list_target="$TMP_ROOT/unsafe-list-target"
mkdir -p "$unsafe_list_state" "$unsafe_list_target"
printf 'do not traverse\n' >"$unsafe_list_target/sentinel"
ln -s "$unsafe_list_target" "$unsafe_list_state/sessions"
if DETACH_CODEX_STATE_ROOT="$unsafe_list_state" run_codex list --json >/dev/null 2>&1; then
  printf 'list unexpectedly accepted a symlinked sessions root\n' >&2
  exit 1
fi
grep -Fx 'do not traverse' "$unsafe_list_target/sentinel" >/dev/null

# A symlinked sessions root must never redirect locked deletion into another
# directory, even when the internal command is called directly.
unsafe_state="$TMP_ROOT/unsafe-delete-state"
unsafe_target="$TMP_ROOT/unsafe-delete-target"
mkdir -p "$unsafe_state" "$unsafe_target/$SESSION"
printf 'do not delete\n' >"$unsafe_target/$SESSION/sentinel"
ln -s "$unsafe_target" "$unsafe_state/sessions"
if DETACH_CODEX_STATE_ROOT="$unsafe_state" run_codex __delete_locked "$SESSION"; then
  printf 'locked delete unexpectedly accepted a symlinked sessions root\n' >&2
  exit 1
fi
grep -Fx 'do not delete' "$unsafe_target/$SESSION/sentinel" >/dev/null
[ ! -e "$FAKE_GIT_MARKER" ]
fi

printf 'Codex detach integration tests passed (%s)\n' "$CODEX_TEST_PART"
