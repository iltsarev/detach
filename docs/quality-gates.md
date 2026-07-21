# Quality gates

`scripts/quality-gate` is the tracked readiness contract for local agents, CI,
and releases. Policy version 6 derives
the mandatory set from the Git diff, and selects the full repository gate for
unknown paths or changes to this policy itself. Its resource-aware scheduler
runs isolated work concurrently without allowing two SwiftPM operations to
share the same build directory.

## Commands

- `scripts/quality-gate` checks the working-tree diff.
- `scripts/quality-gate --base <ref>` checks committed changes since a trusted
  merge base plus staged, unstaged, and untracked files.
- `scripts/quality-gate --mode repository` runs every automated repository
  check. CI uses this mode on `main`; pull requests use impact analysis.
- `scripts/quality-gate --mode release` runs the complete pre-release suite.
  It omits only the recursive test of `scripts/release-version` itself.
- `scripts/quality-gate --plan` prints the selected stages without running
  them. Add `--explain` to show which changed path selected each stage, or
  `--format json` for machine-readable planning.
- `scripts/quality-gate --resume <run-dir>` reuses passed stages from compatible
  evidence whose policy, source commit, resolved base commit, and exact input
  fingerprint still match. The earlier plan must cover every stage in the new
  plan, so a repository run can safely satisfy a smaller change gate.
- `scripts/quality-gate --resume latest` selects the newest compatible local
  evidence automatically. Changed commits, refs, tracked bytes, or untracked
  bytes invalidate reuse.
- `scripts/quality-gate --keep-going` is retained for CI compatibility. The
  resource-aware scheduler always completes independent work so one attempt
  reports every safe-to-run failure. Stages whose prerequisite failed are
  marked blocked instead of wasting time. The final result remains failed.
- `scripts/quality-gate --list-stages` prints the canonical stage names used by
  diagnostics and automation.
- `--stage <name>` is an explicit diagnostic rerun and is never readiness
  evidence.

The stages are `static`, the gate orchestrator's own contract tests, `swift`,
`quality-contracts`, development app build/verification, Codex and Claude
integrations, distribution, bundled runtime, release and publish preflights,
the hermetic release-workflow test, and the zero-work `release-budget`
postflight. Every executable stage has a bounded timeout.
Logs, a versioned TSV summary, a provenance manifest, and JUnit XML are
written privately under `app/build/quality-gates/`. The schema-2 manifest binds
evidence to the policy, source commit, resolved base commit, selected stages,
input and plan fingerprints, timestamps, duration, and the SHA-256 digest of
the summary. Failure, timeout, interruption, blocked dependencies, malformed
evidence, or mismatched resume evidence cannot produce PASS. The failure output
names the exact diagnostic rerun. A red gate must be diagnosed, not made green
by blind retries.

Swift and Clang module caches are rooted under `app/.build`. Coverage-enabled
Swift tests finish before the release app build because SwiftPM owns that
shared directory. Artifact-only coverage analysis then overlaps the release
build and reads test discovery from the completed Swift log instead of invoking
SwiftPM again. Once the app is verified, Codex and Claude
run concurrently with private state/socket roots and use only the freshly
bundled tmux and `detach-state`; they do not invoke SwiftPM. Distribution and
hermetic release contracts form independent lanes. The gate therefore does not
depend on writable user caches, ambient tmux, or provider session state.

There are no quarantined tests in policy version 6. A future quarantine must be
tracked here with an owner, expiry, and reason, and may not remove a release
contract check.

## Policy version 6: lean agent context and durable specs

Policy 6 keeps the policy-5 quality and time ratchets and adds one fast
documentation contract to the existing static stage:

1. Git tracks exactly one canonical `AGENTS.md`; `CLAUDE.md` contains only
   `@AGENTS.md`, so Codex and Claude Code share one source without copied rules.
2. The automatically loaded guide remains below 200 lines and 8 KiB.
   Architecture lives in small task-specific files under `docs/specs/`.
