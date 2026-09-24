#!/bin/bash

# Line rules for tracked build, gate, and runtime sources. Each rule names a
# defect class that escaped review; see docs/quality-gates.md.

set -euo pipefail

DEFAULT_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TEST_MODE="${DETACH_SOURCE_RULES_TEST_MODE:-0}"
ROOT="${DETACH_SOURCE_RULES_ROOT:-$DEFAULT_ROOT}"

case "$TEST_MODE" in 0|1) ;; *) printf 'source rules: invalid test mode\n' >&2; exit 2 ;; esac
if [ "$TEST_MODE" != 1 ] && [ -n "${DETACH_SOURCE_RULES_ROOT:-}" ]; then
  printf 'source rules: root override is test-only\n' >&2
  exit 2
fi

failures=0

# Rule build-layout: SwiftPM product layouts differ between Xcode 26
# (arm64-apple-macosx/<config>) and Xcode 27 (out/Products/<Config>). Local
# paths come from `swift build --show-bin-path`. Only the hosted exact-product
# manifest and lines marked `quality: exact-product-path` may name a layout.
while IFS= read -r -d '' file; do
  case "$file" in
    tools/quality_products.py) continue ;;
    tools/*|scripts/*|tests/*|app/scripts/*|bin/*) ;;
    *) continue ;;
  esac
  [ -f "$ROOT/$file" ] || continue
  if ! awk -v file="$file" '
    /arm64-apple-macosx\/(debug|release)|out\/Products\/(Debug|Release)/ &&
      !/quality: exact-product-path/ {
      printf "source rules: %s:%d: literal SwiftPM layout path; use swift build --show-bin-path or mark quality: exact-product-path\n", file, NR
      bad = 1
    }
    END { exit bad ? 1 : 0 }
  ' "$ROOT/$file" >&2; then
    failures=$((failures + 1))
  fi
done < <(git -C "$ROOT" ls-files -z)

# Rule ignored-failure: a runtime or install mutation must not discard its
# failure (#248: a rollback `mv ... || true` could lose the preserved
# generation). Reads with a fallback stay allowed. A deliberate best-effort
# mutation carries `quality: allow-ignored-failure <reason>` in the statement.
while IFS= read -r -d '' file; do
  case "$file" in
    bin/detach|bin/detach-core|scripts/install.sh) ;;
    *) continue ;;
  esac
  [ -f "$ROOT/$file" ] || continue
  if ! awk -v file="$file" '
    {
      if (buffer != "") statement = buffer " " $0
      else { statement = $0; start = NR }
      if (statement ~ /\\$/) { sub(/\\$/, "", statement); buffer = statement; next }
      buffer = ""
      if (statement ~ /^[[:space:]]*#/) next
      if (statement ~ /quality: allow-ignored-failure [^[:space:]]/) next
      if (statement !~ /\|\|[[:space:]]*(true|:)([[:space:]]|;|\)|$)/) next
      if (statement ~ /(^|[;&|[:space:](])(\/bin\/)?(mv|ln|rm)[[:space:]]/ ||
          statement ~ /\$\{?LOCKF_BIN\}?/ ||
          statement ~ /\$\{?STATE_BIN\}?"?[[:space:]]+(meta[[:space:]]+(patch|set|create|update)|events[[:space:]]+publish|checkpoint)/ ||
          statement ~ /state_update_meta/) {
        printf "source rules: %s:%d: mutation discards its failure; handle it or mark quality: allow-ignored-failure <reason>\n", file, start
        bad = 1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$ROOT/$file" >&2; then
    failures=$((failures + 1))
  fi
done < <(git -C "$ROOT" ls-files -z)

# Rule empty-catch: Swift sources must not swallow an error silently.
while IFS= read -r -d '' file; do
  case "$file" in app/Sources/*.swift) ;; *) continue ;; esac
  [ -f "$ROOT/$file" ] || continue
  if ! awk -v file="$file" '
    /catch[[:space:]]*(let[[:space:]]+[A-Za-z_]+[[:space:]]*)?\{[[:space:]]*\}/ &&
      !/quality: allow-ignored-failure [^[:space:]]/ {
      printf "source rules: %s:%d: empty catch swallows an error\n", file, NR
      bad = 1
    }
    END { exit bad ? 1 : 0 }
  ' "$ROOT/$file" >&2; then
    failures=$((failures + 1))
  fi
done < <(git -C "$ROOT" ls-files -z)

# Rule workflow-yaml: GitHub silently stops scheduling a workflow whose file
# does not parse (a plain `if:` value containing `": "` once disabled the
# mutation workflow). Every tracked workflow must be valid YAML.
workflow_parser=""
if python3 -c 'import yaml' >/dev/null 2>&1; then
  workflow_parser=python
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' >/dev/null 2>&1; then
  workflow_parser=ruby
fi
while IFS= read -r -d '' file; do
  case "$file" in .github/workflows/*.yml|.github/workflows/*.yaml) ;; *) continue ;; esac
  [ -f "$ROOT/$file" ] || continue
  case "$workflow_parser" in
    python)
      python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' \
        "$ROOT/$file" 2>"${TMPDIR:-/tmp}/source-rules-yaml.$$" || {
        printf 'source rules: %s: workflow is not valid YAML: %s\n' "$file" \
          "$(tail -1 "${TMPDIR:-/tmp}/source-rules-yaml.$$")" >&2
        failures=$((failures + 1))
      } ;;
    ruby)
      ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$ROOT/$file" \
        2>/dev/null || {
        printf 'source rules: %s: workflow is not valid YAML\n' "$file" >&2
        failures=$((failures + 1))
      } ;;
    *)
      printf 'source rules: no YAML parser (python3 PyYAML or ruby) to check %s\n' "$file" >&2
      failures=$((failures + 1)) ;;
  esac
done < <(git -C "$ROOT" ls-files -z)
rm -f "${TMPDIR:-/tmp}/source-rules-yaml.$$"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'Source rules passed\n'
