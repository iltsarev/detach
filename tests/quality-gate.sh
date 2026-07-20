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
  REPO="$(cd -P "$TMP_ROOT" && pwd)/repo-$1"
  mkdir -p "$REPO/scripts" "$REPO/tests/quality-gate-fixtures" "$REPO/app/build"
  install -m 0755 "$ROOT/scripts/quality-gate" "$REPO/scripts/quality-gate"
  printf '%s\n' baseline >"$REPO/README.md"
  printf '%s\n' actions.log results '*.out' >"$REPO/.gitignore"
  for stage in static gate-contract swift app codex claude distribution tmux-runtime release-preflight publish-preflight release-workflow; do
    printf '#!/bin/bash\nset -eu\n[ "${CLANG_MODULE_CACHE_PATH:-}" = "${GATE_EXPECTED_MODULE_CACHE:?}" ] || { printf "unexpected Clang module cache: %%s\\n" "${CLANG_MODULE_CACHE_PATH:-missing}" >&2; exit 1; }\n[ "${SWIFTPM_MODULECACHE_OVERRIDE:-}" = "$GATE_EXPECTED_MODULE_CACHE" ] || { printf "unexpected SwiftPM module cache: %%s\\n" "${SWIFTPM_MODULECACHE_OVERRIDE:-missing}" >&2; exit 1; }\nprintf "%%s\\n" "%s" >>"${GATE_ACTION_LOG:?}"\ncase " ${FAIL_STAGES:-} " in *" %s "*) exit 23 ;; esac\n' "$stage" "$stage" \
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
      GATE_EXPECTED_MODULE_CACHE="$REPO/app/.build/module-cache" \
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

setup_fixture deletion
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
rm "$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution,tmux-runtime' ]]

setup_fixture rename
mkdir -p "$REPO/bin" "$REPO/docs"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
git -C "$REPO" mv bin/detach docs/moved.md
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution,tmux-runtime' ]]

setup_fixture unusual-name
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct OddName {}' >"$REPO/app/Sources/DetachKit/line
break.swift"
plan="$(gate --plan --format json)"
[[ "$plan" = '{"policy":2,"mode":"change","fingerprint":"'*'","stages":["static","swift"]}' ]]

setup_fixture explain
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct Explained {}' >"$REPO/app/Sources/DetachKit/Explained.swift"
plan="$(gate --plan --explain)"
[[ "$plan" = *'reason A app/Sources/DetachKit/Explained.swift -> swift'* ]]

setup_fixture fingerprint
printf '%s\n' changed >>"$REPO/README.md"
first_plan="$(gate --plan)"
first_fingerprint="$(sed -E 's/.*fingerprint=([0-9a-f]+).*/\1/' <<<"$first_plan")"
second_plan="$(gate --plan)"
second_fingerprint="$(sed -E 's/.*fingerprint=([0-9a-f]+).*/\1/' <<<"$second_plan")"
[ "$first_fingerprint" = "$second_fingerprint" ]
printf '%s\n' changed-again >>"$REPO/README.md"
third_plan="$(gate --plan)"
third_fingerprint="$(sed -E 's/.*fingerprint=([0-9a-f]+).*/\1/' <<<"$third_plan")"
[ "$first_fingerprint" != "$third_fingerprint" ]

setup_fixture release
if ! gate --mode release >"$REPO/release.out" 2>&1; then
  cat "$REPO/release.out" >&2
  exit 1
fi
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
    GATE_EXPECTED_MODULE_CACHE="$REPO/app/.build/module-cache" \
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

setup_fixture resume
if FAIL_STAGES=swift gate --mode repository >"$REPO/resume-first.out" 2>&1; then
  printf 'quality gate unexpectedly ignored the resume fixture failure\n' >&2
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
gate --mode repository --resume "$resume_dir" >"$REPO/resume-second.out"
grep -F 'reusing static from matching evidence' "$REPO/resume-second.out" >/dev/null
grep -F 'reusing gate-contract from matching evidence' "$REPO/resume-second.out" >/dev/null
grep -R $'static\treused' "$RESULT_ROOT" >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]
grep -F $'result\tpassed' "$RESULT_ROOT"/*/manifest.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="11" failures="0" skipped="2">' "$RESULT_ROOT"/*/junit.xml >/dev/null

setup_fixture stale-resume
if FAIL_STAGES=swift gate --mode repository >"$REPO/stale-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' new-diff >>"$REPO/README.md"
if gate --mode repository --resume "$resume_dir" >"$REPO/stale-second.out" 2>&1; then
  printf 'quality gate reused stale evidence\n' >&2
  exit 1
fi
grep -F 'resume evidence does not match the current diff' "$REPO/stale-second.out" >/dev/null

setup_fixture keep-going
if FAIL_STAGES='swift codex' gate --mode repository --keep-going >"$REPO/keep-going.out" 2>&1; then
  printf 'quality gate unexpectedly passed keep-going failures\n' >&2
  exit 1
fi
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 11 ]
grep -F $'swift\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'codex\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="11" failures="2" skipped="0">' "$RESULT_ROOT"/*/junit.xml >/dev/null

printf 'Quality gate orchestrator tests passed\n'
