#!/bin/bash

set -euo pipefail

DEFAULT_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TEST_MODE="${DETACH_SHELL_SAFETY_TEST_MODE:-0}"
ROOT="${DETACH_SHELL_SAFETY_ROOT:-$DEFAULT_ROOT}"

case "$TEST_MODE" in 0|1) ;; *) printf 'shell safety: invalid test mode\n' >&2; exit 2 ;; esac
if [ "$TEST_MODE" != 1 ] && [ -n "${DETACH_SHELL_SAFETY_ROOT:-}" ]; then
  printf 'shell safety: root override is test-only\n' >&2
  exit 2
fi

failures=0
while IFS= read -r -d '' file; do
  case "$file" in
    tests/shell-safety-contract.sh) continue ;;
    *.sh|bin/detach|bin/detach-core|scripts/quality-gate|scripts/release-version|scripts/release-lid-probe) ;;
    *) continue ;;
  esac
  [ -f "$ROOT/$file" ] || continue
  if ! awk -v file="$file" '
    /^[[:space:]]*#/ {next}
    {
      reason=""
      if ($0 ~ /(^|[;[:space:]])eval[[:space:]]/) reason="dynamic eval"
      else if ($0 ~ /(curl|wget)[^|]*\|[[:space:]]*(sh|bash)([[:space:]]|$)/) reason="remote shell pipeline"
      else if ($0 ~ /rm[[:space:]]+-[^[:space:]]*[rf][^[:space:]]*[[:space:]]+\$[A-Za-z_]/) reason="unquoted variable deletion target"
      else if ($0 ~ /rm[[:space:]]+-[^[:space:]]*[rf][^[:space:]]*[[:space:]]+"?(~|\/|\$\{?HOME\}?)(\/|"|[[:space:]]|$)/) reason="broad deletion target"
      else if ($0 ~ /(^|[;[:space:]])(source|\.)[[:space:]]+\$[A-Za-z_]/) reason="unquoted dynamic source path"
      if (reason != "") {
        printf "shell safety: %s:%d: %s\n", file, NR, reason > "/dev/stderr"
        bad=1
      }
    }
    END {exit bad ? 1 : 0}
  ' "$ROOT/$file"; then
    failures=$((failures + 1))
  fi
done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)

[ "$failures" -eq 0 ] || exit 1
printf 'Shell safety checks passed\n'
