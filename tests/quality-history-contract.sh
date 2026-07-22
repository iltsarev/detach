#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-history-contract.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

write_run() {
  local name="$1" result="$2" wall="$3" static_status="$4" static_duration="$5"
  mkdir -p "$TMP_ROOT/$name"
  printf 'schema\t3\ntiming_wall_seconds\t%s\nresult\t%s\n' "$wall" "$result" \
    >"$TMP_ROOT/$name/manifest.tsv"
  printf 'policy\tmode\tstage\tstatus\tduration_seconds\tlog\tlog_sha256\torigin_run\n' \
    >"$TMP_ROOT/$name/summary.tsv"
  printf '8\trepository\tstatic\t%s\t%s\tstatic.log\tdigest\t-\n' \
    "$static_status" "$static_duration" >>"$TMP_ROOT/$name/summary.tsv"
}

write_run one passed 100 passed 1
write_run two failed 180 environment-failed 3
write_run three passed 120 passed 2

"$ROOT/scripts/quality-history" "$TMP_ROOT" >"$TMP_ROOT/report.tsv"
grep -F $'runs\t3' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'passed\t2' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'wall_p50_seconds\t120' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'wall_p95_seconds\t180' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'static\t3\t1\t1\t2\t3' "$TMP_ROOT/report.tsv" >/dev/null

printf 'Quality history contract tests passed\n'
