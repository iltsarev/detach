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
  install -m 0755 "$ROOT/tests/quality-ratchet.sh" "$ROOT/tests/release-budget-ratchet.sh" "$REPO/tests/"
  install -m 0644 "$ROOT/tests/quality-baseline.tsv" "$ROOT/tests/release-budget.tsv" "$REPO/tests/"
  printf '#!/bin/bash\nexit 0\n' >"$REPO/tests/docs-contract.sh"
  chmod 0755 "$REPO/tests/docs-contract.sh"
  printf '%s\n' baseline >"$REPO/README.md"
  printf '%s\n' actions.log results '*.out' >"$REPO/.gitignore"
  for stage in static gate-contract swift quality-contracts app codex claude distribution tmux-runtime release-preflight publish-preflight release-workflow; do
    printf '#!/bin/bash\nset -eu\n[ "${CLANG_MODULE_CACHE_PATH:-}" = "${GATE_EXPECTED_MODULE_CACHE:?}" ] || { printf "unexpected Clang module cache: %%s\\n" "${CLANG_MODULE_CACHE_PATH:-missing}" >&2; exit 1; }\n[ "${SWIFTPM_MODULECACHE_OVERRIDE:-}" = "$GATE_EXPECTED_MODULE_CACHE" ] || { printf "unexpected SwiftPM module cache: %%s\\n" "${SWIFTPM_MODULECACHE_OVERRIDE:-missing}" >&2; exit 1; }\nprintf "%%s\\n" "%s" >>"${GATE_ACTION_LOG:?}"\nsleep "${STAGE_SLEEP:-0}"\ncase " ${FAIL_STAGES:-} " in *" %s "*) exit 23 ;; esac\n' "$stage" "$stage" \
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

set_manifest_value() {
  local file="$1" key="$2" value="$3" temporary
  temporary="$file.tmp"
  awk -F '\t' -v OFS='\t' -v wanted="$key" -v replacement="$value" \
    '$1 == wanted {$2=replacement} {print}' "$file" >"$temporary"
  mv "$temporary" "$file"
}

refresh_summary_digest() {
  local run_dir="$1" digest
  digest="$(shasum -a 256 "$run_dir/summary.tsv" | awk '{print $1}')"
  set_manifest_value "$run_dir/manifest.tsv" summary_sha256 "$digest"
}

setup_fixture docs
stages="$(gate --list-stages)"
[ "$(printf '%s\n' "$stages" | wc -l | tr -d ' ')" = 13 ]
[ "$(printf '%s\n' "$stages" | head -1)" = static ]
[ "$(printf '%s\n' "$stages" | tail -1)" = release-budget ]
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static' ]]

setup_fixture docs-contract
printf '%s\n' '# changed contract' >"$REPO/tests/docs-contract.sh"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static' ]]

setup_fixture swift
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,release-budget' ]]

setup_fixture package
mkdir -p "$REPO/app"
printf '%s\n' '// changed package' >"$REPO/app/Package.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,tmux-runtime,release-budget' ]]

setup_fixture shell
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture release-impact
printf '%s\n' 999 >"$REPO/BUILD"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,release-preflight,publish-preflight,release-workflow,release-budget' ]]

setup_fixture mixed
mkdir -p "$REPO/bin" "$REPO/app/Sources/DetachKit"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture base-ref
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct CommittedChange {}' >"$REPO/app/Sources/DetachKit/Committed.swift"
git -C "$REPO" add .
git -C "$REPO" commit -qm change
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --base "$BASE" --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,release-budget' ]]

setup_fixture unknown
printf '%s\n' unknown >"$REPO/new-contract.data"
plan="$(gate --plan 2>&1)"
[[ "$plan" = *'stages=static,gate-contract,swift,quality-contracts,app,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow,release-budget' ]]

