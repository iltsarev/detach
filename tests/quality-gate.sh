#!/bin/bash

set -euo pipefail

# Contract fixtures choose their authority explicitly. Do not let the parent
# quality-gates job turn nested local diagnostics into CI merge evidence.
unset DETACH_QUALITY_AUTHORITY GITHUB_ACTIONS

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
POLICY_VERSION="$("$ROOT/scripts/quality-policy" version)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-gate-test.XXXXXX")"
TEMPLATE_REPO="$TMP_ROOT/template"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

grep -F 'timeout-minutes: 10' "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'DETACH_QUALITY_AUTHORITY: ci-merge' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: scripts/quality-gate --mode repository --keep-going' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'name: Validate and partition exact pull-request impact' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
quality_plan_job="$(sed -n '/^  quality-plan:/,/^  quality-shards:/p' \
  "$ROOT/.github/workflows/quality-gates.yml")"
printf '%s\n' "$quality_plan_job" | grep -F 'runs-on: ubuntu-latest' >/dev/null
quality_shards_job="$(sed -n '/^  quality-shards:/,/^  quality-gates:/p' \
  "$ROOT/.github/workflows/quality-gates.yml")"
quality_gate_job="$(sed -n '/^  quality-gates:/,/^  quality-dashboard:/p' \
  "$ROOT/.github/workflows/quality-gates.yml")"
printf '%s\n' "$quality_gate_job" | \
  grep -F "runs-on: \${{ github.event_name == 'pull_request' && 'ubuntu-latest' || 'macos-26' }}" \
  >/dev/null
grep -F 'fail-fast: true' "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'scripts/quality-shard plan --base "$BASE_SHA"' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
if grep -F 'github.event.pull_request.base.sha' \
    "$ROOT/.github/workflows/quality-gates.yml" >/dev/null; then
  printf 'quality workflow used the event base instead of the tested merge first parent\n' >&2
  exit 1
fi
if [ "$(grep -Fc 'BASE_SHA="$(git rev-parse HEAD^1)"' \
    "$ROOT/.github/workflows/quality-gates.yml")" -ne 4 ]; then
  printf 'quality workflow did not derive every pull-request base from the tested merge\n' >&2
  exit 1
fi
grep -F 'name: Run level-zero fail-fast contracts' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'scripts/quality-shard run --base "$BASE_SHA" --shard static' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'name: Aggregate authoritative pull-request evidence' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
fail_fast_step="$(sed -n \
  '/name: Run level-zero fail-fast contracts/,/result-root app\/build\/quality-shards\/static/p' \
  "$ROOT/.github/workflows/quality-gates.yml")"
if printf '%s\n' "$fail_fast_step" | grep -F 'DETACH_QUALITY_AUTHORITY' >/dev/null; then
  printf 'quality workflow gave merge authority directly to a shard\n' >&2
  exit 1
fi
grep -F 'if: matrix.needs_metrics' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'if: matrix.needs_cache' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'key: detach-app-v2-' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'app/.build/tmux-runtime/arm64/product' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "'app/scripts/verify-app.sh'" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'name: Verify and bind exact packaged test app' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "steps.app-cache.outputs.cache-hit != 'true'" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
app_cache_hit_step="$(printf '%s\n' "$quality_shards_job" | sed -n \
  '/name: Verify and bind exact packaged test app/,/name: Build and bind exact packaged test app/p')"
printf '%s\n' "$app_cache_hit_step" | \
  grep -F "steps.app-cache.outputs.cache-hit == 'true'" >/dev/null
printf '%s\n' "$app_cache_hit_step" | \
  grep -F 'app/scripts/verify-app.sh' >/dev/null
printf '%s\n' "$app_cache_hit_step" | \
  grep -F 'DETACH_QUALITY_EXACT_APP=1' >/dev/null
app_cache_miss_step="$(printf '%s\n' "$quality_shards_job" | sed -n \
  '/name: Build and bind exact packaged test app/,/name: Run exact quality shard/p')"
printf '%s\n' "$app_cache_miss_step" | \
  grep -F "steps.app-cache.outputs.cache-hit != 'true'" >/dev/null
printf '%s\n' "$app_cache_miss_step" | \
  grep -F 'DETACH_QUALITY_APP_SCRATCH: 1' >/dev/null
printf '%s\n' "$app_cache_miss_step" | \
  grep -F 'app/scripts/make-app.sh' >/dev/null
printf '%s\n' "$app_cache_miss_step" | \
  grep -F 'DETACH_QUALITY_EXACT_APP=1' >/dev/null
app_build_line="$(printf '%s\n' "$app_cache_miss_step" | \
  grep -nF 'app/scripts/make-app.sh' | cut -d: -f1)"
app_bind_line="$(printf '%s\n' "$app_cache_miss_step" | \
  grep -nF 'DETACH_QUALITY_EXACT_APP=1' | cut -d: -f1)"
if [ "$app_bind_line" -le "$app_build_line" ]; then
  printf 'quality workflow bound a fresh app before its build completed\n' >&2
  exit 1
fi
grep -F 'key: detach-quality-products-v2-' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'app/.build/quality-products-v1.json' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'app/.build/quality-runtime/detach-state' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
printf '%s\n' "$quality_shards_job" | grep -F \
  "if: matrix.needs_app || (matrix.needs_runtime && steps.product-cache.outputs.cache-hit != 'true')" \
  >/dev/null
grep -F 'python3 tools/quality_products.py verify' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'DETACH_QUALITY_EXACT_PRODUCTS=1' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "steps.product-cache.outputs.cache-hit != 'true'" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'name: Publish exact main executable products' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: python3 tools/quality_products.py publish' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'name: Save exact executable quality products' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'key: detach-swift-v3-' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: scripts/quality-cache-warm --reuse-exact-products' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: scripts/quality-cache-warm --record-product-inputs' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "steps.main-products.outcome == 'success'" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'DETACH_QUALITY_APP_SCRATCH: 1' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: scripts/quality-cache-warm' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
swift_warm_step="$(sed -n \
  '/name: Warm exact promoted-main Swift cache/,/run: scripts\/quality-cache-warm/p' \
  "$ROOT/.github/workflows/quality-gates.yml")"
printf '%s\n' "$swift_warm_step" | \
  grep -F "steps.product-cache.outputs.cache-hit != 'true'" >/dev/null
