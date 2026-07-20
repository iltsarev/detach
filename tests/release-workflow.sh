#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-release-workflow-test.XXXXXX")"
PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
IDENTITY='Developer ID Application: Detach Tests (TESTTEAM)'
TARGET_VERSION=1.2.4
TARGET_TAG=v1.2.4

cleanup() {
  if [ "${DETACH_RELEASE_WORKFLOW_TEST_KEEP:-0}" = 1 ]; then
    printf 'Kept release workflow test state: %s\n' "$TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

write_executable() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  /bin/cat >"$path"
  chmod 0755 "$path"
}

setup_fixture() {
  local name="$1"
  FIXTURE="$TMP_ROOT/$name"
  REPO="$FIXTURE/repo"
  ORIGIN="$FIXTURE/origin.git"
  BIN="$FIXTURE/bin"
  APPS="$FIXTURE/Applications"
  REMOTE_ASSETS="$FIXTURE/remote-assets"
  RELEASE_EXISTS="$FIXTURE/release-exists"
  ACTION_LOG="$FIXTURE/actions.log"
  PUBLISHED_MANIFEST="$FIXTURE/published-manifest.json"
  mkdir -p "$REPO/scripts" "$REPO/tests/quality-gate-fixtures" "$REPO/app/scripts" \
    "$REPO/app/.build/artifacts/sparkle/Sparkle/bin" "$BIN" "$APPS" \
    "$REMOTE_ASSETS"

  install -m 0755 "$ROOT/scripts/release-version" "$REPO/scripts/release-version"
  install -m 0755 "$ROOT/scripts/release-lid-probe" "$REPO/scripts/release-lid-probe"
  install -m 0755 "$ROOT/scripts/quality-gate" "$REPO/scripts/quality-gate"
  install -m 0755 "$ROOT/app/scripts/verify-appcast.sh" \
    "$REPO/app/scripts/verify-appcast.sh"
  printf '%s\n' 1.2.3 >"$REPO/VERSION"
  printf '%s\n' 13 >"$REPO/BUILD"
  printf '%s\n' '.env.release' >"$REPO/.gitignore"
  printf '%s\n' '.build/' 'build/' >"$REPO/app/.gitignore"
  printf '%s\n' 'release workflow fixture' >"$REPO/README.md"
  {
    printf "DETACH_CODESIGN_IDENTITY='%s'\n" "$IDENTITY"
    printf '%s\n' 'DETACH_NOTARY_PROFILE=detach-tests'
    printf 'DETACH_SPARKLE_PUBLIC_ED_KEY=%s\n' "$PUBLIC_KEY"
    printf '%s\n' 'DETACH_SPARKLE_KEY_ACCOUNT=detach-tests'
    printf '%s\n' 'DETACH_GITHUB_REPOSITORY=example/detach'
  } >"$REPO/.env.release"
  chmod 0600 "$REPO/.env.release"
  cat >"$PUBLISHED_MANIFEST" <<JSON
{"schema":1,"version":"1.2.3","build":"13","tag":"v1.2.3","git_commit":"0000000000000000000000000000000000000000"}
JSON

  write_executable "$REPO/app/.build/artifacts/sparkle/Sparkle/bin/generate_keys" <<'SH'
#!/bin/bash
printf '%s\n' "${FAKE_PUBLIC_KEY:?}"
SH

  write_executable "$REPO/app/scripts/make-app.sh" <<'SH'
#!/bin/bash
set -eu
root="$(cd -P "$(dirname "$0")/../.." && pwd)"
for name in \
  DETACH_VERSION DETACH_BUILD_VERSION DETACH_BUILD_ARCHS \
  DETACH_CODESIGN_IDENTITY DETACH_RELEASE_BUILD DETACH_SPARKLE_VERSION \
  DETACH_SPARKLE_FEED_URL DETACH_SPARKLE_PUBLIC_ED_KEY DETACH_DOWNLOAD_URL; do
  [ -z "${!name+x}" ] || {
    printf 'development build inherited release override: %s\n' "$name" >&2
    exit 1
  }
done
mkdir -p "$root/app/build/Detach.app/Contents/Resources/DetachCLI"
printf '#!/bin/bash\nexit 0\n' >"$root/app/build/Detach.app/Contents/Resources/DetachCLI/tmux"
chmod 0755 "$root/app/build/Detach.app/Contents/Resources/DetachCLI/tmux"
printf '%s\n' make-app >>"${FAKE_ACTION_LOG:?}"
SH

  write_executable "$REPO/app/scripts/verify-app.sh" <<'SH'
#!/bin/bash
set -eu
app="${DETACH_APP_PATH:-$(cd -P "$(dirname "$0")/.." && pwd)/build/Detach.app}"
[ -d "$app" ]
printf '%s\n' verify-app >>"${FAKE_ACTION_LOG:?}"
SH

  write_executable "$REPO/app/scripts/release.sh" <<'SH'
#!/bin/bash
set -euo pipefail
root="$(cd -P "$(dirname "$0")/../.." && pwd)"
version="${DETACH_VERSION:?}"
build="${DETACH_BUILD_VERSION:?}"
tag="${DETACH_RELEASE_TAG:?}"
commit="$(git -C "$root" rev-parse HEAD)"
app="$root/app/build/Detach.app"
assets="$root/app/build/update-assets"
rm -rf "$app" "$assets"
mkdir -p "$app/Contents/Resources/DetachCLI" "$app/Contents/MacOS" "$assets"
printf '%s\n' "$version" >"$app/Contents/Resources/DetachCLI/VERSION"
printf '%s\n' "$build" >"$app/Contents/Resources/DetachCLI/BUILD"
cat >"$app/Contents/MacOS/detach-power" <<'POWER'
#!/bin/bash
set -eu
ready=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ready-file) ready="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
[ -z "$ready" ] || : >"$ready"
exec "$@"
POWER
chmod 0755 "$app/Contents/MacOS/detach-power"
printf '%s\n' 'signed dmg fixture' >"$root/app/build/Detach.dmg"
printf '%s\n' 'signed update fixture' >"$assets/Detach-$version.zip"
cat >"$assets/appcast.xml" <<XML
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>
<link>https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/latest</link>
<sparkle:version>$build</sparkle:version><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/download/$tag/Detach-$version.zip" />
</item></channel></rss>
XML
dmg_sha="$(shasum -a 256 "$root/app/build/Detach.dmg" | awk '{print $1}')"
update_sha="$(shasum -a 256 "$assets/Detach-$version.zip" | awk '{print $1}')"
appcast_sha="$(shasum -a 256 "$assets/appcast.xml" | awk '{print $1}')"
cat >"$assets/release-manifest.json" <<JSON
{"schema":1,"version":"$version","build":"$build","tag":"$tag","git_commit":"$commit","feed_url":"https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/latest/download/appcast.xml","update_url":"https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/download/$tag/Detach-$version.zip","download_url":"https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/latest","dmg_sha256":"$dmg_sha","update_sha256":"$update_sha","appcast_sha256":"$appcast_sha"}
JSON
(
  cd -P "$root/app/build"
  shasum -a 256 Detach.dmg >Detach.dmg.sha256
)
for asset in "Detach-$version.zip" appcast.xml release-manifest.json; do
  (
    cd -P "$assets"
    shasum -a 256 "$asset" >"$asset.sha256"
  )
