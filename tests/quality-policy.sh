#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-policy.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'quality-policy-contract: %s\n' "$*" >&2
  exit 1
}

field() {
  printf '%s\n' "$1" | awk -F '\t' -v column="$2" '{print $column}'
}

expect_route() {
  local path="$1" expected_test="$2" expected_release="$3" expected_unknown="$4" result
  result="$("$ROOT/scripts/quality-policy" classify "$path")"
  [ "$(field "$result" 1)" = known ] || fail "expected a known route for $path"
  [ "$(field "$result" 2)" = "$expected_test" ] || fail "unexpected test domain for $path"
  [ "$(field "$result" 3)" = "$expected_release" ] || fail "unexpected release domain for $path"
  [ "$(field "$result" 7)" = "$expected_unknown" ] || fail "unexpected unknown flag for $path"
}

"$ROOT/scripts/quality-policy" validate >/dev/null
"$ROOT/scripts/quality-policy" generate --check
git -C "$ROOT" check-ignore --no-index -q -- presentations/internal.html || \
  fail 'the internal presentations directory is a quality input'
git -C "$ROOT" check-ignore --no-index -q -- docs/assets/internal.html || \
  fail 'internal HTML presentation assets are quality inputs'
python3 "$ROOT/tests/quality_policy_contract.py"
policy_version="$("$ROOT/scripts/quality-policy" version)"
[[ "$policy_version" =~ ^[1-9][0-9]*$ ]] || fail 'invalid policy version'
[ "$("$ROOT/scripts/quality-policy" specs | wc -l | tr -d ' ')" = 7 ] || \
  fail 'current specification inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" stages all | wc -l | tr -d ' ')" = 13 ] || \
  fail 'unexpected stage count'
[ "$("$ROOT/scripts/quality-policy" stages release | tail -1)" = publish-preflight ] || \
  fail 'release stage order is incorrect'
[ "$("$ROOT/scripts/quality-policy" timeout app)" = 2400 ] || fail 'app timeout is not policy owned'
[ -z "$("$ROOT/scripts/quality-policy" dependencies)" ] || \
  fail 'stage dependencies must not cascade beyond the routed plan'
[ "$("$ROOT/scripts/quality-policy" critical | wc -l | tr -d ' ')" = 13 ] || \
  fail 'critical source inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" suites | wc -l | tr -d ' ')" = 12 ] || \
  fail 'required Swift suite inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" requirements | wc -l | tr -d ' ')" = 23 ] || \
  fail 'critical requirement inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" capabilities | wc -l | tr -d ' ')" = 12 ] || \
  fail 'capability inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" journeys | wc -l | tr -d ' ')" = 30 ] || \
  fail 'journey inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" scenarios | wc -l | tr -d ' ')" = 44 ] || \
  fail 'scenario inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" coverage-exclusions | wc -l | tr -d ' ')" = 4 ] || \
  fail 'coverage exclusion inventory is incomplete'
[ "$("$ROOT/scripts/quality-policy" coverage-regions | wc -l | tr -d ' ')" = 12 ] || \
  fail 'coverage region inventory is incomplete'
first_json="$("$ROOT/scripts/quality-policy" render-json | shasum -a 256 | awk '{print $1}')"
second_json="$("$ROOT/scripts/quality-policy" render-json | shasum -a 256 | awk '{print $1}')"
[ "$first_json" = "$second_json" ] || fail 'generated policy JSON is not deterministic'
first_specs="$("$ROOT/scripts/quality-policy" render-specs | shasum -a 256 | awk '{print $1}')"
second_specs="$("$ROOT/scripts/quality-policy" render-specs | shasum -a 256 | awk '{print $1}')"
[ "$first_specs" = "$second_specs" ] || fail 'generated specification view is not deterministic'
grep -F '# Generated specification traceability' \
  "$ROOT/quality/generated/spec-traceability.md" >/dev/null || \
  fail 'generated specification view has no title'
grep -F '`QC-QUALITY-POLICY`' \
  "$ROOT/quality/generated/spec-traceability.md" >/dev/null || \
  fail 'generated specification view omits the policy requirement'

