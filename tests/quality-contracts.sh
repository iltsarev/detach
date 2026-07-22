#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT/app"
BASELINE="$ROOT/tests/quality-baseline.tsv"
FILE_BASELINE="$ROOT/tests/quality-file-baseline.tsv"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-contracts.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

baseline_value() {
  local key="$1"
  awk -F '\t' -v wanted="$key" '$1 == wanted {count++; value=$2} END {if (count != 1) exit 1; print value}' "$BASELINE"
}

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

[ -f "$BASELINE" ] && [ ! -L "$BASELINE" ] || {
  printf 'quality contracts: baseline is missing or unsafe\n' >&2
  exit 1
}
awk -F '\t' '
  NF != 2 {exit 1}
  $1 == "schema" {seen[$1]++; if ($2 != "1") exit 1; next}
  $1 ~ /^(ui_test_count_min|business_test_count_min)$/ {
    seen[$1]++; if ($2 !~ /^[0-9]+$/) exit 1; next
  }
  $1 ~ /^(ui_line_coverage_min|business_line_coverage_min)$/ {
    seen[$1]++
    if ($2 !~ /^[0-9]+([.][0-9]+)?$/ || $2 + 0 > 100) exit 1
    next
  }
  {exit 1}
  END {
    if (seen["schema"] != 1 || seen["ui_test_count_min"] != 1 ||
        seen["business_test_count_min"] != 1 ||
        seen["ui_line_coverage_min"] != 1 ||
        seen["business_line_coverage_min"] != 1) exit 1
  }
' "$BASELINE" || {
  printf 'quality contracts: baseline schema is invalid\n' >&2
  exit 1
}

[ -f "$FILE_BASELINE" ] && [ ! -L "$FILE_BASELINE" ] || {
  printf 'quality contracts: per-file baseline is missing or unsafe\n' >&2
  exit 1
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
' "$FILE_BASELINE" || {
  printf 'quality contracts: per-file baseline schema is invalid\n' >&2
  exit 1
}
for source in "${critical_files[@]}"; do
  baseline_value_for_file="$(awk -F '\t' -v wanted="$source" \
    '$1 == wanted {count++; value=$2} END {if (count != 1) exit 1; print value}' \
    "$FILE_BASELINE")" || {
      printf 'quality contracts: per-file baseline is missing: %s\n' "$source" >&2
      exit 1
    }
done
[ "$(awk -F '\t' '$1 != "schema" {count++} END {print count+0}' "$FILE_BASELINE")" \
  = "${#critical_files[@]}" ] || {
    printf 'quality contracts: per-file baseline contains an unknown source\n' >&2
    exit 1
}

build_path="$(cd -P "$APP_ROOT" && swift build --show-bin-path)"
test_binary="$build_path/DetachAppPackageTests.xctest/Contents/MacOS/DetachAppPackageTests"
profdata="$build_path/codecov/default.profdata"
[ -f "$test_binary" ] && [ ! -L "$test_binary" ] && \
  [ -f "$profdata" ] && [ ! -L "$profdata" ] || {
  printf 'quality contracts: run the coverage-enabled Swift stage first\n' >&2
  exit 1
}

xcrun llvm-cov report "$test_binary" -instr-profile "$profdata" \
  >"$TMP_ROOT/coverage.txt"

read -r ui_covered ui_total business_covered business_total < <(
  awk '
    $1 ~ /^Sources\/DetachApp\// &&
      $1 !~ /\/UIE2E(AccessibilityBridge|TestDriver)\.swift$/ {
        ui_total += $8; ui_covered += $8 - $9
      }
    $1 ~ /^Sources\/DetachKit\// &&
      $1 !~ /\/(ClamshellLockRunner|DetachCLI)\.swift$/ {
        business_total += $8; business_covered += $8 - $9
      }
    END {
      if (ui_total == 0 || business_total == 0) exit 1
      printf "%d %d %d %d\n", ui_covered, ui_total, business_covered, business_total
    }
  ' "$TMP_ROOT/coverage.txt"
)

