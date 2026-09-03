#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/quality-scenarios" event begin SC-RELEASE-WORKFLOW
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-release-workflow-test.XXXXXX")"
PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
IDENTITY='Developer ID Application: Detach Tests (TESTTEAM)'
TARGET_VERSION=1.2.4
TARGET_TAG=v1.2.4

cleanup() {
  if [ "${DETACH_RELEASE_WORKFLOW_TEST_KEEP:-0}" = 1 ]; then
    printf 'Kept release workflow test state: %s\n' "$TMP_ROOT" >&2
  else
    cleanup_started="$SECONDS"
    rm -rf "$TMP_ROOT"
    printf 'release-workflow: cleanup completed in %ss\n' \
      "$((SECONDS - cleanup_started))"
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
  if [ -n "${FIXTURE_TEMPLATE:-}" ]; then
    cp -cR "$FIXTURE_TEMPLATE" "$FIXTURE"
    git -C "$REPO" remote set-url origin "$ORIGIN"
    git -C "$REPO" config core.hooksPath "$FIXTURE/hooks"
    return
  fi
  mkdir -p "$REPO/scripts" "$REPO/tests/quality-gate-fixtures" "$REPO/app/scripts" \
    "$REPO/app/.build/artifacts/sparkle/Sparkle/bin" "$REPO/quality" "$REPO/tools" \
    "$BIN" "$APPS" "$FIXTURE/hooks" \
    "$REMOTE_ASSETS"

  install -m 0755 "$ROOT/scripts/release-version" "$REPO/scripts/release-version"
  install -m 0755 "$ROOT/scripts/release-impact" "$REPO/scripts/release-impact"
  install -m 0755 "$ROOT/scripts/release-lid-probe" "$REPO/scripts/release-lid-probe"
  install -m 0755 "$ROOT/scripts/release-sbom" "$REPO/scripts/release-sbom"
  install -m 0755 "$ROOT/scripts/build-tmux.sh" "$REPO/scripts/build-tmux.sh"
  install -m 0755 "$ROOT/scripts/quality-gate" "$REPO/scripts/quality-gate"
  install -m 0755 "$ROOT/scripts/quality-policy" "$REPO/scripts/quality-policy"
  install -m 0644 "$ROOT/tools/quality_gate.py" "$REPO/tools/quality_gate.py"
  install -m 0644 "$ROOT/tools/quality_scenarios.py" "$REPO/tools/quality_scenarios.py"
  install -m 0644 "$ROOT/tools/quality_policy.py" "$REPO/tools/quality_policy.py"
  install -m 0644 "$ROOT/tools/release_sbom.py" "$REPO/tools/release_sbom.py"
  install -m 0644 "$ROOT/app/Package.resolved" "$REPO/app/Package.resolved"
  install -m 0644 "$ROOT/quality/policy.tsv" "$REPO/quality/policy.tsv"
  install -m 0755 "$ROOT/app/scripts/verify-appcast.sh" \
    "$REPO/app/scripts/verify-appcast.sh"
  printf '%s\n' 1.2.3 >"$REPO/VERSION"
  printf '%s\n' 13 >"$REPO/BUILD"
  printf '%s\n' '.env.release' >"$REPO/.gitignore"
  printf '%s\n' '.build/' 'build/' >"$REPO/app/.gitignore"
  printf '%s\n' 'release workflow fixture' >"$REPO/README.md"
  printf '%s\n' \
    $'schema\t3' \
    $'wall_seconds_max\t180' \
    $'stage_static_seconds_max\t10' \
    $'stage_gate_contract_seconds_max\t10' \
    $'stage_swift_seconds_max\t10' \
    $'stage_quality_contracts_seconds_max\t10' \
    $'stage_app_seconds_max\t10' \
    $'stage_ui_e2e_seconds_max\t10' \
    $'stage_codex_seconds_max\t10' \
    $'stage_claude_seconds_max\t10' \
    $'stage_distribution_seconds_max\t10' \
    $'stage_tmux_runtime_seconds_max\t10' \
    $'stage_release_preflight_seconds_max\t10' \
    $'stage_publish_preflight_seconds_max\t10' \
    $'stage_release_workflow_seconds_max\t10' \
    >"$REPO/tests/release-budget.tsv"
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
rm -rf "$root/app/build/fake-dmg"
mkdir -p "$root/app/build/fake-dmg"
cp -R "$app" "$root/app/build/fake-dmg/Detach.app"
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
"$root/scripts/release-sbom" generate \
  --version "$version" \
  --tag "$tag" \
  --commit "$commit" \
  --repository "$DETACH_GITHUB_REPOSITORY" \
  --output "$assets/release-sbom.spdx.json"
sbom_sha="$(shasum -a 256 "$assets/release-sbom.spdx.json" | awk '{print $1}')"
cat >"$assets/release-manifest.json" <<JSON
{"schema":2,"version":"$version","build":"$build","tag":"$tag","git_commit":"$commit","feed_url":"https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/latest/download/appcast.xml","update_url":"https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/download/$tag/Detach-$version.zip","download_url":"https://github.com/${DETACH_GITHUB_REPOSITORY}/releases/latest","dmg_sha256":"$dmg_sha","update_sha256":"$update_sha","appcast_sha256":"$appcast_sha","sbom_sha256":"$sbom_sha"}
JSON
(
  cd -P "$root/app/build"
  shasum -a 256 Detach.dmg >Detach.dmg.sha256
)
for asset in "Detach-$version.zip" appcast.xml release-sbom.spdx.json release-manifest.json; do
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
manifest="$root/app/build/update-assets/release-manifest.json"
[ "${DETACH_RELEASE_EXPECTED_COMMIT:-}" = \
  "$(plutil -extract git_commit raw -o - "$manifest")" ]
mkdir -p "${FAKE_REMOTE_ASSETS:?}"
cp "$root/app/build/Detach.dmg" "$root/app/build/Detach.dmg.sha256" \
  "$root/app/build/update-assets/Detach-$version.zip" \
  "$root/app/build/update-assets/Detach-$version.zip.sha256" \
  "$root/app/build/update-assets/appcast.xml" \
  "$root/app/build/update-assets/appcast.xml.sha256" \
  "$root/app/build/update-assets/release-sbom.spdx.json" \
  "$root/app/build/update-assets/release-sbom.spdx.json.sha256" \
  "$root/app/build/update-assets/release-manifest.json" \
  "$root/app/build/update-assets/release-manifest.json.sha256" \
  "$FAKE_REMOTE_ASSETS/"
if [ "${FAKE_PUBLISH_CORRUPT:-0}" = 1 ]; then
  printf '%s\n' corrupt >>"$FAKE_REMOTE_ASSETS/Detach.dmg"
fi
: >"${FAKE_RELEASE_EXISTS:?}"
printf '%s\n' publish >>"${FAKE_ACTION_LOG:?}"
SH

  write_executable "$REPO/scripts/release-pr" <<'SH'
#!/bin/bash
set -euo pipefail
root="$(cd -P "$(dirname "$0")/.." && pwd)"
branch=""
head=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) branch="$2"; shift 2 ;;
    --head) head="$2"; shift 2 ;;
    --repository|--version|--repair-attempt) shift 2 ;;
    --merged-only) shift ;;
    *) exit 64 ;;
  esac
