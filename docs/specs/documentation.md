# Documentation and agent-context specification

## Outcome

Codex and Claude Code receive the same small durable instruction core, discover
only task-relevant detailed specs, use focused tests while iterating, and finish
against the same deterministic quality gate.

## Invariants

- Exactly one case-insensitive agent instruction file exists: `AGENTS.md`.
- `CLAUDE.md` contains exactly `@AGENTS.md`; it contains no duplicate
  instructions or additional imports.
- Root instructions stay below 200 lines and 8 KiB. Detailed architecture does
  not return to the automatic startup context.
- No individual spec exceeds 12 KiB. Read more than one only when a change
  crosses real subsystem boundaries.
- `AGENTS.md` contains one small human-readable context map. There is no second
  routing DSL or tool for an agent to learn.
- Durable specs describe current contracts. Ignored `docs/work/` contains
  temporary executable plans. Imports are not used for detailed specs because
  Claude expands imports eagerly.
- Fast diagnostics close the edit loop; `scripts/quality-gate` remains the
  sole readiness entry point. A focused command or diagnostic stage is never
  presented as final evidence.
- Resume evidence retains stage timing and digest-bound logs, binds its parent,
  and cannot turn a prior time-budget regression into readiness.
- Hosted CI runs every selected functional check and timing-policy ratchet but
  does not enforce reference-machine wall or per-stage timing ceilings.
- Ready task-scoped changes are committed and pushed to the current branch by
  default after staged public-diff review; an owner request to keep work local
  is the explicit exception, and successful delivery includes upstream parity.
- `tests/docs-contract.sh` enforces this structure and runs inside the
  static quality stage.

## Spec lifecycle

Use a direct edit for a small, obvious task. Use the ExecPlan template when
work crosses subsystems, contains material unknowns, changes security/release
contracts, or needs a resumable multi-session handoff. Keep the plan
self-contained and current while working. Promote only stable outcomes and
invariants into the durable spec.

When agent behavior repeatedly fails, prefer a deterministic check. If behavior
cannot be enforced mechanically, update the narrow spec. Change `AGENTS.md`
only for a rule needed on most tasks.

## Verification

Run `tests/docs-contract.sh`, inspect the context map for the affected area,
then run the impact-selected quality gate.