done
chmod 0644 "$root/app/build/Detach.dmg" "$root/app/build/Detach.dmg.sha256" "$assets"/*
printf '%s\n' release >>"${FAKE_ACTION_LOG:?}"
SH

  write_executable "$REPO/app/scripts/publish-release.sh" <<'SH'
#!/bin/bash
set -euo pipefail
root="$(cd -P "$(dirname "$0")/../.." && pwd)"
version="${DETACH_VERSION:?}"
mkdir -p "${FAKE_REMOTE_ASSETS:?}"
cp "$root/app/build/Detach.dmg" "$root/app/build/Detach.dmg.sha256" \
  "$root/app/build/update-assets/Detach-$version.zip" \
  "$root/app/build/update-assets/Detach-$version.zip.sha256" \
  "$root/app/build/update-assets/appcast.xml" \
  "$root/app/build/update-assets/appcast.xml.sha256" \
  "$root/app/build/update-assets/release-manifest.json" \
  "$root/app/build/update-assets/release-manifest.json.sha256" \
  "$FAKE_REMOTE_ASSETS/"
if [ "${FAKE_PUBLISH_CORRUPT:-0}" = 1 ]; then
  printf '%s\n' corrupt >>"$FAKE_REMOTE_ASSETS/Detach.dmg"
fi
: >"${FAKE_RELEASE_EXISTS:?}"
printf '%s\n' publish >>"${FAKE_ACTION_LOG:?}"
SH

  for test_name in run.sh run-claude.sh distribution.sh tmux-runtime.sh release-preflight.sh publish-preflight.sh; do
    write_executable "$REPO/tests/$test_name" <<SH
#!/bin/bash
set -eu
printf '%s\n' '$test_name' >>"\${FAKE_ACTION_LOG:?}"
SH
  done

  write_executable "$REPO/tests/quality-gate-fixtures/static" <<'SH'
#!/bin/bash
exit 0
SH
  write_executable "$REPO/tests/quality-gate-fixtures/gate-contract" <<'SH'
#!/bin/bash
exit 0
SH
  write_executable "$REPO/tests/quality-gate-fixtures/swift" <<'SH'
#!/bin/bash
exec swift test
SH
  write_executable "$REPO/tests/quality-gate-fixtures/app" <<'SH'
#!/bin/bash
set -eu
root="$(cd -P "$(dirname "$0")/../.." && pwd)"
"$root/app/scripts/make-app.sh"
"$root/app/scripts/verify-app.sh"
SH
  write_executable "$REPO/tests/quality-gate-fixtures/codex" <<'SH'
#!/bin/bash
exec "$(cd -P "$(dirname "$0")/../.." && pwd)/tests/run.sh"
SH
  write_executable "$REPO/tests/quality-gate-fixtures/claude" <<'SH'
#!/bin/bash
exec "$(cd -P "$(dirname "$0")/../.." && pwd)/tests/run-claude.sh"
SH
  for stage in distribution tmux-runtime release-preflight publish-preflight; do
    write_executable "$REPO/tests/quality-gate-fixtures/$stage" <<SH
#!/bin/bash
exec "\$(cd -P "\$(dirname "\$0")/../.." && pwd)/tests/$stage.sh"
SH
  done
  write_executable "$REPO/tests/power-smoke.sh" <<'SH'
#!/bin/bash
set -eu
[ "${DETACH_ALLOW_REAL_POWER_TEST:-0}" = 1 ]
[ -x "${DETACH_TEST_APP:?}/Contents/MacOS/detach-power" ]
printf '%s\n' power-smoke >>"${FAKE_ACTION_LOG:?}"
SH

  write_executable "$BIN/swift" <<'SH'
#!/bin/bash
set -eu
[ "${DETACH_RELEASE_TESTS_DETACHED:-0}" = 1 ] || {
  printf '%s\n' 'swift test inherited the release confirmation session' >&2
  exit 1
}
printf 'swift %s\n' "$*" >>"${FAKE_ACTION_LOG:?}"
SH
  write_executable "$BIN/security" <<'SH'
#!/bin/bash
printf '  1) ABCDEF "%s"\n' "${FAKE_IDENTITY:?}"
SH
  write_executable "$BIN/xcrun" <<'SH'
#!/bin/bash
set -eu
case " $* " in
  *' notarytool history '*) printf '%s\n' '{}' ;;
  *) exit 64 ;;
esac
SH
  write_executable "$BIN/gh" <<'SH'
#!/bin/bash
set -eu
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'release view')
    [ -f "${FAKE_RELEASE_EXISTS:?}" ] || exit 1
    case " $* " in
      *' --json tagName '*) printf '%s\n' "${FAKE_TARGET_TAG:?}" ;;
    esac
    ;;
  *) exit 64 ;;
esac
SH
  write_executable "$BIN/ditto" <<'SH'
#!/bin/bash
set -eu
/bin/cp -R "$1" "$2"
SH
  write_executable "$BIN/open" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' open >>"${FAKE_ACTION_LOG:?}"
SH
  write_executable "$BIN/curl" <<'SH'
#!/bin/bash
set -eu
output=""
write_out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) output="$2"; shift 2 ;;
    --write-out|-w) write_out="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    --fail|--silent|--show-error|--location|--head) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$url" ] || exit 64
status=200
case "$url" in
  https://api.github.com/repos/*/releases/tags/*)
    if [ -f "${FAKE_RELEASE_EXISTS:?}" ]; then
      [ -z "$output" ] || printf '%s\n' '{}' >"$output"
    else
      status=404
      [ -z "$output" ] || printf '%s\n' '{}' >"$output"
    fi
    ;;
  https://github.com/*/releases/latest/download/release-manifest.json)
    if [ -f "${FAKE_RELEASE_EXISTS:?}" ]; then
      cp "${FAKE_REMOTE_ASSETS:?}/release-manifest.json" "$output"
    else
      cp "${FAKE_PUBLISHED_MANIFEST:?}" "$output"
    fi
    ;;
  https://github.com/*/releases/latest/download/appcast.xml)
    cp "${FAKE_REMOTE_ASSETS:?}/appcast.xml" "$output"
    ;;
  https://github.com/*/releases/download/*/*)
    name="${url##*/}"
    if [ "$output" != /dev/null ]; then
      [ -f "${FAKE_REMOTE_ASSETS:?}/$name" ] || exit 22
      cp "$FAKE_REMOTE_ASSETS/$name" "$output"
    fi
    ;;
  *) exit 22 ;;
