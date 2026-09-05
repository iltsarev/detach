# Testing and release verification

## Commands

- `scripts/test critical` — fast diagnostic coverage for the highest-risk
  state, ownership, storage, power, watchdog, and shell-safety contracts. Use
  `scripts/test --plan critical` to inspect the pinned suites.
- `scripts/test unit` — every Swift unit test without packaging or coverage
  analysis; use it after a wider Swift edit when `critical` is too narrow.
- `scripts/test coverage` — every coverage-enabled Swift test followed by
  automatic test-identity, aggregate, critical-source, and changed-line
  metrics. This fast local diagnostic is unit-only. An authoritative gate adds
  the passed packaged-app profiles without another Swift test run. Hosted CI
  compares the combined result with the newest green `main` artifact that
  contains measured metrics. The local command deletes only the active SwiftPM
  build path's prior profile, so stale
  build evidence cannot satisfy the command.
- `scripts/test smoke` — builds a fresh app, validates and runs the isolated
  packaged-app Accessibility flow, then verifies the bundled runtime. It needs
  a logged-in WindowServer session and an environment that permits the private
  app and tmux socket. Use `scripts/test --plan smoke` to inspect the steps.
- `scripts/test full` — every automated repository check as a local diagnostic;
  it delegates exactly to `scripts/quality-gate --mode repository`. It does not
  claim merge readiness. Pull-request CI runs the exact impact-selected matrix
  once on the tested merge commit and is merge authority.

- `scripts/quality-gate` — the policy-versioned, impact-aware local diagnostic
  entry point. It selects checks from the diff and fails safe to the repository
  gate for unknown impact. See `docs/quality-gates.md`.
- `scripts/quality-gate --mode impact --base <ref>` — the committed-diff mode
  used by pull-request CI. Merge authority requires `<ref>` to be the tested
  merge first parent and rejects a dirty checkout.
- A normal change keeps `gate-contract` focused on direct self-contracts.
  `--mode repository` and an explicit `--stage gate-contract` run the full
  orchestrator contract set.
- `scripts/quality-gate --plan --explain` explains impact selection;
  `--plan --format json` is the machine-readable equivalent. A failed or
  interrupted run may use `--resume <run-dir>` or `--resume latest` only while
  its policy, exact source/base commits, input fingerprint, and stage coverage
  still match. `--keep-going` improves diagnosis but never turns a failed or
  blocked stage into readiness evidence.
- Pull-request CI validates that machine plan and runs static contracts before
  optional metrics and Swift cache downloads. The final gate recomputes both,
  so the early pass is fail-fast diagnosis and not readiness evidence.
- `scripts/quality-cache-warm` builds the three isolated Swift products for a
  missing promoted-`main` cache key. It emits no gate evidence and never
  replaces a selected stage. `--dependencies-only` materializes the shared
  cache once before parallel builds. `tools/quality_products.py publish`
  also stages the bundled `tmux` and `detach-state` as exact runtime
  products; a hosted provider shard that binds them skips the app build.
- `scripts/quality-scenarios rerun SC-ID` runs the owning diagnostic stage for
  an instrumented scenario, or its direct policy command otherwise. The stage
  process deadline bounds both forms. The helper has 30 seconds for evidence
  finalization and process-group cleanup. Instrumented suites also write
  scenario-level durations. A monolithic legacy suite reports only stage
  granularity until it gets scenario markers.
- `scripts/quality-history [RESULT_ROOT]` reports p50/p95 wall and stage timing,
  ordinary failures, and execution-environment failures across retained local
  or downloaded current-schema gate evidence. A declared unsupported schema is
  outside the sample. Current-schema timing can span earlier policy identifiers
  without dashboard-only fields. Add `--format json` for care automation. It is
  run telemetry, not policy history or readiness evidence.
