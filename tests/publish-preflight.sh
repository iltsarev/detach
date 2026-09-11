#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/quality-scenarios" event begin SC-UPDATE-APPLY
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-publish-preflight-test.XXXXXX")"
TEST_REPO="$TMP_ROOT/repo"
TEST_APP="$TEST_REPO/app"
FAKE_BIN="$TMP_ROOT/bin"
GH_LOG="$TMP_ROOT/gh.log"
REPOSITORY=example/detach
TAG=v1.2.3
EXPECTED_CONFIRMATION="$REPOSITORY@$TAG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_APP/scripts" "$TEST_REPO/scripts" "$TEST_REPO/tools" "$FAKE_BIN"
install -m 0755 "$ROOT/app/scripts/publish-release.sh" \
  "$TEST_APP/scripts/publish-release.sh"
install -m 0755 "$ROOT/scripts/release-sbom" "$TEST_REPO/scripts/release-sbom"
install -m 0755 "$ROOT/scripts/build-tmux.sh" "$TEST_REPO/scripts/build-tmux.sh"
install -m 0644 "$ROOT/tools/release_sbom.py" "$TEST_REPO/tools/release_sbom.py"
install -m 0644 "$ROOT/app/Package.resolved" "$TEST_APP/Package.resolved"
printf '%s\n' 1.2.3 >"$TEST_REPO/VERSION"
grep -F '"$APPCAST_VERIFIER" "$APPCAST"' \
  "$TEST_APP/scripts/publish-release.sh" >/dev/null || {
  printf 'publish must verify arm64 appcast hardware requirements\n' >&2
  exit 1
}
if grep -F '[ "$SEPARATE_RELEASE_REPOSITORY" = 1 ]' \
    "$TEST_APP/scripts/publish-release.sh" >/dev/null; then
  printf 'publish must not skip tag identity for a separate-release env\n' >&2
  exit 1
fi
printf '%s\n' 'app/build/' >"$TEST_REPO/.gitignore"
printf '%s\n' 'publish fixture' >"$TEST_REPO/README.md"
git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.name 'Detach Tests'
git -C "$TEST_REPO" config user.email 'detach-tests@example.invalid'
git -C "$TEST_REPO" add .
git -C "$TEST_REPO" commit -qm 'publish fixture skeleton'

cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
exit 97
SH
chmod 0755 "$FAKE_BIN/gh"

assert_confirmation_rejected() {
  local supplied="$1" label="$2"
  if PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_GH_LOG="$GH_LOG" \
      DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
      DETACH_CONFIRM_PUBLISH="$supplied" \
      "$TEST_APP/scripts/publish-release.sh" \
      >"$TMP_ROOT/$label.stdout" 2>"$TMP_ROOT/$label.stderr"; then
    printf 'publish unexpectedly accepted confirmation: %s\n' "$supplied" >&2
    exit 1
  fi
  grep -F "DETACH_CONFIRM_PUBLISH must exactly equal $EXPECTED_CONFIRMATION" \
    "$TMP_ROOT/$label.stderr" >/dev/null
  [ ! -e "$GH_LOG" ] || {
    printf 'publish contacted GitHub before exact confirmation\n' >&2
    exit 1
  }
}

assert_confirmation_rejected '' missing-confirmation
assert_confirmation_rejected yes vague-confirmation
assert_confirmation_rejected "$REPOSITORY@v9.9.9" wrong-tag-confirmation

BUILD="$TEST_APP/build"
UPDATE_ASSETS="$BUILD/update-assets"
mkdir -p "$UPDATE_ASSETS"
for artifact in \
  "$BUILD/Detach.dmg" \
  "$BUILD/Detach.dmg.sha256" \
  "$UPDATE_ASSETS/Detach-1.2.3.zip" \
  "$UPDATE_ASSETS/Detach-1.2.3.zip.sha256" \
  "$UPDATE_ASSETS/appcast.xml" \
  "$UPDATE_ASSETS/appcast.xml.sha256" \
  "$UPDATE_ASSETS/release-sbom.spdx.json" \
  "$UPDATE_ASSETS/release-sbom.spdx.json.sha256" \
  "$UPDATE_ASSETS/release-manifest.json" \
  "$UPDATE_ASSETS/release-manifest.json.sha256"; do
  : >"$artifact"
