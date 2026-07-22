#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-gate-test.XXXXXX")"
TEMPLATE_REPO="$TMP_ROOT/template"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

grep -F 'run: scripts/quality-gate --base "$BASE_SHA" --without-release-budget' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: scripts/quality-gate --mode repository --keep-going --without-release-budget' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null

prepare_template() {
  local stage
  mkdir -p "$TEMPLATE_REPO/scripts" "$TEMPLATE_REPO/tests/quality-gate-fixtures" \
    "$TEMPLATE_REPO/app/build"
  install -m 0755 "$ROOT/scripts/quality-gate" "$TEMPLATE_REPO/scripts/quality-gate"
  install -m 0755 "$ROOT/tests/quality-ratchet.sh" "$ROOT/tests/release-budget-ratchet.sh" \
    "$ROOT/tests/shell-safety.sh" "$TEMPLATE_REPO/tests/"
  install -m 0644 "$ROOT/tests/quality-baseline.tsv" "$ROOT/tests/release-budget.tsv" \
    "$TEMPLATE_REPO/tests/"
  printf '#!/bin/bash\nexit 0\n' >"$TEMPLATE_REPO/tests/docs-contract.sh"
  chmod 0755 "$TEMPLATE_REPO/tests/docs-contract.sh"
  printf '%s\n' baseline >"$TEMPLATE_REPO/README.md"
  printf '%s\n' actions.log results '*.out' >"$TEMPLATE_REPO/.gitignore"
  for stage in static gate-contract swift quality-contracts app ui-e2e codex claude distribution tmux-runtime release-preflight publish-preflight release-workflow; do
    printf '#!/bin/bash\nset -eu\n[ "${CLANG_MODULE_CACHE_PATH:-}" = "${GATE_EXPECTED_MODULE_CACHE:?}" ] || { printf "unexpected Clang module cache: %%s\\n" "${CLANG_MODULE_CACHE_PATH:-missing}" >&2; exit 1; }\n[ "${SWIFTPM_MODULECACHE_OVERRIDE:-}" = "$GATE_EXPECTED_MODULE_CACHE" ] || { printf "unexpected SwiftPM module cache: %%s\\n" "${SWIFTPM_MODULECACHE_OVERRIDE:-missing}" >&2; exit 1; }\nprintf "%%s\\n" "%s" >>"${GATE_ACTION_LOG:?}"\nsleep "${STAGE_SLEEP:-0}"\ncase " ${FAIL_STAGES:-} " in *" %s "*) exit 23 ;; esac\n' "$stage" "$stage" \
      >"$TEMPLATE_REPO/tests/quality-gate-fixtures/$stage"
    chmod 0755 "$TEMPLATE_REPO/tests/quality-gate-fixtures/$stage"
  done
  git -C "$TEMPLATE_REPO" init -q
  git -C "$TEMPLATE_REPO" config user.name 'Detach Tests'
  git -C "$TEMPLATE_REPO" config user.email 'detach-tests@example.invalid'
  git -C "$TEMPLATE_REPO" add .
  git -C "$TEMPLATE_REPO" commit -qm baseline
}

setup_fixture() {
  REPO="$(cd -P "$TMP_ROOT" && pwd)/repo-$1"
  [ -d "$TEMPLATE_REPO/.git" ] || prepare_template
  cp -cR "$TEMPLATE_REPO" "$REPO"
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

CONTRACT_SHARD="${DETACH_QUALITY_GATE_CONTRACT_SHARD:-all}"
case "$CONTRACT_SHARD" in
  all|selection|execution|failures|evidence) ;;
  *) printf 'invalid quality-gate contract shard\n' >&2; exit 2 ;;
esac

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = selection ]; then
setup_fixture docs
stages="$(gate --list-stages)"
[ "$(printf '%s\n' "$stages" | wc -l | tr -d ' ')" = 14 ]
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
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,release-budget' ]]

setup_fixture typed-state-impact
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct ChangedState {}' >"$REPO/app/Sources/DetachKit/DetachStateCommand.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture power-impact
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct ChangedPower {}' >"$REPO/app/Sources/DetachKit/PowerHelperLeaseService.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,distribution,tmux-runtime,release-budget' ]]