setup_fixture deletion
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
rm "$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture rename
mkdir -p "$REPO/bin" "$REPO/docs"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
git -C "$REPO" mv bin/detach docs/moved.md
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture unusual-name
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct OddName {}' >"$REPO/app/Sources/DetachKit/line
break.swift"
plan="$(gate --plan --format json)"
[[ "$plan" = '{"policy":6,"mode":"change","source_commit":"'* ]]
[[ "$plan" = *'"base_commit":"","input_fingerprint":"'* ]]
[[ "$plan" = *'"stages":["static","swift","quality-contracts","release-budget"]}' ]]

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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 11 ]

setup_fixture github-budget
plan="$(GITHUB_ACTIONS=true gate --mode repository --without-release-budget --plan)"
[[ "$plan" = *'stages=static,gate-contract,swift,quality-contracts,app,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow' ]]
[[ "$plan" != *'release-budget'* ]]

setup_fixture failure
printf '#!/bin/bash\nprintf "%%s\\n" swift >>"${GATE_ACTION_LOG:?}"\n+exit 23\n' \
  >"$REPO/tests/quality-gate-fixtures/swift"
chmod 0755 "$REPO/tests/quality-gate-fixtures/swift"
if gate --mode repository >"$REPO/failure.out" 2>&1; then
  printf 'quality gate unexpectedly ignored a failed stage\n' >&2
  exit 1
fi
grep -F 'diagnostic rerun: scripts/quality-gate --stage swift' "$REPO/failure.out" >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 11 ]

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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 13 ]
grep -F $'result\tpassed' "$RESULT_ROOT"/*/manifest.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="13" failures="0" skipped="10">' "$RESULT_ROOT"/*/junit.xml >/dev/null

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
grep -F 'resume evidence does not match the current input' "$REPO/stale-second.out" >/dev/null

setup_fixture keep-going
if FAIL_STAGES='swift codex' gate --mode repository --keep-going >"$REPO/keep-going.out" 2>&1; then
  printf 'quality gate unexpectedly passed keep-going failures\n' >&2
  exit 1
fi
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 11 ]
grep -F $'swift\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'codex\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="13" failures="2" skipped="2">' "$RESULT_ROOT"/*/junit.xml >/dev/null

setup_fixture provenance
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --base "$BASE" --plan --format json)"
[[ "$plan" = *'"source_commit":"'"$(git -C "$REPO" rev-parse HEAD)"'"'* ]]
[[ "$plan" = *'"base_commit":"'"$BASE"'"'* ]]
[[ "$plan" = *'"input_fingerprint":"'* ]]

setup_fixture compatible-resume
printf '%s\n' docs >>"$REPO/README.md"
if FAIL_STAGES=swift gate --mode repository >"$REPO/compatible-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
gate --resume "$resume_dir" >"$REPO/compatible-second.out"
grep -F 'reusing static from matching evidence' "$REPO/compatible-second.out" >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 11 ]

setup_fixture latest-resume
printf '%s\n' docs >>"$REPO/README.md"
if FAIL_STAGES=swift gate --mode repository >"$REPO/latest-first.out" 2>&1; then
  exit 1
fi
gate --resume latest >"$REPO/latest-second.out"
grep -F 'selected latest compatible evidence' "$REPO/latest-second.out" >/dev/null
grep -F 'reusing static from matching evidence' "$REPO/latest-second.out" >/dev/null
gate --mode repository --resume latest >"$REPO/latest-third.out"
grep -F 'selected latest compatible evidence' "$REPO/latest-third.out" >/dev/null
grep -F 'reusing gate-contract from matching evidence' "$REPO/latest-third.out" >/dev/null

setup_fixture source-commit
if FAIL_STAGES=swift gate --mode repository >"$REPO/source-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
git -C "$REPO" commit --allow-empty -qm new-head
if gate --mode repository --resume "$resume_dir" >"$REPO/source-second.out" 2>&1; then
  printf 'quality gate reused evidence from another source commit\n' >&2
  exit 1
