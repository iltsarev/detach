#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${DETACH_TEST_APP:-$ROOT/app/build/Detach.app}"
VALIDATE_ONLY="${DETACH_UI_E2E_VALIDATE_ONLY:-0}"
KEEP="${DETACH_UI_E2E_KEEP:-0}"
ARTIFACT_DIR="${DETACH_UI_E2E_ARTIFACT_DIR:-}"
COVERAGE_BINARY="${DETACH_UI_E2E_COVERAGE_BINARY:-}"
TEST_ROOT=""
APP_PID=""

approved_invocation() {
  case "$1" in
    'list --json'|\
    'watch --json'|\
    'codex logs --ansi detach-codex-ui-running'|\
    'codex attach --terminal-features sync detach-codex-ui-running'|\
    'codex logs --ansi detach-codex-ui-stopped'|\
    'codex logs --ansi detach-codex-ui-recoverable'|\
    'codex recover --detach detach-codex-ui-recoverable'|\
    'codex attach --terminal-features sync detach-codex-ui-recoverable'|\
    'claude logs --ansi detach-claude-ui-completed'|\
    'resume --detach a9f58f1d-1234-5678-9abc-def012342ed9'|\
    'claude attach --terminal-features sync detach-claude-ui-completed'|\
    'claude --detach'|\
    'codex --detach'|\
    'codex logs --ansi detach-codex-ui-quick'|\
    'codex attach --terminal-features sync detach-codex-ui-quick'|\
    'claude logs --ansi detach-claude-ui-new'|\
    'claude attach --terminal-features sync detach-claude-ui-new'|\
    client\ switch\ --pid\ *\ --from\ *\ --to\ *\ --provider\ codex|\
    client\ switch\ --pid\ *\ --from\ *\ --to\ *\ --provider\ claude|\
    'codex stop detach-codex-ui-running'|\
    'codex delete --force detach-codex-ui-stopped'|\
    'storage --json'|\
    'config tmux-style'|\
    'config tmux-extended-keys') return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${DETACH_UI_E2E_VALIDATE_INVOCATION+x}" = x ]; then
  approved_invocation "$DETACH_UI_E2E_VALIDATE_INVOCATION"
  exit
fi