printf '%s\n' "$swift_warm_step" | \
  grep -F "steps.app-cache.outputs.cache-hit != 'true'" >/dev/null
grep -F 'name: Materialize exact Swift dependencies' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'id: swift-dependencies' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'run: scripts/quality-cache-warm --dependencies-only' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
if grep -F 'jq ' "$ROOT/.github/workflows/quality-gates.yml" >/dev/null; then
  printf 'quality workflow reintroduced ambient jq\n' >&2
  exit 1
fi
grep -F 'name: Promote exact pull-request evidence' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F '  pull-requests: read' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'promotion_root="$(scripts/quality-promote 2>"$error_log")"' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "steps.promoted-main.outputs.promoted != 'true'" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
! grep -F 'detach-release/' "$ROOT/.github/workflows/quality-gates.yml" >/dev/null || {
  printf 'quality gate has a duplicate release-branch push path\n' >&2
  exit 1
}
! grep -E 'uses:[[:space:]]+[^[:space:]]+@v[0-9]' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null || {
  printf 'quality gate workflow contains a mutable Action tag\n' >&2
  exit 1
}
grep -F 'quality-dashboard:' "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "if: github.event_name == 'push' && github.ref == 'refs/heads/main'" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'pages: write' "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'scripts/quality-dashboard generate' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'scripts/quality-care latest --optional' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'care_args+=(--care-summary' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'MUTATION_SUMMARY:' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F 'delimiter="detach-$(uuidgen)"' \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
grep -F "printf 'summary<<%s\\n' \"\$delimiter\"" \
  "$ROOT/.github/workflows/quality-gates.yml" >/dev/null
if grep -F '<<EOF' \
    "$ROOT/.github/workflows/quality-gates.yml" >/dev/null; then
  printf 'quality dashboard uses a predictable output delimiter\n' >&2
  exit 1
fi
if grep -F 'if [ -n "${{' \
    "$ROOT/.github/workflows/quality-gates.yml" >/dev/null; then
  printf 'quality dashboard interpolates step outputs into the shell\n' >&2
  exit 1
fi
if grep -F "printf 'summary=%s\\n'" \
    "$ROOT/.github/workflows/quality-gates.yml" >/dev/null; then
  printf 'quality dashboard writes summary outputs without a delimiter\n' >&2
  exit 1
fi

