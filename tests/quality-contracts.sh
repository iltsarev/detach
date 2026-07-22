#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT/app"
BASELINE="$ROOT/tests/quality-baseline.tsv"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-contracts.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

baseline_value() {
  local key="$1"
  awk -F '\t' -v wanted="$key" '$1 == wanted {count++; value=$2} END {if (count != 1) exit 1; print value}' "$BASELINE"
}

[ -f "$BASELINE" ] && [ ! -L "$BASELINE" ] || {
  printf 'quality contracts: baseline is missing or unsafe\n' >&2
  exit 1
}
[ "$(baseline_value schema)" = 1 ] || {
  printf 'quality contracts: unsupported baseline schema\n' >&2
  exit 1
}

test_binary="$(find "$APP_ROOT/.build" \
  -path '*DetachAppPackageTests.xctest/Contents/MacOS/DetachAppPackageTests' \
  -type f -print | head -1)"
profdata="$(find "$APP_ROOT/.build" -path '*/codecov/default.profdata' -type f -print | head -1)"
[ -n "$test_binary" ] && [ -n "$profdata" ] || {
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

printf 'Quality contracts passed: UI tests=%s coverage=%s%%; business tests=%s coverage=%s%%\n' \
  "$ui_tests" "$ui_percent" "$business_tests" "$business_percent"
