# Documentation and agent-context specification

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
- Shell is limited to public command wrappers and tests where shell or macOS
  process behavior is the subject. Stdlib Python owns quality planning,
  scheduling, policy, evidence, comparison, mutation, and dashboard logic.
  Each Python tool has deterministic contract tests.
- Local diagnostics close the edit loop. They never claim merge readiness.
  Hosted pull-request CI is the
  sole authority. It runs the tested merge's policy-selected impact plan.
  Unknown and quality-core changes select the full plan.
- `scripts/test critical`, `unit`, `coverage`, `smoke`, and `full` are the
  stable human entry points for the high-risk logic loop, complete Swift loop,
  measured coverage loop, freshly packaged product smoke, and exhaustive local
  repository diagnostic respectively. Each supports `--plan`. No command in
  this group is merge-readiness evidence.
- Resume evidence retains stage timing and digest-bound logs, binds its parent,
  and requires the same authority. Timing is telemetry, never a verdict.
- Quality policy files contain current version and state; Git is history.
  Runtime tools do not decode old policy schemas. A last-green metrics artifact
  can use an earlier policy number only with the current evidence schema,
  preserving continuity without old-policy decoding.
- Quality policy registers each tracked durable spec exactly once. It has
  no spec-history or lifecycle-status field. Each registered spec owns a route,
  a capability, and a requirement. Each requirement links to a user journey
  and at least one automated scenario. Generated JSON and Markdown views must
  match the policy.
- Retained gates are timing and quality history, not policy history. An
  unsupported schema is outside telemetry. Current-schema data can span older
  policy identifiers. Malformed evidence remains an attention signal.
- `quality/evals.json` keeps expected outcomes for historical changes, escaped
  defects, policy mutations, and scope violations. Its graders compare stages,
  specs, capabilities, journeys, release gates, and ignored paths. Change an
  expectation only when the intended outcome changes.
- Instrumented scenarios emit begin and pass events. Evidence records their
  requirement and journey links, duration, result, and bounded rerun. A missing
  event fails a passed stage.
- Stage and wall durations are telemetry, never a verdict. A slow stage is
  performance work. Warm-cache and variance reruns cannot prove readiness.
  Repeat an unchanged run only for a recorded unrelated external transient.
- CI binds checks to the tested merge and first parent. Linux runs level 0
  planning and static work. Level 1 covers units and contracts. Level 2 covers
  packaged and runtime work on macOS. Every selected level is required.
- Shards revalidate merge identity but have no merge authority. The final Linux
  job recomputes the plan and accepts only exact digest-bound shard evidence.
  Evidence roots are absolute. Ambiguity fails closed. A failed shard cancels peers.
- CI keeps a ten-minute workflow deadline and the care p95 SLO as its only
  latency watch.
- Gate contracts admit four heavy shards on eight CPUs and two on smaller
  hosts; light contracts stay concurrent and budgets expose overload.
- Swift and release builds use separate caches and split at three CPUs;
  smaller hosts run in order. UI waits for app; metrics require both.
  Gate-contract excludes heavy peers and gates distribution. Release-workflow
  may overlap one provider and gates distribution. Other work uses two
  heavy and one integration lane.
- Exact keys bind inputs and toolchain. `main` warms missing products. CI
  verifies hits and misses, then reuses a fresh app. Warming emits no
  evidence.
- CI uses the newest green `main` artifact with metrics; a later run without
  them does not replace it. Test identities and aggregate or critical-source
  coverage cannot decrease. Changed Swift lines need 90 percent coverage; a
  person cannot raise floors. Policy exclusions need
  scenario evidence and cannot cover critical sources. Named test-only regions
  stay in aggregate coverage but not changed-line metrics.
- Coverage artifacts name `swift` or `combined`. Ratchets use the newest
  matching main profile; schema-1 means combined. Full runs record a Swift
  snapshot; test-only changes skip app journeys. CI shares one cache
  across isolated builds, splits workers, verifies the bundle, and instruments
  only a private copy. Combined metrics merge profiles without another run.