done
printf '%s\n' 'private local note' >"$UPDATE_ASSETS/private-notes.txt"

if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/extra-asset.stdout" 2>"$TMP_ROOT/extra-asset.stderr"; then
  printf 'publish unexpectedly accepted an extra updater asset\n' >&2
  exit 1
fi
grep -F 'Refusing unexpected updater asset: private-notes.txt' \
  "$TMP_ROOT/extra-asset.stderr" >/dev/null
[ ! -e "$GH_LOG" ] || {
  printf 'publish contacted GitHub before rejecting an extra asset\n' >&2
  exit 1
}

rm "$UPDATE_ASSETS/private-notes.txt"
chmod 0644 \
  "$BUILD/Detach.dmg" \
  "$BUILD/Detach.dmg.sha256" \
  "$UPDATE_ASSETS/Detach-1.2.3.zip" \
  "$UPDATE_ASSETS/Detach-1.2.3.zip.sha256" \
  "$UPDATE_ASSETS/appcast.xml" \
  "$UPDATE_ASSETS/appcast.xml.sha256" \
  "$UPDATE_ASSETS/release-sbom.spdx.json" \
  "$UPDATE_ASSETS/release-sbom.spdx.json.sha256" \
  "$UPDATE_ASSETS/release-manifest.json" \
  "$UPDATE_ASSETS/release-manifest.json.sha256"
chmod 0600 "$BUILD/Detach.dmg"
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/private-mode.stdout" 2>"$TMP_ROOT/private-mode.stderr"; then
  printf 'publish unexpectedly accepted a private-mode release asset\n' >&2
  exit 1
fi
grep -F 'Release asset must be a regular file with mode 0644:' \
  "$TMP_ROOT/private-mode.stderr" >/dev/null
[ ! -e "$GH_LOG" ] || {
  printf 'publish contacted GitHub before rejecting a private-mode asset\n' >&2
  exit 1
}

# Build a self-consistent local release fixture. Publication must independently
# validate the actual mounted DMG and app before even authenticating with gh;
# mutable checksum sidecars and the manifest are not signing/notarization proof.
rm -f "$GH_LOG"
chmod 0644 "$BUILD/Detach.dmg"
printf '%s\n' 'signed dmg fixture' >"$BUILD/Detach.dmg"
printf '%s\n' 'signed update fixture' >"$UPDATE_ASSETS/Detach-1.2.3.zip"
cat >"$UPDATE_ASSETS/appcast.xml" <<XML
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item>
    <link>https://github.com/$REPOSITORY/releases/latest</link>
    <sparkle:version>13</sparkle:version>
    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
    <enclosure url="https://github.com/$REPOSITORY/releases/download/$TAG/Detach-1.2.3.zip" />
  </item></channel>
</rss>
XML
install -m 0755 "$ROOT/app/scripts/verify-appcast.sh" \
  "$TEST_APP/scripts/verify-appcast.sh"
cat >"$TEST_APP/scripts/verify-app.sh" <<'SH'
#!/bin/bash
printf 'verify-app|%s|%s|%s\n' \
  "${DETACH_APP_PATH:-}" \
  "${DETACH_VERIFY_PRODUCTION:-}" \
  "${DETACH_REQUIRE_SPARKLE_CONFIG:-}" \
  >>"${FAKE_VALIDATION_LOG:?}"
[ "${FAIL_VALIDATION:-}" != verify_app ]
SH
chmod 0755 "$TEST_APP/scripts/verify-app.sh"

