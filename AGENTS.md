# Detach agent guide

Detach is a macOS 26+ reliability harness for persistent Codex CLI and Claude
Code sessions. It owns a private tmux runtime, recovery checkpoints, typed
state, an app, and two-layer power protection. Users install and authenticate
the providers separately.

## Start here

1. Inspect the working tree; preserve unrelated user changes.
2. Use the context map below to read the one relevant specification. Read a
   second spec only when the change genuinely crosses that boundary.
3. For a small, obvious change, edit directly. For a cross-subsystem change,
   risky migration, or work with unresolved requirements, create an ignored
   ExecPlan under `docs/work/` from `docs/exec-plan-template.md` and keep it current.
4. During implementation, run the narrow checks named by the selected specs.
   Before reporting readiness, run `scripts/quality-gate` once. Use
   `--resume latest` after a compatible interrupted or failed run.
5. Review the final diff and evidence. Update the user contract or durable spec
   in the same change whenever behavior or an invariant changes.

`README.md` is the user-facing contract. `docs/specs/` contains durable
current-state engineering contracts. Tests and gates are executable evidence;
they do not make stale prose correct.

## Context and specification policy

- Keep this file under 200 lines and limited to rules needed on most tasks.
- Do not add architecture tutorials or file-by-file inventories here. Put a
  durable invariant in the narrowest file under `docs/specs/`; put a
  temporary task plan under ignored `docs/work/`.
- `CLAUDE.md` must contain only `@AGENTS.md`. Never copy this content
  into it or create a second lowercase agent-instruction file.
- Do not import the detailed specs from this file: imports are eager context in
  Claude Code. Follow the small context map below instead.
- Specs state observable outcomes, non-goals, invariants, owning paths, and
  verification. Avoid implementation narration that code already makes clear.
- Complex plans are living, self-contained handoff artifacts. Record decisions,
  discoveries, progress, and end-to-end evidence; delete or archive obsolete
  local plans when the task ends.
- If a correction repeats, encode it at the narrowest durable layer: executable
  check first when possible, then a scoped spec, and only then this file.

## Context map

| Change area | Read | Fast feedback |
| --- | --- | --- |
| CLI, session lifecycle, state, storage, install, tmux | `docs/specs/runtime.md` | one Swift filter, `tests/run.sh`, `tests/run-claude.sh`, or `tests/distribution.sh` |
| Power wrapper/helper, watchdog, clamshell | `docs/specs/power.md` | `cd app && swift test --filter Power` (or the named suite) |
| App UI, onboarding, presentation, Sparkle | `docs/specs/app.md` | `cd app && swift test --filter <Suite>` |
| Packaging, release, publication | `docs/specs/release.md` | one of `tests/{release,publish}-*.sh` |
| Agent docs, specs, test workflow | `docs/specs/documentation.md` | `tests/docs-contract.sh` |

For an unfamiliar or cross-cutting path, start at `docs/specs/README.md`. Do not
read every spec preemptively.

## Verification loop

- `scripts/quality-gate --plan --explain`: inspect the mandatory readiness
  stages selected from the actual diff.
- `scripts/quality-gate`: authoritative impact-aware readiness gate.
- `scripts/quality-gate --mode repository`: every automated repository
  check; use for policy work and final broad audits.
- `--stage <name>` and direct test commands are diagnostic only, not readiness
  evidence.
- Prefer one focused test while iterating. Do not repeatedly pay for the full
  suite when a narrower deterministic check can close the feedback loop.
- Never run real power tests, signing, notarization, tagging, upload, or
  publication during ordinary implementation.

See `docs/testing.md` for commands, evidence/resume semantics, and manual
release-only checks. See `docs/quality-gates.md` for the gate policy.

## Non-negotiable product invariants

- Runtime payloads are immutable and self-contained under
  `~/.local/libexec/detach/versions/<semver>-<hash>/`; production never
  falls back to ambient tmux, jq, or Homebrew helpers.
- `bin/detach` is the public CLI. `bin/detach-core` owns lifecycle and
  rejects direct production invocation.
- Shared state mutations use the established lock order and typed
  `detach-state` boundary. Never reintroduce ad-hoc JSON editing.
- Session operations are run-token- and ownership-safe. Never signal, replace,
  recover, or delete a process whose exact ownership is not proven.
- State and checkpoints are private. Restores must pass canonical-path,
  symlink, identity, and JSONL validation before atomic replacement.
- Power protection requires both the user IOKit assertion and the root-helper
  lease. Authorization remains audit-token, console-user, code-signing, and
  deadline based; the helper never executes arbitrary commands.
- Low battery must fail safe. Real closed-lid behavior is a supervised hardware
  release gate, not something unit tests can establish.
- App, watchdog, helper, CLI JSON, and typed decoders must remain synchronized.
  User-visible power and health claims derive from typed fresh state, never
  terminal text or direct UI `pmset` calls.
- Packaged executables and Sparkle are Apple Silicon `arm64` only. Release
  artifacts and appcasts must preserve that contract.

Read the routed specification before editing any of these behaviors; the
summary above is not a replacement for its detailed safety contract.

## Public repository safety

The repository, history, CI logs, releases, and artifacts are public.

- Never commit credentials, signing material, account/session data, local
  backlogs, working plans, machine-specific absolute paths, or private names.
- Keep temporary plans in ignored `docs/work/`, existing local backlog
  material in ignored `docs/backlog.md`, and build evidence under ignored
  `app/build/`. Never bypass ignore rules with `git add -f`.
- Before a commit or release, inspect the staged diff, tracked files, metadata,
  and artifact contents. Removing private data in a later commit is not enough.
- A release is not published until the remote release and every asset are
  independently verified. `scripts/release-version X.Y.Z` is the only normal
  release entry point and requires clean synchronized `main` plus explicit
  owner confirmation.

## Definition of done

A change is ready only when its observable behavior has regression evidence,
the impact-selected quality gate prints PASS, affected user docs and durable
specs agree with the code, and `git diff --check` is clean. Report manual
release gates that were not run. Do not substitute a plausible implementation,
a narrow test, or a green stale manifest for requirement-by-requirement
evidence.