done
[ -n "$branch" ] && [ -n "$head" ]
if [ "${FAKE_RELEASE_CI_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'release PR quality-gates did not pass; main and tag are unchanged' >&2
  exit 23
fi
base="$(git -C "$root" ls-remote origin refs/heads/main | awk '{print $1}')"
if [ "${FAKE_RELEASE_CI_ADVANCE_MAIN:-0}" = 1 ]; then
  base_tree="$(git -C "$root" rev-parse "$base^{tree}")"
  raced="$(printf '%s\n' 'concurrent main update' | \
    git -C "$root" commit-tree "$base_tree" -p "$base")"
  git -C "$root" push -q origin "$raced:refs/heads/main"
  printf '%s\n' 'remote main changed before release PR merge' >&2
  exit 24
fi
[ "$base" = "$(git -C "$root" rev-parse "$head^")" ] || {
  printf '%s\n' 'remote main changed before release PR merge' >&2
  exit 25
}
tree="$(git -C "$root" rev-parse "$head^{tree}")"
merge="$(printf '%s\n' 'Merge automated release PR' | \
  git -C "$root" commit-tree "$tree" -p "$base" -p "$head")"
git -C "$root" push -q origin "$merge:refs/heads/main"
mkdir -p "$root/app/build"
printf '{"schema":1,"status":"passed","source_commit":"%s","merge_commit":"%s"}\n' \
  "$head" "$merge" >"$root/app/build/release-pr.json"
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
  write_executable "$REPO/tests/quality-gate-fixtures/quality-contracts" <<'SH'
#!/bin/bash
exit 0
SH
  write_executable "$REPO/tests/quality-gate-fixtures/app" <<'SH'
#!/bin/bash
set -eu
root="$(cd -P "$(dirname "$0")/../.." && pwd)"
"$root/app/scripts/make-app.sh"
"$root/app/scripts/verify-app.sh"
SH

  write_executable "$REPO/tests/quality-gate-fixtures/ui-e2e" <<'SH'
#!/bin/bash
exit 0
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
  *' notarytool history '*)
    [ -t 1 ] || {
      printf '%s\n' 'fake notary credential lookup requires a PTY' >&2
      exit 68
    }
    [ "${FAKE_NOTARY_UNAVAILABLE:-0}" != 1 ] || {
      printf '%s\n' 'fake notary credential unavailable' >&2
      exit 69
    }
    printf '%s\n' '{}'
    ;;
  *) exit 64 ;;
