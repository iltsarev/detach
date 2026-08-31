#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'docs-contract: %s\n' "$*" >&2
  exit 1
}

[ "$(cat "$ROOT/CLAUDE.md")" = '@AGENTS.md' ] ||
  fail 'CLAUDE.md must contain only @AGENTS.md'

[ "$(wc -l <"$ROOT/scripts/quality-gate" | tr -d ' ')" -le 12 ] ||
  fail 'scripts/quality-gate must stay a thin wrapper'
grep -F 'exec python3 "$ROOT/tools/quality_gate.py" "$@"' \
  "$ROOT/scripts/quality-gate" >/dev/null ||
  fail 'scripts/quality-gate must delegate to the Python orchestrator'
[ -f "$ROOT/tools/quality_gate.py" ] || fail 'quality-gate Python orchestrator is missing'

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

for file in AGENTS.md docs/specs/documentation.md; do
  grep -F '[ASD-STE100 Issue 9](https://www.asd-ste100.org/)' "$ROOT/$file" >/dev/null ||
    fail "$file must define ASD-STE100 Issue 9 as the documentation standard"
done

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
  .github/pull_request_template.md
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

for heading in   '## Purpose and observable outcome'   '## Scope and non-goals'   '## Contract delta'   '## Pre-implementation review'   '## Requirements and acceptance evidence'   '## Decisions'   '## Verification'   '## Outcomes and retrospective'; do
  grep -Fx "$heading" "$ROOT/docs/exec-plan-template.md" >/dev/null ||
    fail "ExecPlan template missing $heading"
done

grep -F 'Classify each requirement as ADDED, MODIFIED, or REMOVED.' \
  "$ROOT/docs/exec-plan-template.md" >/dev/null ||
  fail 'ExecPlan template must define the contract delta'
grep -F 'and acceptance evidence. Record the reviewer, approval source, and `Ready` or' \
  "$ROOT/docs/exec-plan-template.md" >/dev/null ||
  fail 'ExecPlan template must require a pre-implementation review'
grep -F 'The request is approval only when it fixes the same' \
  "$ROOT/docs/exec-plan-template.md" >/dev/null ||
  fail 'ExecPlan review must identify valid prior approval'
grep -F 'Before implementation, write and review its current-to-target' \
  "$ROOT/AGENTS.md" >/dev/null ||
  fail 'agent instructions must require contract-delta review'
grep -F 'contract delta, durable decisions, and evidence in the PR.' \
  "$ROOT/AGENTS.md" >/dev/null ||
  fail 'agent instructions must require a safe pull request summary'
grep -F 'approval only if it fixes the same target and boundaries.' \
  "$ROOT/docs/specs/documentation.md" >/dev/null ||
  fail 'documentation spec must define the approval boundary'

for heading in '## Contract delta' '## Durable decisions' '## Acceptance evidence'; do
  grep -Fx "$heading" "$ROOT/.github/pull_request_template.md" >/dev/null ||
    fail "pull request template missing $heading"
done
grep -F 'Do not copy private ExecPlan content' \
  "$ROOT/.github/pull_request_template.md" >/dev/null ||
  fail 'pull request template must protect private plan content'
grep -F 'write "No contract change" and explain why.' \
  "$ROOT/.github/pull_request_template.md" >/dev/null ||
  fail 'pull request template must cover changes without a contract delta'

git -C "$ROOT" check-ignore -q docs/work/example.md ||
  fail 'temporary ExecPlans must remain ignored'
git -C "$ROOT" check-ignore -q presentations/internal.html ||
  fail 'internal presentation sources must remain ignored'

skill="$ROOT/.agents/skills/detach/SKILL.md"
[ -f "$skill" ] || fail 'Detach harness skill is missing'
grep -F 'name: detach' "$skill" >/dev/null ||
  fail 'harness skill must use name detach'
grep -F 'detach list --json' "$skill" >/dev/null ||
  fail 'harness skill must name detach list --json'
grep -F 'detach power status --json' "$skill" >/dev/null ||
  fail 'harness skill must name detach power status --json'
grep -F '## Do not' "$skill" >/dev/null ||
  fail 'harness skill must refuse unsolicited mutations'
! grep -E 'tmux send-keys|detach-core ' "$skill" >/dev/null ||
  fail 'harness skill must not teach pane injection or detach-core'
! grep -F '.cursor/skills' "$skill" >/dev/null ||
  fail 'harness skill must not bind to a host-only skills path'

grep -F 'Hosted pull-request CI is readiness authority.' "$ROOT/AGENTS.md" >/dev/null ||
  fail 'agent instructions must identify hosted CI as readiness authority'
grep -F 'They never claim merge readiness.' \
  "$ROOT/docs/specs/documentation.md" >/dev/null ||
  fail 'documentation spec must keep local gates diagnostic'
! grep -F 'Only full is readiness evidence.' "$ROOT/scripts/test" >/dev/null ||
  fail 'local full suite must not claim readiness authority'

printf 'Documentation and context contracts passed\n'
