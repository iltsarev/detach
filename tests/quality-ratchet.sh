#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TEST_MODE="${DETACH_QUALITY_RATCHET_TEST_MODE:-0}"
BASELINE="${DETACH_QUALITY_BASELINE:-$ROOT/tests/quality-baseline.tsv}"
PRIOR_OVERRIDE="${DETACH_QUALITY_PRIOR_BASELINE:-}"
BASE_COMMIT="${RESOLVED_BASE:-}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-ratchet.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

case "$TEST_MODE" in 0|1) ;; *) printf 'quality ratchet: invalid test mode\n' >&2; exit 2 ;; esac
if [ "$TEST_MODE" != 1 ] && { [ -n "${DETACH_QUALITY_BASELINE:-}" ] || [ -n "$PRIOR_OVERRIDE" ]; }; then
  printf 'quality ratchet: baseline overrides are test-only\n' >&2
  exit 2
fi

keys=(ui_test_count_min business_test_count_min ui_line_coverage_min business_line_coverage_min)

baseline_value() {
  local file="$1" key="$2"
  awk -F '\t' -v wanted="$key" \
    '$1 == wanted {count++; value=$2} END {if (count != 1) exit 1; print value}' "$file"
}

validate_baseline() {
  local file="$1" label="$2" key value
  [ -f "$file" ] && [ ! -L "$file" ] || {
    printf 'quality ratchet: %s baseline is missing or unsafe\n' "$label" >&2
    return 1
  }
  awk -F '\t' '
    NF != 2 {exit 1}
    $1 !~ /^(schema|ui_test_count_min|business_test_count_min|ui_line_coverage_min|business_line_coverage_min)$/ {exit 1}
    {seen[$1]++}
    END {
      if (seen["schema"] != 1 || seen["ui_test_count_min"] != 1 ||
          seen["business_test_count_min"] != 1 ||
          seen["ui_line_coverage_min"] != 1 ||
          seen["business_line_coverage_min"] != 1) exit 1
    }
  ' "$file" || {
    printf 'quality ratchet: %s baseline schema is invalid\n' "$label" >&2
    return 1
  }
  [ "$(baseline_value "$file" schema)" = 1 ] || {
    printf 'quality ratchet: %s baseline version is unsupported\n' "$label" >&2
    return 1
  }
  for key in "${keys[@]}"; do
    value="$(baseline_value "$file" "$key")"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
      printf 'quality ratchet: %s %s is not numeric\n' "$label" "$key" >&2
      return 1
    }
  done
}

hard_floor() {
  case "$1" in
    ui_test_count_min) printf 170 ;;
    business_test_count_min) printf 294 ;;
    ui_line_coverage_min) printf 21.54 ;;
    business_line_coverage_min) printf 80.98 ;;
  esac
}

assert_not_lower() {
  local key="$1" current="$2" floor="$3" source="$4"
  awk -v current="$current" -v floor="$floor" 'BEGIN {exit !(current + 0 >= floor + 0)}' || {
    printf 'quality ratchet: %s regressed below %s: %s < %s\n' \
      "$key" "$source" "$current" "$floor" >&2
    return 1
  }
}

validate_baseline "$BASELINE" current
for key in "${keys[@]}"; do
  assert_not_lower "$key" "$(baseline_value "$BASELINE" "$key")" "$(hard_floor "$key")" locked-floor
done

PRIOR=""
if [ -n "$PRIOR_OVERRIDE" ]; then
  PRIOR="$PRIOR_OVERRIDE"
elif [ -n "$BASE_COMMIT" ] && git -C "$ROOT" cat-file -e "$BASE_COMMIT:tests/quality-baseline.tsv" 2>/dev/null; then
  PRIOR="$TMP_ROOT/prior.tsv"
  git -C "$ROOT" show "$BASE_COMMIT:tests/quality-baseline.tsv" >"$PRIOR"
fi

if [ -n "$PRIOR" ]; then
  validate_baseline "$PRIOR" prior
  for key in "${keys[@]}"; do
    assert_not_lower "$key" "$(baseline_value "$BASELINE" "$key")" \
      "$(baseline_value "$PRIOR" "$key")" merge-base
  done
fi

printf 'Quality ratchet passed: UI tests >=%s coverage >=%s%%; business tests >=%s coverage >=%s%%\n' \
  "$(baseline_value "$BASELINE" ui_test_count_min)" \
  "$(baseline_value "$BASELINE" ui_line_coverage_min)" \
  "$(baseline_value "$BASELINE" business_test_count_min)" \
  "$(baseline_value "$BASELINE" business_line_coverage_min)"
