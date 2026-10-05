# Documentation and agent-context specification

<a id="qc-doc-consistency"></a>

## Outcome

Codex and Claude Code receive the same small durable instruction core, discover
only task-relevant detailed specs, and use focused tests while iterating.
Hosted CI is the merge-readiness authority.

## Invariants

- Exactly one case-insensitive agent instruction file exists: `AGENTS.md`.
- `CLAUDE.md` contains exactly `@AGENTS.md`; it contains no duplicate
  instructions or additional imports.
- Root instructions stay below 200 lines and 8 KiB. Detailed architecture does
  not return to the automatic startup context.
- No individual spec exceeds 16 KiB. The static check and dashboard warn above
  12 KiB so a split is planned first. Read a second spec only for a real
  cross-subsystem change.
- `AGENTS.md` contains one small human-readable context map. There is no second
  routing DSL or tool for an agent to learn.
- New or changed English text in `README.md` and `docs/` uses
  [ASD-STE100 Issue 9](https://www.asd-ste100.org/). Product names, paths,
  commands, and identifiers are project technical terms. A document does not
  claim verified STE compliance unless a reviewer checks it against the
  official standard.
- Durable specs describe current contracts. Ignored `docs/work/` contains
  temporary executable plans. A required plan states and reviews the contract
  delta before primary implementation. Detailed specs are not imported because
  Claude expands imports eagerly.
- Ignored `presentations/` contains internal presentation sources. Git and the
  quality gate do not treat these files as repository inputs.
Quality planning, execution, and merge evidence follow
[the quality specification](quality.md).

- By default, put a ready task-scoped change on a topic branch. Review the
  staged public diff, commit it, and push it. The pull request summarizes the
  safe contract delta, durable decisions, and acceptance evidence; it never
  copies private plan content. Give its number, exact head, and repair attempt
  to `scripts/quality-merge`. After PASS, verify local and upstream `main` parity.
  The owner can ask to keep the change local.
- `tests/docs-contract.sh` enforces this structure and runs inside the
  static quality stage.

## Spec lifecycle

Use a direct edit for a small, obvious task. Use the ExecPlan template when work
crosses subsystems, has material unknowns, changes security or release contracts,
or needs a resumable handoff. Before primary implementation, record and review
the current-to-target contract delta for each affected `README.md` contract or
durable spec. Classify requirements as ADDED, MODIFIED, or REMOVED, or record
no contract change with evidence. Link changed requirements to journeys,
scenarios, and evidence.

Review scope, non-goals, and evidence in the same checkpoint. The request is
approval only if it fixes the same target and boundaries. Otherwise ask the
owner about material choices. Record the reviewer, approval source, and result.
Revise the checkpoint when the delta changes. Promote only stable outcomes and
invariants into durable specs. Keep the plan ignored and put only safe rationale
in the pull request.

When agent behavior repeatedly fails, prefer a deterministic check. If behavior
cannot be enforced mechanically, update the narrow spec. Change `AGENTS.md`
only for a rule needed on most tasks.

## Verification

Every changed requirement needs a reviewed PR contract delta and direct passed
evidence. This rule applies to all requirements. Run
`python3 tools/quality_contract_change.py --base BASE --draft` after committing
the change. Put its `detach-contract` JSON block in the PR body and replace each
TODO with the reviewed before/after behavior. Use ADDED, MODIFIED, or REMOVED.
For a prose correction or a moved contract, use UNCHANGED and state why the
behavior stays the same. Keep a specific reason and mapped acceptance scenarios
on every row. An added or removed requirement cannot use UNCHANGED.

CI detects changes to owning spec files, requirement definitions, verification
links, and directly mapped test files. A spec text edit requires review of all
requirements in that spec. Code-only behavior changes must also update the
owning spec and declare the affected requirements. Automatic detection cannot
establish that a source edit preserves behavior. The agent must review this.

Review changed assertions against the intended contract. For a bug fix, show
that the new regression test rejects the old behavior when an isolated bounded
run is possible. Record any reason that this comparison is not possible. Never
change an expected result only to make a failed check pass.

The initial CI job checks the declaration and the tested PR head. The final
aggregate requires passed direct scenario or test-case evidence from that run.
It binds the reviewed declaration to the source, base, policy, and PR body
digest. Missing or unrelated evidence blocks merge. PR body edits start a new
workflow. Syntax validation does not prove that the reason or assertion is
correct; the agent still reviews their meaning.

Run `tests/docs-contract.sh`, `tests/test-suite-contract.sh`, and the focused
contracts for changed quality tools. Inspect the context map for the affected
area. The required pull-request job supplies final merge evidence.