- `scripts/quality-care validate` checks the four required eval categories.
  `scripts/quality-care evaluate --output <json>` grades exact diff impact and
  private-scope outcomes. `scripts/quality-care assess` fails before the
  pull-request wall p95 reaches the ten-minute SLO. It also fails for invalid
  evidence or an unresolved latest gate result. Older repaired failures remain
  telemetry. Scheduled quality care opens one scoped issue. Its summary binds
  the source commit and both input digests.
  `scripts/quality-care latest --optional` inspects at most five completed runs
  inside one 60-second deadline. It supplies only a valid current-policy
  artifact to later dashboard deploys. Scheduled documentation care can open a
  pull request only for deterministic files under `quality/generated/`.
- `scripts/quality-policy generate --check` checks both generated policy JSON
  and the readable current-spec traceability table.
- `scripts/quality-promote` is the hosted post-merge path. It downloads the
  exact successful pull-request artifact, classifies its impact again, and
  proves tree and parent equality. It does not run locally or change the tested
  evidence. A failed proof makes the workflow run the full main repository
  gate.
- `scripts/quality-dashboard generate` creates
  `app/build/quality-dashboard/{index.html,data.json}` from the newest schema-4
  evidence. `scripts/quality-dashboard serve --seconds 300` serves it only on
  loopback and stops at the deadline. A green `main` workflow publishes the
  same static files to `https://iltsarev.github.io/detach/`. Add
  `--care-summary <json>` to show validated eval, latency, and run-health
  facts. A merge commit from `scripts/quality-merge` adds the bounded repair
  attempt. Scheduled care can publish an attention result before the
  workflow records FAIL and opens its issue.
- `scripts/quality-mutation validate` checks the deterministic safety corpus.
  `scripts/quality-mutation run --id <id> --output <json> --log <log>` runs one
  mutant and restores its source. The weekly hosted workflow runs all mutants
  in parallel and requires a 100-percent score. Each mutant has a 240-second
  deadline. This workflow does not run on pull requests. A successful run
  updates the GitHub Pages dashboard with its score.
- `scripts/quality-gate --mode repository` — every automated repository check.
  Local use is diagnostic. Pull-request CI uses impact mode once with
  `ci-merge` authority. `--stage` is diagnostic only and is not
  proof that a change is ready. On hosts with at least three CPUs, the current
  policy splits workers across isolated Swift tests, normal app, and
  instrumented app builds. Smaller hosts run Swift and app work in sequence.
  It then runs the isolated Codex and Claude suites concurrently
  against the verified bundled tmux and state helper. Stage and wall durations
  are telemetry for `scripts/quality-history` and the care SLO; they never
  change a verdict. A quality-core or unknown change selects the full
  repository plan. `--resume auto` starts
  fresh when no compatible run exists and is the release default. Resume
  inherits timing and parent provenance. It preserves bounded failure
  diagnostics and classifies known execution-environment denials without
  weakening FAIL.

- `DETACH_TEST_TMUX_BIN="$PWD/app/build/Detach.app/Contents/Resources/DetachCLI/tmux" tests/run.sh`
  — hermetic Codex integration with a fake provider, private tmux
  socket/state roots, a fake native power wrapper, and an explicitly selected
  bundled tmux artifact.
- `DETACH_TEST_TMUX_BIN="$PWD/app/build/Detach.app/Contents/Resources/DetachCLI/tmux" tests/run-claude.sh`
  — the equivalent Claude integration. Build and verify the
  app first; repository integrations must not fall back to an ambient tmux.
- Add `DETACH_CODEX_TEST_KEEP=1` to the Codex command above to keep its
  temporary state and tmux server for inspection. Use
  `DETACH_CLAUDE_TEST_KEEP=1` with the Claude command.
- Long-lived provider fixtures use bounded release files. They do not use a
  fixed sleep window for liveness checks. Failure artifacts identify the
  failing test line.
- `tests/distribution.sh` — immutable install/upgrade/repair/doctor/uninstall
  coverage for the fixed payload (`detach`, `detach-core`, `detach-install`,
  `detach-state`, `detach-power`, and `tmux`) with a temporary home.