preserve_failure_diagnostics() {
  local status="$1" source destination
  [ "$status" -ne 0 ] && [ -n "$ARTIFACT_DIR" ] && [ -n "$TEST_ROOT" ] || return 0
  case "$ARTIFACT_DIR" in /*) ;; *) printf 'UI e2e artifact directory must be absolute\n' >&2; return 0 ;; esac
  [ ! -e "$ARTIFACT_DIR" ] || [ -d "$ARTIFACT_DIR" ] && [ ! -L "$ARTIFACT_DIR" ] || {
    printf 'UI e2e artifact directory is unsafe\n' >&2
    return 0
  }
  mkdir -p "$ARTIFACT_DIR"
  chmod 0700 "$ARTIFACT_DIR"
  for source in "$TEST_ROOT"/app-*.log "$TEST_ROOT"/result-*.json \
      "$FAKE_DIR/invocations.log"; do
    [ -f "$source" ] && [ ! -L "$source" ] || continue
    destination="$ARTIFACT_DIR/$(basename "$source")"
    install -m 0600 "$source" "$destination"
  done
  {
    printf 'schema\t1\n'
    printf 'exit_status\t%s\n' "$status"
    printf 'result_present\t%s\n' "$([ -f "$RESULT" ] && printf true || printf false)"
    printf 'app_log_bytes\t%s\n' "$([ -f "$APP_LOG" ] && wc -c <"$APP_LOG" | tr -d ' ' || printf 0)"
    printf 'invocations_present\t%s\n' "$([ -f "$FAKE_DIR/invocations.log" ] && printf true || printf false)"
  } >"$ARTIFACT_DIR/diagnostics.tsv"
  chmod 0600 "$ARTIFACT_DIR/diagnostics.tsv"
  printf 'UI e2e diagnostics preserved at %s\n' "$ARTIFACT_DIR" >&2
}

cleanup() {
  local status="${1:-0}"
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  preserve_failure_diagnostics "$status"
  if [ "$KEEP" = 1 ] && [ -n "$TEST_ROOT" ]; then
    printf 'UI e2e fixture kept at %s\n' "$TEST_ROOT" >&2
    return
  fi
  case "$TEST_ROOT" in
    /private/tmp/detach-ui-e2e.*) rm -rf "$TEST_ROOT" ;;
  esac
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM HUP

validate_fresh_app() {
  local app="$1" marker binary
  marker="$app/Contents/Resources/BUILD_MARKER"
  binary="$app/Contents/MacOS/Detach"
  [ -x "$binary" ] || { printf 'UI e2e: Detach executable is missing\n' >&2; return 1; }
  [ -f "$marker" ] && [ ! -L "$marker" ] || {
    printf 'UI e2e: build marker is missing or unsafe\n' >&2
    return 1
  }
  [[ "$(<"$marker")" =~ ^detach-app-build:[0-9A-F-]{36}$ ]] || {
    printf 'UI e2e: build marker is malformed\n' >&2
    return 1
  }
  otool -l "$binary" | awk '
    $1 == "segname" && $2 == "__TEXT" { in_text = 1; next }
    in_text && $1 == "sectname" && $2 == "__detach_build" { found = 1 }
    $1 == "segname" && $2 != "__TEXT" { in_text = 0 }
    END { exit found ? 0 : 1 }
  ' || {
    printf 'UI e2e: executable has no build-marker section\n' >&2
    return 1
  }
  strings "$binary" | grep -Fx "$(<"$marker")" >/dev/null || {
    printf 'UI e2e: executable and bundle build markers differ\n' >&2
    return 1
  }
}

case "$VALIDATE_ONLY:$KEEP" in 0:0|0:1|1:0|1:1) ;;
  *) printf 'invalid UI e2e boolean option\n' >&2; exit 2 ;;
esac
validate_fresh_app "$SOURCE_APP"
if [ -n "$COVERAGE_BINARY" ]; then
  [ -f "$COVERAGE_BINARY" ] && [ ! -L "$COVERAGE_BINARY" ] && \
    [ -x "$COVERAGE_BINARY" ] || {
    printf 'UI e2e: coverage executable is missing or unsafe\n' >&2
    exit 2
  }
  [ "$(lipo -archs "$COVERAGE_BINARY")" = arm64 ] || {
    printf 'UI e2e: coverage executable must be arm64-only\n' >&2
    exit 2
  }
  otool -l "$COVERAGE_BINARY" | grep -F '__llvm_covmap' >/dev/null || {
    printf 'UI e2e: coverage executable has no coverage map\n' >&2
    exit 2
  }
fi

[ "$VALIDATE_ONLY" = 0 ] || exit 0

TEST_ROOT="$(mktemp -d /private/tmp/detach-ui-e2e.XXXXXX)"
TEST_APP="$TEST_ROOT/Detach-UI-E2E.app"
TEST_HOME="$TEST_ROOT/home"
FAKE_DIR="$TEST_ROOT/fake"
FAKE_CLI="$FAKE_DIR/detach"
FIXTURE_STATE="$FAKE_DIR/state"
RESULT="$TEST_ROOT/result.json"
BREACH="$TEST_ROOT/production-cli-breach"
APP_LOG="$TEST_ROOT/app.log"
IDENTIFIER="dev.tsarev.detach.ui-e2e.$$"
UI_E2E_DEADLINE=$((SECONDS + 50))

mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/Library/Preferences" \
  "$TEST_ROOT/state" "$TEST_ROOT/power" "$TEST_ROOT/project" "$FAKE_DIR"
cp -cR "$SOURCE_APP" "$TEST_APP"

if [ -n "$COVERAGE_BINARY" ]; then
  install -m 0755 "$COVERAGE_BINARY" "$TEST_APP/Contents/MacOS/Detach"
  if ! otool -l "$TEST_APP/Contents/MacOS/Detach" | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" && $2 == "@executable_path/../Frameworks" { found = 1 }
      in_rpath && $1 == "path" { in_rpath = 0 }
      END { exit found ? 0 : 1 }
    '; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' \
      "$TEST_APP/Contents/MacOS/Detach"
  fi
fi

# The test copy cannot install, repair, unregister, power-protect, or invoke a
# bundled runtime even if the app regresses. Only the main UI executable and
# its UI framework/resources remain.
rm -rf "$TEST_APP/Contents/Resources/DetachCLI" "$TEST_APP/Contents/Library"
rm -f "$TEST_APP/Contents/MacOS/DetachWatchdog" \
  "$TEST_APP/Contents/MacOS/DetachPowerHelper" \
  "$TEST_APP/Contents/MacOS/detach-power" \
  "$TEST_APP/Contents/MacOS/detach-state" \
  "$TEST_APP/Contents/MacOS/tmux"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $IDENTIFIER" \
  "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' \
  "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Detach UI E2E' \
  "$TEST_APP/Contents/Info.plist"
codesign --force --deep --sign - "$TEST_APP" >/dev/null
codesign --verify --strict "$TEST_APP"

install -m 0755 "$ROOT/tests/fake-ui-cli" "$FAKE_CLI"
printf 'sessions\n' >"$FIXTURE_STATE"

# If app startup ever falls back to its normal GUI default before accepting
# the injected CLI, it reaches this private trap instead of the user's
# installed Detach. The smoke fails on the marker below.
printf '#!/bin/bash\nprintf breach >%q\nexit 91\n' "$BREACH" \
  >"$TEST_HOME/.local/bin/detach"
chmod 0755 "$TEST_HOME/.local/bin/detach"

"$ROOT/scripts/quality-scenarios" event begin \
  SC-UI-DASHBOARD \
  SC-UI-SESSION-DETAIL \
  SC-UI-SESSION-DELETE \
  SC-UI-SESSION-STOP \
  SC-UI-NEW-SESSION \
  SC-UI-EMPTY \
  SC-UI-FOCUS \
  SC-UI-FAILURE \
  SC-UI-ONBOARD-FIRST-RUN \
  SC-UI-ONBOARD-PROVIDER \
  SC-UI-ONBOARD-APPROVAL \
  SC-UI-SETTINGS

run_app_scenario() {
  local scenario="$1" fixture="$2" scenario_budget="$3"
  local app_status check_index=0 actual check scenario_deadline driver_budget pass
  local passed_scenarios=()
  local scenario_started="$SECONDS"
  shift 3
  scenario_deadline=$((SECONDS + scenario_budget))
  driver_budget=$((scenario_budget - 3))
  [ "$driver_budget" -ge 1 ] || {
    printf 'UI e2e: %s process budget leaves no driver deadline\n' "$scenario" >&2
    exit 2
  }
  RESULT="$TEST_ROOT/result-$scenario.json"
  APP_LOG="$TEST_ROOT/app-$scenario.log"
  printf '%s\n' "$fixture" >"$FIXTURE_STATE"
  if [ "$scenario" = onboarding-first-run ]; then
    printf '{"schema":1,"state":"ok","power_state":"protected","checked_at":"%s","thermal_state":"nominal","thermal_safety_active":false,"exit_status":0}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >"$TEST_ROOT/power/watchdog-status.json"
  fi

  HOME="$TEST_HOME" \
  CFFIXED_USER_HOME="$TEST_HOME" \
  XDG_STATE_HOME="$TEST_ROOT/state" \
  DETACH_STATE_ROOT="$TEST_ROOT/state/detach" \
  DETACH_POWER_STATE_ROOT="$TEST_ROOT/power" \
  DETACH_UI_E2E_ROOT="$TEST_ROOT" \
  DETACH_UI_E2E_CLI="$FAKE_CLI" \
  DETACH_UI_E2E_RESULT="$RESULT" \
  DETACH_UI_E2E_FIXTURE_STATE="$FIXTURE_STATE" \
  DETACH_UI_E2E_SCENARIO="$scenario" \
  DETACH_UI_E2E_DRIVER_BUDGET="$driver_budget" \
  LANG=en_US.UTF-8 \
  LC_ALL=en_US.UTF-8 \
    "$TEST_APP/Contents/MacOS/Detach" >"$APP_LOG" 2>&1 &
  APP_PID=$!

  while [ "$SECONDS" -lt "$scenario_deadline" ] \
      && [ "$SECONDS" -lt "$UI_E2E_DEADLINE" ]; do
    [ ! -f "$RESULT" ] || break
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 0.05
  done
  if [ ! -f "$RESULT" ]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    set +e
    wait "$APP_PID"
    app_status=$?
    set -e
    APP_PID=""
    printf 'UI e2e: %s produced no result within its %ss budget (status %s)\n' \
      "$scenario" "$scenario_budget" "$app_status" >&2
    sed -n '1,240p' "$APP_LOG" >&2
    exit 1
  fi
  for _ in $(seq 1 10); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    [ "$SECONDS" -lt "$UI_E2E_DEADLINE" ] || break
    sleep 0.05
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
    printf 'UI e2e: %s did not terminate after writing its result\n' \
      "$scenario" >&2
    exit 1
  fi
  set +e
  wait "$APP_PID"
  app_status=$?
  set -e
  APP_PID=""
  [ "$app_status" -eq 0 ] || {
    printf 'UI e2e: %s exited with status %s\n' "$scenario" "$app_status" >&2
    sed -n '1,240p' "$APP_LOG" >&2
    exit 1
  }
  [ ! -e "$BREACH" ] || {
    printf 'UI e2e: app attempted to use its normal installed-CLI path\n' >&2
    exit 1
  }
  [ "$(plutil -extract schema raw -o - "$RESULT")" = 1 ]
  if [ "$(plutil -extract passed raw -o - "$RESULT")" != true ]; then
    printf 'UI e2e %s failed: %s\n' "$scenario" \
      "$(plutil -extract error raw -o - "$RESULT" 2>/dev/null || true)" >&2
    plutil -p "$RESULT" >&2
    sed -n '1,240p' "$APP_LOG" >&2
    exit 1
  fi

  for check in "$@"; do
    actual="$(plutil -extract "checks.$check_index" raw -o - "$RESULT")"
    [ "$actual" = "$check" ] || {
      printf 'UI e2e %s: check %s is %s, expected %s\n' \
        "$scenario" "$check_index" "$actual" "$check" >&2
      exit 1
    }
    case "$check" in
      background-app-starts-without-focus|disconnected-stop-blocks-action|\
      finished-selection-clears-scrollbar|session-uuid-copies-from-text-side|\
      live-session-hosts-attach-client|\
      session-switch-keeps-terminal-layout-stable|\
      live-terminal-renders-on-demand|\
      live-terminal-routes-control-v|\
      live-session-switch-reuses-synchronized-client|\
      non-live-session-switch-uses-warm-cache|\
      session-title-survives-narrow-window-and-large-text|\
      recover-and-reconnect-run-in-app-with-terminal-fallback|\
      resume-runs-in-app-with-terminal-fallback|\
      session-shortcut-selects-assigned-session|\
      settings-text-growth-stays-on-screen|\
      settings-window-stays-on-screen|\
      settings-system-reveals-storage-and-installation|\
      new-session-advanced-keeps-top-edge|\
      new-session-starts-without-outer-terminal|\
      new-session-start-opens-embedded-terminal) ;;
      dashboard-accessible) pass=SC-UI-DASHBOARD ;;
      sidebar-shortcut-guide-visible) ;;
      sidebar-selects-completed-session) ;;
      bulk-delete-reaches-fake-cli) pass=SC-UI-SESSION-DELETE ;;
      session-signals-stay-distinct) pass=SC-UI-SESSION-DETAIL ;;
      safe-action-reaches-fake-cli) pass=SC-UI-SESSION-STOP ;;
      new-session-sheet-semantics) pass=SC-UI-NEW-SESSION ;;
      new-session-command-opens-sheet) ;;
      empty-dashboard-state) pass=SC-UI-EMPTY ;;
      installed-app-focus-restored) pass=SC-UI-FOCUS ;;
      actionable-failure-presentation) pass=SC-UI-FAILURE ;;
      onboarding-first-run-completes) pass=SC-UI-ONBOARD-FIRST-RUN ;;
      onboarding-detects-provider) pass=SC-UI-ONBOARD-PROVIDER ;;
      onboarding-explains-approval) pass=SC-UI-ONBOARD-APPROVAL ;;
      settings-change-persists) pass=SC-UI-SETTINGS ;;
      settings-session-defaults-visible) ;;
      settings-quick-chat-provider-persists) ;;
      settings-quick-chat-folder-panel) ;;
      quick-chat-command-starts-session) ;;
      session-shortcut-reopens-closed-main-window) ;;
      *) printf 'UI e2e: unowned check: %s\n' "$check" >&2; exit 1 ;;
    esac
    if [ -n "${pass:-}" ]; then
      passed_scenarios+=("$pass")
      pass=""
    fi
    check_index=$((check_index + 1))
  done
  if [ "${#passed_scenarios[@]}" -gt 0 ]; then
    "$ROOT/scripts/quality-scenarios" event pass "${passed_scenarios[@]}"
  fi
  printf 'UI e2e: %s passed in %ss\n' "$scenario" "$((SECONDS - scenario_started))"
}

run_app_scenario main sessions 32 \
  background-app-starts-without-focus \
  dashboard-accessible \
  sidebar-shortcut-guide-visible \
  non-live-session-switch-uses-warm-cache \
  session-title-survives-narrow-window-and-large-text \
  recover-and-reconnect-run-in-app-with-terminal-fallback \
  sidebar-selects-completed-session \
  session-uuid-copies-from-text-side \
  resume-runs-in-app-with-terminal-fallback \
  session-shortcut-selects-assigned-session \
  live-session-hosts-attach-client \
  session-switch-keeps-terminal-layout-stable \
  live-terminal-renders-on-demand \
  live-terminal-routes-control-v \
  live-session-switch-reuses-synchronized-client \
  session-signals-stay-distinct \
  disconnected-stop-blocks-action \
  safe-action-reaches-fake-cli \
  finished-selection-clears-scrollbar \
  bulk-delete-reaches-fake-cli \
  new-session-starts-without-outer-terminal \
  new-session-advanced-keeps-top-edge \
  new-session-sheet-semantics \
  new-session-command-opens-sheet \
  new-session-start-opens-embedded-terminal \
  empty-dashboard-state \
  actionable-failure-presentation \
  settings-change-persists \
  settings-session-defaults-visible \
  settings-quick-chat-provider-persists \
  settings-quick-chat-folder-panel \
  settings-text-growth-stays-on-screen \
  settings-window-stays-on-screen \
  settings-system-reveals-storage-and-installation \
  quick-chat-command-starts-session \
  session-shortcut-reopens-closed-main-window \
  installed-app-focus-restored
run_app_scenario onboarding-first-run empty 8 onboarding-first-run-completes
run_app_scenario onboarding-provider empty 8 onboarding-detects-provider
run_app_scenario onboarding-approval empty 8 onboarding-explains-approval

[ -s "$FAKE_DIR/invocations.log" ]
while IFS= read -r invocation; do
  if ! approved_invocation "$invocation"; then
    printf 'UI e2e: fake CLI observed an unapproved command: %s\n' \
      "$invocation" >&2
    exit 1
  fi
done <"$FAKE_DIR/invocations.log"

recover_count="$(grep -Fxc 'codex recover --detach detach-codex-ui-recoverable' \
  "$FAKE_DIR/invocations.log" || true)"
recover_attach_count="$(grep -Fxc \
  'codex attach --terminal-features sync detach-codex-ui-recoverable' \
  "$FAKE_DIR/invocations.log" || true)"
running_attach_count="$(grep -Fxc \
  'codex attach --terminal-features sync detach-codex-ui-running' \
  "$FAKE_DIR/invocations.log" || true)"
switch_count="$(grep -Fc 'client switch --pid ' \
  "$FAKE_DIR/invocations.log" || true)"
claude_start_count="$(grep -Fxc 'claude --detach' \
  "$FAKE_DIR/invocations.log" || true)"
codex_start_count="$(grep -Fxc 'codex --detach' \
  "$FAKE_DIR/invocations.log" || true)"
quick_attach_count="$(grep -Fxc \
  'codex attach --terminal-features sync detach-codex-ui-quick' \
  "$FAKE_DIR/invocations.log" || true)"
new_attach_count="$(grep -Fxc \
  'claude attach --terminal-features sync detach-claude-ui-new' \
  "$FAKE_DIR/invocations.log" || true)"
quick_switch_count="$(grep -Fc \
  ' --to detach-codex-ui-quick --provider codex' \
  "$FAKE_DIR/invocations.log" || true)"
new_switch_count="$(grep -Fc \
  ' --to detach-claude-ui-new --provider claude' \
  "$FAKE_DIR/invocations.log" || true)"
if [ "$recover_count" -lt 1 ] || [ "$recover_attach_count" -lt 2 ] \
    || [ "$switch_count" -lt 3 ] \
    || [ "$claude_start_count" -ne 1 ] || [ "$codex_start_count" -ne 1 ] \
    || [ "$((quick_attach_count + quick_switch_count))" -lt 1 ] \
    || [ "$((new_attach_count + new_switch_count))" -lt 1 ]; then
  printf 'UI e2e invocation counts: recover=%s recover_attach=%s running_attach=%s switch=%s claude_start=%s codex_start=%s quick_attach=%s quick_switch=%s new_attach=%s new_switch=%s\n' \
    "$recover_count" "$recover_attach_count" "$running_attach_count" \
    "$switch_count" "$claude_start_count" "$codex_start_count" \
    "$quick_attach_count" "$quick_switch_count" "$new_attach_count" \
    "$new_switch_count" >&2
  exit 1
fi

printf 'Packaged Detach.app UI e2e smoke passed\n'
