#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-gate-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

setup_fixture() {
  local stage
  REPO="$TMP_ROOT/repo-$1"
  mkdir -p "$REPO/scripts" "$REPO/tests/quality-gate-fixtures" "$REPO/app/build"
  install -m 0755 "$ROOT/scripts/quality-gate" "$REPO/scripts/quality-gate"
  printf '%s\n' baseline >"$REPO/README.md"
  for stage in static gate-contract swift app codex claude distribution tmux-runtime release-preflight publish-preflight release-workflow; do
    printf '#!/bin/bash\nset -eu\nprintf "%%s\\n" "%s" >>"${GATE_ACTION_LOG:?}"\n' "$stage" \
      >"$REPO/tests/quality-gate-fixtures/$stage"
    chmod 0755 "$REPO/tests/quality-gate-fixtures/$stage"
  done
  git -C "$REPO" init -q
  git -C "$REPO" config user.name 'Detach Tests'
  git -C "$REPO" config user.email 'detach-tests@example.invalid'
  git -C "$REPO" add .
  git -C "$REPO" commit -qm baseline
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  ACTION_LOG="$REPO/actions.log"
  RESULT_ROOT="$REPO/results"
}

gate() {
  (
    cd -P "$REPO"
    GATE_ACTION_LOG="$ACTION_LOG" \
      DETACH_QUALITY_GATE_TEST_MODE=1 \
      DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" \
      "$REPO/scripts/quality-gate" "$@"
  )
}

setup_fixture docs
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static' ]]

setup_fixture swift
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift' ]]

setup_fixture package
mkdir -p "$REPO/app"
printf '%s\n' '// changed package' >"$REPO/app/Package.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,app,tmux-runtime' ]]

setup_fixture shell
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution,tmux-runtime' ]]

setup_fixture release-impact
printf '%s\n' 999 >"$REPO/BUILD"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,release-preflight,publish-preflight,release-workflow' ]]

setup_fixture mixed
mkdir -p "$REPO/bin" "$REPO/app/Sources/DetachKit"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,app,codex,claude,distribution,tmux-runtime' ]]

setup_fixture base-ref
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct CommittedChange {}' >"$REPO/app/Sources/DetachKit/Committed.swift"
git -C "$REPO" add .
git -C "$REPO" commit -qm change
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --base "$BASE" --plan)"
[[ "$plan" = *'stages=static,swift' ]]

setup_fixture unknown
printf '%s\n' unknown >"$REPO/new-contract.data"
plan="$(gate --plan 2>&1)"
[[ "$plan" = *'stages=static,gate-contract,swift,app,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow' ]]

setup_fixture release
gate --mode release >/dev/null
! grep -Fx release-workflow "$ACTION_LOG" >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 10 ]

setup_fixture failure
printf '#!/bin/bash\nprintf "%%s\\n" swift >>"${GATE_ACTION_LOG:?}"\n+exit 23\n' \
  >"$REPO/tests/quality-gate-fixtures/swift"
chmod 0755 "$REPO/tests/quality-gate-fixtures/swift"
if gate --mode repository >"$REPO/failure.out" 2>&1; then
  printf 'quality gate unexpectedly ignored a failed stage\n' >&2
  exit 1
fi
grep -F 'diagnostic rerun: scripts/quality-gate --stage swift' "$REPO/failure.out" >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 3 ]

setup_fixture timeout
printf '#!/bin/bash\nsleep 5\n' >"$REPO/tests/quality-gate-fixtures/static"
chmod 0755 "$REPO/tests/quality-gate-fixtures/static"
if DETACH_QUALITY_GATE_TIMEOUT=1 gate --stage static >"$REPO/timeout.out" 2>&1; then
  printf 'quality gate unexpectedly ignored a timeout\n' >&2
  exit 1
fi
grep -F 'static timeout' "$REPO/timeout.out" >/dev/null

setup_fixture interrupt
printf '#!/bin/bash\ntrap "exit 130" INT TERM HUP\nsleep 20\n' \
  >"$REPO/tests/quality-gate-fixtures/static"
chmod 0755 "$REPO/tests/quality-gate-fixtures/static"
(
  cd -P "$REPO"
  exec env GATE_ACTION_LOG="$ACTION_LOG" \
    DETACH_QUALITY_GATE_TEST_MODE=1 \
    DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" \
    "$REPO/scripts/quality-gate" --stage static
) >"$REPO/interrupt.out" 2>&1 &
gate_pid=$!
attempts=0
while ! grep -F 'quality-gate: running static' "$REPO/interrupt.out" >/dev/null 2>&1; do
  if ! kill -0 "$gate_pid" 2>/dev/null; then
    wait "$gate_pid" || true
    printf 'quality gate exited before the interrupt fixture became ready\n' >&2
    cat "$REPO/interrupt.out" >&2
    exit 1
  fi
  attempts=$((attempts + 1))
  [ "$attempts" -lt 200 ] || {
    kill -TERM "$gate_pid" 2>/dev/null || true
    wait "$gate_pid" || true
    printf 'quality gate did not start the interrupt fixture\n' >&2
    exit 1
  }
  sleep 0.05
done
kill -TERM "$gate_pid"
set +e
wait "$gate_pid"
interrupt_status=$?
set -e
[ "$interrupt_status" -eq 130 ]
grep -R $'static\tinterrupted' "$RESULT_ROOT" >/dev/null

printf 'Quality gate orchestrator tests passed\n'
