#!/bin/bash

set -eu
set -o pipefail

APP="${DETACH_TEST_APP:-/Applications/Detach.app}"
POWER="$APP/Contents/MacOS/detach-power"
STATE="$APP/Contents/MacOS/detach-state"
SESSION="detach-power-system-smoke-$$"
RUN_TOKEN="smoke-$$-$(date +%s)"
CHILD_PID=""
BASELINE_KIND=""
BASELINE_LEASE_COUNT=""

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

classify_baseline() {
  local state="$1" lease_count="$2" assertion_active="$3"
  local closed_lid_protection_active="$4" helper_reachable="$5"
  local transition_in_progress="$6" low_battery="$7" sleep_setting="$8"

  case "$lease_count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$assertion_active:$closed_lid_protection_active:$helper_reachable:$transition_in_progress:$low_battery" in
    true:true:true:false:false|false:false:true:false:false) ;;
    *) return 1 ;;
  esac
  case "$sleep_setting" in
    0|1) ;;
    *) return 1 ;;
  esac

  if [ "$state" = "allowed" ] && [ "$lease_count" = "0" ] && \
      [ "$assertion_active" = "false" ] && \
      [ "$closed_lid_protection_active" = "false" ] && \
      [ "$helper_reachable" = "true" ] && \
      [ "$transition_in_progress" = "false" ] && \
      [ "$low_battery" = "false" ] && [ "$sleep_setting" = "0" ]; then
    printf 'pristine\n'
    return
  fi

  if [ "$state" = "protected" ] && [ "$lease_count" -ge 1 ] && \
      [ "$assertion_active" = "true" ] && \
      [ "$closed_lid_protection_active" = "true" ] && \
      [ "$helper_reachable" = "true" ] && \
      [ "$transition_in_progress" = "false" ] && \
      [ "$low_battery" = "false" ] && [ "$sleep_setting" = "1" ]; then
    printf 'protected\n'
    return
  fi

  return 1
}

# Safe regression hook: parse supplied fixture text and exit before checking
# the signed app, querying pmset, connecting to XPC, or changing power state.
if [ "${DETACH_TEST_PMSET_PARSE_ONLY:-0}" = "1" ]; then
  parse_sleep_disabled
  exit
fi

# Safe regression hook: classify a supplied, already-parsed status snapshot
# and exit before checking the signed app, querying pmset, connecting to XPC,
# or changing power state.
if [ "${DETACH_TEST_BASELINE_CLASSIFY_ONLY:-0}" = "1" ]; then
  [ "$#" = 8 ] || exit 2
  classify_baseline "$@"
  exit
fi

if [ "${DETACH_ALLOW_REAL_POWER_TEST:-0}" != "1" ]; then
  printf 'Refusing to change real system power state. Set DETACH_ALLOW_REAL_POWER_TEST=1 explicitly.\n' >&2
  exit 2
fi
[ -x "$POWER" ] || { printf 'Missing signed power client: %s\n' "$POWER" >&2; exit 1; }
[ -x "$STATE" ] || { printf 'Missing state helper: %s\n' "$STATE" >&2; exit 1; }

sleep_disabled() {
  /usr/bin/pmset -g | parse_sleep_disabled
}

report_value() {
  local report="$1" key="$2"
  printf '%s\n' "$report" | "$STATE" meta get /dev/stdin "$key"
}

capture_power_report() {
  local report
  report="$("$POWER" status --json)" || return 1
  REPORT_STATE="$(report_value "$report" state)" || return 1
  REPORT_LEASE_COUNT="$(report_value "$report" lease_count)" || return 1
  REPORT_ASSERTION_ACTIVE="$(report_value "$report" assertion_active)" || return 1
  REPORT_CLOSED_LID_PROTECTION_ACTIVE="$(report_value "$report" closed_lid_protection_active)" || return 1
  REPORT_HELPER_REACHABLE="$(report_value "$report" helper_reachable)" || return 1
  REPORT_TRANSITION_IN_PROGRESS="$(report_value "$report" transition_in_progress)" || return 1
  REPORT_LOW_BATTERY="$(report_value "$report" low_battery)" || return 1
}

