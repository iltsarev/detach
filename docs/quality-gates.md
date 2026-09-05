# Quality gates

`quality/policy.tsv` is the single quality policy. It owns path impact,
capabilities, user journeys, requirements, stages, time limits, critical
sources, and release impact. `scripts/quality-policy` validates this source and
generates `quality/generated/policy.json` and
`quality/generated/spec-traceability.md`. The policy contains only current
state. Git stores its history. Generated data must match the source.

`scripts/quality-gate` applies the policy. Local runs are diagnostics. Hosted
pull request CI runs the exact policy-selected impact plan on the current merge
commit and is the only ordinary merge authority. Unknown paths and changes to
the core planner, policy, or quality workflow select the full plan.
For a normal local change, `gate-contract` runs direct self-contracts only.
`--mode repository` runs the full orchestrator shards. An explicit local
`--stage gate-contract` also runs all shards for diagnosis.

## Commands

- `scripts/quality-gate --plan --explain` shows affected capabilities,
  specifications, journeys, stages, and the path that selected each stage.
- `scripts/quality-gate` checks the working-tree diff and writes local
  diagnostic evidence.
- `scripts/quality-gate --base <ref>` also checks committed changes after the
  resolved merge base.
- `scripts/quality-gate --mode repository` runs every automated repository
  check. A local run remains diagnostic.
- `scripts/quality-gate --mode impact --base <ref>` runs the committed
  dependency-closed impact plan. Hosted merge authority requires this mode, a
  clean checkout, and the tested merge first parent as `<ref>`.
- `scripts/quality-gate --mode release --base <tag>` runs the release stages
  selected by the accumulated diff from `<tag>`. It omits the recursive
  `scripts/release-version` test. Release mode without a base fails safe to the
  complete release plan.
- `scripts/quality-gate --mode release --reuse-hosted <run-dir>` also reuses
  every selected stage that digest-bound hosted evidence already proved for
  the exact source tree. `scripts/quality-evidence fetch --commit <sha>`
  downloads that evidence from the green `main` workflow run of the commit.
- `scripts/quality-gate --resume <run-dir>` reuses compatible passed stages.
  `--resume latest` selects the newest compatible local run.
  `--resume auto` starts fresh when no compatible run exists. Releases use
  this mode so an interrupted attempt does not repeat passed stages.
- `scripts/quality-gate --stage <name>` reruns one diagnostic stage. It is not
  readiness evidence.
- `scripts/quality-scenarios rerun SC-ID` runs the owning diagnostic stage for
  an instrumented scenario, or its direct policy command otherwise. The owning
  stage process deadline bounds both forms. The helper has 30 seconds for
  evidence finalization and process-group cleanup.
- `scripts/quality-history [--format tsv|json] [RESULT_ROOT]` validates retained
  current-schema summaries and reports run and failure counts plus p50 and p95
  wall and stage durations. A declared unsupported schema is outside the
  sample. Current-schema timing can span earlier policy identifiers and does
  not require dashboard-only manifest fields. Malformed telemetry evidence
  stays invalid. The tool cannot produce readiness evidence or decode an old
  layout.
- `scripts/quality-care validate` checks the versioned workflow eval corpus.
  `scripts/quality-care evaluate` grades diff impact and private-scope cases.
  `scripts/quality-care assess` compares the results with retained run latency.
  `scripts/quality-care latest --optional` inspects at most five completed
  runs within one 60-second deadline. It restores the newest valid
  current-policy care artifact for a dashboard deploy.
- `scripts/quality-policy specs` lists current durable specs.
  `scripts/quality-policy render-specs` prints their requirement, journey, and
  scenario links.
- `scripts/quality-dashboard generate` writes deterministic static HTML and
  JSON. `scripts/quality-dashboard serve` binds to loopback and stops after its
  deadline.
- `scripts/quality-mutation` validates and runs the deterministic safety mutant
  corpus. Mutation work does not add to pull request latency.
- `scripts/quality-promote` binds a successful pull-request artifact to its
  final `main` merge commit. It runs only in the hosted main-push workflow.

## Authority and evidence

Every manifest records one authority:

- `local-diagnostic` for ordinary local work;
- `ci-merge` for the pull request merge commit;
- `ci-main` for the current `main` commit;
- `release` for the owner-confirmed release flow.

An ordinary main merge keeps the original `ci-merge` manifest immutable. A
separate promotion record supplies `ci-main` authority only when GitHub and Git
facts prove that the tested synthetic merge and final merge have the same tree
and ordered parents. The dashboard shows both commits and the source run. The
next metrics comparison uses the final main commit. A direct or ambiguous main
push runs the complete repository gate instead.