setup_fixture package
mkdir -p "$REPO/app"
printf '%s\n' '// changed package' >"$REPO/app/Package.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,tmux-runtime,release-budget' ]]

setup_fixture shell
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture release-impact
printf '%s\n' 999 >"$REPO/BUILD"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,ui-e2e,release-preflight,publish-preflight,release-workflow,release-budget' ]]

setup_fixture mixed
mkdir -p "$REPO/bin" "$REPO/app/Sources/DetachKit"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture base-ref
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct CommittedChange {}' >"$REPO/app/Sources/DetachKit/Committed.swift"
git -C "$REPO" add .
git -C "$REPO" commit -qm change
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --base "$BASE" --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,release-budget' ]]

setup_fixture unknown
printf '%s\n' unknown >"$REPO/new-contract.data"
plan="$(gate --plan 2>&1)"
[[ "$plan" = *'stages=static,gate-contract,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow,release-budget' ]]

setup_fixture deletion
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
rm "$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture rename
mkdir -p "$REPO/bin" "$REPO/docs"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
git -C "$REPO" mv bin/detach docs/moved.md
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-budget' ]]

setup_fixture unusual-name
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct OddName {}' >"$REPO/app/Sources/DetachKit/line
break.swift"
plan="$(gate --plan --format json)"
[[ "$plan" = '{"policy":8,"mode":"change","source_commit":"'* ]]
[[ "$plan" = *'"base_commit":"","input_fingerprint":"'* ]]
[[ "$plan" = *'"stages":["static","swift","quality-contracts","app","ui-e2e","release-budget"]}' ]]

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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]

setup_fixture github-budget
plan="$(GITHUB_ACTIONS=true gate --mode repository --without-release-budget --plan)"
[[ "$plan" = *'stages=static,gate-contract,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow' ]]
[[ "$plan" != *'release-budget'* ]]
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = execution ] || [ "$CONTRACT_SHARD" = failures ]; then
setup_fixture failure
printf '#!/bin/bash\nprintf "%%s\\n" swift >>"${GATE_ACTION_LOG:?}"\n+exit 23\n' \
  >"$REPO/tests/quality-gate-fixtures/swift"
chmod 0755 "$REPO/tests/quality-gate-fixtures/swift"
if FAIL_STAGES=ui-e2e gate --mode repository >"$REPO/failure.out" 2>&1; then
  printf 'quality gate unexpectedly ignored a failed stage\n' >&2
  exit 1
fi
grep -F 'diagnostic rerun: scripts/quality-gate --stage swift' "$REPO/failure.out" >/dev/null
grep -F 'diagnostic rerun: scripts/quality-gate --stage ui-e2e' \
  "$REPO/failure.out" >/dev/null
grep -F $'ui-e2e\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'release-budget\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]

setup_fixture ui-e2e-timeout
printf '#!/bin/bash\nsleep 5\n' >"$REPO/tests/quality-gate-fixtures/ui-e2e"
chmod 0755 "$REPO/tests/quality-gate-fixtures/ui-e2e"
if DETACH_QUALITY_GATE_TIMEOUT_UI_E2E=1 gate --stage ui-e2e \
  >"$REPO/ui-e2e-timeout.out" 2>&1; then
  printf 'quality gate unexpectedly ignored a UI e2e timeout\n' >&2
  exit 1
