# Release and distribution specification

## Outcome

A Detach release is an independently verified, Apple Silicon-only app and
immutable CLI payload. Ordinary development must never create tags, notarize,
change real power state, upload assets, or claim publication.

## Invariants

- `scripts/release-version X.Y.Z` is the only normal release entry point.
  The lower-level release and publication scripts are implementation details.
- Release starts from clean, synchronized `main`. The tracked `BUILD`
  must match the latest published manifest; `VERSION` and `BUILD`
  change together in one release commit.
- Invoking `scripts/release-version X.Y.Z` authorizes its automated commit,
  tag, and publication steps. Push the release head to its unique
  `detach-release/vX.Y.Z` branch. `scripts/release-pr` creates or resumes one
  exact pull request. It validates the evidence path before it creates or
  merges a pull request. The normal strict `quality-gates` job must pass before
  bounded auto-merge. The final merge must have the tested source and release
  head as its ordered parents and the tested tree. Tag that merge, verify the
  remote `main` and tag, and remove only the matching temporary branch. No
  actor has a general `main` ruleset bypass or direct-main release path.
- The app, watchdog, bundled tmux, state helper, power client, root helper, and
  Sparkle executables contain only `arm64`. Intel Macs are unsupported.
- The pinned tmux source build may reuse only an arm64 product keyed by the
  builder, source checksums, SDK, compiler, and deployment target; every copied
  cache product passes the normal architecture and linkage validation.
- The immutable payload order is `detach`, `detach-core`,
  `detach-install`, `detach-state`, `detach-power`, `tmux`.
  Installation activates a content-addressed version atomically.
- The locally installed release candidate is copied from the validated signed
  DMG. The workflow never installs a mutable intermediate app build.
- Developer ID signing, notarization, and the real signed power smoke are
  mandatory for every release. `scripts/release-impact` compares the last
  published tag with the release source. It selects supervised closed-lid
  testing only for power, helper, watchdog, lease, assertion, or lid-probe
  impact. An unknown product path selects the closed-lid gate. Test-only,
  documentation-only, release-orchestrator, and known unrelated product paths
  do not select it.
- Notary credential preflight gives `notarytool` a private PTY and captures its
  output in private workflow evidence. This supports protected Keychain
  profiles without exposing submission history in the release log.
- The path classifier is the fail-safe default. An explicit private semantic
  review can omit a false-positive manual gate only when it is permission-safe,
  ignored by Git, bound to the exact base and head commits, and gives a reason
  for the decision. It cannot narrow unknown-path impact or omit automated
  tests, signing, notarization, the signed power smoke, or artifact checks.
- A selected closed-lid probe must emit its first liveness sample within a
  bounded ten-second launch window before owner confirmation is accepted.
  Automated release tests cover install, repair, uninstall, update, CLI
  synchronization, and helper replacement paths.
- `DETACH_RELEASE_TEST_MODE=1` relaxes selected local production-path checks
  for hermetic tests. It can simulate push and publication only after it proves
  the exact fixture repository, local origin, empty hooks, placeholder name,
  and fake external tools. This boundary never authorizes an external release.
- End-to-end release fixtures use separate repositories and external-state
  roots. They run with bounded admission, report each case duration, and always
  run the complete case set. A scheduler change cannot omit a release case.
- The release entry point supplies the low-level publication confirmation after
  all selected gates pass. After upload, verification lists every remote asset
  name. A name outside the expected set fails closed. Every expected remote
  asset is downloaded and its digest is independently matched. Missing, extra,
  changed, or mismatched assets fail closed.
- Each release includes a deterministic SPDX 2.3 SBOM. It lists the exact
  Swift resolution, including SwiftTerm, and the checksummed tmux, libevent,
  and utf8proc sources.
  The SBOM names the exact tag and commit. The release manifest binds its
  digest to the signed and notarized artifacts. Publication validates the SBOM
  before upload and after an independent remote download.
- Stage and wall durations are telemetry. Every functional, artifact,
  signing, power, lid, and publication gate remains mandatory; no timing
  comparison can pass or fail a release.
- The pre-release quality gate classifies the complete diff from the last
  published tag to synchronized `main`. It runs that plan on the release Mac.
  An empty or
  unknown diff selects the complete release plan. This selection does not omit
  later signing, notarization, hardware, artifact, or publication gates.
- A resumed release automatically reuses digest-bound passed stages from the
  newest compatible local run. It starts fresh when no compatible run exists.
  It inherits the earlier wall time as telemetry.
- Before the pre-release gate, the orchestrator downloads the evidence from the
  newest green `main` run that contains measured quality metrics.
  Critical-source coverage must not regress from that artifact.
  Missing or invalid baseline evidence stops the release.
- Resume state is private under `app/build/`. Resume is allowed only when
  source, durable stage evidence, and existing asset digests still match.
- A resume after the artifact stage requires only credentials for the remaining
  publication work. If artifact validation requires a rebuild, the workflow
  requires the Developer ID, notarization, and Sparkle credentials again.
- After the atomic main/tag push, a paused release can resume from a newer
  synchronized `main` only when the release commit remains an ancestor and all
  later paths are release tooling, release documentation, or test-only source
  under `app/Tests/`. Product sources and build inputs remain rejected. The
  annotated tag and artifact manifest stay bound to the release commit.
- The release orchestrator gives the lower-level publisher the exact manifest
  commit. The publisher requires the tag to match it and the current `HEAD` to
  contain it. The orchestrator separately rejects all other descendants.
- Sparkle remains pinned and signed inside-out. Production builds never carry
  the development library-validation exception. Appcasts contain exactly one
  arm64 hardware requirement.
- Distribution bootstrap runs only from `/Applications`, never a DMG or
  App Translocation path. A Sparkle update replaces the app; bootstrap switches
  the CLI payload without rewriting binaries used by live sessions. A failed
  download, archive, signature, app installation, CLI synchronization, or
  helper replacement keeps the prior app or CLI control path usable and
  provides a Repair path.

## Owned paths

`scripts/release-version`, `scripts/release-pr`, `scripts/release-lid-probe`,
`scripts/release-sbom`, `tools/release_pr.py`, `tools/release_sbom.py`,
`app/scripts/release.sh`, `app/scripts/publish-release.sh`,
`app/scripts/make-dmg.sh`, `app/scripts/verify-appcast.sh`,
`VERSION`, `BUILD`, release/publish workflow tests, and release CI.

## Fast feedback

Run the narrow hermetic script matching the edit:
`tests/release-preflight.sh`, `tests/publish-preflight.sh`, or
`tests/release-workflow.sh`. These never replace the impact-selected
quality gate or the manual release-only gates listed in `docs/testing.md`.