git -C "$TEST_REPO" add .
git -C "$TEST_REPO" commit -qm 'publish verification fixture'
git -C "$TEST_REPO" tag "$TAG"
GIT_COMMIT="$(git -C "$TEST_REPO" rev-parse HEAD)"
DMG_SHA256="$(shasum -a 256 "$BUILD/Detach.dmg" | awk '{print $1}')"
UPDATE_SHA256="$(shasum -a 256 "$UPDATE_ASSETS/Detach-1.2.3.zip" | awk '{print $1}')"
APPCAST_SHA256="$(shasum -a 256 "$UPDATE_ASSETS/appcast.xml" | awk '{print $1}')"
"$TEST_REPO/scripts/release-sbom" generate \
  --version 1.2.3 \
  --tag "$TAG" \
  --commit "$GIT_COMMIT" \
  --repository "$REPOSITORY" \
  --output "$UPDATE_ASSETS/release-sbom.spdx.json"
SBOM_SHA256="$(shasum -a 256 "$UPDATE_ASSETS/release-sbom.spdx.json" | awk '{print $1}')"
cat >"$UPDATE_ASSETS/release-manifest.json" <<JSON
{"schema":2,"version":"1.2.3","build":"13","tag":"$TAG","git_commit":"$GIT_COMMIT","feed_url":"https://github.com/$REPOSITORY/releases/latest/download/appcast.xml","update_url":"https://github.com/$REPOSITORY/releases/download/$TAG/Detach-1.2.3.zip","download_url":"https://github.com/$REPOSITORY/releases/latest","dmg_sha256":"$DMG_SHA256","update_sha256":"$UPDATE_SHA256","appcast_sha256":"$APPCAST_SHA256","sbom_sha256":"$SBOM_SHA256"}
JSON
(
  cd -P "$BUILD"
  shasum -a 256 Detach.dmg >Detach.dmg.sha256
)
for checksum_target in \
  Detach-1.2.3.zip \
  appcast.xml \
  release-sbom.spdx.json \
  release-manifest.json; do
  (
    cd -P "$UPDATE_ASSETS"
    shasum -a 256 "$checksum_target" >"$checksum_target.sha256"
  )
done
chmod 0644 \
  "$BUILD/Detach.dmg" \
  "$BUILD/Detach.dmg.sha256" \
  "$UPDATE_ASSETS/Detach-1.2.3.zip" \
  "$UPDATE_ASSETS/Detach-1.2.3.zip.sha256" \
  "$UPDATE_ASSETS/appcast.xml" \
  "$UPDATE_ASSETS/appcast.xml.sha256" \
  "$UPDATE_ASSETS/release-sbom.spdx.json" \
  "$UPDATE_ASSETS/release-sbom.spdx.json.sha256" \
  "$UPDATE_ASSETS/release-manifest.json" \
  "$UPDATE_ASSETS/release-manifest.json.sha256"

cat >"$FAKE_BIN/hdiutil" <<'SH'
#!/bin/bash
set -eu
printf 'hdiutil|%s\n' "$*" >>"${FAKE_VALIDATION_LOG:?}"
case "${1:-}" in
  verify)
    [ "${FAIL_VALIDATION:-}" != hdiutil_verify ]
    ;;
  attach)
    [ "${FAIL_VALIDATION:-}" != hdiutil_attach ] || exit 71
    mountpoint=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -mountpoint ]; then
        mountpoint="$2"
        break
      fi
      shift
    done
    [ -n "$mountpoint" ]
    mkdir -p "$mountpoint/Detach.app"
    ln -s /Applications "$mountpoint/Applications"
    if [ "${FAIL_VALIDATION:-}" = layout ]; then
      printf 'unexpected\n' >"$mountpoint/extra.txt"
    fi
    ;;
  detach) ;;
  *) exit 64 ;;
esac
SH
cat >"$FAKE_BIN/codesign" <<'SH'
#!/bin/bash
set -eu
printf 'codesign|%s\n' "$*" >>"${FAKE_VALIDATION_LOG:?}"
target=""
for argument in "$@"; do target="$argument"; done
case "${FAIL_VALIDATION:-}:$target" in
  codesign_dmg:*.dmg|codesign_app:*.app) exit 72 ;;
