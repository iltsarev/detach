#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TEST_MODE="${DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE:-0}"
BUDGET="${DETACH_RELEASE_BUDGET:-$ROOT/tests/release-budget.tsv}"
PRIOR_OVERRIDE="${DETACH_RELEASE_PRIOR_BUDGET:-}"
BASE_COMMIT="${RESOLVED_BASE:-}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-release-budget-ratchet.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

case "$TEST_MODE" in 0|1) ;; *) printf 'release budget ratchet: invalid test mode\n' >&2; exit 2 ;; esac
if [ "$TEST_MODE" != 1 ] && { [ -n "${DETACH_RELEASE_BUDGET:-}" ] || [ -n "$PRIOR_OVERRIDE" ]; }; then
  printf 'release budget ratchet: budget overrides are test-only\n' >&2
  exit 2
fi

keys=(
  wall_seconds_max
  stage_static_seconds_max
  stage_gate_contract_seconds_max
  stage_swift_seconds_max
  stage_quality_contracts_seconds_max
  stage_app_seconds_max
  stage_ui_e2e_seconds_max
  stage_codex_seconds_max
  stage_claude_seconds_max
  stage_distribution_seconds_max
  stage_tmux_runtime_seconds_max
  stage_release_preflight_seconds_max
  stage_publish_preflight_seconds_max
  stage_release_workflow_seconds_max
)

legacy_keys=(
  wall_seconds_max
  stage_static_seconds_max
  stage_gate_contract_seconds_max
  stage_swift_seconds_max
  stage_quality_contracts_seconds_max
  stage_app_seconds_max
  stage_codex_seconds_max
  stage_claude_seconds_max
  stage_distribution_seconds_max
  stage_tmux_runtime_seconds_max
  stage_release_preflight_seconds_max
  stage_publish_preflight_seconds_max
  stage_release_workflow_seconds_max
)

budget_value() {
  local file="$1" key="$2"
  awk -F '\t' -v wanted="$key" \
    '$1 == wanted {count++; value=$2} END {if (count != 1) exit 1; print value}' "$file"
}

ceiling() {
  case "$1" in
    wall_seconds_max) printf 180 ;;
    stage_static_seconds_max) printf 2 ;;
    stage_gate_contract_seconds_max) printf 100 ;;
    stage_swift_seconds_max) printf 20 ;;
    stage_quality_contracts_seconds_max) printf 5 ;;
    stage_app_seconds_max) printf 70 ;;
    stage_ui_e2e_seconds_max) printf 15 ;;
    stage_codex_seconds_max) printf 110 ;;
    stage_claude_seconds_max) printf 50 ;;
    stage_distribution_seconds_max) printf 80 ;;
    stage_tmux_runtime_seconds_max) printf 8 ;;
    stage_release_preflight_seconds_max) printf 15 ;;
    stage_publish_preflight_seconds_max) printf 25 ;;
    stage_release_workflow_seconds_max) printf 70 ;;
  esac
}

validate_budget() {
  local file="$1" label="$2" expected_schema="$3" key value expected_count
  local -a expected_keys
  [ -f "$file" ] && [ ! -L "$file" ] || {
    printf 'release budget ratchet: %s budget is missing or unsafe\n' "$label" >&2
    return 1
  }
  if [ "$expected_schema" = 1 ]; then
    expected_keys=("${legacy_keys[@]}")
  else
    expected_keys=("${keys[@]}")
  fi
  expected_count=$((${#expected_keys[@]} + 1))
  [ "$(awk -F '\t' 'NF == 2 {count++} END {print count+0}' "$file")" -eq "$expected_count" ] || {
    printf 'release budget ratchet: %s budget schema is invalid\n' "$label" >&2
    return 1
  }
  [ "$(budget_value "$file" schema 2>/dev/null || true)" = "$expected_schema" ] || {
    printf 'release budget ratchet: %s budget version is unsupported\n' "$label" >&2
    return 1
  }
  for key in "${expected_keys[@]}"; do
    value="$(budget_value "$file" "$key" 2>/dev/null || true)"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
      printf 'release budget ratchet: %s %s is missing, duplicated, or invalid\n' "$label" "$key" >&2
      return 1
    }
  done
}

assert_not_higher() {
  local key="$1" current="$2" maximum="$3" source="$4"
  [ "$current" -le "$maximum" ] || {
    printf 'release budget ratchet: %s increased above %s: %s > %s\n' \
      "$key" "$source" "$current" "$maximum" >&2
    return 1
  }
}

validate_budget "$BUDGET" current 2
for key in "${keys[@]}"; do
  assert_not_higher "$key" "$(budget_value "$BUDGET" "$key")" "$(ceiling "$key")" locked-ceiling
done

PRIOR=""
if [ -n "$PRIOR_OVERRIDE" ]; then
  PRIOR="$PRIOR_OVERRIDE"
elif [ -n "$BASE_COMMIT" ] && git -C "$ROOT" cat-file -e "$BASE_COMMIT:tests/release-budget.tsv" 2>/dev/null; then
  PRIOR="$TMP_ROOT/prior.tsv"
  git -C "$ROOT" show "$BASE_COMMIT:tests/release-budget.tsv" >"$PRIOR"
fi
if [ -n "$PRIOR" ]; then
  prior_schema="$(budget_value "$PRIOR" schema 2>/dev/null || true)"
  case "$prior_schema" in 1|2) ;; *) prior_schema=invalid ;; esac
  validate_budget "$PRIOR" prior "$prior_schema"
  comparison_keys=("${keys[@]}")
  if [ "$prior_schema" = 1 ]; then
    comparison_keys=("${legacy_keys[@]}")
  fi
  for key in "${comparison_keys[@]}"; do
    assert_not_higher "$key" "$(budget_value "$BUDGET" "$key")" \
      "$(budget_value "$PRIOR" "$key")" merge-base
  done
fi

printf 'Release budget ratchet passed: wall <=%ss\n' "$(budget_value "$BUDGET" wall_seconds_max)"