report_matches() {
  local expected_state="$1" expected_lease_count="$2" expected_sleep="$3"
  capture_power_report || return 1
  [ "$REPORT_STATE" = "$expected_state" ] && \
    [ "$REPORT_LEASE_COUNT" = "$expected_lease_count" ] && \
    [ "$REPORT_ASSERTION_ACTIVE" = "$([ "$expected_state" = protected ] && printf true || printf false)" ] && \
    [ "$REPORT_CLOSED_LID_PROTECTION_ACTIVE" = "$([ "$expected_state" = protected ] && printf true || printf false)" ] && \
    [ "$REPORT_HELPER_REACHABLE" = true ] && \
    [ "$REPORT_TRANSITION_IN_PROGRESS" = false ] && \
    [ "$REPORT_LOW_BATTERY" = false ] && \
    [ "$(sleep_disabled)" = "$expected_sleep" ]
}

wait_for_report() {
  local expected_state="$1" expected_lease_count="$2" expected_sleep="$3"
  local attempts=0
  while [ "$attempts" -lt 50 ]; do
    report_matches "$expected_state" "$expected_lease_count" "$expected_sleep" \
      2>/dev/null && return 0
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
  if [ "$BASELINE_KIND" = pristine ] && \
      ! wait_for_report allowed 0 0; then
    printf 'WARNING: sleep is still disabled; keep Detach.app installed so its helper can expire the test lease.\n' >&2
  elif [ "$BASELINE_KIND" = protected ] && \
      ! wait_for_report protected "$BASELINE_LEASE_COUNT" 1; then
    printf 'WARNING: the test lease did not return to the existing Detach protection baseline; keep Detach.app installed so its helper can expire the test lease.\n' >&2
  fi
}
trap cleanup EXIT

capture_power_report || {
  printf 'Could not read a complete signed Detach power status report.\n' >&2
  exit 1
}
INITIAL_SLEEP_DISABLED="$(sleep_disabled)"
[ "$REPORT_STATE" != "unavailable" ] || {
  printf 'The signed Detach power helper is not registered or approved.\n' >&2
  exit 1
}
BASELINE_KIND="$(classify_baseline \
  "$REPORT_STATE" "$REPORT_LEASE_COUNT" "$REPORT_ASSERTION_ACTIVE" \
  "$REPORT_CLOSED_LID_PROTECTION_ACTIVE" "$REPORT_HELPER_REACHABLE" \
  "$REPORT_TRANSITION_IN_PROGRESS" "$REPORT_LOW_BATTERY" \
  "$INITIAL_SLEEP_DISABLED")" || {
  printf 'Refusing real-power smoke: the existing power state is not a safe Detach-owned baseline.\n' >&2
  exit 1
}
BASELINE_LEASE_COUNT="$REPORT_LEASE_COUNT"
TARGET_LEASE_COUNT=$((BASELINE_LEASE_COUNT + 1))

"$POWER" run --session "$SESSION" --run-token "$RUN_TOKEN" -- /bin/sleep 8 &
CHILD_PID=$!
wait_for_report protected "$TARGET_LEASE_COUNT" 1

wait "$CHILD_PID"
CHILD_PID=""
if [ "$BASELINE_KIND" = pristine ]; then
  wait_for_report allowed 0 0
  printf 'Native power lifecycle smoke test passed. Closed-lid behavior still requires a supervised hardware test.\n'
else
  wait_for_report protected "$BASELINE_LEASE_COUNT" 1
  printf 'Native power lease lifecycle smoke test passed under existing Detach protection. Closed-lid behavior still requires a supervised hardware test.\n'
fi