esac
[ -z "$write_out" ] || printf '%s' "$status"
SH

  git -C "$REPO" init -q
  git -C "$REPO" checkout -qb main
  git -C "$REPO" config user.name 'Detach Tests'
  git -C "$REPO" config user.email 'detach-tests@example.invalid'
  git -C "$REPO" add .
  git -C "$REPO" commit -qm 'release workflow fixture'
  git init -q --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push -q -u origin main
}

run_workflow() {
  local fail_after="${1:-}" lid_confirmation="${2:-example/detach@$TARGET_TAG}"
  (
    cd -P "$REPO"
    PATH="$BIN:/usr/bin:/bin" \
      FAKE_PUBLIC_KEY="$PUBLIC_KEY" \
      FAKE_IDENTITY="$IDENTITY" \
      FAKE_ACTION_LOG="$ACTION_LOG" \
      FAKE_REMOTE_ASSETS="$REMOTE_ASSETS" \
      FAKE_RELEASE_EXISTS="$RELEASE_EXISTS" \
      FAKE_PUBLISHED_MANIFEST="$PUBLISHED_MANIFEST" \
      FAKE_TARGET_TAG="$TARGET_TAG" \
      DETACH_RELEASE_TEST_MODE=1 \
      DETACH_QUALITY_GATE_TEST_MODE=1 \
      DETACH_RELEASE_TEST_APPLICATIONS_DIR="$APPS" \
      DETACH_RELEASE_TEST_LID_MIN_SECONDS=0 \
      DETACH_RELEASE_TEST_FAIL_AFTER="$fail_after" \
      DETACH_CONFIRM_RELEASE="example/detach@$TARGET_TAG" \
      DETACH_CONFIRM_LID_TEST="$lid_confirmation" \
      "$REPO/scripts/release-version" "$TARGET_VERSION"
  )
}