prepare_template() {
  local stage
  mkdir -p "$TEMPLATE_REPO/scripts" "$TEMPLATE_REPO/tests/quality-gate-fixtures" \
    "$TEMPLATE_REPO/app/build" "$TEMPLATE_REPO/docs/specs" \
    "$TEMPLATE_REPO/quality/generated" "$TEMPLATE_REPO/tools"
  install -m 0755 "$ROOT/scripts/quality-gate" "$TEMPLATE_REPO/scripts/quality-gate"
  install -m 0755 "$ROOT/scripts/quality-shard" "$TEMPLATE_REPO/scripts/quality-shard"
  install -m 0755 "$ROOT/scripts/quality-policy" "$TEMPLATE_REPO/scripts/quality-policy"
  install -m 0755 "$ROOT/scripts/quality-metrics" "$TEMPLATE_REPO/scripts/quality-metrics"
  install -m 0755 "$ROOT/scripts/quality-baseline" "$TEMPLATE_REPO/scripts/quality-baseline"
  install -m 0755 "$ROOT/scripts/quality-dashboard" "$TEMPLATE_REPO/scripts/quality-dashboard"
  install -m 0755 "$ROOT/scripts/release-impact" "$TEMPLATE_REPO/scripts/release-impact"
  install -m 0644 "$ROOT/tools/quality_gate.py" "$TEMPLATE_REPO/tools/quality_gate.py"
  install -m 0644 "$ROOT/tools/quality_shard.py" "$TEMPLATE_REPO/tools/quality_shard.py"
  install -m 0644 "$ROOT/tools/quality_scenarios.py" "$TEMPLATE_REPO/tools/quality_scenarios.py"
  install -m 0644 "$ROOT/tools/quality_policy.py" "$TEMPLATE_REPO/tools/quality_policy.py"
  install -m 0644 "$ROOT/tools/quality_metrics.py" "$TEMPLATE_REPO/tools/quality_metrics.py"
  install -m 0644 "$ROOT/tools/quality_dashboard.py" "$TEMPLATE_REPO/tools/quality_dashboard.py"
  install -m 0755 "$ROOT/scripts/test" "$TEMPLATE_REPO/scripts/test"
  install -m 0644 "$ROOT/quality/policy.tsv" "$TEMPLATE_REPO/quality/policy.tsv"
  install -m 0644 "$ROOT/quality/generated/policy.json" \
    "$TEMPLATE_REPO/quality/generated/policy.json"
  install -m 0644 "$ROOT"/docs/specs/*.md "$TEMPLATE_REPO/docs/specs/"
  install -m 0755 "$ROOT/tests/shell-safety.sh" "$ROOT/tests/quality-policy.sh" \
    "$ROOT/tests/quality-dashboard.sh" "$TEMPLATE_REPO/tests/"
  printf '#!/bin/bash\nexit 0\n' >"$TEMPLATE_REPO/tests/docs-contract.sh"
  chmod 0755 "$TEMPLATE_REPO/tests/docs-contract.sh"
  printf '#!/bin/bash\nexit 0\n' >"$TEMPLATE_REPO/tests/test-suite-contract.sh"
  chmod 0755 "$TEMPLATE_REPO/tests/test-suite-contract.sh"
  printf '%s\n' baseline >"$TEMPLATE_REPO/README.md"
  printf '%s\n' actions.log results aggregate tampered-aggregate '*.out' /presentations/ \
    >"$TEMPLATE_REPO/.gitignore"
  for stage in static gate-contract swift quality-contracts app ui-e2e codex claude distribution tmux-runtime release-preflight publish-preflight release-workflow; do
    printf '#!/bin/bash\nset -eu\nexpected_cache="${GATE_EXPECTED_MODULE_CACHE:?}/%s"\n[ -z "${DETACH_CONFIRM_RELEASE:-}" ] || { printf "release confirmation leaked into stage\\n" >&2; exit 1; }\n[ -z "${DETACH_QUALITY_GATE_RESULT_ROOT:-}" ] || { printf "quality result root leaked into stage\\n" >&2; exit 1; }\n[ "${CLANG_MODULE_CACHE_PATH:-}" = "$expected_cache" ] || { printf "unexpected Clang module cache: %%s\\n" "${CLANG_MODULE_CACHE_PATH:-missing}" >&2; exit 1; }\n[ "${SWIFTPM_MODULECACHE_OVERRIDE:-}" = "$expected_cache" ] || { printf "unexpected SwiftPM module cache: %%s\\n" "${SWIFTPM_MODULECACHE_OVERRIDE:-missing}" >&2; exit 1; }\nprintf "%%s\\n" "%s" >>"${GATE_ACTION_LOG:?}"\n[ "${STAGE_SLEEP:-0}" = 0 ] || sleep "$STAGE_SLEEP"\ncase " ${FAIL_STAGES:-} " in *" %s "*) exit 23 ;; esac\n' "$stage" "$stage" "$stage" \
      >"$TEMPLATE_REPO/tests/quality-gate-fixtures/$stage"
    chmod 0755 "$TEMPLATE_REPO/tests/quality-gate-fixtures/$stage"
  done
  printf '%s\n' \
    '[ -n "${DETACH_QUALITY_SOURCE_COMMIT:-}" ] || { printf "quality source commit missing\\n" >&2; exit 1; }' \
    '[ -n "${DETACH_QUALITY_AUTHORITY:-}" ] || { printf "quality authority missing\\n" >&2; exit 1; }' \
    '[ -z "${DETACH_QUALITY_METRICS_OUTPUT:-}" ] || printf "{}\\n" >"$DETACH_QUALITY_METRICS_OUTPUT"' \
    >>"$TEMPLATE_REPO/tests/quality-gate-fixtures/quality-contracts"
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

commit_ci_merge() {
  local path="$1" value="$2" feature
  git -C "$REPO" checkout -qb impact-feature
  mkdir -p "$(dirname "$REPO/$path")"
  printf '%s\n' "$value" >"$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit -qm impact-feature
  feature="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb tested-merge "$BASE"
  git -C "$REPO" merge -q --no-ff --no-edit "$feature"
  CI_MERGE="$(git -C "$REPO" rev-parse HEAD)"
}

gate() {
  local release_confirmation="${DETACH_TEST_RELEASE_CONFIRMATION:-}"
  (
    cd -P "$REPO"
    GATE_ACTION_LOG="$ACTION_LOG" \
      GATE_EXPECTED_MODULE_CACHE="$REPO/app/.build/module-cache" \
      DETACH_QUALITY_GATE_TEST_MODE=1 \
      DETACH_QUALITY_GATE_TEST_DIRECT="${DETACH_QUALITY_GATE_TEST_DIRECT:-1}" \
      DETACH_QUALITY_GATE_RESULT_ROOT="$RESULT_ROOT" \
      DETACH_CONFIRM_RELEASE="$release_confirmation" \
      "$REPO/scripts/quality-gate" "$@"
  )
}

production_plan() {
  local release_confirmation="${DETACH_TEST_RELEASE_CONFIRMATION:-}"
  (
    cd -P "$REPO"
    GITHUB_ACTIONS= \
      DETACH_CONFIRM_RELEASE="$release_confirmation" \
      "$REPO/scripts/quality-gate" "$@"
  )
}

quality_shard() {
  (
    cd -P "$REPO"
    GITHUB_ACTIONS=true \
      GITHUB_SHA="$CI_MERGE" \
      GATE_ACTION_LOG="$ACTION_LOG" \
      GATE_EXPECTED_MODULE_CACHE="$REPO/app/.build/module-cache" \
      DETACH_QUALITY_GATE_TEST_MODE=1 \
      DETACH_QUALITY_GATE_TEST_DIRECT=1 \
      "$REPO/scripts/quality-shard" "$@"
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
  all|selection|execution|failures|distributed|evidence|evidence-resume|evidence-resume-a|evidence-resume-b|evidence-runtime|evidence-runtime-a|evidence-runtime-b) ;;
  *) printf 'invalid quality-gate contract shard\n' >&2; exit 2 ;;
esac

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = selection ]; then
setup_fixture docs
stages="$(gate --list-stages)"
[ "$(printf '%s\n' "$stages" | wc -l | tr -d ' ')" = 13 ]
[ "$(printf '%s\n' "$stages" | head -1)" = static ]
[ "$(printf '%s\n' "$stages" | tail -1)" = release-workflow ]
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static' ]]

setup_fixture docs-contract
printf '%s\n' '# changed contract' >"$REPO/tests/docs-contract.sh"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static' ]]

setup_fixture codex-provider-test
printf '%s\n' '#!/bin/bash' >"$REPO/tests/run.sh"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,codex' ]]

setup_fixture claude-provider-test
printf '%s\n' '#!/bin/bash' >"$REPO/tests/run-claude.sh"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,claude' ]]

setup_fixture ignored-presentations
clean_plan="$(gate --plan)"
mkdir -p "$REPO/presentations"
printf '%s\n' '<html>internal</html>' >"$REPO/presentations/internal.html"
ignored_plan="$(gate --plan)"
[ "$ignored_plan" = "$clean_plan" ]
[ -z "$(git -C "$REPO" ls-files --others --exclude-standard presentations)" ]

setup_fixture swift
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e' ]]

setup_fixture swift-test
mkdir -p "$REPO/app/Tests/DetachKitTests"
printf '%s\n' 'final class ChangedTests {}' \
  >"$REPO/app/Tests/DetachKitTests/ChangedTests.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts' ]]

setup_fixture typed-state-impact
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct ChangedState {}' >"$REPO/app/Sources/DetachKit/DetachStateCommand.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,codex,claude' ]]

setup_fixture power-impact
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct ChangedPower {}' >"$REPO/app/Sources/DetachKit/PowerHelperLeaseService.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e' ]]

setup_fixture onboarding-journey-impact
mkdir -p "$REPO/app/Sources/DetachApp"
printf '%s\n' 'struct ChangedOnboarding {}' \
  >"$REPO/app/Sources/DetachApp/OnboardingFuture.swift"
plan="$(gate --plan)"
[[ "$plan" = *'specs=app'* ]]
[[ "$plan" = *'capabilities=onboarding'* ]]
[[ "$plan" = *'journeys=J-ONBOARD-FIRST-RUN,J-ONBOARD-PROVIDER,J-ONBOARD-APPROVAL'* ]]

setup_fixture package
mkdir -p "$REPO/app"
printf '%s\n' '// changed package' >"$REPO/app/Package.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,tmux-runtime' ]]

setup_fixture shell
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution' ]]

setup_fixture release-files
printf '%s\n' 999 >"$REPO/BUILD"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,release-preflight,publish-preflight,release-workflow' ]]

setup_fixture release-impact
printf '%s\n' '#!/bin/bash' >"$REPO/scripts/release-impact"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,release-preflight,publish-preflight,release-workflow' ]]

setup_fixture mixed
mkdir -p "$REPO/bin" "$REPO/app/Sources/DetachKit"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
printf '%s\n' 'struct Changed {}' >"$REPO/app/Sources/DetachKit/Changed.swift"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e,codex,claude,distribution' ]]

setup_fixture base-ref
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct CommittedChange {}' >"$REPO/app/Sources/DetachKit/Committed.swift"
git -C "$REPO" add .
git -C "$REPO" commit -qm change
printf '%s\n' docs >>"$REPO/README.md"
plan="$(gate --base "$BASE" --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e' ]]

setup_fixture unknown
printf '%s\n' unknown >"$REPO/new-contract.data"
plan="$(gate --plan 2>&1)"
[[ "$plan" = *'stages=static,gate-contract,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow' ]]

setup_fixture deletion
mkdir -p "$REPO/bin"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
rm "$REPO/bin/detach"
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution' ]]

setup_fixture rename
mkdir -p "$REPO/bin" "$REPO/docs"
printf '%s\n' '#!/bin/bash' >"$REPO/bin/detach"
git -C "$REPO" add .
git -C "$REPO" commit -qm add-lifecycle-file
git -C "$REPO" mv bin/detach docs/moved.md
plan="$(gate --plan)"
[[ "$plan" = *'stages=static,app,codex,claude,distribution' ]]

setup_fixture unusual-name
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct OddName {}' >"$REPO/app/Sources/DetachKit/line
break.swift"
plan="$(gate --plan --format json)"
[[ "$plan" = '{"policy":'"$POLICY_VERSION"',"mode":"change","authority":"local-diagnostic","source_commit":"'* ]]
[[ "$plan" = *'"base_commit":"","input_fingerprint":"'* ]]
[[ "$plan" = *'"stages":["static","swift","quality-contracts","app","ui-e2e"]}' ]]

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
grep -F "quality-gate: PASS policy=$POLICY_VERSION authority=release" \
  "$REPO/release.out" >/dev/null

setup_fixture impact-release
mkdir -p "$REPO/app/Sources/DetachKit"
printf '%s\n' 'struct ReleaseImpact {}' >"$REPO/app/Sources/DetachKit/ReleaseImpact.swift"
git -C "$REPO" add .
git -C "$REPO" commit -qm release-impact
plan="$(gate --mode release --base "$BASE" --plan)"
[[ "$plan" = *'stages=static,swift,quality-contracts,app,ui-e2e'* ]]
[[ "$plan" != *'codex'* ]]
[[ "$plan" != *'release-workflow'* ]]

setup_fixture github-impact
commit_ci_merge .github/workflows/quality-gates.yml '# impact core'
plan="$(GITHUB_ACTIONS=true GITHUB_SHA="$CI_MERGE" DETACH_QUALITY_AUTHORITY=ci-merge \
  gate --mode impact --base "$BASE" --plan)"
[[ "$plan" = *'stages=static,gate-contract,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight,release-workflow' ]]
[[ "$plan" = *'authority=ci-merge'* ]]
plan="$(GITHUB_ACTIONS=true GITHUB_SHA="$CI_MERGE" DETACH_QUALITY_AUTHORITY=ci-shard \
  gate --mode impact --base "$BASE" --shard static,gate-contract --plan)"
[[ "$plan" = *'authority=ci-shard'* ]]
[[ "$plan" = *'stages=static,gate-contract'* ]]
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = distributed ]; then
setup_fixture distributed
commit_ci_merge .github/workflows/quality-gates.yml '# distributed impact'
for shard in static contracts-and-runtime build-and-coverage codex \
    claude-and-publish distribution-and-release; do
  quality_shard run --base "$BASE" --shard "$shard" \
    --result-root "$RESULT_ROOT/$shard" >/dev/null
done
quality_shard aggregate --base "$BASE" --input-root "$RESULT_ROOT" \
  --result-root "$REPO/aggregate" >"$REPO/shard-aggregate.out"
grep -F 'quality-shard: PASS evidence=' "$REPO/shard-aggregate.out" >/dev/null
grep -F $'authority\tci-merge' "$REPO/aggregate"/*/manifest.tsv >/dev/null
grep -F $'file\tshards.tsv\t' "$REPO/aggregate"/*/artifacts.tsv >/dev/null
awk -F '\t' 'NR > 1 && $8 != "-" {exit 1}' \
  "$REPO/aggregate"/*/summary.tsv
printf 'tampered\n' >>"$RESULT_ROOT/static"/*/static.log
if quality_shard aggregate --base "$BASE" --input-root "$RESULT_ROOT" \
    --result-root "$REPO/tampered-aggregate" \
    >"$REPO/tampered-shard.out" 2>&1; then
  printf 'quality shard aggregation accepted a tampered log\n' >&2
  exit 1
fi
grep -F 'summary log digest does not match: static' \
  "$REPO/tampered-shard.out" >/dev/null
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = selection ]; then
setup_fixture github-docs-impact
commit_ci_merge README.md 'documentation impact'
plan="$(GITHUB_ACTIONS=true GITHUB_SHA="$CI_MERGE" DETACH_QUALITY_AUTHORITY=ci-merge \
  gate --mode impact --base "$BASE" --plan)"
[[ "$plan" = *'stages=static specs=documentation capabilities=documentation'* ]]
[[ "$plan" != *'swift'* ]]
if GITHUB_ACTIONS=true GITHUB_SHA="$CI_MERGE" DETACH_QUALITY_AUTHORITY=ci-shard \
    gate --mode impact --base "$BASE" --shard swift --plan \
      >"$REPO/unplanned-shard.out" 2>&1; then
  printf 'quality gate accepted an unplanned shard stage\n' >&2
  exit 1
fi
grep -F 'shard contains an unplanned stage: swift' \
  "$REPO/unplanned-shard.out" >/dev/null
if GITHUB_ACTIONS=true GITHUB_SHA="$CI_MERGE" DETACH_QUALITY_AUTHORITY=ci-merge \
    gate --mode impact --base "$CI_MERGE^2" --plan \
    >"$REPO/wrong-impact-base.out" 2>&1; then
  printf 'quality gate accepted a non-first-parent CI impact base\n' >&2
  exit 1
fi
grep -F 'ci-merge base is not the tested merge first parent' \
  "$REPO/wrong-impact-base.out" >/dev/null

setup_fixture github-spoof
if DETACH_QUALITY_AUTHORITY=ci-merge gate --mode impact --base "$BASE" --plan \
    >"$REPO/spoof-authority.out" 2>&1; then
  printf 'quality gate accepted spoofed CI merge authority\n' >&2
  exit 1
fi
grep -F 'ci-merge authority is restricted to GitHub Actions' \
  "$REPO/spoof-authority.out" >/dev/null

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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 12 ]

setup_fixture ui-e2e-timeout
printf '#!/bin/bash\nsleep 5\n' >"$REPO/tests/quality-gate-fixtures/ui-e2e"
chmod 0755 "$REPO/tests/quality-gate-fixtures/ui-e2e"
if DETACH_QUALITY_GATE_TEST_DIRECT=0 DETACH_QUALITY_GATE_TIMEOUT_UI_E2E=1 \
  gate --stage ui-e2e \
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
    DETACH_QUALITY_GATE_TEST_DIRECT=0 \
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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 15 ]
[ "$(awk '$0 == "ui-e2e" { count += 1 } END { print count + 0 }' \
    "$ACTION_LOG")" = 2 ]
grep -F $'result\tpassed' "$RESULT_ROOT"/*/manifest.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="13" failures="0" skipped="10">' "$RESULT_ROOT"/*/junit.xml >/dev/null
grep -F $'resumed_from_run\t'"$(basename "$resume_dir")" "$resumed_run/manifest.tsv" >/dev/null
expected_parent_digest="$(shasum -a 256 "$resume_dir/manifest.tsv" | awk '{print $1}')"
grep -F $'resumed_from_manifest_sha256\t'"$expected_parent_digest" "$resumed_run/manifest.tsv" >/dev/null
reused_log="$(awk -F '\t' '$3 == "static" {print $6}' "$resumed_run/summary.tsv")"
reused_log_sha256="$(awk -F '\t' '$3 == "static" {print $7}' "$resumed_run/summary.tsv")"
[ "$reused_log" != - ]
[ "$(shasum -a 256 "$resumed_run/$reused_log" | awk '{print $1}')" = "$reused_log_sha256" ]
grep -F $'origin_run\n' "$resumed_run/summary.tsv" >/dev/null

# Release mode reuses digest-bound hosted evidence for the exact source
# commit. A ci-main run names the commit directly; a promoted ci-merge run
# binds it through a promotion record with equal trees.
setup_fixture hosted-reuse
gate --mode repository >"$REPO/hosted-source.out"
hosted_source="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
mkdir -p "$REPO/hosted"
cp -R "$hosted_source" "$REPO/hosted/"
hosted_dir="$REPO/hosted/$(basename "$hosted_source")"
rm -rf "$RESULT_ROOT"
set_manifest_value "$hosted_dir/manifest.tsv" authority ci-main
# Aggregated hosted runs inventory their shard binding table too.
printf 'schema\t1\nshard\tstatic\n' >"$hosted_dir/shards.tsv"
printf 'file\tshards.tsv\t%s\n' \
  "$(shasum -a 256 "$hosted_dir/shards.tsv" | awk '{print $1}')" \
  >>"$hosted_dir/artifacts.tsv"
set_manifest_value "$hosted_dir/manifest.tsv" artifacts_sha256 \
  "$(shasum -a 256 "$hosted_dir/artifacts.tsv" | awk '{print $1}')"
: >"$ACTION_LOG"
gate --mode release --reuse-hosted "$hosted_dir" >"$REPO/hosted-reuse.out"
grep -F "hosted evidence $(basename "$hosted_dir") proves static,gate-contract,swift,quality-contracts,app,ui-e2e,codex,claude,distribution,tmux-runtime,release-preflight,publish-preflight for" \
  "$REPO/hosted-reuse.out" >/dev/null
grep -F "reusing codex from hosted evidence $hosted_dir" "$REPO/hosted-reuse.out" >/dev/null
grep -F "quality-gate: PASS policy=$POLICY_VERSION authority=release" \
  "$REPO/hosted-reuse.out" >/dev/null
[ ! -s "$ACTION_LOG" ]
grep -F $'codex\treused\t' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F "$(basename "$hosted_dir")" "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'resumed_from_run\t' "$RESULT_ROOT"/*/manifest.tsv | grep -qv "$(basename "$hosted_dir")"
if gate --mode change --reuse-hosted "$hosted_dir" --plan >"$REPO/hosted-change.out" 2>&1; then
  printf 'quality gate accepted hosted reuse outside release mode\n' >&2
  exit 1
fi
grep -F -- '--reuse-hosted requires release mode' "$REPO/hosted-change.out" >/dev/null
rm -rf "$RESULT_ROOT"
printf 'tampered\n' >>"$hosted_dir/codex.log"
if gate --mode release --reuse-hosted "$hosted_dir" >"$REPO/hosted-tampered.out" 2>&1; then
  printf 'quality gate reused a tampered hosted log\n' >&2
  exit 1
fi
grep -F 'log digest does not match: codex' "$REPO/hosted-tampered.out" >/dev/null
sed -i '' '$d' "$hosted_dir/codex.log"
rm -rf "$RESULT_ROOT"
git -C "$REPO" commit -q --allow-empty -m 'same tree, new commit'
if gate --mode release --reuse-hosted "$hosted_dir" >"$REPO/hosted-unbound.out" 2>&1; then
  printf 'quality gate reused hosted evidence for another commit\n' >&2
  exit 1
fi
grep -F 'hosted evidence is not bound to the source commit' "$REPO/hosted-unbound.out" >/dev/null
rm -rf "$RESULT_ROOT"
set_manifest_value "$hosted_dir/manifest.tsv" authority ci-merge
hosted_tree="$(git -C "$REPO" rev-parse HEAD^{tree})"
printf '%s\n' \
  $'schema\t1' $'authority\tci-main' $'result\tpassed' \
  "repository	example/detach" \
  "main_commit	$(git -C "$REPO" rev-parse HEAD)" \
  "main_tree	$hosted_tree" \
  "tested_commit	$BASE" \
  "tested_tree	$hosted_tree" \
  "source_manifest_sha256	$(shasum -a 256 "$hosted_dir/manifest.tsv" | awk '{print $1}')" \
  >"$hosted_dir/promotion.tsv"
: >"$ACTION_LOG"
gate --mode release --reuse-hosted "$hosted_dir" >"$REPO/hosted-promoted.out"
grep -F "reusing claude from hosted evidence" "$REPO/hosted-promoted.out" >/dev/null
[ ! -s "$ACTION_LOG" ]
rm -rf "$RESULT_ROOT"
if DETACH_QUALITY_REPOSITORY=other/detach gate --mode release --reuse-hosted "$hosted_dir" \
    >"$REPO/hosted-repository.out" 2>&1; then
  printf 'quality gate reused hosted evidence from another repository\n' >&2
  exit 1
fi
grep -F 'hosted promotion names another repository' "$REPO/hosted-repository.out" >/dev/null

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
grep -F '<testsuite name="detach-quality-gate" tests="13" failures="2" skipped="1">' "$RESULT_ROOT"/*/junit.xml >/dev/null

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

setup_fixture ui-environment-denial
printf '#!/bin/bash\nprintf "UI e2e: environment denied: no interactive GUI session (no-session)\\n" >&2\nexit 2\n' \
  >"$REPO/tests/quality-gate-fixtures/ui-e2e"
chmod 0755 "$REPO/tests/quality-gate-fixtures/ui-e2e"
if gate --mode repository >"$REPO/ui-environment-denial.out" 2>&1; then
  printf 'quality gate accepted a UI smoke without a GUI session\n' >&2
  exit 1
fi
grep -F $'ui-e2e\tenvironment-failed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F 'ui-e2e environment-failed' "$REPO/ui-environment-denial.out" >/dev/null
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = execution ] || \
   [ "$CONTRACT_SHARD" = evidence ] || [ "$CONTRACT_SHARD" = evidence-resume ] || \
   [ "$CONTRACT_SHARD" = evidence-resume-a ]; then
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

setup_fixture auto-resume
printf '%s\n' docs >>"$REPO/README.md"
gate --mode repository --resume auto >"$REPO/auto-first.out"
grep -F 'starting a fresh compatible run' "$REPO/auto-first.out" >/dev/null
gate --mode repository --resume auto >"$REPO/auto-second.out"
grep -F 'selected latest compatible evidence' "$REPO/auto-second.out" >/dev/null
grep -F 'reusing static from matching evidence' "$REPO/auto-second.out" >/dev/null

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
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = execution ] || \
   [ "$CONTRACT_SHARD" = evidence ] || [ "$CONTRACT_SHARD" = evidence-resume ] || \
   [ "$CONTRACT_SHARD" = evidence-resume-b ]; then
setup_fixture tampered-summary
if FAIL_STAGES=swift gate --mode repository >"$REPO/tamper-first.out" 2>&1; then
  exit 1
fi
resume_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
printf '%s\n' $'9\trepository\tapp\tpassed\t0\tapp.log\tinvalid\t-' >>"$resume_dir/summary.tsv"
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
printf '%s\n' $'9\trepository\tstatic\tpassed\t0\tduplicate.log\tinvalid\t-' >>"$resume_dir/summary.tsv"
refresh_summary_digest "$resume_dir"
if gate --mode repository --resume "$resume_dir" >"$REPO/invalid-summary-second.out" 2>&1; then
  printf 'quality gate accepted duplicate stage records\n' >&2
  exit 1
fi
grep -F 'resume summary contains invalid or duplicate stage records' "$REPO/invalid-summary-second.out" >/dev/null
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = execution ] || \
   [ "$CONTRACT_SHARD" = evidence ] || [ "$CONTRACT_SHARD" = evidence-runtime ] || \
   [ "$CONTRACT_SHARD" = evidence-runtime-a ]; then
setup_fixture stage-timeout
printf '#!/bin/bash\nsleep 5\n' >"$REPO/tests/quality-gate-fixtures/static"
chmod 0755 "$REPO/tests/quality-gate-fixtures/static"
if DETACH_QUALITY_GATE_TEST_DIRECT=0 DETACH_QUALITY_GATE_TIMEOUT=10 \
  DETACH_QUALITY_GATE_TIMEOUT_STATIC=1 gate --stage static \
  >"$REPO/stage-timeout.out" 2>&1; then
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
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 8 ]
grep -F $'codex\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'tmux-runtime\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'ui-e2e\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'quality-contracts\tblocked' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F '<testsuite name="detach-quality-gate" tests="13" failures="1" skipped="5">' "$RESULT_ROOT"/*/junit.xml >/dev/null

setup_fixture parallel-lanes
PARALLEL_ROOT="$REPO/parallel"
mkdir -p "$PARALLEL_ROOT"
for parallel_stage in codex claude; do
  parallel_peer=codex
  [ "$parallel_stage" = codex ] && parallel_peer=claude
  cat >"$REPO/tests/quality-gate-fixtures/$parallel_stage" <<SH
#!/bin/bash
set -eu
: >"\${GATE_PARALLEL_ROOT:?}/$parallel_stage"
attempt=0
while [ ! -f "\$GATE_PARALLEL_ROOT/$parallel_peer" ] && [ "\$attempt" -lt 50 ]; do
  attempt=\$((attempt + 1))
  sleep 0.1
done
[ -f "\$GATE_PARALLEL_ROOT/$parallel_peer" ]
SH
done
chmod 0755 \
  "$REPO/tests/quality-gate-fixtures/codex" \
  "$REPO/tests/quality-gate-fixtures/claude"
GATE_PARALLEL_ROOT="$PARALLEL_ROOT" gate --mode repository >"$REPO/parallel.out"
[ "$(wc -l <"$ACTION_LOG" | tr -d ' ')" = 11 ]
grep -F 'quality-gate: DIAGNOSTIC PASS' "$REPO/parallel.out" >/dev/null

setup_fixture resource-order
ORDER_ROOT="$REPO/order"
mkdir -p "$ORDER_ROOT"
cat >"$REPO/tests/quality-gate-fixtures/swift" <<'SH'
#!/bin/bash
set -eu
: >"${GATE_ORDER_ROOT:?}/swift-started"
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/app-started" ] && [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/app-started" ]
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/app" ] && [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/app" ]
: >"$GATE_ORDER_ROOT/swift"
SH
cat >"$REPO/tests/quality-gate-fixtures/app" <<'SH'
#!/bin/bash
set -eu
: >"${GATE_ORDER_ROOT:?}/app-started"
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/swift-started" ] && [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/swift-started" ]
[ ! -f "$GATE_ORDER_ROOT/swift" ]
: >"$GATE_ORDER_ROOT/app"
SH
cat >"$REPO/tests/quality-gate-fixtures/quality-contracts" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/swift" ]
[ -f "${GATE_ORDER_ROOT:?}/ui-e2e" ]
printf '{}\n' >"${DETACH_QUALITY_METRICS_OUTPUT:?}"
: >"$GATE_ORDER_ROOT/quality-contracts"
SH
cat >"$REPO/tests/quality-gate-fixtures/ui-e2e" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/app" ]
: >"$GATE_ORDER_ROOT/ui-e2e"
SH
cat >"$REPO/tests/quality-gate-fixtures/codex" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/app" ]
[ -f "$GATE_ORDER_ROOT/ui-e2e" ]
[ -f "$GATE_ORDER_ROOT/quality-contracts" ]
[ -f "$GATE_ORDER_ROOT/gate-contract" ]
: >"$GATE_ORDER_ROOT/codex-started"
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/release-workflow-started" ] && \
    [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/release-workflow-started" ]