3. A five-row context map points to one spec and one focused feedback loop per
   subsystem. Detailed specs are not eagerly imported.
4. Small changes skip planning. Complex or cross-subsystem work may use the
   ignored ExecPlan template without publishing temporary task history.
5. `tests/docs-contract.sh` checks the single-source link, context budgets,
   required specs, context-map coverage, plan shape, and ignored work area.
6. Documentation-only changes still run only the bounded static stage; no new
   build or test pass was added to the repository critical path.

## Policy version 5: monotonic quality and time budgets

Policy 5 makes the policy-4 measurements fail-closed contracts without adding
another build or test pass:

1. `quality-contracts` now requires the exact established floors: 170 UI tests,
   294 business tests, 21.54% UI line coverage, and 80.75% business line
   coverage.
2. The parallel static-policy branch runs `quality-ratchet`, which rejects
   missing, duplicate, unknown, or non-numeric baseline fields and rejects any
   floor below the locked policy-5 values.
3. On pull requests, every quality floor is also compared with the immutable
   merge-base version. Floors may increase but never decrease.
4. The same parallel branch validates that time budgets were not weakened;
   `release-budget` then evaluates existing evidence after all selected work. It
   launches no subprocess workload and has a recorded duration of zero.
5. A repository or release gate fails when wall time exceeds 180 seconds. It
   also fails earlier diagnostics when a stage exceeds its tracked budget.
6. Wall and stage budgets are ratcheted in the opposite direction: they may be
   lowered, but cannot be raised above either the merge-base value or the
   locked policy-5 ceiling.
7. The postflight is selected for every code, test, packaging, and release-tool
   impact, while documentation-only changes retain the static-only fast path.
8. Negative contract tests prove that lowering each quality metric, weakening
   either time budget, duplicating baseline fields, slowing one stage, or
   exceeding wall time cannot produce PASS.
9. Coverage analysis reuses the completed Swift log and runs beside the app
   build; the app is verified once inside `make-app.sh`, eliminating a second
   identical verifier invocation without removing its fail-closed check.
10. Codex lifecycle tests wait for observable tmux, metadata, argument, token,
    and checkpoint events instead of fixed sleeps. Their failure deadlines are
    unchanged, but successful runs no longer pay arbitrary idle delays.

The tracked stage ceilings are diagnostic guardrails: static 2s, orchestrator
100s, Swift 20s, quality analysis 5s, app 70s, Codex 110s, Claude 50s,
distribution 80s, runtime 8s, release preflight 15s, publish preflight 25s, and
release workflow 70s. The stricter 180-second wall ceiling is authoritative.
Changing machine class or intentionally adding mandatory coverage requires
making enough scheduling improvement to remain inside that same ceiling; the
budget itself cannot be relaxed. CI pins Xcode 26.6 so coverage does not move
when GitHub changes its default toolchain.

## Policy version 4: speed without quality loss

Policy 4 adds a measured release-speed contract while preserving the existing
checks:

1. Run independent distribution, release, provider, runtime, and orchestrator
   lanes concurrently, with explicit SwiftPM and app prerequisites.
2. Run Codex and Claude integration suites concurrently only after the verified
   app exists; each suite keeps its existing isolated state and tmux socket.
3. Reuse the app's bundled `detach-state` in provider suites, eliminating two
   redundant Swift builds from the critical path.
4. Remove three exact release-suite duplicates from `distribution`; those same
   suites remain mandatory first-class stages with their own logs and evidence.
5. Write each stage's status and real duration when it finishes, so parallel
   evidence does not report queueing time as execution time.
6. Add `quality-contracts`, which fails on a reduction below 170 UI tests, 294
   business tests, 21.54% UI line coverage, or 80.75% business line coverage.
7. Require representative power, presentation, setup, watchdog, CLI, state,
   lease, health, and storage suites to remain discoverable.
8. Exercise the scheduler with a 36-second synthetic serial workload and require
   it to complete in at most 18 seconds.

