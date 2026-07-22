#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TEST_MODE="${DETACH_QUALITY_RATCHET_TEST_MODE:-0}"
BASELINE="${DETACH_QUALITY_BASELINE:-$ROOT/tests/quality-baseline.tsv}"
PRIOR_OVERRIDE="${DETACH_QUALITY_PRIOR_BASELINE:-}"
FILE_BASELINE="${DETACH_QUALITY_FILE_BASELINE:-$ROOT/tests/quality-file-baseline.tsv}"
PRIOR_FILE_OVERRIDE="${DETACH_QUALITY_PRIOR_FILE_BASELINE:-}"
BASE_COMMIT="${RESOLVED_BASE:-}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-ratchet.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

case "$TEST_MODE" in 0|1) ;; *) printf 'quality ratchet: invalid test mode\n' >&2; exit 2 ;; esac
if [ "$TEST_MODE" != 1 ] && {
  [ -n "${DETACH_QUALITY_BASELINE:-}" ] || [ -n "$PRIOR_OVERRIDE" ] ||
    [ -n "${DETACH_QUALITY_FILE_BASELINE:-}" ] || [ -n "$PRIOR_FILE_OVERRIDE" ]
}; then
  printf 'quality ratchet: baseline overrides are test-only\n' >&2
  exit 2
fi

keys=(ui_test_count_min business_test_count_min ui_line_coverage_min business_line_coverage_min)
critical_files=(
  Sources/DetachKit/SessionHealth.swift
  Sources/DetachKit/DetachState.swift
  Sources/DetachKit/DetachStateCommand.swift
  Sources/DetachKit/Storage.swift
  Sources/DetachKit/StorageStore.swift
  Sources/DetachKit/Tip.swift
  Sources/DetachKit/DetachPowerCommand.swift
  Sources/DetachKit/DetachPowerExecutable.swift
  Sources/DetachKit/PowerHelperLeaseService.swift
  Sources/DetachKit/PowerHelperXPC.swift
  Sources/DetachKit/PowerHelperPlatform.swift
  Sources/DetachKit/SessionStore.swift
  Sources/DetachKit/DoctorReport.swift
)

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

validate_file_baseline() {
  local file="$1" label="$2" source
  [ -f "$file" ] && [ ! -L "$file" ] || {
    printf 'quality ratchet: %s per-file baseline is missing or unsafe\n' "$label" >&2
    return 1
  }
  awk -F '\t' '
    NF != 2 {exit 1}
    $1 == "schema" {schema++; if ($2 != "1") exit 1; next}
    $1 !~ /^Sources\/DetachKit\/[A-Za-z0-9]+\.swift$/ {exit 1}
    $2 !~ /^[0-9]+([.][0-9]+)?$/ || $2 + 0 > 100 {exit 1}
    {files++; seen[$1]++}
    END {
      if (schema != 1 || files == 0) exit 1
      for (path in seen) if (seen[path] != 1) exit 1
    }
  ' "$file" || {
    printf 'quality ratchet: %s per-file baseline schema is invalid\n' "$label" >&2
    return 1
  }
  while IFS=$'\t' read -r source _; do
    [ "$source" = schema ] || file_hard_floor "$source" >/dev/null || {
      printf 'quality ratchet: %s per-file baseline contains unknown source %s\n' \
        "$label" "$source" >&2
      return 1
    }
  done <"$file"
}

hard_floor() {
  case "$1" in
    ui_test_count_min) printf 221 ;;
    business_test_count_min) printf 433 ;;
    ui_line_coverage_min) printf 25.80 ;;
    business_line_coverage_min) printf 94.38 ;;
  esac
}

file_hard_floor() {
  case "$1" in
    Sources/DetachKit/SessionHealth.swift) printf 99.10 ;;
    Sources/DetachKit/DetachState.swift) printf 99.03 ;;
    Sources/DetachKit/DetachStateCommand.swift) printf 96.70 ;;
    Sources/DetachKit/Storage.swift) printf 95.28 ;;
    Sources/DetachKit/StorageStore.swift) printf 100.00 ;;
    Sources/DetachKit/Tip.swift) printf 100.00 ;;
    Sources/DetachKit/DetachPowerCommand.swift) printf 95.21 ;;
    Sources/DetachKit/DetachPowerExecutable.swift) printf 100.00 ;;
    Sources/DetachKit/PowerHelperLeaseService.swift) printf 98.21 ;;
    Sources/DetachKit/PowerHelperXPC.swift) printf 82.23 ;;
    Sources/DetachKit/PowerHelperPlatform.swift) printf 84.54 ;;
    Sources/DetachKit/SessionStore.swift) printf 98.11 ;;
    Sources/DetachKit/DoctorReport.swift) printf 100.00 ;;
    *) return 1 ;;
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
validate_file_baseline "$FILE_BASELINE" current
for source in "${critical_files[@]}"; do
  current_value="$(baseline_value "$FILE_BASELINE" "$source")" || {
    printf 'quality ratchet: current per-file baseline is missing %s\n' "$source" >&2
    exit 1
  }
  assert_not_lower "per-file $source" "$current_value" \
    "$(file_hard_floor "$source")" locked-floor
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

PRIOR_FILE=""
if [ -n "$PRIOR_FILE_OVERRIDE" ]; then
  PRIOR_FILE="$PRIOR_FILE_OVERRIDE"
elif [ -n "$BASE_COMMIT" ] && \
    git -C "$ROOT" cat-file -e "$BASE_COMMIT:tests/quality-file-baseline.tsv" 2>/dev/null; then
  PRIOR_FILE="$TMP_ROOT/prior-file.tsv"
  git -C "$ROOT" show "$BASE_COMMIT:tests/quality-file-baseline.tsv" >"$PRIOR_FILE"
fi

if [ -n "$PRIOR_FILE" ]; then
  validate_file_baseline "$PRIOR_FILE" prior
  while IFS=$'\t' read -r source prior_value; do
    [ "$source" != schema ] || continue
    current_value="$(baseline_value "$FILE_BASELINE" "$source")" || {
      printf 'quality ratchet: current per-file baseline removed %s\n' "$source" >&2
      exit 1
    }
    assert_not_lower "per-file $source" "$current_value" "$prior_value" merge-base
  done <"$PRIOR_FILE"
fi

printf 'Quality ratchet passed: UI tests >=%s coverage >=%s%%; business tests >=%s coverage >=%s%%; critical files=%s\n' \
  "$(baseline_value "$BASELINE" ui_test_count_min)" \
  "$(baseline_value "$BASELINE" ui_line_coverage_min)" \
  "$(baseline_value "$BASELINE" business_test_count_min)" \
  "$(baseline_value "$BASELINE" business_line_coverage_min)" \
  "${#critical_files[@]}"