fi
grep -F 'resume evidence uses another source commit' "$REPO/source-second.out" >/dev/null

setup_fixture moved-base
git -C "$REPO" branch comparison "$BASE"
git -C "$REPO" commit --allow-empty -qm head-after-base
printf '%s\n' docs >>"$REPO/README.md"
if FAIL_STAGES=swift gate --mode repository --base comparison >"$REPO/base-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
git -C "$REPO" branch -f comparison HEAD
if gate --mode repository --base comparison --resume "$resume_dir" >"$REPO/base-second.out" 2>&1; then
  printf 'quality gate reused evidence from a moved base ref\n' >&2
  exit 1
fi
grep -F 'resume evidence uses another base commit' "$REPO/base-second.out" >/dev/null

setup_fixture tampered-summary
if FAIL_STAGES=swift gate --mode repository >"$REPO/tamper-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' $'6\trepository\tapp\tpassed\t0\tapp.log' >>"$resume_dir/summary.tsv"
if gate --mode repository --resume "$resume_dir" >"$REPO/tamper-second.out" 2>&1; then
  printf 'quality gate reused tampered summary evidence\n' >&2
  exit 1
fi
grep -F 'resume summary digest does not match its manifest' "$REPO/tamper-second.out" >/dev/null

setup_fixture duplicate-manifest
if FAIL_STAGES=swift gate --mode repository >"$REPO/duplicate-manifest-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' $'policy\t6' >>"$resume_dir/manifest.tsv"
if gate --mode repository --resume "$resume_dir" >"$REPO/duplicate-manifest-second.out" 2>&1; then
  printf 'quality gate accepted duplicate manifest keys\n' >&2
  exit 1
fi
grep -F 'resume evidence uses another policy version' "$REPO/duplicate-manifest-second.out" >/dev/null

setup_fixture incomplete-resume
if FAIL_STAGES=swift gate --mode repository >"$REPO/incomplete-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
set_manifest_value "$resume_dir/manifest.tsv" result running
if gate --mode repository --resume "$resume_dir" >"$REPO/incomplete-second.out" 2>&1; then
  printf 'quality gate accepted an incomplete run\n' >&2
  exit 1
fi
grep -F 'resume evidence is not from a completed run' "$REPO/incomplete-second.out" >/dev/null

setup_fixture invalid-summary
if FAIL_STAGES=swift gate --mode repository >"$REPO/invalid-summary-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' $'6\trepository\tstatic\tpassed\t0\tduplicate.log' >>"$resume_dir/summary.tsv"
refresh_summary_digest "$resume_dir"
if gate --mode repository --resume "$resume_dir" >"$REPO/invalid-summary-second.out" 2>&1; then
  printf 'quality gate accepted duplicate stage records\n' >&2
  exit 1
fi
grep -F 'resume summary contains invalid or duplicate stage records' "$REPO/invalid-summary-second.out" >/dev/null

setup_fixture stage-timeout
printf '#!/bin/bash\nsleep 5\n' >"$REPO/tests/quality-gate-fixtures/static"
chmod 0755 "$REPO/tests/quality-gate-fixtures/static"
if DETACH_QUALITY_GATE_TIMEOUT=10 DETACH_QUALITY_GATE_TIMEOUT_STATIC=1 gate --stage static >"$REPO/stage-timeout.out" 2>&1; then
  printf 'quality gate ignored the stage-specific timeout\n' >&2
  exit 1
fi
grep -F 'running static (timeout 1s)' "$REPO/stage-timeout.out" >/dev/null
if DETACH_QUALITY_GATE_TIMEOUT_STATIC=invalid gate --stage static >"$REPO/invalid-timeout.out" 2>&1; then
  printf 'quality gate accepted an invalid timeout\n' >&2
  exit 1
fi
grep -F 'timeout for static must be a positive integer' "$REPO/invalid-timeout.out" >/dev/null