expect_route docs/testing.md policy safe false
expect_route app/Sources/DetachKit/DetachStateCommand.swift state-source safe false
expect_route app/Sources/DetachKit/PowerProtection.swift power both false
expect_route app/Sources/DetachKit/TerminalLauncher.swift runtime-source safe false
expect_route app/Sources/DetachApp/OnboardingView.swift onboarding-source install false
expect_route app/Sources/DetachApp/FutureFlow.swift swift-source unknown true
expect_route scripts/release-lid-probe release-tool lid false
expect_route scripts/release-version release-tool safe false
expect_route scripts/quality-metrics policy safe false
expect_route scripts/quality-mutation policy safe false

onboarding="$("$ROOT/scripts/quality-policy" classify app/Sources/DetachApp/OnboardingView.swift)"
[ "$(field "$onboarding" 10)" = onboarding ] || fail 'onboarding capability impact is missing'
[[ "$(field "$onboarding" 11)" = *J-ONBOARD-FIRST-RUN* ]] || \
  fail 'onboarding journey impact is missing'
session="$("$ROOT/scripts/quality-policy" classify app/Sources/DetachKit/SessionStore.swift)"
[ "$(field "$session" 10)" = session-lifecycle,session-state ] || \
  fail 'session capability impact is missing'
[[ "$(field "$session" 11)" = *J-SESSION-RECOVER* ]] || \
  fail 'session recovery journey impact is missing'
[[ "$(field "$session" 11)" = *J-SESSION-PERSIST* ]] || \
  fail 'session persistence journey impact is missing'

unknown="$("$ROOT/scripts/quality-policy" classify product/new-runtime)"
[ "$(field "$unknown" 1)" = unknown ] || fail 'new product path must fail safe'
[ "$(field "$unknown" 5)" = "$("$ROOT/scripts/quality-policy" stages all | paste -sd, -)" ] || \
  fail 'unknown product path must select every stage'
[ "$(field "$unknown" 6)" = lid ] || fail 'unknown product path must select the closed-lid release gate'

awk -F '\t' -v OFS='\t' \
  '$1 == "release-domain" && $2 == "install" {$3="install"} {print}' \
  "$ROOT/quality/policy.tsv" >"$TMP_ROOT/removed-install-gate.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/removed-install-gate.tsv" \
    "$ROOT/scripts/quality-policy" validate >"$TMP_ROOT/removed-install-gate.out" 2>&1; then
  fail 'removed clean-account release gate was accepted'
fi
grep -F 'unknown release gate' "$TMP_ROOT/removed-install-gate.out" >/dev/null || \
  fail 'removed clean-account gate failure is unclear'

cp "$ROOT/quality/policy.tsv" "$TMP_ROOT/duplicate.tsv"
printf '%s\n' $'route\t950\tREADME.md\tdocs\tsafe\tdocs/specs/documentation.md' \
  >>"$TMP_ROOT/duplicate.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/duplicate.tsv" \
    "$ROOT/scripts/quality-policy" classify README.md >"$TMP_ROOT/duplicate.out" 2>&1; then
  fail 'equal-priority routes were accepted'
fi
grep -F 'equal-priority routes' "$TMP_ROOT/duplicate.out" >/dev/null || \
  fail 'equal-priority route failure is unclear'

awk -F '\t' -v OFS='\t' \
  '$1 == "test-domain" && $2 == "docs" {$3="static,missing-stage"} {print}' \
  "$ROOT/quality/policy.tsv" >"$TMP_ROOT/missing-stage.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/missing-stage.tsv" \
    "$ROOT/scripts/quality-policy" validate >"$TMP_ROOT/missing-stage.out" 2>&1; then
  fail 'unresolved stage reference was accepted'
fi
grep -F 'references unknown stage: missing-stage' "$TMP_ROOT/missing-stage.out" >/dev/null || \
  fail 'unresolved stage failure is unclear'

awk -F '\t' '$1 != "suite" {print}' "$ROOT/quality/policy.tsv" \
  >"$TMP_ROOT/missing-suites.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/missing-suites.tsv" \
    "$ROOT/scripts/quality-policy" validate >"$TMP_ROOT/missing-suites.out" 2>&1; then
  fail 'an empty required Swift suite inventory was accepted'