- `tests/tmux-runtime.sh` — pinned tmux source/provenance, arm64-only packaging,
  linkage, signing, and bundled native-helper contract checks.
- `tests/ui-e2e-contract.sh` and `tests/ui-e2e.sh` — freshness-marker negative
  contracts and the bounded real-control smoke for the freshly built app.
  The smoke uses a stripped background-only copy, a fake CLI, and private
  HOME/preferences/state below `/private/tmp`; it cannot use the installed
  Detach or user session state. It temporarily activates the isolated app,
  posts AppKit mouse events to measured SwiftUI controls, uses native slider
  increment actions, and restores the prior application. The locator bridge
  has no application actions. Run the
  app build first. The UI smoke needs a logged-in WindowServer session but no
  Accessibility approval. Before it launches the app it probes the console
  session. An agent sandbox, an SSH session, the login window, or a locked
  screen produces `UI e2e: environment denied`, exit 2, and the gate records
  `environment-failed` instead of a product failure. Every scenario and
  attempt starts from a clean private state, and the smoke deletes the test
  copy's preference domains through cfprefsd at the end. A scenario whose
  app never reports a result, or reports a timeout, gets one retry; the log
  records `e2e retry 1 of 1`. A reported assertion failure never retries.
  Do not grant
  it broader filesystem or production
  payload access. Its fake CLI allowlist covers only the exact status and stop
  flow and the completed-session forced delete asserted by the smoke. The
  same run disconnects Stop, proves that no action occurs, reconnects it, and
  requires the exact action.
- `tests/release-preflight.sh` and `tests/publish-preflight.sh` — hermetic release
  tooling, arm64 appcast, production-DMG verification, exact artifact allowlist,
  and explicit publication-confirmation guards.
- `tests/release-workflow.sh` — hermetic end-to-end orchestration, including
  resume after every durable stage, dirty/diverged source rejection, duplicate
  tag/release rejection, hardware-gate failure, remote hash mismatch,
  hermetic publication-boundary rejection, and unexpected remote assets. It
  admits at most five independent fixture repositories and reports each case
  duration. Every case remains required.
- `cd app && swift test --enable-code-coverage --disable-sandbox`, followed by
  `tests/quality-contracts.sh` — unit tests plus measured UI and business test
  identities, aggregate coverage, and coverage for the 13 critical sources.
  The authoritative gate also merges the release-configuration packaged-app
  profiles after all UI journeys pass. CI rejects a critical-source reduction
  from the last green `main` artifact and a new critical source that is not
  fully covered. Aggregate, test-identity, and changed-line comparisons
  (90 percent floor) are advisory. The quality policy owns each coverage
  exclusion and links it to automated scenario evidence. Excluded sources do
  not enter aggregate or changed-line denominators. Named test-only regions in
  product files stay in aggregate coverage but use their automated scenario as
  changed-line evidence. `tests/quality-metrics.sh` covers missing, malformed,
  removed-test, aggregate, critical-file, changed-line, combined-profile, and
  ranked-opportunity contracts. The opportunity artifact is advisory. It does
  not set a coverage floor.
- `tests/quality-mutation.sh` checks source restoration, timeout handling,
  failure classification, score enforcement, remote evidence restore, and the
  scheduled workflow contract. A nonzero compiler exit without the declared
  test-failure marker does not count as a killed mutant.
- `cd app && swift test` — a faster diagnostic unit-test rerun for DetachKit,
  app services, typed state
  operations, power lifecycle, lease policy, XPC policy, and presentation.
- `app/scripts/make-app.sh` followed by `app/scripts/verify-app.sh` — build and
  verify a local app. A normal build must contain only an `arm64` slice for the
  app, watchdog, tmux, state helper, power client, root helper, and embedded
  Sparkle executables. Intel Macs are not supported.