fi
grep -F 'ui-e2e timeout' "$REPO/ui-e2e-timeout.out" >/dev/null

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
resumed_run="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort | tail -1)"
grep -F 'reusing static from matching evidence' "$REPO/resume-second.out" >/dev/null
grep -F 'reusing gate-contract from matching evidence' "$REPO/resume-second.out" >/dev/null
grep -R $'static\treused' "$RESULT_ROOT" >/dev/null
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 14 ]
grep -F $'result\tpassed' "$RESULT_ROOT"/*/manifest.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="14" failures="0" skipped="11">' "$RESULT_ROOT"/*/junit.xml >/dev/null
grep -F $'resumed_from_run\t'"$(basename "$resume_dir")" "$resumed_run/manifest.tsv" >/dev/null
expected_parent_digest="$(shasum -a 256 "$resume_dir/manifest.tsv" | awk '{print $1}')"
grep -F $'resumed_from_manifest_sha256\t'"$expected_parent_digest" "$resumed_run/manifest.tsv" >/dev/null
reused_log="$(awk -F '\t' '$3 == "static" {print $6}' "$resumed_run/summary.tsv")"
reused_log_sha256="$(awk -F '\t' '$3 == "static" {print $7}' "$resumed_run/summary.tsv")"
[ "$reused_log" != - ]
[ "$(shasum -a 256 "$resumed_run/$reused_log" | awk '{print $1}')" = "$reused_log_sha256" ]
grep -F $'origin_run\n' "$resumed_run/summary.tsv" >/dev/null

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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]
grep -F $'swift\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'codex\tfailed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="14" failures="2" skipped="2">' "$RESULT_ROOT"/*/junit.xml >/dev/null

setup_fixture environment-failure
printf '#!/bin/bash\nprintf "error creating /tmp/test.sock (Operation not permitted)\\n" >&2\nexit 23\n' \
  >"$REPO/tests/quality-gate-fixtures/codex"
chmod 0755 "$REPO/tests/quality-gate-fixtures/codex"
if gate --mode repository >"$REPO/environment-failure.out" 2>&1; then
  printf 'quality gate accepted an execution-environment failure\n' >&2
  exit 1
fi
grep -F $'codex\tenvironment-failed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F 'codex environment-failed' "$REPO/environment-failure.out" >/dev/null
grep -F '<failure message="environment-failed">' "$RESULT_ROOT"/*/junit.xml >/dev/null
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = execution ] || [ "$CONTRACT_SHARD" = evidence ]; then
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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]

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
printf '%s\n' $'8\trepository\tapp\tpassed\t0\tapp.log\tinvalid\t-' >>"$resume_dir/summary.tsv"
if gate --mode repository --resume "$resume_dir" >"$REPO/tamper-second.out" 2>&1; then
  printf 'quality gate reused tampered summary evidence\n' >&2
  exit 1
fi
grep -F 'resume summary digest does not match its manifest' "$REPO/tamper-second.out" >/dev/null

setup_fixture tampered-log
if FAIL_STAGES=swift gate --mode repository >"$REPO/tampered-log-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' tampered >>"$resume_dir/static.log"
if gate --mode repository --resume "$resume_dir" >"$REPO/tampered-log-second.out" 2>&1; then
  printf 'quality gate reused a tampered stage log\n' >&2
  exit 1
fi
grep -F 'resume summary log digest does not match: static' "$REPO/tampered-log-second.out" >/dev/null

setup_fixture duplicate-manifest
if FAIL_STAGES=swift gate --mode repository >"$REPO/duplicate-manifest-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' $'policy\t7' >>"$resume_dir/manifest.tsv"
if gate --mode repository --resume "$resume_dir" >"$REPO/duplicate-manifest-second.out" 2>&1; then
  printf 'quality gate accepted duplicate manifest keys\n' >&2
  exit 1
fi
grep -F 'resume evidence uses another policy version' "$REPO/duplicate-manifest-second.out" >/dev/null

setup_fixture cyclic-parent
if FAIL_STAGES=swift gate --mode repository >"$REPO/cyclic-parent-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
set_manifest_value "$resume_dir/manifest.tsv" resumed_from_run "$(basename "$resume_dir")"
set_manifest_value "$resume_dir/manifest.tsv" resumed_from_manifest_sha256 \
  0000000000000000000000000000000000000000000000000000000000000000
if gate --mode repository --resume "$resume_dir" >"$REPO/cyclic-parent-second.out" 2>&1; then
  printf 'quality gate accepted a cyclic evidence parent\n' >&2
  exit 1
fi
grep -F 'resume evidence parent chain contains a cycle' "$REPO/cyclic-parent-second.out" >/dev/null

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
printf '%s\n' $'8\trepository\tstatic\tpassed\t0\tduplicate.log\tinvalid\t-' >>"$resume_dir/summary.tsv"
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
grep -F $'ui-e2e\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="14" failures="1" skipped="5">' "$RESULT_ROOT"/*/junit.xml >/dev/null