The repository gate writes private evidence under
`app/build/quality-gates/`. One run contains a schema-versioned TSV summary,
gate and scenario JUnit, scenario JSONL, Markdown, stage logs, safe environment
facts, a provenance manifest, and a digest inventory. Coverage runs also
contain `quality-metrics.json` and `coverage-opportunities.json`. A failed
scenario adds a bounded
`repair-bundle.json` with its requirement and journey links, exact rerun, and
at most the last 100 log lines.

The manifest binds the evidence to the policy, authority, source and base
commits, exact input and plan fingerprints, selected capabilities, journeys,
owning specifications, stages, timestamps, inherited timing, parent evidence,
environment, artifacts, summary, and every stage log. A failure, timeout,
interruption, blocked
dependency, unsafe file, malformed record, or digest mismatch cannot produce
PASS. Failure output gives the exact diagnostic rerun.

An instrumented scenario writes one begin event and one pass event. Missing,
duplicate, reordered, unknown, or cross-stage events fail closed. Legacy stage
records remain explicit until the owning suite gets markers. Planned scenario
records remain visible gaps. Only the supervised closed-lid release gate is
manual because it needs physical evidence.

Resume requires the same policy, authority, source commit, base commit, and
input fingerprint. The old plan must contain every selected stage. Reused logs
keep their duration and digest. The new manifest binds the parent manifest.
Inherited wall time cannot become shorter.

Hosted reuse is separate. Release mode may reuse a passed stage from a
`ci-main` run that names the source commit, or from a promoted `ci-merge` run
whose promotion record names the source commit and proves equal tested and
merged trees. The evidence must have the current policy, a passed result, and
matching environment, artifact, summary, and log digests. Each reused stage
records the hosted run as its origin. Stages the hosted plan did not cover run
on the release Mac.

## Automated stages and scheduling

The policy defines these stages:

- static syntax, documentation, suite inventory, and policy ratchets;
- gate self-contracts;
- coverage-enabled Swift tests and automatic quality metrics;
- development app build and verification;
- packaged-app UI integration;
- isolated Codex and Claude provider integrations;
- distribution and bundled runtime contracts;
- release and publish preflights;
- release-impact and release-workflow contracts.

Every executable stage has a policy-owned process deadline. Stage and wall
durations are telemetry for `scripts/quality-history` and the care SLO; they
never change a verdict. The GitHub workflow
has a ten-minute deadline and cancels superseded work. The pull request feedback
SLO is less than ten minutes.

Pull-request CI validates its exact impact plan and runs static contracts on a
Linux control runner before it downloads optional metrics or Swift data. The
macOS shards run every selected product check. The final Linux control runner
recomputes the plan and validates the exact digest-bound shard set. These
control runners do not execute or replace macOS product evidence. Independent
level-zero contracts run concurrently. The early fail-fast pass is diagnostic
only. A failed matrix shard cancels its peers; missing evidence fails the final
aggregate.

Swift tests, the normal app, and the instrumented app use isolated scratch and
module-cache paths. CI materializes their shared dependency cache once before
parallel builds. A host with at least three CPUs splits workers and builds all
three at the same time. Smaller hosts run Swift and app work in sequence.
The normal bundle is verified. On a hosted app-cache miss, the successful
fresh build becomes the exact app for that job. The selected app stage verifies
the same bundle and does not build it again. A failed build cannot create this
binding. Only the private UI copy gets the instrumented executable.
The short packaged UI lane runs after the verified app and before the
CPU-intensive provider, runtime, and gate-contract lanes. This prevents
WindowServer event delivery from competing with those workers. The UI smoke
probes the console session first. An agent sandbox, SSH session, login window,
or locked screen is an environment denial that the gate records as
`environment-failed`, never as a product failure. After the UI and metric phases,
the scheduler starts ready process-heavy stages in descending policy timing
order. It admits at most two process-heavy top-level lanes. One separate lane
runs short runtime and release preflights during gate-contract. Distribution
uses that lane only after gate-contract ends. Gate-contract excludes every
heavy peer. Release-workflow can overlap one provider lane, but distribution
waits until release-workflow ends. A free slot starts the next ready stage
without a fixed wave barrier.

Quality analysis runs after the UI lane. It merges the completed Swift profile
with all passed packaged-app profiles. It reads the existing Swift log and does
not run a test twice.

The gate-contract stage keeps lightweight contracts concurrent. It admits
four process-heavy orchestrator shards on a host with at least eight logical
CPUs, and two on a smaller host. This limit prevents process oversubscription
without increasing the stage budget. At most four contract children run at one
time, so lightweight contracts do not crowd adjacent preflights.