- `DETACH_SIGNED_APP_FIXTURE=/path/to/Detach.app swift test --filter
  ServiceManagementMutationAdmission` — runs the real Security framework check
  of the release-signing gate against a signed bundle. Without the variable the
  test skips, so run it before a release that changes code signing.
- `DETACH_ALLOW_REAL_POWER_TEST=1 tests/power-smoke.sh` — deliberately changes
  real system power state through an installed, signed, approved app. Never run
  it as routine verification. Before a release, run it only on supervised
  hardware whose initial sleep setting is normal, then separately verify actual
  closed-lid behavior.

There is no third-party linter dependency. The static stage runs shell syntax,
the repository-specific shell safety contract, documentation checks, the
timing-policy ratchet, and `git diff --check`. Stdlib Python owns quality-gate
planning, scheduling, evidence, and policy decisions. Shell entry points only
locate Python. Behavioral shell integrations remain runtime evidence for shell
products and macOS processes.

Each selected stage writes scenario evidence to `scenarios.jsonl` and
`scenarios.junit.xml`. Instrumented scenarios fail closed when their begin or
pass event is missing. Failed scenario records also produce
`repair-bundle.json`. The bundle contains requirement and journey links, the
exact bounded rerun, and at most the last 100 log lines. Planned scenarios stay
visible as gaps. The closed-lid scenario remains a supervised release-only
gate because software automation cannot prove physical lid behavior.

`tests/docs-contract.sh` is the focused check for agent instructions, durable
specs, and the documentation workflow. It does not replace the selected gate.

`scripts/release-version X.Y.Z` is the only normal release entry point. It
requires a clean synchronized `main`, reads literal release settings from the
ignored owner-only `.env.release`, runs the impact-selected suite from the last
published tag before changing Git,
requires the tracked root `BUILD` to match the latest published manifest,
increments it together with `VERSION` in one release commit, and creates one
annotated tag. The invocation authorizes its automated commit, tag, and
publication steps. It pushes the release head to a unique
`detach-release/vX.Y.Z` branch. `scripts/release-pr` creates or resumes one
exact pull request. The normal strict `quality-gates` job must pass before
bounded exact-head auto-merge. The workflow verifies the final merge parents
and tree, tags that merge, verifies remote `main` and the tag, and removes the
matching temporary branch. It does not push release metadata directly to
`main`. It then reuses the
strict `app/scripts/release.sh` and `app/scripts/publish-release.sh`, installs
the signed candidate, runs the real power smoke, publishes, and independently
lists, downloads, and hashes every remote asset. `scripts/release-impact` compares the
last published tag with the release source. It selects the supervised
closed-lid probe only for power, helper, watchdog, lease, assertion, or
lid-probe impact. Unknown product paths select the closed-lid gate. The policy
`release-scan` row for `bin/detach-core` waives the probe for a plain
modification whose diff hunks mention no power token; the result records
`lid_test_scan_waived`. Its private
resume state and impact evidence live under ignored `app/build/`.
The path result is fail-safe. For a false positive, a release operator can
supply `DETACH_RELEASE_IMPACT_REVIEW` with an absolute path directly under
ignored `app/build/release-impact-reviews/`. The `0600` TSV file must bind the
exact base and head commits, set the manual-gate decision, and give a reason.
It cannot narrow unknown-path impact or an automated release gate.
Interrupted draft uploads may resume only after every existing asset digest is
matched; an unexpected or changed asset fails closed. Do not run the two
low-level scripts manually during a normal release. Do not run, tag, notarize,
upload, or publish as part of ordinary implementation or verification.

Each published release also contains `release-sbom.spdx.json` and its SHA-256
sidecar. `scripts/release-sbom` builds it from the pinned Swift and bundled tmux
source metadata. The release manifest binds the SBOM digest to the exact tag
and commit. Preflight and remote verification reject a missing, changed, or
structurally invalid SBOM.
