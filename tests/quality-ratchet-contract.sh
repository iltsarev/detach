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

write_file_baseline() {
  local file="$1" session_health="$2" helper_xpc="$3"
  printf 'schema\t1\nSources/DetachKit/SessionHealth.swift\t%s\nSources/DetachKit/DetachState.swift\t99.03\nSources/DetachKit/DetachStateCommand.swift\t96.70\nSources/DetachKit/Storage.swift\t95.28\nSources/DetachKit/StorageStore.swift\t100.00\nSources/DetachKit/Tip.swift\t100.00\nSources/DetachKit/DetachPowerCommand.swift\t95.21\nSources/DetachKit/DetachPowerExecutable.swift\t100.00\nSources/DetachKit/PowerHelperLeaseService.swift\t98.21\nSources/DetachKit/PowerHelperXPC.swift\t%s\nSources/DetachKit/PowerHelperPlatform.swift\t84.54\nSources/DetachKit/SessionStore.swift\t98.11\nSources/DetachKit/DoctorReport.swift\t100.00\n' \
    "$session_health" "$helper_xpc" >"$file"
}

current="$TMP_ROOT/current.tsv"
prior="$TMP_ROOT/prior.tsv"
current_files="$TMP_ROOT/current-files.tsv"
prior_files="$TMP_ROOT/prior-files.tsv"
missing_files="$TMP_ROOT/missing-files.tsv"
write_baseline "$current" 221 433 25.80 94.38
write_baseline "$prior" 221 433 25.80 94.38
write_file_baseline "$current_files" 99.10 82.23
write_file_baseline "$prior_files" 99.10 82.23

DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_PRIOR_BASELINE="$prior" \
  DETACH_QUALITY_FILE_BASELINE="$current_files" \
  DETACH_QUALITY_PRIOR_FILE_BASELINE="$prior_files" "$RATCHET" >/dev/null

for regression in ui-tests business-tests ui-coverage business-coverage; do
  case "$regression" in
    ui-tests) write_baseline "$current" 220 433 25.80 94.38 ;;
    business-tests) write_baseline "$current" 221 432 25.80 94.38 ;;
    ui-coverage) write_baseline "$current" 221 433 25.79 94.38 ;;
    business-coverage) write_baseline "$current" 221 433 25.80 94.37 ;;
  esac
  if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" "$RATCHET" \
    >"$TMP_ROOT/$regression.out" 2>&1; then
    printf 'quality ratchet contract: accepted %s regression\n' "$regression" >&2
    exit 1
  fi
  grep -F 'regressed below locked-floor' "$TMP_ROOT/$regression.out" >/dev/null
done

write_baseline "$current" 222 434 25.81 94.39
write_baseline "$prior" 223 434 25.81 94.39
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_PRIOR_BASELINE="$prior" "$RATCHET" >"$TMP_ROOT/prior.out" 2>&1; then
  printf 'quality ratchet contract: accepted a merge-base regression\n' >&2
  exit 1
fi
grep -F 'regressed below merge-base' "$TMP_ROOT/prior.out" >/dev/null

write_baseline "$current" 221 433 25.80 94.38
printf 'ui_test_count_min\t221\n' >>"$current"
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" "$RATCHET" \
  >"$TMP_ROOT/duplicate.out" 2>&1; then
  printf 'quality ratchet contract: accepted a duplicate key\n' >&2
  exit 1
fi
grep -F 'baseline schema is invalid' "$TMP_ROOT/duplicate.out" >/dev/null

write_baseline "$current" 221 433 25.80 94.38
write_file_baseline "$current_files" 99.09 82.23
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_FILE_BASELINE="$current_files" "$RATCHET" \
  >"$TMP_ROOT/file-floor.out" 2>&1; then
  printf 'quality ratchet contract: accepted a per-file locked-floor regression\n' >&2
  exit 1
fi
grep -F 'per-file Sources/DetachKit/SessionHealth.swift regressed below locked-floor' \
  "$TMP_ROOT/file-floor.out" >/dev/null

write_file_baseline "$current_files" 99.10 83.00
write_file_baseline "$prior_files" 99.10 84.00
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_FILE_BASELINE="$current_files" \
  DETACH_QUALITY_PRIOR_FILE_BASELINE="$prior_files" "$RATCHET" \
  >"$TMP_ROOT/file-prior.out" 2>&1; then
  printf 'quality ratchet contract: accepted a per-file merge-base regression\n' >&2
  exit 1
fi
grep -F 'per-file Sources/DetachKit/PowerHelperXPC.swift regressed below merge-base' \
  "$TMP_ROOT/file-prior.out" >/dev/null

write_file_baseline "$current_files" 99.10 82.23
printf 'Sources/DetachKit/SessionHealth.swift\t99.10\n' >>"$current_files"
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_FILE_BASELINE="$current_files" "$RATCHET" \
  >"$TMP_ROOT/file-duplicate.out" 2>&1; then
  printf 'quality ratchet contract: accepted a duplicate per-file key\n' >&2
  exit 1
fi
grep -F 'per-file baseline schema is invalid' "$TMP_ROOT/file-duplicate.out" >/dev/null

write_file_baseline "$current_files" 99.10 82.23
printf 'Sources/DetachKit/Unreviewed.swift\t0.01\n' >>"$current_files"
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_FILE_BASELINE="$current_files" "$RATCHET" \
  >"$TMP_ROOT/file-extra.out" 2>&1; then
  printf 'quality ratchet contract: accepted an unknown per-file key\n' >&2
  exit 1
fi
grep -F 'per-file baseline contains unknown source Sources/DetachKit/Unreviewed.swift' \
  "$TMP_ROOT/file-extra.out" >/dev/null

write_file_baseline "$current_files" 99.10 82.23
awk -F '\t' '$1 != "Sources/DetachKit/DoctorReport.swift"' \
  "$current_files" >"$missing_files"
if DETACH_QUALITY_RATCHET_TEST_MODE=1 DETACH_QUALITY_BASELINE="$current" \
  DETACH_QUALITY_FILE_BASELINE="$missing_files" "$RATCHET" \
  >"$TMP_ROOT/file-missing.out" 2>&1; then
  printf 'quality ratchet contract: accepted a missing critical per-file key\n' >&2
  exit 1
fi
grep -F 'current per-file baseline is missing Sources/DetachKit/DoctorReport.swift' \
  "$TMP_ROOT/file-missing.out" >/dev/null

printf 'Quality ratchet contract tests passed\n'