ui_percent="$(awk -v covered="$ui_covered" -v total="$ui_total" 'BEGIN {printf "%.2f", 100 * covered / total}')"
business_percent="$(awk -v covered="$business_covered" -v total="$business_total" 'BEGIN {printf "%.2f", 100 * covered / total}')"

if [ -n "${DETACH_SWIFT_TEST_LOG:-}" ]; then
  [ -f "$DETACH_SWIFT_TEST_LOG" ] && [ ! -L "$DETACH_SWIFT_TEST_LOG" ] || {
    printf 'quality contracts: Swift test log is missing or unsafe\n' >&2
    exit 1
  }
  sed -n "s/^Test Case '-\\[\\([^ ]*\\) \\([^]]*\\)\\]' started\\.$/\\1\\/\\2/p" \
    "$DETACH_SWIFT_TEST_LOG" | LC_ALL=C sort -u >"$TMP_ROOT/tests.txt"
else
  (
    cd -P "$APP_ROOT"
    mkdir -p .build/quality-codecov
    LLVM_PROFILE_FILE="$APP_ROOT/.build/quality-codecov/list-%p-%m.profraw" \
      swift test list --skip-build --disable-sandbox
  ) >"$TMP_ROOT/tests.txt"
fi
ui_tests="$(awk '/^DetachAppTests\./ {count++} END {print count+0}' "$TMP_ROOT/tests.txt")"
business_tests="$(awk '/^DetachKitTests\./ {count++} END {print count+0}' "$TMP_ROOT/tests.txt")"

for suite in \
  DetachAppTests.InstallationStorePowerStateTests \
  DetachAppTests.MenuBarPresentationTests \
  DetachAppTests.SetupGuidanceTests \
  DetachAppTests.TextSizeTests \
  DetachAppTests.UIE2EConfigurationTests \
  DetachAppTests.WatchdogServiceTests \
  DetachKitTests.DetachCLITests \
  DetachKitTests.DetachStateTests \
  DetachKitTests.PowerHelperLeaseServiceTests \
  DetachKitTests.SessionHealthTests \
  DetachKitTests.StorageStoreTests; do
  grep -q "^$suite/" "$TMP_ROOT/tests.txt" || {
    printf 'quality contracts: critical suite is missing: %s\n' "$suite" >&2
    exit 1
  }
done

assert_at_least() {
  local label="$1" actual="$2" minimum="$3"
  awk -v actual="$actual" -v minimum="$minimum" 'BEGIN {exit !(actual + 0 >= minimum + 0)}' || {
    printf 'quality contracts: %s regressed: %s < %s\n' "$label" "$actual" "$minimum" >&2
    if [ "$label" = 'business line coverage' ]; then
      printf 'quality contracts: DetachKit coverage by file:\n' >&2
      awk '$1 ~ /^Sources\/DetachKit\// {print}' "$TMP_ROOT/coverage.txt" >&2
      xcrun swift --version >&2
      sw_vers >&2
    fi
    exit 1
  }
}

assert_at_least 'UI test count' "$ui_tests" "$(baseline_value ui_test_count_min)"
assert_at_least 'business test count' "$business_tests" "$(baseline_value business_test_count_min)"
assert_at_least 'UI line coverage' "$ui_percent" "$(baseline_value ui_line_coverage_min)"
assert_at_least 'business line coverage' "$business_percent" "$(baseline_value business_line_coverage_min)"

file_count=0
while IFS=$'\t' read -r source minimum; do
  [ "$source" != schema ] || continue
  actual="$(awk -v wanted="$source" '
    $1 == wanted {
      count++
      total += $8
      covered += $8 - $9
    }
    END {
      if (count != 1 || total == 0) exit 1
      printf "%.2f", 100 * covered / total
    }
  ' "$TMP_ROOT/coverage.txt")" || {
    printf 'quality contracts: critical coverage source is missing: %s\n' "$source" >&2
    exit 1
  }
  assert_at_least "per-file line coverage for $source" "$actual" "$minimum"
  file_count=$((file_count + 1))
done <"$FILE_BASELINE"

printf 'Quality contracts passed: UI tests=%s coverage=%s%%; business tests=%s coverage=%s%%; critical files=%s\n' \
  "$ui_tests" "$ui_percent" "$business_tests" "$business_percent" "$file_count"
