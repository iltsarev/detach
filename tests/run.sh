#!/bin/bash

set -eu
set -o pipefail

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

cleanup() {
  if [ "${DETACH_CODEX_TEST_KEEP:-0}" = "1" ]; then
    printf 'Preserved test state: %s (socket=%s, tmux_tmpdir=%s)\n' "$TMP_ROOT" "$SOCKET_PATH" "$TMUX_TMPDIR" >&2
  else
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    tmux -L "$CWD_SOCKET" kill-server >/dev/null 2>&1 || true
    tmux -L "$OUTER_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMUX_TMPDIR"
    rm -rf "$TEST_INSTALL_STATE_ROOT"
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

export DETACH_STATE_ROOT="$TMP_ROOT/detach-state"
export DETACH_STATE_BIN="$STATE_HELPER"
FAKE_POWER_BIN="$TMP_ROOT/fake-detach-power"
FAKE_ENV_BIN="$TMP_ROOT/fake-env"
export FAKE_ENV_ARGS_FILE="$TMP_ROOT/env-args.txt"
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
# influence the absolute Detach socket or make attach semantics switch clients.
unset TMUX TMUX_PANE DETACH_CORE_ENTRYPOINT DETACH_PROVIDER DETACH_PROGRAM
unset DETACH_TMUX_SOCKET
mkdir -p "$TMUX_TMPDIR" "$TMUX_SOCKET_ROOT" "$CODEX_HOME"
printf '%s\n' 'set -g base-index 1' 'set -g pane-base-index 1' >"$DETACH_TMUX_CONFIG"
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request"]' >"$DETACH_CODEX_REQUIREMENTS_FILE"

bash -n "$SCRIPT"
bash -n "$ROOT/bin/detach-core"
[ "$($SCRIPT __version)" = "$(<"$ROOT/VERSION")" ]

if FAKE_POWER_STATE=unavailable run_codex --name power-preflight --detach -- \
  'must not start without power protection' >/dev/null 2>&1; then
  printf 'start unexpectedly passed an unavailable power preflight\n' >&2
  exit 1
fi
! tmux -L "$SOCKET" has-session -t '=detach-codex-power-preflight' 2>/dev/null

readiness_output=""
if readiness_output="$(FAKE_POWER_FAIL_RUN=1 \
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
if FAKE_POWER_STATE=low_battery run_codex --name power-preflight --detach -- \
  'must not start at low battery' >/dev/null 2>&1; then
  printf 'start unexpectedly passed the low-battery power preflight\n' >&2
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

# A repository marker is enough to canonicalize a nested project. Detach must
# not execute ambient git (which can prompt for Xcode Command Line Tools on a
# clean Mac) either while resolving the project root or while checkpointing.
marker_repository="$TMP_ROOT/marker-repository"
marker_repository_nested="$marker_repository/sources/nested"
mkdir -p "$marker_repository/.git" "$marker_repository_nested"
(cd "$marker_repository_nested" && \
  FAKE_CODEX_INIT_DELAY=0 FAKE_CODEX_SLEEP=20 FAKE_CODEX_EXIT=0 \
  "$SCRIPT" codex --name marker-repository --detach -- 'marker repository coverage')
marker_session="detach-codex-marker-repository"
marker_meta="$DETACH_CODEX_STATE_ROOT/sessions/$marker_session/meta.json"
marker_repository_real="$(cd -P "$marker_repository" && pwd)"
[ "$("$STATE_HELPER" meta get "$marker_meta" project_dir)" = "$marker_repository_real" ]
marker_checkpoint="$DETACH_CODEX_STATE_ROOT/sessions/$marker_session/checkpoint/worktree-status.txt"
attempts=0
while [ ! -f "$marker_checkpoint" ] && [ "$attempts" -lt 30 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
[ -f "$marker_checkpoint" ]
grep -Fx "repository-root: $marker_repository_real" "$marker_checkpoint" >/dev/null
[ ! -e "$FAKE_GIT_MARKER" ]
run_codex stop marker-repository
run_codex delete --force marker-repository

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
export FAKE_CODEX_SLEEP=12
run_codex --name integration --detach -- "$literal_prompt"

wait_for_tmux_option "$SESSION" @detach_status running
tmux -L "$SOCKET" has-session -t "=$SESSION"
"$DETACH" list | grep -F 'codex' | grep -F "$SESSION" >/dev/null
mkdir -p "$TMP_ROOT/unrelated-tmux-tmpdir"
TMUX_TMPDIR="$TMP_ROOT/unrelated-tmux-tmpdir" \
  "$DETACH" list | grep -F 'codex' | grep -F "$SESSION" >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach)" = "1" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_provider)" = "codex" ]
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
# The creator CLI has already exited. The tmux server and worker must remain
# alive without an attached client (the same lifecycle as closing Terminal or
# Detach.app after starting a session).
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "0" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_status)" = "running" ]
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
[ "$(tmux -L "$SOCKET" show-options -sqv copy-command)" = "/usr/bin/pbcopy" ]
tmux -L "$SOCKET" list-keys -T copy-mode | grep -F 'WheelUpPane' | \
  grep -F 'scroll-up' >/dev/null