esac
case " $* " in
  *' -d '*)
    printf '%s\n' \
      'Authority=Developer ID Application: Detach Tests (TESTTEAM)' \
      'TeamIdentifier=TESTTEAM' >&2
    ;;
esac
SH
cat >"$FAKE_BIN/xcrun" <<'SH'
#!/bin/bash
set -eu
printf 'xcrun|%s\n' "$*" >>"${FAKE_VALIDATION_LOG:?}"
target=""
for argument in "$@"; do target="$argument"; done
case "${FAIL_VALIDATION:-}:$target" in
  stapler_dmg:*.dmg|stapler_app:*.app) exit 73 ;;
esac
SH
cat >"$FAKE_BIN/spctl" <<'SH'
#!/bin/bash
set -eu
printf 'spctl|%s\n' "$*" >>"${FAKE_VALIDATION_LOG:?}"
case "${FAIL_VALIDATION:-}: $* " in
  gatekeeper_app:*' --type execute '*) exit 74 ;;
  gatekeeper_dmg:*' --type open '*) exit 74 ;;
esac
SH
cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
grep -F 'spctl|--assess --type open --context context:primary-signature --verbose=2' \
  "${FAKE_VALIDATION_LOG:?}" >/dev/null || exit 96
exit 97
SH
chmod 0755 \
  "$FAKE_BIN/hdiutil" \
  "$FAKE_BIN/codesign" \
  "$FAKE_BIN/xcrun" \
  "$FAKE_BIN/spctl" \
  "$FAKE_BIN/gh"

assert_local_validation_rejected() {
  local failure="$1"
  local validation_log="$TMP_ROOT/$failure.validation.log"
  local gh_log="$TMP_ROOT/$failure.gh.log"
  : >"$validation_log"
  rm -f "$gh_log"
  if PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_GH_LOG="$gh_log" \
      FAKE_VALIDATION_LOG="$validation_log" \
      FAIL_VALIDATION="$failure" \
      DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
      DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
      "$TEST_APP/scripts/publish-release.sh" \
      >"$TMP_ROOT/$failure.stdout" 2>"$TMP_ROOT/$failure.stderr"; then
    printf 'publish unexpectedly ignored failed local validation: %s\n' \
      "$failure" >&2
    exit 1
  fi
  [ ! -e "$gh_log" ] || {
    printf 'publish contacted GitHub before rejecting: %s\n' "$failure" >&2
    exit 1
  }
  if [ "$failure" = hdiutil_attach ]; then
    grep -F 'hdiutil|detach ' "$validation_log" >/dev/null || {
      printf 'failed DMG attach was not cleaned up with detach\n' >&2
      exit 1
    }
  fi
}

assert_dirty_worktree_rejected() {
  local label="$1"
  : >"$TMP_ROOT/validation.log"
  rm -f "$GH_LOG"
  if PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_GH_LOG="$GH_LOG" \
      FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
      DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
      DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
      "$TEST_APP/scripts/publish-release.sh" \
      >"$TMP_ROOT/$label.stdout" 2>"$TMP_ROOT/$label.stderr"; then
    printf 'publish unexpectedly accepted a dirty worktree: %s\n' \
      "$label" >&2
    exit 1
  fi
  grep -F 'Publication requires a clean git worktree' \
    "$TMP_ROOT/$label.stderr" >/dev/null
  [ ! -s "$TMP_ROOT/validation.log" ] || {
    printf 'publish validated a DMG before rejecting dirty worktree: %s\n' \
      "$label" >&2
    exit 1
  }
  [ ! -e "$GH_LOG" ] || {
    printf 'publish contacted GitHub before rejecting dirty worktree: %s\n' \
      "$label" >&2
    exit 1
  }
}

