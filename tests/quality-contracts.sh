#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT/app"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-contracts.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

swift_scratch="${DETACH_SWIFT_TEST_SCRATCH:-}"
exact_test_binary="${DETACH_SWIFT_TEST_BINARY:-}"
exact_test_profile="${DETACH_SWIFT_TEST_PROFILE:-}"
if { [ -n "$exact_test_binary" ] && [ -z "$exact_test_profile" ]; } || \
   { [ -z "$exact_test_binary" ] && [ -n "$exact_test_profile" ]; }; then
  printf 'quality contracts: exact Swift binary and profile must occur together\n' >&2
  exit 2
fi
if [ -n "$exact_test_binary" ]; then
  expected_binary="$APP_ROOT/.build/quality-swift-tests/arm64-apple-macosx/debug/DetachAppPackageTests.xctest/Contents/MacOS/DetachAppPackageTests"
  case "$exact_test_profile" in "$ROOT"/app/build/quality-shards/*/*/exact-swift.profdata|"$ROOT"/app/build/quality-gates/*/exact-swift.profdata) ;; *)
    printf 'quality contracts: exact Swift profile path is not a quality evidence path\n' >&2
    exit 2
  esac
  [ "$exact_test_binary" = "$expected_binary" ] || {
    printf 'quality contracts: exact Swift binary path is not the quality product\n' >&2
    exit 2
  }
  test_binary="$exact_test_binary"
  profdata="$exact_test_profile"
else
  build_path_args=(swift build --show-bin-path)
  test_list_args=(swift test list --skip-build --disable-sandbox)
  if [ -n "$swift_scratch" ]; then
    [ "$swift_scratch" = "$APP_ROOT/.build/quality-swift-tests" ] || {
      printf 'quality contracts: Swift scratch path is not the quality path\n' >&2
      exit 2
    }
    build_path_args+=(--disable-automatic-resolution --cache-path "$APP_ROOT/.build" --scratch-path "$swift_scratch")
    test_list_args+=(--disable-automatic-resolution --cache-path "$APP_ROOT/.build" --scratch-path "$swift_scratch")
  fi
  build_path="$(cd -P "$APP_ROOT" && "${build_path_args[@]}")"
  test_binary="$build_path/DetachAppPackageTests.xctest/Contents/MacOS/DetachAppPackageTests"
  profdata="$build_path/codecov/default.profdata"
fi
[ -f "$test_binary" ] && [ ! -L "$test_binary" ] && \
  [ -f "$profdata" ] && [ ! -L "$profdata" ] || {
  printf 'quality contracts: run the coverage-enabled Swift stage first\n' >&2
  exit 1
}

if [ -n "${DETACH_SWIFT_TEST_LOG:-}" ]; then
  [ -f "$DETACH_SWIFT_TEST_LOG" ] && [ ! -L "$DETACH_SWIFT_TEST_LOG" ] || {
    printf 'quality contracts: Swift test log is missing or unsafe\n' >&2
    exit 1
  }
  tests="$DETACH_SWIFT_TEST_LOG"
else
  [ -z "$exact_test_binary" ] || {
    printf 'quality contracts: exact Swift evidence requires its test log\n' >&2
    exit 2
  }
  tests="$TMP_ROOT/tests.txt"
  (
    cd -P "$APP_ROOT"
    mkdir -p .build/quality-codecov
    LLVM_PROFILE_FILE="$APP_ROOT/.build/quality-codecov/list-%p-%m.profraw" \
      "${test_list_args[@]}"
  ) >"$tests"
fi

source_commit="${DETACH_QUALITY_SOURCE_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
authority="${DETACH_QUALITY_AUTHORITY:-local-diagnostic}"
output="${DETACH_QUALITY_METRICS_OUTPUT:-$ROOT/app/build/quality-metrics/quality-metrics.json}"
opportunities="${DETACH_QUALITY_OPPORTUNITIES_OUTPUT:-$ROOT/app/build/quality-metrics/coverage-opportunities.json}"
arguments=(
  evaluate
  --test-binary "$test_binary"
  --profile "$profdata"
  --tests "$tests"
  --output "$output"
  --opportunities-output "$opportunities"
  --source-commit "$source_commit"
  --authority "$authority"
)
if { [ -n "${DETACH_UI_COVERAGE_BINARY:-}" ] && [ -z "${DETACH_UI_COVERAGE_PROFILE_DIR:-}" ]; } || \
   { [ -z "${DETACH_UI_COVERAGE_BINARY:-}" ] && [ -n "${DETACH_UI_COVERAGE_PROFILE_DIR:-}" ]; }; then
  printf 'quality contracts: UI coverage binary and profile directory must occur together\n' >&2
  exit 2
fi
if [ -n "${DETACH_UI_COVERAGE_BINARY:-}" ]; then
  arguments+=(
    --additional-object "$DETACH_UI_COVERAGE_BINARY"
    --additional-profile-directory "$DETACH_UI_COVERAGE_PROFILE_DIR"
  )
fi
[ -z "${RESOLVED_BASE:-}" ] || arguments+=(--base-commit "$RESOLVED_BASE")
[ -z "${DETACH_QUALITY_BASELINE_ROOT:-}" ] || \
  arguments+=(--baseline-root "$DETACH_QUALITY_BASELINE_ROOT")

"$ROOT/scripts/quality-metrics" "${arguments[@]}"

if [ -n "${DETACH_UI_COVERAGE_BINARY:-}" ]; then
  swift_output="${DETACH_QUALITY_SWIFT_METRICS_OUTPUT:-$(dirname "$output")/quality-metrics-swift.json}"
  "$ROOT/scripts/quality-metrics" evaluate \
    --test-binary "$test_binary" \
    --profile "$profdata" \
    --tests "$tests" \
    --output "$swift_output" \
    --source-commit "$source_commit" \
    --coverage-profile swift \
    --authority local-diagnostic
fi
