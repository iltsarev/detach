#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'docs-contract: %s\n' "$*" >&2
  exit 1
}

[ "$(cat "$ROOT/CLAUDE.md")" = '@AGENTS.md' ] ||
  fail 'CLAUDE.md must contain only @AGENTS.md'

agent_files=()
while IFS= read -r -d '' file; do
  agent_files+=("$file")
done < <(find "$ROOT" -maxdepth 1 -type f -iname 'agents.md' -print0)
[ "${#agent_files[@]}" -eq 1 ] || fail 'exactly one case-insensitive AGENTS.md must exist'
[ "$(basename "${agent_files[0]}")" = AGENTS.md ] || fail 'canonical instructions must be AGENTS.md'

tracked_agents="$(git -C "$ROOT" ls-files | awk 'tolower($0) == "agents.md" {print}')"
[ "$tracked_agents" = AGENTS.md ] || fail 'Git must track only AGENTS.md'

agent_lines="$(wc -l <"$ROOT/AGENTS.md" | tr -d ' ')"
agent_bytes="$(wc -c <"$ROOT/AGENTS.md" | tr -d ' ')"
[ "$agent_lines" -lt 200 ] || fail "AGENTS.md is ${agent_lines} lines; limit is 199"
[ "$agent_bytes" -le 8192 ] || fail "AGENTS.md is ${agent_bytes} bytes; limit is 8192"
! grep -F '@docs/' "$ROOT/AGENTS.md" >/dev/null ||
  fail 'detailed specs must not be eagerly imported'

required=(
  docs/specs/README.md
  docs/specs/runtime.md
  docs/specs/power.md
  docs/specs/app.md
  docs/specs/release.md
  docs/specs/documentation.md
  docs/testing.md
  docs/quality-gates.md
  docs/exec-plan-template.md
)
for file in "${required[@]}"; do
  [ -f "$ROOT/$file" ] || fail "missing $file"
done

for spec in "$ROOT"/docs/specs/*.md; do
  bytes="$(wc -c <"$spec" | tr -d ' ')"
  [ "$bytes" -le 12288 ] ||
    fail "${spec#"$ROOT/"} is ${bytes} bytes; routed spec limit is 12288"
done

for spec in runtime power app release documentation; do
  [ "$(grep -Fc "docs/specs/$spec.md" "$ROOT/AGENTS.md")" -eq 1 ] ||
    fail "context map must reference $spec.md exactly once"
done

for heading in   '## Purpose and observable outcome'   '## Scope and non-goals'   '## Requirements and acceptance evidence'   '## Decisions'   '## Verification'   '## Outcomes and retrospective'; do
  grep -Fx "$heading" "$ROOT/docs/exec-plan-template.md" >/dev/null ||
    fail "ExecPlan template missing $heading"
done

git -C "$ROOT" check-ignore -q docs/work/example.md ||
  fail 'temporary ExecPlans must remain ignored'

printf 'Documentation and context contracts passed\n'