[ -z "$(git -C "$TEST_REPO" status --porcelain --untracked-files=all)" ] || {
  printf 'publish validation fixture must start with a clean worktree\n' >&2
  exit 1
}
printf '%s\n' dirty >>"$TEST_REPO/README.md"
assert_dirty_worktree_rejected dirty-tracked
printf '%s\n' 'publish fixture' >"$TEST_REPO/README.md"
printf '%s\n' dirty >"$TEST_REPO/local-note.txt"
assert_dirty_worktree_rejected dirty-untracked
rm "$TEST_REPO/local-note.txt"

validation_case_pids=()
validation_case_names=()
for failed_validation in \
  hdiutil_verify \
  hdiutil_attach \
  layout \
  codesign_dmg \
  codesign_app \
  verify_app \
  stapler_app \
  stapler_dmg \
  gatekeeper_app \
  gatekeeper_dmg; do
  assert_local_validation_rejected "$failed_validation" &
  validation_case_pids+=("$!")
  validation_case_names+=("$failed_validation")
done
validation_case_status=0
for validation_case_index in "${!validation_case_pids[@]}"; do
  if ! wait "${validation_case_pids[$validation_case_index]}"; then
    printf 'publish validation lane failed: %s\n' \
      "${validation_case_names[$validation_case_index]}" >&2
    validation_case_status=1
  fi
done
[ "$validation_case_status" -eq 0 ] || exit 1

: >"$TMP_ROOT/validation.log"
rm -f "$GH_LOG"
PUBLISH_EXIT=0
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/validated.stdout" 2>"$TMP_ROOT/validated.stderr"; then
  printf 'publish unexpectedly passed the fake gh boundary\n' >&2
  exit 1
else
  PUBLISH_EXIT=$?
fi
[ "$PUBLISH_EXIT" = 97 ] || {
  printf 'publish reached gh before finishing local validation (exit %s)\n' \
    "$PUBLISH_EXIT" >&2
  exit 1
}
grep -Fx 'auth status' "$GH_LOG" >/dev/null
grep -F 'verify-app|' "$TMP_ROOT/validation.log" >/dev/null
grep -F 'hdiutil|attach -readonly -nobrowse -owners on -mountpoint ' \
  "$TMP_ROOT/validation.log" >/dev/null
grep -F 'spctl|--assess --type open --context context:primary-signature --verbose=2' \
  "$TMP_ROOT/validation.log" >/dev/null
"$ROOT/scripts/quality-scenarios" event pass SC-UPDATE-APPLY
"$ROOT/scripts/quality-scenarios" event begin SC-PUBLISH-CONTRACT

# The release orchestrator can continue from a clean tooling descendant while
# the tag and manifest stay bound to the built release commit. Direct use keeps
# the stricter HEAD equality check.
printf '%s\n' 'release tooling follow-up' >>"$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -qm 'release tooling follow-up'
rm -f "$GH_LOG"
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/descendant-direct.stdout" \
    2>"$TMP_ROOT/descendant-direct.stderr"; then
  printf 'direct publish unexpectedly accepted a descendant HEAD\n' >&2
  exit 1
fi
grep -F 'Current HEAD does not match the built release manifest' \
  "$TMP_ROOT/descendant-direct.stderr" >/dev/null
[ ! -e "$GH_LOG" ] || {
  printf 'direct descendant rejection contacted GitHub\n' >&2
  exit 1
}

: >"$TMP_ROOT/validation.log"
PUBLISH_EXIT=0
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    DETACH_RELEASE_EXPECTED_COMMIT="$GIT_COMMIT" \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/descendant-orchestrated.stdout" \
    2>"$TMP_ROOT/descendant-orchestrated.stderr"; then
  printf 'orchestrated descendant unexpectedly passed fake gh\n' >&2
  exit 1
else
  PUBLISH_EXIT=$?
