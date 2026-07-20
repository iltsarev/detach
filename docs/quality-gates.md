# Quality gates

`scripts/quality-gate` is the tracked readiness contract for local agents, CI,
and releases. Policy version 1 orders checks from cheap to expensive, derives
the mandatory set from the Git diff, and selects the full repository gate for
unknown paths or changes to this policy itself.

## Commands

- `scripts/quality-gate` checks the working-tree diff.
- `scripts/quality-gate --base <ref>` checks committed changes since a trusted
  merge base plus staged, unstaged, and untracked files.
- `scripts/quality-gate --mode repository` runs every automated repository
  check. CI uses this mode on `main`; pull requests use impact analysis.
- `scripts/quality-gate --mode release` runs the complete pre-release suite.
  It omits only the recursive test of `scripts/release-version` itself.
- `scripts/quality-gate --plan` prints the selected stages without running
  them. `--stage <name>` is an explicit diagnostic rerun and is never readiness
  evidence.

The stages are `static`, the gate orchestrator's own contract tests, `swift`,
development app build/verification, serial Codex and Claude integrations,
distribution, bundled runtime, release and publish preflights, and the hermetic
release-workflow test. Integrations that
share tmux or project locks are intentionally serial. Every stage has a bounded
timeout. Logs and a versioned TSV result are written privately under
`app/build/quality-gates/`; failure, timeout, skip, or interruption cannot
produce PASS. The failure output names the exact diagnostic rerun. A red gate
must be diagnosed, not made green by blind retries.

Swift and Clang module caches are rooted under `app/.build`; integrations use
only the freshly verified bundled tmux and their existing private state/socket
roots. The gate therefore does not depend on writable user caches, ambient tmux,
or provider session state.

There are no quarantined tests in policy version 1. A future quarantine must be
tracked here with an owner, expiry, and reason, and may not remove a release
contract check.

## Impact classes

| Change | Mandatory automated gates |
| --- | --- |
| Documentation only | static syntax and diff checks |
| Swift source or tests | static, Swift tests |
| Package/resources/app build | static, Swift, app, runtime contracts |
| CLI/session lifecycle | static, app, both serial integrations, distribution, runtime |
| Install/distribution | static, app, distribution, runtime |
| Release/publication | static, app, release/publish preflights, release-workflow test |
| Gate policy, CI, mixed unknown path | full repository gate |

Known mixed diffs take the union of their mandatory gates. Dependencies are
added by the mapping (for example an integration always gets a freshly built
bundled tmux). An unclassifiable path fails safe to the full set.

## Definition of Done

An agent may report a change ready only when the changed behavior has a
regression or contract test, the normal impact-selected gate has printed PASS,
user-facing documentation is synchronized, and `git diff --check` is clean.
The report must name any manual release gate that was not run. A single test or
`--stage` rerun is useful diagnosis but cannot replace the selected gate.

CI and `scripts/release-version` invoke this same entry point. They must not
copy a separate test matrix.

## Manual release-only gates

These are the only checks deliberately outside the automated repository gate:

1. Developer ID signing and Apple notarization with owner-held credentials.
2. The explicitly opted-in signed real-power smoke test.
3. The supervised closed-lid probe on supported Apple Silicon hardware.
4. Exact owner/repository/tag publication confirmation.

They remain fail-closed stages of `scripts/release-version`; ordinary agents
and pull-request jobs must never receive their secrets or pretend to run them.
