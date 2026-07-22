#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
RATCHET="$ROOT/tests/quality-ratchet.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-ratchet-contract.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

write_baseline() {
  local file="$1" ui_tests="$2" business_tests="$3" ui_coverage="$4" business_coverage="$5"
  printf 'schema\t1\nui_test_count_min\t%s\nbusiness_test_count_min\t%s\nui_line_coverage_min\t%s\nbusiness_line_coverage_min\t%s\n' \
    "$ui_tests" "$business_tests" "$ui_coverage" "$business_coverage" >"$file"
}

current="$TMP_ROOT/current.tsv"
prior="$TMP_ROOT/prior.tsv"
write_baseline "$current" 175 294 22.21 80.98
write_baseline "$prior" 175 294 22.21 80.98

DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_PRIOR_BASELINE="$prior" "$RATCHET" >/dev/null

for regression in ui-tests business-tests ui-coverage business-coverage; do
  case "$regression" in
    ui-tests) write_baseline "$current" 174 294 22.21 80.98 ;;
    business-tests) write_baseline "$current" 175 293 22.21 80.98 ;;
    ui-coverage) write_baseline "$current" 175 294 22.20 80.98 ;;
    business-coverage) write_baseline "$current" 175 294 22.21 80.97 ;;
  esac
  if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" "$RATCHET" \
    >"$TMP_ROOT/$regression.out" 2>&1; then
    printf 'quality ratchet contract: accepted %s regression\n' "$regression" >&2
    exit 1
  fi
  grep -F 'regressed below locked-floor' "$TMP_ROOT/$regression.out" >/dev/null
done

write_baseline "$current" 176 295 22.22 81
write_baseline "$prior" 177 295 22.22 81
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_PRIOR_BASELINE="$prior" "$RATCHET" >"$TMP_ROOT/prior.out" 2>&1; then
  printf 'quality ratchet contract: accepted a merge-base regression\n' >&2
  exit 1
fi
grep -F 'regressed below merge-base' "$TMP_ROOT/prior.out" >/dev/null

write_baseline "$current" 175 294 22.21 80.98
printf 'ui_test_count_min\t175\n' >>"$current"
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" "$RATCHET" \
  >"$TMP_ROOT/duplicate.out" 2>&1; then
  printf 'quality ratchet contract: accepted a duplicate key\n' >&2
  exit 1
fi
grep -F 'baseline schema is invalid' "$TMP_ROOT/duplicate.out" >/dev/null

printf 'Quality ratchet contract tests passed\n'
