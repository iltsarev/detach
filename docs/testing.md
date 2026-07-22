# Testing and release verification

## Commands

- `scripts/quality-gate` — the policy-versioned, impact-aware readiness entry
  point for agents. It selects mandatory checks from the diff and fails safe to
  the repository gate for unknown impact. See `docs/quality-gates.md`.
- `scripts/quality-gate --plan --explain` explains impact selection;
  `--plan --format json` is the machine-readable equivalent. A failed or
  interrupted run may use `--resume <run-dir>` or `--resume latest` only while
  its policy, exact source/base commits, input fingerprint, and stage coverage
  still match. `--keep-going` improves diagnosis but never turns a failed or
  blocked stage into readiness evidence.
- `scripts/quality-history [RESULT_ROOT]` reports p50/p95 wall and stage timing,
  ordinary failures, and execution-environment failures across retained local
  or downloaded gate evidence. It is telemetry, not readiness evidence.
- `scripts/quality-gate --mode repository` — every automated repository gate.
  CI uses the same entry point with `--without-release-budget`, disabling local
  reference-machine wall and stage timing enforcement while retaining every
  selected functional stage and the static budget ratchets; that option is not
  local or release readiness evidence. `--stage` is diagnostic only and is not
  proof that a change is ready. Policy 4 keeps SwiftPM work exclusive, then
  runs the isolated Codex and Claude suites concurrently against the verified
  bundled tmux and state helper. Policy 5 additionally rejects wall time above
  180 seconds, individual stage regressions, and any attempt to lower quality
  floors or raise time budgets relative to their merge-base values. Policy 6
  adds the fast documentation/context contract to the existing static stage.
  Policy 7 adds the mandatory packaged-app `ui-e2e` stage after every selected app
  build, without raising the 180-second wall budget. Policy 8 makes resume
  inherit timing and parent provenance, preserves bounded failure diagnostics,
  classifies known execution-environment denials without weakening FAIL,
  applies stage budgets to ordinary local partial plans, exempts only the
  explicit GitHub-only budget-free plan, and raises the established UI floors.

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
- `tests/distribution.sh` — immutable install/upgrade/repair/doctor/uninstall
  coverage for the fixed payload (`detach`, `detach-core`, `detach-install`,
  `detach-state`, `detach-power`, and `tmux`) with a temporary home.
- `tests/tmux-runtime.sh` — pinned tmux source/provenance, arm64-only packaging,
  linkage, signing, and bundled native-helper contract checks.
- `tests/ui-e2e-contract.sh` and `tests/ui-e2e.sh` — freshness-marker negative
  contracts and the bounded Accessibility smoke for the freshly built app.
  The smoke uses a stripped background-only copy, fake CLI, and private
  HOME/preferences/state below `/private/tmp`; it cannot use the installed
  Detach or user session state. Run the app build first. The UI smoke needs a
  logged-in WindowServer session but must not be granted broader filesystem or
  production payload access.
- `tests/release-preflight.sh` and `tests/publish-preflight.sh` — hermetic release
  tooling, arm64 appcast, production-DMG verification, exact artifact allowlist,
  and explicit publication-confirmation guards.
- `tests/release-workflow.sh` — hermetic end-to-end orchestration, including
  resume after every durable stage, dirty/diverged source rejection, duplicate
  tag/release rejection, hardware-gate failure, and remote hash mismatch.
- `cd app && swift test --enable-code-coverage --disable-sandbox`, followed by
  `tests/quality-contracts.sh` — unit tests plus fail-closed UI/business test
  count, critical-suite presence, and exact line-coverage floors. The current
  floors are 175 UI tests, 294 business tests, 22.21% UI line coverage, and
  80.98% stable business-core line coverage. The static
  policy branch runs the monotonic baseline ratchets in parallel with SwiftPM.
  `tests/quality-ratchet-contract.sh` and
  `tests/release-budget-ratchet-contract.sh` are fast negative diagnostics for
  attempted policy weakening.
- `cd app && swift test` — a faster diagnostic unit-test rerun for DetachKit,
  app services, typed state
  operations, power lifecycle, lease policy, XPC policy, and presentation.
- `app/scripts/make-app.sh` followed by `app/scripts/verify-app.sh` — build and
  verify a local app. A normal build must contain only an `arm64` slice for the
  app, watchdog, tmux, state helper, power client, root helper, and embedded
  Sparkle executables. Intel Macs are not supported.
- `DETACH_ALLOW_REAL_POWER_TEST=1 tests/power-smoke.sh` — deliberately changes
  real system power state through an installed, signed, approved app. Never run
  it as routine verification. Before a release, run it only on supervised
  hardware whose initial sleep setting is normal, then separately verify actual
  closed-lid behavior.

There is no third-party linter dependency. The static stage runs shell syntax,
the repository-specific shell safety contract, documentation checks, monotonic
ratchets, and `git diff --check`; behavioral shell integrations remain the main
runtime evidence.

`tests/docs-contract.sh` is the focused check for agent instructions, durable
specs, and the documentation workflow. It does not replace the selected gate.

`scripts/release-version X.Y.Z` is the only normal release entry point. It
requires a clean synchronized `main`, reads literal release settings from the
ignored owner-only `.env.release`, runs the complete suite before changing Git,
requires the tracked root `BUILD` to match the latest published manifest,
increments it together with `VERSION` in one release commit, creates one
annotated tag, and requires an exact
`owner/repository@tag` confirmation before an atomic push. It then reuses the
strict `app/scripts/release.sh` and `app/scripts/publish-release.sh`, installs
the signed candidate, runs the real power smoke, measures a supervised
closed-lid probe, publishes, and independently downloads and hashes every
remote asset. Its private resume state lives under ignored `app/build/`.
Interrupted draft uploads may resume only after every existing asset digest is
matched; an unexpected or changed asset fails closed. Do not run the two
low-level scripts manually during a normal release. Do not run, tag, notarize,
upload, or publish as part of ordinary implementation or verification.