fi
[ "$PUBLISH_EXIT" = 97 ] || {
  printf 'orchestrated descendant did not reach gh (exit %s)\n' \
    "$PUBLISH_EXIT" >&2
  exit 1
}
grep -Fx 'auth status' "$GH_LOG" >/dev/null

WRONG_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
grep -F 'spctl|--assess --type open --context context:primary-signature --verbose=2' \
  "${FAKE_VALIDATION_LOG:?}" >/dev/null || exit 96
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'api repos/'*)
    printf '%s\n' "${FAKE_REMOTE_COMMIT:?}"
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$FAKE_BIN/gh"
rm -f "$GH_LOG"
: >"$TMP_ROOT/validation.log"
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
    FAKE_REMOTE_COMMIT="$WRONG_COMMIT" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    DETACH_RELEASE_EXPECTED_COMMIT="$GIT_COMMIT" \
    DETACH_SEPARATE_RELEASE_REPOSITORY=1 \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/separate-tag.stdout" 2>"$TMP_ROOT/separate-tag.stderr"; then
  printf 'publish skipped remote-tag identity with ambient separate-release env\n' >&2
  exit 1
fi
grep -F "Remote tag $TAG does not point to the built source commit" \
  "$TMP_ROOT/separate-tag.stderr" >/dev/null
if grep -E 'release create|release upload|release edit' "$GH_LOG" >/dev/null; then
  printf 'publish mutated a release after tag identity failure\n' >&2
  exit 1
fi

cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
grep -F 'spctl|--assess --type open --context context:primary-signature --verbose=2' \
  "${FAKE_VALIDATION_LOG:?}" >/dev/null || exit 96
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'api repos/'*)
    case " $* " in
      *"/${FAKE_MISSING_TAG:?} "*) exit 1 ;;
    esac
    printf '%s\n' "${FAKE_REMOTE_COMMIT:?}"
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$FAKE_BIN/gh"
rm -f "$GH_LOG"
: >"$TMP_ROOT/validation.log"
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
    FAKE_REMOTE_COMMIT="$WRONG_COMMIT" \
    FAKE_MISSING_TAG="$TAG" \
    DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
    DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
    DETACH_RELEASE_EXPECTED_COMMIT="$GIT_COMMIT" \
    DETACH_GITHUB_RELEASE_TARGET=other-ref \
    DETACH_SEPARATE_RELEASE_REPOSITORY=1 \
    "$TEST_APP/scripts/publish-release.sh" \
    >"$TMP_ROOT/separate-target.stdout" 2>"$TMP_ROOT/separate-target.stderr"; then
  printf 'publish skipped release-target identity with ambient separate-release env\n' >&2
  exit 1
fi
grep -F 'GitHub release target does not match the built source commit' \
  "$TMP_ROOT/separate-target.stderr" >/dev/null
if grep -E 'release create|release upload|release edit' "$GH_LOG" >/dev/null; then
  printf 'publish mutated a release after target identity failure\n' >&2
  exit 1
fi

# A safe retry may encounter a draft created by a previous interrupted upload.
# It must validate every existing digest, upload only missing allowlisted files,
# and then publish the same draft instead of creating or replacing a release.
cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"

asset_path() {
  case "$1" in
    Detach.dmg|Detach.dmg.sha256) printf '%s/%s\n' "${FAKE_DRAFT_BUILD:?}" "$1" ;;
    *) printf '%s/%s\n' "${FAKE_DRAFT_ASSETS:?}" "$1" ;;
  esac
}

print_asset_names() {
  printf '%s\n' Detach.dmg Detach.dmg.sha256
  if [ -f "${FAKE_DRAFT_UPLOADED:?}" ]; then
    printf '%s\n' \
      Detach-1.2.3.zip \
      Detach-1.2.3.zip.sha256 \
      appcast.xml \
      appcast.xml.sha256 \
      release-sbom.spdx.json \
      release-sbom.spdx.json.sha256 \
      release-manifest.json \
      release-manifest.json.sha256
  fi
}