expect_failure() {
  local label="$1" expected="$2"
  shift 2
  if "$@" >"$FIXTURE/$label.stdout" 2>"$FIXTURE/$label.stderr"; then
    printf 'release workflow unexpectedly succeeded: %s\n' "$label" >&2
    exit 1
  fi
  grep -F "$expected" "$FIXTURE/$label.stderr" >/dev/null || {
    printf 'release workflow failed for the wrong reason: %s\n' "$label" >&2
    sed -n '1,80p' "$FIXTURE/$label.stderr" >&2
    exit 1
  }
}

setup_fixture resume
for stage in preflight prepared pushed artifacts installed power-smoke lid published verified; do
  expect_failure "resume-$stage" "injected safe failure after $stage" \
    run_workflow "$stage"
done
run_workflow
[ "$(<"$REPO/VERSION")" = "$TARGET_VERSION" ]
[ "$(<"$REPO/BUILD")" = 14 ]
[ "$(git -C "$REPO" log --format=%s | grep -c "^Prepare $TARGET_VERSION release$")" = 1 ]
[ "$(git -C "$REPO" cat-file -t "$TARGET_TAG")" = tag ]
[ "$(grep -c '^release$' "$ACTION_LOG")" = 1 ]
[ "$(grep -c '^publish$' "$ACTION_LOG")" = 1 ]
[ "$(grep -c '^power-smoke$' "$ACTION_LOG")" = 1 ]
[ "$(grep -c '^release-preflight.sh$' "$ACTION_LOG")" = 2 ]
[ "$(grep -c '^publish-preflight.sh$' "$ACTION_LOG")" = 2 ]
[ -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-verified" ]

setup_fixture dirty
printf '%s\n' dirty >"$REPO/untracked-note.txt"
expect_failure dirty 'release workflow requires a clean worktree' run_workflow
[ ! -s "$ACTION_LOG" ]

setup_fixture stale-build
printf '%s\n' 12 >"$REPO/BUILD"
git -C "$REPO" add BUILD
git -C "$REPO" commit -qm 'stale tracked build'
git -C "$REPO" push -q origin main
expect_failure stale-build 'tracked BUILD 12 does not match published build 13' run_workflow

setup_fixture diverged
printf '%s\n' local >>"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'local divergence'
expect_failure diverged 'main must be synchronized with origin/main' run_workflow

setup_fixture duplicate-tag
git -C "$REPO" tag -a "$TARGET_TAG" -m duplicate
expect_failure duplicate-tag "local tag already exists: $TARGET_TAG" run_workflow

setup_fixture duplicate-release
: >"$RELEASE_EXISTS"
expect_failure duplicate-release "GitHub release already exists: $TARGET_TAG" run_workflow

setup_fixture hardware-gate
expect_failure hardware-gate \
  "closed-lid hardware test confirmation must exactly equal example/detach@$TARGET_TAG" \
  run_workflow '' wrong-confirmation
[ ! -f "$RELEASE_EXISTS" ]
! grep -q '^publish$' "$ACTION_LOG"

setup_fixture remote-hash
export FAKE_PUBLISH_CORRUPT=1
expect_failure remote-hash 'published asset hash mismatch: Detach.dmg' run_workflow
unset FAKE_PUBLISH_CORRUPT
[ -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-published" ]
[ ! -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-verified" ]

printf 'Detach release workflow tests passed\n'
