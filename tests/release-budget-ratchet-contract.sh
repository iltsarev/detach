#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
RATCHET="$ROOT/tests/release-budget-ratchet.sh"
SOURCE="$ROOT/tests/release-budget.tsv"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-release-budget-ratchet-contract.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

current="$TMP_ROOT/current.tsv"
prior="$TMP_ROOT/prior.tsv"
cp "$SOURCE" "$current"
cp "$SOURCE" "$prior"

DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE=1 DETACH_RELEASE_BUDGET="$current" \
  DETACH_RELEASE_PRIOR_BUDGET="$prior" "$RATCHET" >/dev/null

set_value() {
  local file="$1" key="$2" value="$3" temporary
  temporary="$file.tmp"
  awk -F '\t' -v OFS='\t' -v wanted="$key" -v replacement="$value" \
    '$1 == wanted {$2=replacement} {print}' "$file" >"$temporary"
  mv "$temporary" "$file"
}

set_value "$current" wall_seconds_max 181
if DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE=1 DETACH_RELEASE_BUDGET="$current" "$RATCHET" \
  >"$TMP_ROOT/wall.out" 2>&1; then
  printf 'release budget contract: accepted a higher wall budget\n' >&2
  exit 1
fi
grep -F 'increased above locked-ceiling' "$TMP_ROOT/wall.out" >/dev/null

cp "$SOURCE" "$current"
set_value "$current" stage_codex_seconds_max 111
if DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE=1 DETACH_RELEASE_BUDGET="$current" "$RATCHET" \
  >"$TMP_ROOT/stage.out" 2>&1; then
  printf 'release budget contract: accepted a higher stage budget\n' >&2
  exit 1
fi
grep -F 'increased above locked-ceiling' "$TMP_ROOT/stage.out" >/dev/null

cp "$SOURCE" "$current"
set_value "$current" stage_ui_e2e_seconds_max 16
if DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE=1 DETACH_RELEASE_BUDGET="$current" "$RATCHET" \
  >"$TMP_ROOT/ui-e2e.out" 2>&1; then
  printf 'release budget contract: accepted a higher UI e2e budget\n' >&2
  exit 1
fi
grep -F 'increased above locked-ceiling' "$TMP_ROOT/ui-e2e.out" >/dev/null

# Policy 7 adds the UI stage without invalidating an otherwise valid policy 6
# merge-base budget. The new stage is still held to its locked ceiling above.
cp "$SOURCE" "$current"
cp "$SOURCE" "$prior"
set_value "$prior" schema 1
awk -F '\t' '$1 != "stage_ui_e2e_seconds_max"' "$prior" >"$prior.tmp"
mv "$prior.tmp" "$prior"
DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE=1 DETACH_RELEASE_BUDGET="$current" \
  DETACH_RELEASE_PRIOR_BUDGET="$prior" "$RATCHET" >/dev/null

cp "$SOURCE" "$current"
cp "$SOURCE" "$prior"
set_value "$prior" wall_seconds_max 179
if DETACH_RELEASE_BUDGET_RATCHET_TEST_MODE=1 DETACH_RELEASE_BUDGET="$current" \
  DETACH_RELEASE_PRIOR_BUDGET="$prior" "$RATCHET" >"$TMP_ROOT/prior.out" 2>&1; then
  printf 'release budget contract: accepted a merge-base budget increase\n' >&2
  exit 1
fi
grep -F 'increased above merge-base' "$TMP_ROOT/prior.out" >/dev/null

printf 'Release budget ratchet contract tests passed\n'
