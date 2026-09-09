# Engineering specifications

These files are the durable current-state contracts for behavior that is
important but not obvious from one source file. They are shared by Codex,
Claude Code, and humans. The small context map in `AGENTS.md` is the canonical
entry point.

## Authority

- `README.md` defines supported user-visible behavior.
- These specs define non-obvious architecture, safety, and cross-component
  invariants.
- Source code implements the contract.
- Tests and `scripts/quality-gate` provide executable evidence.
- An ignored ExecPlan under `docs/work/` records one task's reviewed contract
  delta, temporary intent, decisions, and progress.

When these disagree, do not silently choose one. Establish intended behavior,
then update every affected durable artifact in the same change.

## Choosing context

Use the context map in `AGENTS.md`. The filenames are deliberately literal.
Read one spec by default and another only when the change crosses a real
subsystem boundary. Use
`../testing.md` only when the focused command or gate semantics are unclear.
Do not load every document preemptively.

## Writing a durable spec

A spec should state observable outcomes, boundaries/non-goals, invariants,
ownership paths, and verification. Explain why only where it prevents a likely
wrong implementation. Do not copy code, maintain a file inventory, preserve
task history, or prescribe incidental implementation detail.

`quality/policy.tsv` registers each current durable spec. It owns the stable
spec identity and the links from requirements to user journeys and automated
scenarios. `quality/generated/spec-traceability.md` is the generated readable
view. Do not copy this metadata into individual specs or edit the generated
view.

Change the narrowest owning spec whenever behavior or an invariant changes.
Keep task progress and rejected experiments in the local ExecPlan, not here.
A finished spec describes the system as it is, not the sequence used to build it.
