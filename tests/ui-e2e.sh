#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${DETACH_TEST_APP:-$ROOT/app/build/Detach.app}"
VALIDATE_ONLY="${DETACH_UI_E2E_VALIDATE_ONLY:-0}"
KEEP="${DETACH_UI_E2E_KEEP:-0}"
ARTIFACT_DIR="${DETACH_UI_E2E_ARTIFACT_DIR:-}"
TEST_ROOT=""
APP_PID=""

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
  for source in "$APP_LOG" "$RESULT" "$FAKE_DIR/invocations.log"; do
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

mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/Library/Preferences" \
  "$TEST_ROOT/state" "$TEST_ROOT/power" "$FAKE_DIR"
ditto "$SOURCE_APP" "$TEST_APP"

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

HOME="$TEST_HOME" \
CFFIXED_USER_HOME="$TEST_HOME" \
XDG_STATE_HOME="$TEST_ROOT/state" \
DETACH_STATE_ROOT="$TEST_ROOT/state/detach" \
DETACH_POWER_STATE_ROOT="$TEST_ROOT/power" \
DETACH_UI_E2E_ROOT="$TEST_ROOT" \
DETACH_UI_E2E_CLI="$FAKE_CLI" \
DETACH_UI_E2E_RESULT="$RESULT" \
DETACH_UI_E2E_FIXTURE_STATE="$FIXTURE_STATE" \
LANG=en_US.UTF-8 \
LC_ALL=en_US.UTF-8 \
  "$TEST_APP/Contents/MacOS/Detach" >"$APP_LOG" 2>&1 &
APP_PID=$!

for _ in $(seq 1 250); do
  [ ! -f "$RESULT" ] || break
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 0.1
done

if [ ! -f "$RESULT" ]; then
  kill -TERM "$APP_PID" 2>/dev/null || true
  set +e
  wait "$APP_PID"
  APP_STATUS=$?
  set -e
  APP_PID=""
  printf 'UI e2e: app produced no result before the 25s deadline (status %s)\n' \
    "$APP_STATUS" >&2
  sed -n '1,240p' "$APP_LOG" >&2
  exit 1
fi

for _ in $(seq 1 50); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  kill -TERM "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  printf 'UI e2e: app did not terminate after writing its result\n' >&2
  exit 1
fi

set +e
wait "$APP_PID"
APP_STATUS=$?
set -e
APP_PID=""

[ "$APP_STATUS" -eq 0 ] || {
  printf 'UI e2e: app exited with status %s\n' "$APP_STATUS" >&2
  sed -n '1,240p' "$APP_LOG" >&2
  exit 1
}
[ -f "$RESULT" ] || {
  printf 'UI e2e: app produced no bounded result\n' >&2
  sed -n '1,240p' "$APP_LOG" >&2
  exit 1
}
[ ! -e "$BREACH" ] || {
  printf 'UI e2e: app attempted to use its normal installed-CLI path\n' >&2
  exit 1
}
[ "$(plutil -extract schema raw -o - "$RESULT")" = 1 ]
if [ "$(plutil -extract passed raw -o - "$RESULT")" != true ]; then
  printf 'UI e2e failed: %s\n' \
    "$(plutil -extract error raw -o - "$RESULT" 2>/dev/null || true)" >&2
  plutil -p "$RESULT" >&2
  sed -n '1,240p' "$APP_LOG" >&2
  exit 1
fi

check_index=0
for check in \
  dashboard-accessible \
  sidebar-selects-completed-session \
  safe-action-reaches-fake-cli \
  new-session-sheet-semantics \
  empty-dashboard-state \
  installed-app-focus-undisturbed; do
  actual="$(plutil -extract "checks.$check_index" raw -o - "$RESULT")"
  [ "$actual" = "$check" ] || {
    printf 'UI e2e: check %s is %s, expected %s\n' \
      "$check_index" "$actual" "$check" >&2
    exit 1
  }
  check_index=$((check_index + 1))
done

[ -s "$FAKE_DIR/invocations.log" ]
if grep -Ev '^(list --json|(codex|claude) logs --ansi detach-(codex-ui-running|claude-ui-completed)|codex stop detach-codex-ui-running)$' \
    "$FAKE_DIR/invocations.log" >/dev/null; then
  printf 'UI e2e: fake CLI observed an unapproved command\n' >&2
  cat "$FAKE_DIR/invocations.log" >&2
  exit 1
fi

printf 'Packaged Detach.app UI e2e smoke passed\n'