: >"$GATE_ORDER_ROOT/codex"
SH
cat >"$REPO/tests/quality-gate-fixtures/gate-contract" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/ui-e2e" ]
[ -f "$GATE_ORDER_ROOT/quality-contracts" ]
: >"$GATE_ORDER_ROOT/gate-contract-started"
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/short-preflight-during-contract" ] && \
    [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/short-preflight-during-contract" ]
: >"$GATE_ORDER_ROOT/gate-contract"
SH
cat >"$REPO/tests/quality-gate-fixtures/distribution" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/gate-contract" ]
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/release-workflow" ] && [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/release-workflow" ]
[ -f "$GATE_ORDER_ROOT/claude-started" ]
[ ! -f "$GATE_ORDER_ROOT/claude" ]
: >"$GATE_ORDER_ROOT/integration-after-release"
SH
cat >"$REPO/tests/quality-gate-fixtures/publish-preflight" <<'SH'
#!/bin/bash
set -eu
attempt=0
while [ ! -f "${GATE_ORDER_ROOT:?}/gate-contract-started" ] && \
    [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/gate-contract-started" ]
[ ! -f "$GATE_ORDER_ROOT/gate-contract" ]
[ ! -f "$GATE_ORDER_ROOT/codex-started" ]
: >"$GATE_ORDER_ROOT/short-preflight-during-contract"
SH
cat >"$REPO/tests/quality-gate-fixtures/release-workflow" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/gate-contract" ]
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/codex-started" ] && [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/codex-started" ]
[ ! -f "$GATE_ORDER_ROOT/codex" ]
: >"$GATE_ORDER_ROOT/release-workflow-started"
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/claude-started" ] && [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/claude-started" ]
[ ! -f "$GATE_ORDER_ROOT/claude" ]
: >"$GATE_ORDER_ROOT/release-workflow"
SH
cat >"$REPO/tests/quality-gate-fixtures/claude" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/gate-contract" ]
[ -f "$GATE_ORDER_ROOT/release-workflow-started" ]
[ ! -f "$GATE_ORDER_ROOT/release-workflow" ]
: >"$GATE_ORDER_ROOT/claude-started"
attempt=0
while [ ! -f "$GATE_ORDER_ROOT/integration-after-release" ] && \
    [ "$attempt" -lt 50 ]; do
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -f "$GATE_ORDER_ROOT/integration-after-release" ]
: >"$GATE_ORDER_ROOT/claude"
SH
for ordered_stage in tmux-runtime release-preflight; do
  cat >"$REPO/tests/quality-gate-fixtures/$ordered_stage" <<'SH'