Coverage thresholds are floors recorded in `tests/quality-baseline.tsv`, not
targets. Raising coverage or adding tests must not automatically lower them.

## Policy version 3: 20 release improvements

Policy 3 completes the following 20 concrete speed and quality tasks:

1. Resolve a symbolic `--base` to its immutable commit before classification.
2. Bind every fingerprint and reusable result to the exact source commit.
3. Separate the input fingerprint from the mode-and-stage plan fingerprint.
4. Reuse passed stages from a compatible superset plan, not only an identical
   plan.
5. Select the newest compatible evidence with `--resume latest`.
6. Reject evidence from a running or diagnostic-only invocation.
7. Require exactly one value for every security-relevant manifest key.
8. Bind the reusable TSV summary to its manifest with SHA-256.
9. Validate the summary header, field count, policy, mode, stage, and status.
10. Reject duplicate stage records and expose canonical names through
    `--list-stages`.
11. Syntax-check only changed shell files in change mode while repository,
    release, and diagnostic gates retain the exhaustive scan.
12. Allow a bounded timeout override for one named stage without weakening the
    others.
13. Reject zero, negative, and non-numeric timeout overrides before execution.
14. Run every stage command under fail-fast shell semantics so an early command
    failure cannot be hidden by a later successful command.
15. Mark Codex, Claude, distribution, and runtime checks blocked after their app
    prerequisite fails while continuing independent preflights under
    `--keep-going`.
16. Represent blocked stages as skipped in JUnit and XML-escape report values.
17. Record UTC start/finish timestamps and total duration in schema-2 evidence.
18. Produce a human-readable Markdown summary next to TSV and JUnit evidence.
19. Refuse symlinked result roots and keep run artifacts below a private
    directory.
20. Publish the generated Markdown evidence directly in the CI job summary.

Policy 2's rename/deletion-safe NUL-delimited classification, explanations,
JSON planning, fail-safe unknown impact, resumable stages, and retained CI
artifacts remain part of the contract. New or changed shell files still cannot
evade the static gate merely because they are untracked.

## Impact classes

| Change | Mandatory automated gates |
| --- | --- |
| Documentation only | static syntax and diff checks |
| Swift source or tests | static, Swift tests, quality contracts, release budget |
| Package/resources/app build | static, Swift, quality contracts, app, runtime contracts, release budget |
| CLI/session lifecycle | static, app, both isolated integrations, distribution, runtime, release budget |
| Install/distribution | static, app, distribution, runtime, release budget |
| Release/publication | static, app, release/publish preflights, release-workflow test, release budget |
| Gate policy, CI, mixed unknown path | full repository gate |

Known mixed diffs take the union of their mandatory gates. Deletions use their
old path; renames and copies conservatively use both paths. Dependencies are
added by the mapping (for example an integration always gets a freshly built
bundled tmux). An unclassifiable path fails safe to the full set.

## Definition of Done

An agent may report a change ready only when the changed behavior has a
regression or contract test, the normal impact-selected gate has printed PASS,
user-facing documentation is synchronized, and `git diff --check` is clean.
The report must name any manual release gate that was not run. A single test or
`--stage` rerun is useful diagnosis but cannot replace the selected gate.

CI and `scripts/release-version` invoke this same entry point. CI publishes its
manifest, TSV, JUnit report, and logs for 14 days even when the gate passes, and
also exposes the summary in the workflow UI. They must not copy a separate test
matrix.

## Manual release-only gates

These are the only checks deliberately outside the automated repository gate:

1. Developer ID signing and Apple notarization with owner-held credentials.
2. The explicitly opted-in signed real-power smoke test.
3. The supervised closed-lid probe on supported Apple Silicon hardware.
4. Exact owner/repository/tag publication confirmation.

They remain fail-closed stages of `scripts/release-version`; ordinary agents
and pull-request jobs must never receive their secrets or pretend to run them.