tmux -L "$SOCKET" list-keys -T copy-mode-vi | grep -F 'MouseDragEnd1Pane' | \
  grep -F 'copy-pipe-and-cancel' >/dev/null
grep -Fx -- 'run' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--session' "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- "$SESSION" "$FAKE_POWER_ARGS_FILE" >/dev/null
grep -Fx -- '--run-token' "$FAKE_POWER_ARGS_FILE" >/dev/null
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_cli_version)" = "$installed_version" ]
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_core_path)" = "$installed_core" ]
first_worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
first_worker_pgid="$(ps -o pgid= -p "$first_worker_pid" | tr -d '[:space:]')"
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
"$STATE_HELPER" meta patch "$health_meta" --run-token "$run_token" \
  --integer worker_heartbeat_epoch 1 \
  --string worker_heartbeat_at '1970-01-01T00:00:01Z'
tmux -L "$SOCKET" set-option -q -t "=$SESSION:" @detach_heartbeat_epoch 1
health_json="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = running ]
[ "$(printf '%s' "$health_json" | "$STATE_HELPER" meta get /dev/stdin health_reason)" = heartbeat_stale ]

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
    grep -Fx "$SESSION" >/dev/null && [ "$attempts" -lt 50 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
tmux -L "$SOCKET" list-clients -F '#{client_session}' | grep -Fx "$SESSION" >/dev/null
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
"$DETACH" config tmux-mouse on
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" mouse)" = "on" ]

run_codex logs integration | grep -F 'fake Codex finished' >/dev/null

stopped_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
run_codex stop integration
! tmux -L "$SOCKET" has-session -t "=$SESSION" 2>/dev/null
[ "$("$STATE_HELPER" meta get "$meta" status)" = "stopped" ]
[ -n "$("$STATE_HELPER" meta get "$meta" stopped_at)" ]
grep -Fx "release --session $SESSION --run-token $stopped_run_token" \
  "$FAKE_POWER_RELEASES_FILE" >/dev/null

# Simulate losing the primary metadata in a power failure. Auto-recovery must
# use the checkpoint metadata and resume the exact saved UUID.
"$STATE_HELPER" meta patch "$checkpoint/meta.json" --string status running
rm -f "$meta"

export FAKE_CODEX_SLEEP=20
export FAKE_CODEX_EXIT=0
export FAKE_CODEX_FOREIGN_FIRST=0
run_codex recover --detach integration
wait_for_file_text "$FAKE_CODEX_ARGS_FILE" resume
grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
grep -Fx "$expected_id" "$FAKE_CODEX_ARGS_FILE" >/dev/null
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
worker_pid="$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_pid}')"
worker_pgid="$(ps -o pgid= -p "$worker_pid" | tr -d '[:space:]')"

run_codex stop integration
! kill -0 "$worker_pid" 2>/dev/null
wait_for_process_group_exit "$worker_pgid"
[ "$("$STATE_HELPER" meta get "$meta" status)" = "stopped" ]
[ -n "$("$STATE_HELPER" meta get "$meta" stopped_at)" ]

# A fresh run with the same name must never inherit the previous run's UUID.
[ -s "$checkpoint/rollout.jsonl" ]
export FAKE_CODEX_INIT_DELAY=5
printf '%s\n' 'allowed_approval_policies = ["untrusted", "on-request", "never"]' >"$DETACH_CODEX_REQUIREMENTS_FILE"
run_codex --name integration --detach -- 'start a new thread'
wait_for_file_text "$FAKE_CODEX_ARGS_FILE" 'start a new thread'
[ "$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_cli_version)" = "$upgraded_version" ]
[ "$(grep -Fxc -- '--ask-for-approval' "$FAKE_CODEX_ARGS_FILE")" = "1" ]
[ "$(grep -Fxc -- 'never' "$FAKE_CODEX_ARGS_FILE")" = "1" ]
[ ! -e "$checkpoint/rollout.jsonl" ]
[ ! -e "$checkpoint/meta.json" ]
fresh_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
if run_codex --name integration --detach -- 'must not replace a running task'; then
  printf 'new default start unexpectedly replaced a running task\n' >&2
  exit 1