fi
grep -F 'at least one required Swift suite is required' \
  "$TMP_ROOT/missing-suites.out" >/dev/null || fail 'missing suite failure is unclear'

awk -F '\t' -v OFS='\t' \
  '!($1 == "requirement" && $2 == "QC-POWER-CLI") {print}' \
  "$ROOT/quality/policy.tsv" >"$TMP_ROOT/missing-requirement.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/missing-requirement.tsv" \
    "$ROOT/scripts/quality-policy" validate >"$TMP_ROOT/missing-requirement.out" 2>&1; then
  fail 'unresolved critical requirement was accepted'
fi

awk -F '\t' -v OFS='\t' \
  '!($1 == "scenario" && $2 == "SC-UI-SETTINGS") {print}' \
  "$ROOT/quality/policy.tsv" >"$TMP_ROOT/missing-scenario.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/missing-scenario.tsv" \
    "$ROOT/scripts/quality-policy" validate >"$TMP_ROOT/missing-scenario.out" 2>&1; then
  fail 'unresolved journey scenario was accepted'
fi
grep -F 'references unknown scenario: SC-UI-SETTINGS' \
  "$TMP_ROOT/missing-scenario.out" >/dev/null || fail 'missing scenario failure is unclear'

awk -F '\t' -v OFS='\t' \
  '$1 == "coverage-exclusion" && $2 == "ui" {$4="SC-UI-UNKNOWN"} {print}' \
  "$ROOT/quality/policy.tsv" >"$TMP_ROOT/missing-coverage-scenario.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/missing-coverage-scenario.tsv" \
    "$ROOT/scripts/quality-policy" validate \
    >"$TMP_ROOT/missing-coverage-scenario.out" 2>&1; then
  fail 'an unresolved coverage-exclusion scenario was accepted'
fi
grep -F 'references unknown scenario: SC-UI-UNKNOWN' \
  "$TMP_ROOT/missing-coverage-scenario.out" >/dev/null || \
  fail 'missing coverage-exclusion scenario failure is unclear'

cp "$ROOT/quality/policy.tsv" "$TMP_ROOT/excluded-critical.tsv"
printf '%s\n' \
  $'coverage-exclusion\tbusiness\tapp/Sources/DetachKit/SessionHealth.swift\tSC-POWER-UNIT\tInvalid critical exclusion.' \
  >>"$TMP_ROOT/excluded-critical.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/excluded-critical.tsv" \
    "$ROOT/scripts/quality-policy" validate \
    >"$TMP_ROOT/excluded-critical.out" 2>&1; then
  fail 'a critical source was excluded from coverage'
fi
grep -F 'critical source cannot be excluded from coverage' \
  "$TMP_ROOT/excluded-critical.out" >/dev/null || \
  fail 'critical coverage-exclusion failure is unclear'

awk -F '\t' -v OFS='\t' \
  '$1 == "coverage-region" && $3 ~ /SidebarView/ {$4="missing-marker"} {print}' \
  "$ROOT/quality/policy.tsv" >"$TMP_ROOT/missing-region-marker.tsv"
if DETACH_QUALITY_POLICY="$TMP_ROOT/missing-region-marker.tsv" \
    "$ROOT/scripts/quality-policy" validate \
    >"$TMP_ROOT/missing-region-marker.out" 2>&1; then
  fail 'a coverage region without a source marker was accepted'
fi
grep -F 'unmapped coverage region' \
  "$TMP_ROOT/missing-region-marker.out" >/dev/null || \
  fail 'mismatched coverage-region marker failure is unclear'

! grep -F 'case "$path" in' "$ROOT/scripts/quality-gate" "$ROOT/scripts/release-impact" >/dev/null || \
  fail 'a second path classifier remains in a production script'
! grep -F 'UI_EXCLUSIONS' "$ROOT/tools/quality_metrics.py" >/dev/null || \
  fail 'coverage exclusions remain duplicated in Python'

printf 'Quality policy contracts passed\n'