Swift and Clang caches stay under `app/.build`. Their hosted key covers the
compiler, package, sources, tests, build scripts, and version metadata. A
promoted `main` run warms only a missing exact product and emits no gate
evidence. The packaged UI test uses a
stripped process-private app, fake CLI, and private state. Provider tests use
private state and socket roots plus the bundled `tmux` and `detach-state`. A
hosted provider shard binds the exact runtime products that the last green
`main` published when the product cache has them, so a change that touches
only the shell CLI does not rebuild the app in every shard. Without them the
shard verifies or builds the packaged app first. Each provider part has
private state, socket, log, and failure
artifact roots. Parts run concurrently. The bounded large-host Codex lane
starts the longest measured independent parts first, and still runs every
part. Smaller hosts use three Codex parts and two Claude parts; larger hosts
use finer parts. Compact layouts reuse
checkpoints across recovery and restart, resume and identity, or Claude
lifecycle and recovery. The parent writes scenario events in one order and
fails the stage when any part fails. Tests do not use installed product state
or ambient helpers. Distribution runs its runtime and shell-profile contracts
concurrently in separate private temporary homes.

There are no quarantined tests. A future quarantine needs an owner, reason, and
expiry. It cannot remove release evidence. The packaged UI journeys are the
only retry layer: every scenario and every attempt starts from a clean
private state with no app state, fake CLI markers, attach client, or
persisted defaults; a scenario whose app never reports a result, or reports
a timeout, gets exactly one retry inside the stage budget, and the stage log
records the retry. A reported assertion failure never retries.

## Impact and user journeys

The policy maps each path to one test domain, release impact, owning spec, and
one or more user capabilities. Capabilities map to stable user journeys,
requirements, and automated scenarios. A known mixed diff uses the union of
its routes. Deletions use the old path. Renames and copies use both paths. An
unknown path selects every functional stage and every release impact.

| Change | Local diagnostic plan |
| --- | --- |
| Documentation | static |
| Quality policy or CI | static and gate self-contracts |
| Swift source | Swift, metrics, app, and packaged UI |
| Swift tests | Swift and matching-profile metrics |
| CLI or session lifecycle | app, both providers, and distribution |
| One provider test | static and that provider; its shard verifies the exact app prerequisite |
| Install or distribution | app and distribution |
| Release or publication | app, preflights, and workflow contracts |
| Unknown path | full repository plan |

Stages do not cascade. The packaged UI smoke drives a fake CLI, so it runs only
for app product sources, resources, and UI tests. The pinned tmux runtime
contract runs only for package, script, and tmux build changes. Each domain
selects the stages that can observe its change and nothing else.

Hosted pull request CI does not trust a caller-supplied stage list. It requires
the clean tested merge commit, classifies the exact base-to-merge diff, applies
dependency closure, and records the result. Main promotion classifies the same
diff again. Unknown paths and quality-core changes select the full plan.

## Automatic quality facts

CI inspects recent successful `main` runs and downloads the newest exact
evidence that contains quality metrics. A narrow run can omit metrics only when
its impact does not select `quality-contracts`. An authoritative metric run
accepts only a digest-bound `quality-metrics.json` from `ci-main`. It never
reads a manual floor file.

The metric artifact records its `swift` or `combined` profile, exact UI and
business test identities, aggregate line coverage, critical-source coverage,
and changed executable Swift lines. The baseline restore selects the newest
green-main artifact with the same profile. Schema-1 artifacts are combined
profiles during migration. Each combined run also records a digest-bound Swift
snapshot for later Swift-profile comparisons without a second ratchet. Thus,
Swift-test-only changes do not run packaged app journeys only to make coverage
inputs equivalent.
CI rejects a lower critical-source ratio and a new critical source that is not
fully covered in its first baseline. Missing, stale, unbound, unsafe, or
malformed baseline evidence fails closed. Aggregate ratios, removed test
identities, and changed-line coverage below the 90 percent floor are advisory.
The stage prints them as `quality-metrics: advisory:` lines and stays green.

The UI aggregate includes Swift tests and the bounded packaged-app journeys.
The separate opportunity artifact ranks current uncovered UI sources. Its risk
order comes from the current policy route, release impact, requirements, and
user journeys. The next milestone is the next five-point boundary above the
observed ratio. It is advisory and does not replace the last-green ratchet.

A weekly and manual workflow runs each deterministic safety mutant in a
separate bounded macOS job. The required mutation score is 100 percent. A
survivor, timeout, or infrastructure-like failure is not a kill and fails the
workflow.

## Continuous care

