#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app/build/Detach.app"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-ui-e2e-contract.XXXXXX")"

cleanup() {
  case "$TMP_ROOT" in
    "${TMPDIR:-/tmp}"/detach-ui-e2e-contract.*) rm -rf "$TMP_ROOT" ;;
  esac
}
trap cleanup EXIT

run_validation() {
  DETACH_TEST_APP="$1" DETACH_UI_E2E_VALIDATE_ONLY=1 "$ROOT/tests/ui-e2e.sh"
}

run_validation "$APP"

mkdir -p "$TMP_ROOT/mismatch.app/Contents/MacOS" \
  "$TMP_ROOT/mismatch.app/Contents/Resources"
cp "$APP/Contents/MacOS/Detach" "$TMP_ROOT/mismatch.app/Contents/MacOS/Detach"
printf 'detach-app-build:00000000-0000-0000-0000-000000000000\n' \
  >"$TMP_ROOT/mismatch.app/Contents/Resources/BUILD_MARKER"
if run_validation "$TMP_ROOT/mismatch.app" >"$TMP_ROOT/mismatch.log" 2>&1; then
  printf 'UI e2e marker validation accepted mismatched metadata\n' >&2
  exit 1
fi
grep -F 'executable and bundle build markers differ' "$TMP_ROOT/mismatch.log" >/dev/null

mkdir -p "$TMP_ROOT/missing.app/Contents/MacOS" \
  "$TMP_ROOT/missing.app/Contents/Resources"
cp "$APP/Contents/MacOS/Detach" "$TMP_ROOT/missing.app/Contents/MacOS/Detach"
if run_validation "$TMP_ROOT/missing.app" >"$TMP_ROOT/missing.log" 2>&1; then
  printf 'UI e2e marker validation accepted missing metadata\n' >&2
  exit 1
fi
grep -F 'build marker is missing or unsafe' "$TMP_ROOT/missing.log" >/dev/null

printf 'UI e2e harness contract tests passed\n'