esac
SH
  write_executable "$BIN/hdiutil" <<'SH'
#!/bin/bash
set -eu
case "${1:-}" in
  attach)
    mount=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -mountpoint) mount="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$mount" ]
    cp -R "${FAKE_DMG_APP:?}" "$mount/Detach.app"
    ;;
  detach)
    rm -rf "${2:?}/Detach.app"
    ;;
  *) exit 64 ;;
esac
SH
  write_executable "$BIN/gh" <<'SH'
#!/bin/bash
set -eu
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'run list') printf '%s\n' 4242 ;;
  'run watch')
    if [ "${FAKE_RELEASE_CI_ADVANCE_MAIN:-0}" = 1 ]; then
      source_commit="$(git rev-parse HEAD^)"
      source_tree="$(git rev-parse "$source_commit^{tree}")"
      raced_commit="$(printf '%s\n' 'concurrent main update' | \
        git commit-tree "$source_tree" -p "$source_commit")"
      git push -q origin "$raced_commit:refs/heads/main"
    fi
    [ "${FAKE_RELEASE_CI_FAIL:-0}" != 1 ] || exit 23
    ;;
  'run view') printf '%s\n' 1 ;;
  'release view')
    [ -f "${FAKE_RELEASE_EXISTS:?}" ] || exit 1
    case " $* " in
      *' --json tagName '*) printf '%s\n' "${FAKE_TARGET_TAG:?}" ;;
      *' --json assets '*)
        for path in "${FAKE_REMOTE_ASSETS:?}"/*; do
          [ -f "$path" ] || continue
          basename "$path"
        done
        ;;
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
  git -C "$REPO" tag -a v1.2.3 -m 'published fixture'
  git init -q --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" config core.hooksPath "$FIXTURE/hooks"
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" push -q origin v1.2.3
}

run_workflow() {
  local fail_after="${1:-}" lid_confirmation="${2:-example/detach@$TARGET_TAG}"
  local release_confirmation="${3:-}" ignore_timing="${4:-0}"
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
      FAKE_DMG_APP="$REPO/app/build/fake-dmg/Detach.app" \
      DETACH_RELEASE_TEST_MODE=1 \
      DETACH_RELEASE_TEST_FIXTURE_ROOT="${DETACH_RELEASE_TEST_FIXTURE_ROOT-$FIXTURE}" \
      DETACH_QUALITY_GATE_TEST_MODE=1 \
      DETACH_RELEASE_TEST_APPLICATIONS_DIR="$APPS" \
      DETACH_RELEASE_TEST_LID_MIN_SECONDS=0 \
      DETACH_RELEASE_TEST_FAIL_AFTER="$fail_after" \
      DETACH_RELEASE_IGNORE_TIMING="$ignore_timing" \
      DETACH_QUALITY_AUTHORITY= \
      DETACH_CONFIRM_RELEASE="$release_confirmation" \
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

run_resume_case() {
  setup_fixture resume
  for stage in preflight prepared; do
    expect_failure "resume-$stage" "injected safe failure after $stage" \
      run_workflow "$stage"
  done
  release_ci_source="$(git -C "$REPO" rev-parse HEAD^)"

  git -C "$REPO" push -q origin \
    "$release_ci_source:refs/heads/detach-release/$TARGET_TAG"
  expect_failure release-ci-collision \
    "remote release PR branch already points to a different commit: detach-release/$TARGET_TAG" \
    run_workflow
  git -C "$REPO" push -q origin ":refs/heads/detach-release/$TARGET_TAG"

  export FAKE_RELEASE_CI_FAIL=1
  expect_failure release-ci-failure \
    'release PR quality-gates did not pass; main and tag are unchanged' \
    run_workflow
  unset FAKE_RELEASE_CI_FAIL
  [ "$(git -C "$REPO" ls-remote origin refs/heads/main | awk '{print $1}')" = \
    "$release_ci_source" ]
  [ -z "$(git -C "$REPO" ls-remote origin "refs/tags/$TARGET_TAG")" ]
  [ -n "$(git -C "$REPO" ls-remote origin "refs/heads/detach-release/$TARGET_TAG")" ]
  [ ! -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-pushed" ]

  export FAKE_RELEASE_CI_ADVANCE_MAIN=1
  expect_failure release-ci-main-race 'remote main changed before release PR merge' \
    run_workflow
  unset FAKE_RELEASE_CI_ADVANCE_MAIN
  [ -z "$(git -C "$REPO" ls-remote origin "refs/tags/$TARGET_TAG")" ]
  [ -n "$(git -C "$REPO" ls-remote origin "refs/heads/detach-release/$TARGET_TAG")" ]
  [ ! -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-pushed" ]

  git -C "$REPO" push -q --force origin "$release_ci_source:refs/heads/main"

  for stage in pushed artifacts; do
    expect_failure "resume-$stage" "injected safe failure after $stage" \
      run_workflow "$stage"
  done
  printf '%s\n' development \
    >"$REPO/app/build/Detach.app/Contents/Resources/DetachCLI/VERSION"
  export FAKE_NOTARY_UNAVAILABLE=1
  mkdir -p "$REPO/docs" "$REPO/app/Tests/DetachAppTests"
  printf '%s\n' 'release tooling follow-up' >"$REPO/docs/testing.md"
  printf '%s\n' 'test-only Swift source' \
    >"$REPO/app/Tests/DetachAppTests/ResumeTests.swift"
  git -C "$REPO" add docs/testing.md app/Tests/DetachAppTests/ResumeTests.swift
  git -C "$REPO" commit -qm 'adjust release tooling and app tests'
  git -C "$REPO" push -q origin main
  for stage in installed power-smoke lid published verified; do
    expect_failure "resume-$stage" "injected safe failure after $stage" \
      run_workflow "$stage"
  done
  run_workflow
  unset FAKE_NOTARY_UNAVAILABLE
  [ "$(<"$REPO/VERSION")" = "$TARGET_VERSION" ]
  [ "$(<"$REPO/BUILD")" = 14 ]
  [ "$(git -C "$REPO" log --format=%s | grep -c "^Prepare $TARGET_VERSION release$")" = 1 ]
  [ "$(git -C "$REPO" cat-file -t "$TARGET_TAG")" = tag ]
  [ "$(grep -c '^release$' "$ACTION_LOG")" = 1 ]
  [ "$(grep -c '^publish$' "$ACTION_LOG")" = 1 ]
  [ "$(grep -c '^power-smoke$' "$ACTION_LOG")" = 1 ]
  [ "$(grep -c '^release-preflight.sh$' "$ACTION_LOG")" = 2 ]
  [ "$(grep -c '^publish-preflight.sh$' "$ACTION_LOG")" = 2 ]
  [ -z "$(git -C "$REPO" ls-remote origin "refs/heads/detach-release/$TARGET_TAG")" ]
  [ ! -e "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-install-matrix" ]
  grep -F $'schema\t2' \
    "$REPO/app/build/release-workflow/$TARGET_VERSION/release-impact.tsv" >/dev/null
  grep -F $'lid_test_required\tfalse' \
    "$REPO/app/build/release-workflow/$TARGET_VERSION/release-impact.tsv" >/dev/null
}

run_invalid_resume_artifact_credentials_case() {
  setup_fixture invalid-resume-artifact-credentials
  expect_failure invalid-resume-artifact-preparation \
    'injected safe failure after artifacts' run_workflow artifacts
  printf '%s\n' 'changed after notarization' >"$REPO/app/build/Detach.dmg"
  export FAKE_NOTARY_UNAVAILABLE=1
  expect_failure invalid-resume-artifact-credentials \
    'notary credential preflight failed' run_workflow
  unset FAKE_NOTARY_UNAVAILABLE
  [ ! -f "$RELEASE_EXISTS" ]
}

run_timing_override_confirmation_case() {
  setup_fixture timing-override-confirmation
  grep -F 'DETACH_CONFIRM_RELEASE="$REPOSITORY@$TAG" \' \
    "$REPO/scripts/release-version" >/dev/null
  expect_failure timing-override-confirmation \
    "confirmation must exactly equal example/detach@$TARGET_TAG" \
    run_workflow '' "example/detach@$TARGET_TAG" wrong-confirmation 1
  [ ! -s "$ACTION_LOG" ]
}

run_timing_override_invalid_case() {
  setup_fixture timing-override-invalid
  expect_failure timing-override-invalid 'DETACH_RELEASE_IGNORE_TIMING must be 0 or 1' \
    run_workflow '' "example/detach@$TARGET_TAG" "example/detach@$TARGET_TAG" invalid
  [ ! -s "$ACTION_LOG" ]
}

run_timing_override_case() {
  setup_fixture timing-override
  expect_failure timing-override 'injected safe failure after preflight' \
    run_workflow preflight "example/detach@$TARGET_TAG" "example/detach@$TARGET_TAG" 1
  [ "$(<"$REPO/app/build/release-workflow/$TARGET_VERSION/timing-budget-enforced")" = false ]
  grep -F $'release_timing_override\t1' \
    "$REPO"/app/build/quality-gates/*/environment.tsv >/dev/null
  ! grep -F $'\trelease-budget\t' \
    "$REPO"/app/build/quality-gates/*/summary.tsv >/dev/null
  run_workflow
  [ "$(<"$REPO/VERSION")" = "$TARGET_VERSION" ]
  [ "$(grep -c '^release$' "$ACTION_LOG")" = 1 ]
  [ -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-verified" ]
}

run_dirty_preflight_rejection_case() {
  setup_fixture dirty
  printf '%s\n' dirty >"$REPO/untracked-note.txt"
  expect_failure dirty 'release workflow requires a clean worktree' run_workflow
  [ ! -s "$ACTION_LOG" ]
}

run_stale_build_preflight_rejection_case() {
  setup_fixture stale-build
  printf '%s\n' 12 >"$REPO/BUILD"
  git -C "$REPO" add BUILD
  git -C "$REPO" commit -qm 'stale tracked build'
  git -C "$REPO" push -q origin main
  expect_failure stale-build 'tracked BUILD 12 does not match published build 13' run_workflow
}

run_diverged_preflight_rejection_case() {
  setup_fixture diverged
  printf '%s\n' local >>"$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm 'local divergence'
  expect_failure diverged 'main must be synchronized with origin/main' run_workflow
}

run_duplicate_tag_preflight_rejection_case() {
  setup_fixture duplicate-tag
  git -C "$REPO" tag -a "$TARGET_TAG" -m duplicate
  expect_failure duplicate-tag "local tag already exists: $TARGET_TAG" run_workflow
}

run_duplicate_release_preflight_rejection_case() {
  setup_fixture duplicate-release
  : >"$RELEASE_EXISTS"
  expect_failure duplicate-release "GitHub release already exists: $TARGET_TAG" run_workflow
}

run_hardware_rejection_case() {
  setup_fixture hardware-gate
  mkdir -p "$REPO/app/Sources/DetachPower"
  printf '%s\n' 'power impact' >"$REPO/app/Sources/DetachPower/main.swift"
  git -C "$REPO" add app/Sources/DetachPower/main.swift
  git -C "$REPO" commit -qm 'change power runtime'
  git -C "$REPO" push -q origin main
  expect_failure hardware-gate \
    "closed-lid hardware test confirmation must exactly equal example/detach@$TARGET_TAG" \
    run_workflow '' wrong-confirmation
  [ ! -f "$RELEASE_EXISTS" ]
  ! grep -q '^publish$' "$ACTION_LOG"
}

run_remote_hash_case() {
  setup_fixture remote-hash
  export FAKE_PUBLISH_CORRUPT=1
  expect_failure remote-hash 'published asset hash mismatch: Detach.dmg' run_workflow
  unset FAKE_PUBLISH_CORRUPT
  [ -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-published" ]
  [ ! -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-verified" ]
}

run_test_mode_rejects_unproven_fixture_case() {
  setup_fixture test-mode-rejects-unproven-fixture
  export DETACH_RELEASE_TEST_FIXTURE_ROOT=
  expect_failure test-mode-rejects-unproven-fixture \
    'test-mode push and publication require an absolute hermetic fixture root' \
    run_workflow
  [ -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-prepared" ]
  [ ! -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-pushed" ]
  [ ! -f "$RELEASE_EXISTS" ]
  [ -z "$(git -C "$REPO" ls-remote origin "refs/tags/$TARGET_TAG")" ]
  [ -z "$(git -C "$REPO" ls-remote origin "refs/heads/detach-release/$TARGET_TAG")" ]
  ! grep -q '^publish$' "$ACTION_LOG"
}

run_unexpected_remote_asset_case() {
  setup_fixture unexpected-remote-asset
  expect_failure unexpected-remote-asset-prep \
    'injected safe failure after published' run_workflow published
  printf '%s\n' extra >"$REMOTE_ASSETS/unexpected-notes.txt"
  expect_failure unexpected-remote-asset \
    'published release has unexpected asset: unexpected-notes.txt' \
    run_workflow
  [ -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-published" ]
  [ ! -f "$REPO/app/build/release-workflow/$TARGET_VERSION/stage-verified" ]
}

run_post_push_main_rejection_case() {
  setup_fixture post-push-main
  expect_failure post-push-source 'injected safe failure after pushed' \
    run_workflow pushed
  mkdir -p "$REPO/app/Sources/DetachKit"
  printf '%s\n' 'product change' >"$REPO/app/Sources/DetachKit/TerminalLauncher.swift"
  git -C "$REPO" add app/Sources/DetachKit/TerminalLauncher.swift
  git -C "$REPO" commit -qm 'advance product source after tag'
  git -C "$REPO" push -q origin main
  expect_failure post-push-main \
    'main advanced after the release with disallowed changes' run_workflow
  [ ! -f "$RELEASE_EXISTS" ]
}

# Each lane owns a separate repository below TMP_ROOT. Admit a bounded set of
# lanes so independent Git and fake-publication work do not saturate the disk.
# Clone one immutable APFS fixture instead of rebuilding the same Git history
# and fake tools in every lane.
setup_fixture fixture-template
FIXTURE_TEMPLATE="$FIXTURE"
release_case_limit=5
release_case_pids=()
release_case_names=()
release_case_status=0
release_cases=(
  run_resume_case
  run_timing_override_case
  run_unexpected_remote_asset_case
  run_remote_hash_case
  run_hardware_rejection_case
  run_invalid_resume_artifact_credentials_case
  run_post_push_main_rejection_case
  run_test_mode_rejects_unproven_fixture_case
  run_timing_override_confirmation_case
  run_timing_override_invalid_case
  run_dirty_preflight_rejection_case
  run_stale_build_preflight_rejection_case
  run_diverged_preflight_rejection_case
  run_duplicate_tag_preflight_rejection_case
  run_duplicate_release_preflight_rejection_case
)

wait_for_release_case_slot() {
  local index pid
  while :; do
    for index in "${!release_case_pids[@]}"; do
      pid="${release_case_pids[$index]}"
      if kill -0 "$pid" 2>/dev/null; then
        continue
      fi
      if ! wait "$pid"; then
        printf 'release workflow lane failed: %s\n' \
          "${release_case_names[$index]}" >&2
        release_case_status=1
      fi
      unset 'release_case_pids[index]' 'release_case_names[index]'
      if [ "${#release_case_pids[@]}" -gt 0 ]; then
        release_case_pids=("${release_case_pids[@]}")
        release_case_names=("${release_case_names[@]}")
      fi
      return
    done
    sleep 0.05
  done
}

for release_case in "${release_cases[@]}"; do
  while [ "${#release_case_pids[@]}" -ge "$release_case_limit" ]; do
    wait_for_release_case_slot
  done
  (
    release_case_started="$SECONDS"
    trap 'release_case_status=$?; printf "%s\n" "$((SECONDS - release_case_started))" >"$TMP_ROOT/$release_case.seconds"; exit "$release_case_status"' EXIT
    "$release_case"
  ) &
  release_case_pids+=("$!")
  release_case_names+=("$release_case")
done

while [ "${#release_case_pids[@]}" -gt 0 ]; do
  wait_for_release_case_slot
done
[ "$release_case_status" -eq 0 ] || exit 1
for release_case in "${release_cases[@]}"; do
  printf 'release-workflow: %s completed in %ss\n' \
    "$release_case" "$(<"$TMP_ROOT/$release_case.seconds")"
done

"$ROOT/scripts/quality-scenarios" event pass SC-RELEASE-WORKFLOW
printf 'Detach release workflow tests passed\n'