case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'api repos/'*) printf '%s\n' "${FAKE_DRAFT_COMMIT:?}" ;;
  'release view')
    case " $* " in
      *' --json isDraft '*)
        if [ -f "${FAKE_DRAFT_PUBLISHED:?}" ]; then printf '%s\n' false; else printf '%s\n' true; fi
        ;;
      *' --json tagName '*) printf '%s\n' "${FAKE_DRAFT_TAG:?}" ;;
      *' --json assets '*)
        case " $* " in
          *'.digest'*)
            name="$(printf '%s\n' "$*" | sed -n 's/.*name == "\([^"]*\)".*/\1/p')"
            [ -n "$name" ]
            path="$(asset_path "$name")"
            [ -f "$path" ]
            printf 'sha256:%s\n' "$(shasum -a 256 "$path" | awk '{print $1}')"
            ;;
          *) print_asset_names ;;
        esac
        ;;
      *) exit 0 ;;
    esac
    ;;
  'release upload') : >"${FAKE_DRAFT_UPLOADED:?}" ;;
  'release edit') : >"${FAKE_DRAFT_PUBLISHED:?}" ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$FAKE_BIN/gh"

rm -f "$GH_LOG"
: >"$TMP_ROOT/validation.log"
rm -f "$TMP_ROOT/draft-uploaded" "$TMP_ROOT/draft-published"
PATH="$FAKE_BIN:/usr/bin:/bin" \
  FAKE_GH_LOG="$GH_LOG" \
  FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
  FAKE_DRAFT_BUILD="$BUILD" \
  FAKE_DRAFT_ASSETS="$UPDATE_ASSETS" \
  FAKE_DRAFT_COMMIT="$GIT_COMMIT" \
  FAKE_DRAFT_TAG="$TAG" \
  FAKE_DRAFT_UPLOADED="$TMP_ROOT/draft-uploaded" \
  FAKE_DRAFT_PUBLISHED="$TMP_ROOT/draft-published" \
  DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
  DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
  DETACH_RELEASE_EXPECTED_COMMIT="$GIT_COMMIT" \
  DETACH_RESUME_DRAFT=1 \
  "$TEST_APP/scripts/publish-release.sh" \
  >"$TMP_ROOT/resume-draft.stdout" 2>"$TMP_ROOT/resume-draft.stderr"
[ -f "$TMP_ROOT/draft-uploaded" ]
[ -f "$TMP_ROOT/draft-published" ]
grep -F 'release upload' "$GH_LOG" >/dev/null
grep -F 'release edit' "$GH_LOG" >/dev/null
grep -F 'Published Detach 1.2.3' "$TMP_ROOT/resume-draft.stdout" >/dev/null

PATH="$FAKE_BIN:/usr/bin:/bin" \
  FAKE_GH_LOG="$GH_LOG" \
  FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
  FAKE_DRAFT_BUILD="$BUILD" \
  FAKE_DRAFT_ASSETS="$UPDATE_ASSETS" \
  FAKE_DRAFT_COMMIT="$GIT_COMMIT" \
  FAKE_DRAFT_TAG="$TAG" \
  FAKE_DRAFT_UPLOADED="$TMP_ROOT/draft-uploaded" \
  FAKE_DRAFT_PUBLISHED="$TMP_ROOT/draft-published" \
  DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
  DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
  DETACH_RELEASE_EXPECTED_COMMIT="$GIT_COMMIT" \
  DETACH_RESUME_PUBLISHED=1 \
  "$TEST_APP/scripts/publish-release.sh" \
  >"$TMP_ROOT/resume-published.stdout" 2>"$TMP_ROOT/resume-published.stderr"
[ "$(grep -c '^release upload' "$GH_LOG")" = 1 ]
grep -F 'Published Detach 1.2.3' "$TMP_ROOT/resume-published.stdout" >/dev/null

"$ROOT/scripts/quality-scenarios" event pass SC-PUBLISH-CONTRACT
printf 'Detach publish preflight tests passed\n'