`quality/evals.json` contains stable expected outcomes for representative
historical tasks, escaped defects, policy mutations, and repository-scope
violations. Impact cases assert the complete stage, specification, capability,
user-journey, and release-gate plan after dependency closure. Scope cases assert
that internal presentations, work plans, and credential paths stay ignored.

The quality-care workflow has a five-minute deadline. It reads up to 10 gate
artifacts from the last 13 days. Each download has a 20-second deadline. A
missing artifact fails the care run. The workflow creates one open issue for
an eval regression, invalid evidence, an unresolved latest gate result, or wall p95 at
or above 480 seconds. Repaired failures remain in run and stage telemetry. The
documentation-care workflow has the same overall
deadline. It can create one repair pull request only when deterministic
generated policy views drift. Both workflows cancel superseded runs and never
run release tools.

## Dashboard

The dashboard generator validates the current manifest, summary, metric,
coverage-opportunity, and mutation digests. It also validates the care policy,
source commit, schema, and input digests. It shows authority, result, exact
commit, exact CI run, freshness, fingerprint, durations, coverage, ranked UI
opportunities, affected journeys, scenario gaps, mutation score, workflow
evals, feedback p95 and SLO, security state, and recent latency. Code review
stays a read-only step in the active agent workflow. It is not a repository
gate or a second merge authority.

The same artifact opens locally and deploys to GitHub Pages. Main and mutation
workflows deploy only after a green `ci-main` gate or a green mutation score for
that policy. The bounded care workflow can publish a validated attention
result, then marks its run failed and opens one issue. A later deploy restores
the newest valid care artifact for the current policy. The next healthy care
run closes the issue. No workflow publishes pull request or local gate
evidence. Hosted dashboard jobs pass downloaded summary and baseline paths
through environment variables. They do not expand those paths with workflow
expressions inside the shell. Producing steps write those paths with
unpredictable multiline output delimiters.

## Definition of done

An ordinary change is ready only when it has regression evidence, the current
pull request merge commit has an authoritative `quality-gates` PASS, affected
public docs and durable specs match the behavior, and `git diff --check` is
clean. A narrow test or stage rerun is diagnostic only.

The active `main` ruleset has no bypass actor. It requires a pull request, one
current strict `quality-gates` check from GitHub Actions, and a merge commit. It
requires zero approving reviews. It also rejects branch deletion and
non-fast-forward updates. A pull request or administrator push cannot update
`main` when the check is missing, pending, failed, or stale.

After a pull request opens, run:

```text
scripts/quality-merge --repository OWNER/REPOSITORY \
  --pull-request NUMBER --head HEAD_SHA --repair-attempt ATTEMPT
```

The command waits no longer than `pr_feedback_seconds` for the authoritative
check. It enables native auto-merge only for `HEAD_SHA`, then waits no longer
than `merge_wait_seconds`. It disables auto-merge on timeout. The command
rejects a changed head, a weaker ruleset, and an attempt above
`max_repair_loops`. Its JSON evidence is current-policy state under
`app/build/`; Git remains the history.

## Security care

Dependabot checks immutable GitHub Actions pins and Swift package pins each
week. It groups each ecosystem into at most one open update pull request. This
keeps update traffic from exhausting the pull-request feedback queue. The
bounded security workflow scans both GitHub Actions source and arm64 Swift
source with CodeQL on a weekly schedule or explicit request. The Swift
scan restores the existing quality-gate dependency graph, resolves the tracked
lock before tracing, and removes cached products. One supported `swift build`
command then builds the complete package graph in the traced zone. The command
does not select one target or product. It builds only arm64 and uses one
whole-module batch per module with three workers. Debug and index output are
disabled because CodeQL does not use them. The workflow does not repeat SwiftPM
preparation in a matrix. The Swift job has a 30-minute deadline. Dependency
network, repeated package planning, and process oversubscription cannot consume
the complete security workflow budget. A 25-minute successful hosted run makes
this workflow too expensive for each merge. The dashboard reads and shows the
configured CodeQL languages and cadence. Generation fails if the workflow no
longer uses weekly and explicit runs. These care jobs do not extend pull-request
feedback and cannot run release commands.

Release readiness also requires the release-only gates below. Ordinary
implementation must not run release-only gates.

## Release-only gates

The release workflow automates signing and notarization. A person supplies only
the irreversible publication confirmation and physical evidence that CI cannot
produce.

1. Owner confirmation before irreversible publication.
2. Developer ID signing and Apple notarization with owner-held credentials.
3. The signed real-power smoke test when release impact selects it.
4. The supervised closed-lid probe when release impact selects it.

They remain fail closed. Pull request jobs and ordinary agents do not receive
their credentials and cannot report them as executed.