setup_fixture dependency-block
if FAIL_STAGES=app gate --mode repository --keep-going >"$REPO/dependency.out" 2>&1; then
  printf 'quality gate unexpectedly passed a failed prerequisite\n' >&2
  exit 1
fi
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 9 ]
grep -F $'codex\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'tmux-runtime\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="13" failures="1" skipped="4">' "$RESULT_ROOT"/*/junit.xml >/dev/null

setup_fixture parallel-speed
parallel_started="$(date +%s)"
STAGE_SLEEP=3 gate --mode repository >"$REPO/parallel.out"
parallel_duration=$(($(date +%s) - parallel_started))
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]
[ "$parallel_duration" -le 18 ] || {
  printf 'parallel gate took %ss; expected at most 18s for a 36s serial fixture\n' \
    "$parallel_duration" >&2
  exit 1
}
grep -F 'quality-gate: PASS' "$REPO/parallel.out" >/dev/null

setup_fixture release-budget-wall
set_manifest_value "$REPO/tests/release-budget.tsv" wall_seconds_max 1
if DETACH_QUALITY_GATE_TEST_WALL_SECONDS=2 gate --mode repository >"$REPO/release-budget-wall.out" 2>&1; then
  printf 'quality gate accepted a wall-time regression\n' >&2
  exit 1
fi
grep -F 'wall time regressed' "$RESULT_ROOT"/*/release-budget.log >/dev/null
grep -F $'release-budget\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null

setup_fixture release-budget-stage
set_manifest_value "$REPO/tests/release-budget.tsv" stage_codex_seconds_max 1
if DETACH_QUALITY_GATE_TEST_CODEX_SECONDS=2 gate --mode repository >"$REPO/release-budget-stage.out" 2>&1; then
  printf 'quality gate accepted a stage-time regression\n' >&2
  exit 1
fi
grep -F 'codex regressed' "$RESULT_ROOT"/*/release-budget.log >/dev/null

setup_fixture evidence
printf '%s\n' docs >>"$REPO/README.md"
gate >"$REPO/evidence.out"
run_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
grep -F $'schema\t2' "$run_dir/manifest.tsv" >/dev/null
grep -F $'input_fingerprint\t' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^started_at\t[0-9]{4}-' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^finished_at\t[0-9]{4}-' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^duration_seconds\t[0-9]+$' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^summary_sha256\t[0-9a-f]{64}$' "$run_dir/manifest.tsv" >/dev/null
grep -F '# Quality gate' "$run_dir/summary.md" >/dev/null
grep -F '| `static` | passed |' "$run_dir/summary.md" >/dev/null
grep -F 'markdown=' "$REPO/evidence.out" >/dev/null

setup_fixture result-symlink
mkdir -p "$REPO/real-results"
ln -s "$REPO/real-results" "$RESULT_ROOT"
if gate --stage static >"$REPO/symlink.out" 2>&1; then
  printf 'quality gate accepted a symlink result root\n' >&2
  exit 1
fi
grep -F 'result root must be a non-symlink directory' "$REPO/symlink.out" >/dev/null

setup_fixture targeted-static
printf '%s\n' 'if then' >"$REPO/legacy.sh"
git -C "$REPO" add legacy.sh
git -C "$REPO" commit -qm legacy-invalid-shell
printf '%s\n' docs >>"$REPO/README.md"
(
  cd -P "$REPO"
  DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" "$REPO/scripts/quality-gate"
) >"$REPO/targeted-static.out"
grep -F 'quality-gate: PASS' "$REPO/targeted-static.out" >/dev/null
if (
  cd -P "$REPO"
  DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" "$REPO/scripts/quality-gate" --stage static
) >"$REPO/full-static.out" 2>&1; then
  printf 'repository static scan ignored an unchanged malformed shell file\n' >&2
  exit 1
fi
grep -F 'static failed' "$REPO/full-static.out" >/dev/null

printf 'Quality gate orchestrator tests passed\n'
