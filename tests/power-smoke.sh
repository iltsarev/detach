#!/bin/bash

set -eu
set -o pipefail

APP="${DETACH_TEST_APP:-/Applications/Detach.app}"
POWER="$APP/Contents/MacOS/detach-power"
STATE="$APP/Contents/MacOS/detach-state"
SESSION="detach-power-system-smoke-$$"
RUN_TOKEN="smoke-$$-$(date +%s)"
CHILD_PID=""

parse_sleep_disabled() {
  /usr/bin/awk '
    {
      name = tolower($1)
      if (name == "sleepdisabled" || name == "disablesleep") {
        matches += 1
        value = $2
        if (NF != 2 || (value != "0" && value != "1")) malformed = 1
      }
    }
    END {
      if (matches > 1 || malformed) exit 2
      if (matches == 0) print 0
      else print value
    }
  '
}

# Safe regression hook: parse supplied fixture text and exit before checking
# the signed app, querying pmset, connecting to XPC, or changing power state.
if [ "${DETACH_TEST_PMSET_PARSE_ONLY:-0}" = "1" ]; then
  parse_sleep_disabled
  exit
fi

if [ "${DETACH_ALLOW_REAL_POWER_TEST:-0}" != "1" ]; then
  printf 'Refusing to change real system power state. Set DETACH_ALLOW_REAL_POWER_TEST=1 explicitly.\n' >&2
  exit 2
fi
[ -x "$POWER" ] || { printf 'Missing signed power client: %s\n' "$POWER" >&2; exit 1; }
[ -x "$STATE" ] || { printf 'Missing state helper: %s\n' "$STATE" >&2; exit 1; }

power_state() {
  "$POWER" status --json | "$STATE" meta get /dev/stdin state
}

sleep_disabled() {
  /usr/bin/pmset -g | parse_sleep_disabled
}

wait_for_value() {
  local expected="$1" attempts=0
  while [ "$attempts" -lt 50 ]; do
    [ "$(power_state 2>/dev/null || true)" = "$expected" ] && return 0
    attempts=$((attempts + 1))
    sleep 0.2
  done
  return 1
}

cleanup() {
  if [ -n "$CHILD_PID" ]; then
    kill -TERM "$CHILD_PID" >/dev/null 2>&1 || true
    wait "$CHILD_PID" >/dev/null 2>&1 || true
  fi
  if [ "$(sleep_disabled)" != "0" ]; then
    printf 'WARNING: sleep is still disabled; keep Detach.app installed so its helper can expire the test lease.\n' >&2
  fi
}
trap cleanup EXIT

[ "$(power_state)" != "unavailable" ] || {
  printf 'The signed Detach power helper is not registered or approved.\n' >&2
  exit 1
}
[ "$(sleep_disabled)" = "0" ] || {
  printf 'Refusing to replace a pre-existing disable-sleep setting.\n' >&2
  exit 1
}

"$POWER" run --session "$SESSION" --run-token "$RUN_TOKEN" -- /bin/sleep 8 &
CHILD_PID=$!
wait_for_value protected
[ "$(sleep_disabled)" = "1" ]

wait "$CHILD_PID"
CHILD_PID=""
wait_for_value allowed
[ "$(sleep_disabled)" = "0" ]

printf 'Native power lifecycle smoke test passed. Closed-lid behavior still requires a supervised hardware test.\n'
