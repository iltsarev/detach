#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/tests/shell-safety.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-shell-safety-contract.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" config user.name 'Detach Tests'
git -C "$TMP_ROOT" config user.email 'detach-tests@example.invalid'
mkdir -p "$TMP_ROOT/scripts"
printf '#!/bin/bash\nset -euo pipefail\ntarget="$(mktemp -d)"\nrm -rf "$target"\n' \
  >"$TMP_ROOT/scripts/safe.sh"
git -C "$TMP_ROOT" add .
git -C "$TMP_ROOT" commit -qm safe
DETACH_SHELL_SAFETY_TEST_MODE=1 DETACH_SHELL_SAFETY_ROOT="$TMP_ROOT" "$CHECK" >/dev/null

printf '#!/bin/bash\neval "$1"\n' >"$TMP_ROOT/scripts/unsafe.sh"
if DETACH_SHELL_SAFETY_TEST_MODE=1 DETACH_SHELL_SAFETY_ROOT="$TMP_ROOT" "$CHECK" \
    >"$TMP_ROOT/unsafe.out" 2>&1; then
  printf 'shell safety contract accepted dynamic eval\n' >&2
  exit 1
fi
grep -F 'dynamic eval' "$TMP_ROOT/unsafe.out" >/dev/null

printf '#!/bin/bash\nrm -rf $target\n' >"$TMP_ROOT/scripts/unsafe.sh"
if DETACH_SHELL_SAFETY_TEST_MODE=1 DETACH_SHELL_SAFETY_ROOT="$TMP_ROOT" "$CHECK" \
    >"$TMP_ROOT/unsafe.out" 2>&1; then
  printf 'shell safety contract accepted an unquoted deletion target\n' >&2
  exit 1
fi
grep -F 'unquoted variable deletion target' "$TMP_ROOT/unsafe.out" >/dev/null

printf 'Shell safety contract tests passed\n'
