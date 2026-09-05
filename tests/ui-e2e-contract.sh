#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app/build/Detach.app"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-ui-e2e-contract.XXXXXX")"
FAKE_ROOT=""
FAKE_QUICK_ROOT=""

cleanup() {
  case "$TMP_ROOT" in
    "${TMPDIR:-/tmp}"/detach-ui-e2e-contract.*) rm -rf "$TMP_ROOT" ;;
  esac
  case "$FAKE_ROOT" in
    /private/tmp/detach-ui-e2e.contract.*) rm -rf "$FAKE_ROOT" ;;
  esac
  case "$FAKE_QUICK_ROOT" in
    /private/tmp/detach-chat-contract.*) rm -rf "$FAKE_QUICK_ROOT" ;;
  esac
}
trap cleanup EXIT

run_validation() {
  DETACH_TEST_APP="$1" DETACH_UI_E2E_VALIDATE_ONLY=1 "$ROOT/tests/ui-e2e.sh"
}

run_validation "$APP"

if DETACH_TEST_APP="$APP" DETACH_UI_E2E_GUI_PROBE_RESULT=no-session \
    "$ROOT/tests/ui-e2e.sh" >"$TMP_ROOT/no-gui-session.log" 2>&1; then
  printf 'UI e2e ran without an interactive GUI session\n' >&2
  exit 1
fi
grep -F 'UI e2e: environment denied: no interactive GUI session (no-session)' \
  "$TMP_ROOT/no-gui-session.log" >/dev/null

if DETACH_TEST_APP="$APP" DETACH_UI_E2E_VALIDATE_ONLY=1 \
    DETACH_UI_E2E_COVERAGE_BINARY="$TMP_ROOT/missing-coverage-binary" \
    "$ROOT/tests/ui-e2e.sh" >"$TMP_ROOT/missing-coverage.log" 2>&1; then
  printf 'UI e2e accepted a missing coverage executable\n' >&2
  exit 1
fi
grep -F 'coverage executable is missing or unsafe' \
  "$TMP_ROOT/missing-coverage.log" >/dev/null

if DETACH_TEST_APP="$APP" DETACH_UI_E2E_VALIDATE_ONLY=1 \
    DETACH_UI_E2E_COVERAGE_BINARY="$APP/Contents/MacOS/Detach" \
    "$ROOT/tests/ui-e2e.sh" >"$TMP_ROOT/uninstrumented-coverage.log" 2>&1; then
  printf 'UI e2e accepted an uninstrumented coverage executable\n' >&2
  exit 1
fi
grep -F 'coverage executable has no coverage map' \
  "$TMP_ROOT/uninstrumented-coverage.log" >/dev/null

for invocation in \
  'list --json' \
  'codex logs --ansi detach-codex-ui-running' \
  'codex attach --terminal-features sync detach-codex-ui-running' \
  'codex logs --ansi detach-codex-ui-recoverable' \
  'codex recover --detach detach-codex-ui-recoverable' \
  'codex attach --terminal-features sync detach-codex-ui-recoverable' \
  'claude logs --ansi detach-claude-ui-completed' \
  'resume --detach a9f58f1d-1234-5678-9abc-def012342ed9' \
  'claude attach --terminal-features sync detach-claude-ui-completed' \
  'claude --detach' \
  'claude attach --terminal-features sync detach-claude-ui-new' \
  'codex stop detach-codex-ui-running' \
  'storage --json' \
  'config tmux-style' \
  'config tmux-extended-keys'; do
  DETACH_UI_E2E_VALIDATE_INVOCATION="$invocation" "$ROOT/tests/ui-e2e.sh"
done

for invocation in \
  'config tmux-style detach' \
  'config tmux-extended-keys on' \
  'storage cleanup --dry-run --json' \
  'codex stop detach-codex-ui-completed'; do
  if DETACH_UI_E2E_VALIDATE_INVOCATION="$invocation" \
      "$ROOT/tests/ui-e2e.sh"; then
    printf 'UI e2e invocation policy accepted mutation: %s\n' \
      "$invocation" >&2
    exit 1
  fi
done

FAKE_ROOT="$(mktemp -d /private/tmp/detach-ui-e2e.contract.XXXXXX)"
mkdir -p "$FAKE_ROOT/fake"
FAKE_STATE="$FAKE_ROOT/fake/state"
printf 'empty\n' >"$FAKE_STATE"

run_fake() {
  DETACH_UI_E2E_ROOT="$FAKE_ROOT" \
  DETACH_UI_E2E_FIXTURE_STATE="$FAKE_STATE" \
    "$ROOT/tests/fake-ui-cli" "$@"
}

storage_json="$(run_fake storage --json)"
[ "$(printf '%s\n' "$storage_json" | plutil -extract schema raw -o - -)" = 1 ]
[ "$(printf '%s\n' "$storage_json" | plutil -extract complete raw -o - -)" = true ]
[ "$(printf '%s\n' "$storage_json" | plutil -extract state_root raw -o - -)" = \
  "$FAKE_ROOT/state/detach" ]
[ "$(run_fake config tmux-style)" = inherit ]
[ "$(run_fake config tmux-extended-keys)" = off ]
if run_fake config tmux-style detach >/dev/null 2>&1; then
  printf 'Fake UI CLI accepted a Settings mutation\n' >&2
  exit 1
fi

FAKE_QUICK_ROOT="$(mktemp -d /private/tmp/detach-chat-contract.XXXXXX)"
chmod 0700 "$FAKE_QUICK_ROOT"
(
  cd "$FAKE_QUICK_ROOT"
  run_fake codex --detach
)
printf 'sessions\n' >"$FAKE_STATE"
quick_json="$(run_fake list --json | tail -n 1)"
[ "$(printf '%s\n' "$quick_json" \
  | plutil -extract session_name raw -o - -)" = detach-codex-ui-quick ]
[ "$(printf '%s\n' "$quick_json" \
  | plutil -extract project_dir raw -o - -)" = "$FAKE_QUICK_ROOT" ]

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