#!/bin/bash
set -eu
[ -f "${GATE_ORDER_ROOT:?}/quality-contracts" ]
for prerequisite_stage in ui-e2e; do
  [ -f "${GATE_ORDER_ROOT:?}/$prerequisite_stage" ]
done
SH
done
chmod 0755 \
  "$REPO/tests/quality-gate-fixtures/swift" \
  "$REPO/tests/quality-gate-fixtures/quality-contracts" \
  "$REPO/tests/quality-gate-fixtures/app" \
  "$REPO/tests/quality-gate-fixtures/ui-e2e" \
  "$REPO/tests/quality-gate-fixtures/codex" \
  "$REPO/tests/quality-gate-fixtures/claude" \
  "$REPO/tests/quality-gate-fixtures/tmux-runtime" \
  "$REPO/tests/quality-gate-fixtures/gate-contract" \
  "$REPO/tests/quality-gate-fixtures/distribution" \
  "$REPO/tests/quality-gate-fixtures/release-preflight" \
  "$REPO/tests/quality-gate-fixtures/publish-preflight" \
  "$REPO/tests/quality-gate-fixtures/release-workflow"
GATE_ORDER_ROOT="$ORDER_ROOT" gate --mode repository >"$REPO/resource-order.out"
grep -F 'quality-gate: DIAGNOSTIC PASS' "$REPO/resource-order.out" >/dev/null
[ -f "$ORDER_ROOT/integration-after-release" ] || {
  printf 'bounded scheduler did not defer distribution until after release workflow\n' >&2
  exit 1
}
[ -f "$ORDER_ROOT/short-preflight-during-contract" ] || {
  printf 'bounded scheduler did not use the safe preflight lane\n' >&2
  exit 1
}
[ -f "$ORDER_ROOT/release-workflow" ] || {
  printf 'bounded scheduler did not complete the provider-overlapped release workflow\n' >&2
  exit 1
}
fi

