#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
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

mkdir -p "$TEST_APP/scripts" "$FAKE_BIN"
install -m 0755 "$ROOT/app/scripts/publish-release.sh" \
  "$TEST_APP/scripts/publish-release.sh"
printf '%s\n' 1.2.3 >"$TEST_REPO/VERSION"
grep -F '"$APPCAST_VERIFIER" "$APPCAST"' \
  "$TEST_APP/scripts/publish-release.sh" >/dev/null || {
  printf 'publish must verify arm64 appcast hardware requirements\n' >&2
  exit 1
}
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
cat >"$UPDATE_ASSETS/release-manifest.json" <<JSON
{"schema":1,"version":"1.2.3","build":"13","tag":"$TAG","git_commit":"$GIT_COMMIT","feed_url":"https://github.com/$REPOSITORY/releases/latest/download/appcast.xml","update_url":"https://github.com/$REPOSITORY/releases/download/$TAG/Detach-1.2.3.zip","download_url":"https://github.com/$REPOSITORY/releases/latest","dmg_sha256":"$DMG_SHA256","update_sha256":"$UPDATE_SHA256","appcast_sha256":"$APPCAST_SHA256"}
JSON
(
  cd -P "$BUILD"
  shasum -a 256 Detach.dmg >Detach.dmg.sha256
)
for checksum_target in \
  Detach-1.2.3.zip \
  appcast.xml \
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
  : >"$TMP_ROOT/validation.log"
  rm -f "$GH_LOG"
  if PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_GH_LOG="$GH_LOG" \
      FAKE_VALIDATION_LOG="$TMP_ROOT/validation.log" \
      FAIL_VALIDATION="$failure" \
      DETACH_GITHUB_REPOSITORY="$REPOSITORY" \
      DETACH_CONFIRM_PUBLISH="$EXPECTED_CONFIRMATION" \
      "$TEST_APP/scripts/publish-release.sh" \
      >"$TMP_ROOT/$failure.stdout" 2>"$TMP_ROOT/$failure.stderr"; then
    printf 'publish unexpectedly ignored failed local validation: %s\n' \
      "$failure" >&2
    exit 1
  fi
  [ ! -e "$GH_LOG" ] || {
    printf 'publish contacted GitHub before rejecting: %s\n' "$failure" >&2
    exit 1
  }
  if [ "$failure" = hdiutil_attach ]; then
    grep -F 'hdiutil|detach ' "$TMP_ROOT/validation.log" >/dev/null || {
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
  assert_local_validation_rejected "$failed_validation"
done

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

printf 'Detach publish preflight tests passed\n'