setup_fixture parallel-speed
parallel_started="$(date +%s)"
STAGE_SLEEP=2 gate --mode repository >"$REPO/parallel.out"
parallel_duration=$(($(date +%s) - parallel_started))
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 13 ]
[ "$parallel_duration" -le 12 ] || {
  printf 'parallel gate took %ss; expected at most 12s for a 24s serial fixture\n' \
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

setup_fixture resumed-release-budget-wall
set_manifest_value "$REPO/tests/release-budget.tsv" wall_seconds_max 1
if DETACH_QUALITY_GATE_TEST_WALL_SECONDS=2 gate --mode repository >"$REPO/resumed-budget-first.out" 2>&1; then
  printf 'quality gate accepted the initial wall-time regression\n' >&2
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
if DETACH_QUALITY_GATE_TEST_WALL_SECONDS=0 gate --mode repository --resume "$resume_dir" \
    >"$REPO/resumed-budget-second.out" 2>&1; then
  printf 'quality gate erased a wall-time regression through resume\n' >&2
  exit 1
fi
grep -F $'inherited_wall_seconds\t2' "$RESULT_ROOT"/*/release-budget.log >/dev/null
grep -F 'wall time regressed: 2s > 1s' "$RESULT_ROOT"/*/release-budget.log >/dev/null

setup_fixture static-only-budget
printf '%s\n' docs >>"$REPO/README.md"
if DETACH_QUALITY_GATE_TEST_STAGE_SECONDS_STATIC=3 gate >"$REPO/static-only-budget.out" 2>&1; then
  printf 'quality gate accepted a slow documentation-only static stage\n' >&2
  exit 1
fi
grep -F 'stage budget: static regressed: 3s > 2s' "$RESULT_ROOT"/*/static.log >/dev/null
grep -F $'static\tfailed\t3' "$RESULT_ROOT"/*/summary.tsv >/dev/null

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
grep -F $'schema\t3' "$run_dir/manifest.tsv" >/dev/null
grep -F $'input_fingerprint\t' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^started_at\t[0-9]{4}-' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^finished_at\t[0-9]{4}-' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^duration_seconds\t[0-9]+$' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^timing_wall_seconds\t[0-9]+$' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^environment_sha256\t[0-9a-f]{64}$' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^artifacts_sha256\t[0-9a-f]{64}$' "$run_dir/manifest.tsv" >/dev/null
grep -E $'^summary_sha256\t[0-9a-f]{64}$' "$run_dir/manifest.tsv" >/dev/null
grep -F $'schema\t1' "$run_dir/environment.tsv" >/dev/null
grep -F $'architecture\t' "$run_dir/environment.tsv" >/dev/null
grep -F $'xcode\t' "$run_dir/environment.tsv" >/dev/null
grep -F $'swift\t' "$run_dir/environment.tsv" >/dev/null
grep -F $'schema\t1' "$run_dir/artifacts.tsv" >/dev/null
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
  DETACH_QUALITY_GATE_TEST_MODE=1 DETACH_QUALITY_GATE_TEST_REAL_STATIC=1 \
    DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" "$REPO/scripts/quality-gate"
) >"$REPO/targeted-static.out"
grep -F 'quality-gate: PASS' "$REPO/targeted-static.out" >/dev/null
if (
  cd -P "$REPO"
  DETACH_QUALITY_GATE_TEST_MODE=1 DETACH_QUALITY_GATE_TEST_REAL_STATIC=1 \
    DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" "$REPO/scripts/quality-gate" --stage static
) >"$REPO/full-static.out" 2>&1; then
  printf 'repository static scan ignored an unchanged malformed shell file\n' >&2
  exit 1
fi
grep -F 'static failed' "$REPO/full-static.out" >/dev/null
fi

case "$CONTRACT_SHARD" in
  all) printf 'Quality gate orchestrator tests passed\n' ;;
  selection) printf 'Quality gate selection tests passed\n' ;;
  execution) printf 'Quality gate execution tests passed\n' ;;
  failures) printf 'Quality gate failure tests passed\n' ;;
  evidence) printf 'Quality gate evidence tests passed\n' ;;
esac
