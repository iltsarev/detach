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
- The app, watchdog, bundled tmux, state helper, power client, root helper, and
  Sparkle executables contain only `arm64`. Intel Macs are unsupported.
- The immutable payload order is `detach`, `detach-core`,
  `detach-install`, `detach-state`, `detach-power`, `tmux`.
  Installation activates a content-addressed version atomically.
- Developer ID signing, notarization, real signed power smoke, and supervised
  closed-lid testing are mandatory release gates and are never inferred from
  unit tests.
- Publication requires exact `owner/repository@tag` confirmation. After
  upload, every remote asset is downloaded and its digest independently
  matched. Missing, extra, changed, or mismatched assets fail closed.
- Resume state is private under `app/build/`. Resume is allowed only when
  source, durable stage evidence, and existing asset digests still match.
- Sparkle remains pinned and signed inside-out. Production builds never carry
  the development library-validation exception. Appcasts contain exactly one
  arm64 hardware requirement.
- Distribution bootstrap runs only from `/Applications`, never a DMG or
  App Translocation path. A Sparkle update replaces the app; bootstrap switches
  the CLI payload without rewriting binaries used by live sessions.

## Owned paths

`scripts/release-version`, `scripts/release-lid-probe`,
`app/scripts/release.sh`, `app/scripts/publish-release.sh`,
`app/scripts/make-dmg.sh`, `app/scripts/verify-appcast.sh`,
`VERSION`, `BUILD`, release/publish workflow tests, and release CI.

## Fast feedback

Run the narrow hermetic script matching the edit:
`tests/release-preflight.sh`, `tests/publish-preflight.sh`, or
`tests/release-workflow.sh`. These never replace the impact-selected
quality gate or the manual release-only gates listed in `docs/testing.md`.