fi
[ "$("$STATE_HELPER" meta get "$meta" run_token)" = "$fresh_run_token" ]
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
wait_for_tmux_option "$SESSION" @detach_status completed
grep -Fx 'resume' "$FAKE_CODEX_ARGS_FILE" >/dev/null
grep -Fx "$expected_id" "$FAKE_CODEX_ARGS_FILE" >/dev/null
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$expected_id" ]
completed_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
pane_id="$(tmux -L "$SOCKET" show-options -qv -t "=$SESSION:" @detach_pane_id)"
[ "$(tmux -L "$SOCKET" display-message -p -t "$pane_id" '#{pane_dead}')" = "1" ]
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
[ -z "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin exit_status)" ]
[[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin session_color)" =~ ^#[[:xdigit:]]{6}$ ]]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin power_protection_state)" = "protected" ]
printf '%s' "$json_line" | grep -F '"model":' | grep -F '"context_used_tokens":' | \
  grep -F '"context_window":' >/dev/null
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "working" ]
turn_rollout="$("$STATE_HELPER" meta get "$meta" transcript_path)"
turn_id="$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)"
[ -n "$turn_id" ]
printf '{"timestamp":"2099-01-01T00:10:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"%s"}}\n' \
  "$turn_id" >>"$turn_rollout"
json_line="$(run_codex list --json | grep -F "\"session_name\":\"$SESSION\"")"
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin effective_status)" = "running" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_state)" = "waiting" ]
[ "$(printf '%s' "$json_line" | "$STATE_HELPER" meta get /dev/stdin agent_turn_id)" = "$turn_id" ]

# Codex /clear opens a successor thread inside the same provider process.
# Discovery must rebind identity, turn state, and checkpoints to the newest
# run-owned thread, refuse a creation-time tie, ignore subagent threads, and
# consume superseded ids so the next switch is unambiguous again.
switch_project_dir="$("$STATE_HELPER" meta get "$meta" project_dir)"
switch_run_token="$("$STATE_HELPER" meta get "$meta" run_token)"
pre_switch_id="$("$STATE_HELPER" meta get "$meta" codex_session_id)"
[ -n "$pre_switch_id" ]
switch_base_ms="$(($(date '+%s') * 1000))"
switch_thread() {
  local switch_id="$1"
  local switch_ms="$2"
  local switch_source="$3"
  local switch_turn="$4"
  local switch_rollout="$CODEX_HOME/sessions/2099/01/01/rollout-test-$switch_id.jsonl"

  printf '{"timestamp":"2099-01-01T00:20:00Z","type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"detach_%s"}}\n' \
    "$switch_id" "$switch_project_dir" "$switch_run_token" >"$switch_rollout"
  printf '{"timestamp":"2099-01-01T00:20:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"%s"}}\n' \
    "$switch_turn" >>"$switch_rollout"
  sqlite3 "$CODEX_HOME/state_5.sqlite" \
    "INSERT OR REPLACE INTO threads (id, rollout_path, created_at_ms, updated_at_ms, source, thread_source, cwd) \
     VALUES ('$switch_id', '${switch_rollout//\'/\'\'}', $switch_ms, $switch_ms, 'cli', '$switch_source', '${switch_project_dir//\'/\'\'}');"
}
switch_a="22222222-2222-7222-8222-222222222222"
switch_b="33333333-3333-7333-8333-333333333333"
switch_subagent="44444444-4444-7444-8444-444444444444"
switch_thread "$switch_a" "$((switch_base_ms + 1000))" user clear-turn-a
switch_thread "$switch_b" "$((switch_base_ms + 1000))" user clear-turn-b
switch_thread "$switch_subagent" "$((switch_base_ms + 5000))" subagent clear-turn-subagent
wait_for_file_text "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" \
  'ambiguous Codex thread switch'
[ "$("$STATE_HELPER" meta get "$meta" codex_session_id)" = "$pre_switch_id" ]
grep -F 'ambiguous Codex thread switch' \
  "$DETACH_CODEX_STATE_ROOT/sessions/$SESSION/checkpoint.log" >/dev/null
sqlite3 "$CODEX_HOME/state_5.sqlite" "DELETE FROM threads WHERE id = '$switch_b';"
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
switch_thread "$switch_c" "$((switch_base_ms + 10000))" user clear-turn-c
switch_thread "$switch_d" "$((switch_base_ms + 11000))" user clear-turn-d
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

# delete refuses a live session and removes a stopped one.
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
  'touch "$1"; sleep 1; test -d "$2"' sh \
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

# Killing the worker can leave its provider alive in a retained pane. Detach
# must expose that uncertainty, refuse every state-changing action, and keep
# the session out of both cleanup plans until the whole managed process group
# is gone.
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
worker_crash_pane="$(tmux -L "$SOCKET" show-options -qv \
  -t "=$worker_crash_session:" @detach_pane_id)"
worker_crash_pid="$("$STATE_HELPER" meta get "$worker_crash_meta" worker_pid)"
worker_crash_provider_pid="$("$STATE_HELPER" meta get "$worker_crash_meta" provider_pid)"
worker_crash_pgid="$(ps -o pgid= -p "$worker_crash_pid" | tr -d '[:space:]')"
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
provider_crash_pgid="$(ps -o pgid= -p "$provider_crash_worker" | tr -d '[:space:]')"
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
tmux_loss_pgid="$(ps -o pgid= -p "$tmux_loss_worker" | tr -d '[:space:]')"
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

printf 'Codex detach integration tests passed\n'