if [ "$CONTRACT_SHARD" = all ] || [ "$CONTRACT_SHARD" = execution ] || \
   [ "$CONTRACT_SHARD" = evidence ] || [ "$CONTRACT_SHARD" = evidence-runtime ] || \
   [ "$CONTRACT_SHARD" = evidence-runtime-b ]; then

setup_fixture github-impact-run
commit_ci_merge .github/workflows/quality-gates.yml '# impact core'
if ! GITHUB_ACTIONS=true DETACH_QUALITY_AUTHORITY=ci-merge \
    GITHUB_SHA="$CI_MERGE" \
    gate --mode impact --base "$BASE" \
      >"$REPO/github-impact-run.out" 2>&1; then
  cat "$REPO/github-impact-run.out" >&2
  printf 'quality gate failed the hosted impact run\n' >&2
  exit 1
fi
grep -F "quality-gate: PASS policy=$POLICY_VERSION authority=ci-merge" \
  "$REPO/github-impact-run.out" >/dev/null
grep -F $'authority\tci-merge' "$RESULT_ROOT"/*/manifest.tsv >/dev/null
grep -F $'swift\tpassed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'app\tpassed' "$RESULT_ROOT"/*/summary.tsv >/dev/null
grep -F $'publish-preflight\tpassed' "$RESULT_ROOT"/*/summary.tsv >/dev/null

setup_fixture evidence
printf '%s\n' docs >>"$REPO/README.md"
gate >"$REPO/evidence.out"
run_dir="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d -print | head -1)"
grep -F $'schema\t4' "$run_dir/manifest.tsv" >/dev/null
grep -F $'authority\tlocal-diagnostic' "$run_dir/manifest.tsv" >/dev/null
grep -F $'specs\tdocumentation' "$run_dir/manifest.tsv" >/dev/null
grep -F $'capabilities\tdocumentation' "$run_dir/manifest.tsv" >/dev/null
grep -F $'journeys\tJ-DOCS-CONSISTENCY' "$run_dir/manifest.tsv" >/dev/null
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
grep -F $'file\tspec-sizes.json\t' "$run_dir/artifacts.tsv" >/dev/null
grep -F $'scenarios.jsonl\t' "$run_dir/artifacts.tsv" >/dev/null
grep -F $'scenarios.junit.xml\t' "$run_dir/artifacts.tsv" >/dev/null
grep -F '"id":"SC-DOCS-CONTRACT"' "$run_dir/scenarios.jsonl" >/dev/null
grep -F '"journeys":["J-DOCS-CONSISTENCY"]' "$run_dir/scenarios.jsonl" >/dev/null
grep -F '<testsuite name="detach-quality-scenarios"' "$run_dir/scenarios.junit.xml" >/dev/null
grep -F '# Quality gate' "$run_dir/summary.md" >/dev/null
grep -F -- '- Specifications: `documentation`' "$run_dir/summary.md" >/dev/null
grep -F '| `static` | passed |' "$run_dir/summary.md" >/dev/null
grep -F '| `SC-DOCS-CONTRACT` | `static` | passed |' "$run_dir/summary.md" >/dev/null
grep -F 'markdown=' "$REPO/evidence.out" >/dev/null
python3 - "$run_dir/spec-sizes.json" "$run_dir/manifest.tsv" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
manifest = dict(
    line.rstrip("\n").split("\t", 1)
    for line in open(sys.argv[2], encoding="utf-8")
)
assert document["schema"] == 1
assert document["policy"] == int(manifest["policy"])
assert document["source_commit"] == manifest["source_commit"]
assert document["input_fingerprint"] == manifest["input_fingerprint"]
assert document["warning_bytes"] < document["limit_bytes"]
assert [record["id"] for record in document["specifications"]] == [
    "documentation", "runtime", "state", "power", "app", "app-setup", "release",
]
for record in document["specifications"]:
    size = record["bytes"]
    expected = (
        "over-limit" if size > document["limit_bytes"]
        else "warning" if size > document["warning_bytes"]
        else "healthy"
    )
    assert record["status"] == expected
    assert record["headroom_bytes"] == max(0, document["limit_bytes"] - size)
PY
cp "$run_dir/spec-sizes.json" "$TMP_ROOT/first-spec-sizes.json"
gate >"$REPO/evidence-repeat.out"
repeat_run="$(find "$RESULT_ROOT" -mindepth 1 -maxdepth 1 -type d \
  ! -path "$run_dir" -print | head -1)"
cmp "$TMP_ROOT/first-spec-sizes.json" "$repeat_run/spec-sizes.json" >/dev/null || {
  printf 'quality gate specification-size evidence is not deterministic\n' >&2
  exit 1
}

setup_fixture spec-size-missing
rm "$REPO/docs/specs/runtime.md"
if gate --stage static >"$REPO/spec-size-missing.out" 2>&1; then
  printf 'quality gate accepted a missing routed specification\n' >&2
  exit 1
fi
grep -F 'routed specification is missing or unsafe: docs/specs/runtime.md' \
  "$REPO/spec-size-missing.out" >/dev/null

setup_fixture spec-size-symlink
mv "$REPO/docs/specs/runtime.md" "$REPO/docs/specs/runtime-target.md"
ln -s runtime-target.md "$REPO/docs/specs/runtime.md"
if gate --stage static >"$REPO/spec-size-symlink.out" 2>&1; then
  printf 'quality gate accepted a symlinked routed specification\n' >&2
  exit 1
fi
grep -F 'routed specification is missing or unsafe: docs/specs/runtime.md' \
  "$REPO/spec-size-symlink.out" >/dev/null

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
grep -F 'quality-gate: DIAGNOSTIC PASS' "$REPO/targeted-static.out" >/dev/null
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
  distributed) printf 'Quality gate distributed evidence tests passed\n' ;;
  evidence) printf 'Quality gate evidence tests passed\n' ;;
  evidence-resume) printf 'Quality gate resume evidence tests passed\n' ;;
  evidence-resume-a) printf 'Quality gate resume provenance tests passed\n' ;;
  evidence-resume-b) printf 'Quality gate resume integrity tests passed\n' ;;
  evidence-runtime) printf 'Quality gate runtime evidence tests passed\n' ;;
  evidence-runtime-a) printf 'Quality gate runtime evidence A tests passed\n' ;;
  evidence-runtime-b) printf 'Quality gate runtime evidence B tests passed\n' ;;
esac