- `coverage-opportunities.json` is a separate digest-bound advisory artifact.
  It ranks uncovered UI sources from policy routes, release impact,
  requirements, and journeys. Its next milestone is the five-point boundary
  above observed coverage. It does not set a floor or change gate status.
- A scheduled, manually dispatchable mutation workflow checks a small
  deterministic safety corpus. It runs mutants in parallel, gives each test a
  240-second deadline, and requires a 100-percent score. Mutation work does not
  extend pull-request feedback time.
- A bounded quality-care workflow evaluates the workflow corpus and recent
  current-schema gate evidence twice each week. It opens one issue when an eval
  changes, evidence is invalid, the latest gate result is unresolved, or
  pull-request wall p95 reaches 80 percent of the ten-minute SLO. Repaired
  failures remain flake and latency telemetry but do not keep the issue open.
  A separate bounded documentation-care workflow can open
  a pull request only for deterministic files under `quality/generated/`.
  Neither workflow can enter a release path. Code review stays a read-only step
  in the active agent workflow. It is not a second merge authority and does not
  require a repository provider, secret, or blocking check.
- A deterministic static dashboard reads only validated gate evidence. The
  same artifact opens locally and deploys to GitHub Pages only after a green
  `main` run with direct or promoted evidence, or a green scheduled mutation
  run. Bounded quality care can also deploy its validated result before it
  marks an attention run as failed. Care evidence binds the source commit and
  SHA-256 digests of its eval and history inputs. A digest-bound gate artifact
  supplies routed-spec sizes. The dashboard also shows measured coverage,
  ranked UI coverage opportunities, mutation score, workflow evals, feedback
  p95 and SLO, and security state when they exist. The security state comes
  from a typed current-policy
  artifact. It includes both CodeQL job results, the analyzed commit, an
  identity fingerprint, and the exact workflow link. A later main, care, or
  mutation deploy restores the newest valid current-policy security and care
  artifacts. Each restore checks at most five completed runs and has a
  60-second deadline. Only deploy jobs have Pages write permission. A
  main-branch Security run can deploy its passed or failed CodeQL result over
  the last green main evidence. A healthy care run closes the prior scoped
  attention issue.
- `main` promotes a successful pull-request artifact only when its stages equal
  a fresh impact plan and both merges have the same tree and ordered parents.
  Spec, capability, and journey identities must match without duplicates;
  their record order can differ. Promotion does not rewrite the manifest.
  Promotion keeps identities and digests. Ambiguity runs a full `ci-main` gate.
- The active GitHub ruleset for `main` has no bypass actors. It requires a pull
  request, a current strict GitHub Actions `quality-gates` job, merge commits,
  and no approving review. It rejects deletion and non-fast-forward updates.
  An administrator cannot use an unchecked push as a substitute for CI. A
  release head gets the same check through its release pull request.
- `scripts/quality-merge` waits at most the pull-request feedback SLO for the
  exact head check. It then enables native auto-merge for that head and waits
  at most the merge deadline. It disables auto-merge on timeout. The command
  rejects a changed head, an invalid ruleset, and a repair attempt above the
  policy maximum. It validates the evidence path and creates its parent
  before it calls GitHub. Invalid paths cannot trigger a merge. It writes
  current-policy evidence under `app/build/`.
- Weekly Dependabot checks pinned Actions and Swift packages. It groups each
  ecosystem into at most one pull request to protect the feedback queue. The
  bounded weekly/manual CodeQL workflow scans Actions on Linux and arm64 Swift
  on macOS. Swift restores the gate dependency graph, resolves the tracked lock,
  and removes cached products before tracing. One whole-module `swift build`
  with three workers builds the complete arm64 graph without per-target builds
  or repeated matrix preparation. The job has 30 minutes. It does not run after
  merges, affect pull-request feedback, or enter release. It uploads results
  before enforcement. The dashboard validates the configuration, result, and
  fingerprint and shows languages, cadence, jobs, commit, and workflow link.
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

Run `tests/docs-contract.sh`, `tests/test-suite-contract.sh`, and the focused
contracts for changed quality tools. Inspect the context map for the affected
area. The required pull-request job supplies final merge evidence.
