#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-release-preflight-test.XXXXXX")"
TEST_REPO="$TMP_ROOT/repo"
TEST_APP="$TEST_REPO/app"
FAKE_BIN="$TMP_ROOT/bin"
SPARKLE_BIN="$TEST_APP/.build/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_APP/scripts" "$SPARKLE_BIN" "$FAKE_BIN" "$TMP_ROOT/home"
install -m 0755 "$ROOT/app/scripts/release.sh" "$TEST_APP/scripts/release.sh"
install -m 0755 /usr/bin/true "$SPARKLE_BIN/generate_appcast"
printf '%s\n' 1.2.3 >"$TEST_REPO/VERSION"

cat >"$SPARKLE_BIN/generate_keys" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >"${FAKE_GENERATE_KEYS_LOG:?}"
printf '%s\n' "${FAKE_PUBLIC_KEY:?}"
SH

cat >"$FAKE_BIN/swift" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >"${FAKE_SWIFT_LOG:?}"
exit 86
SH

cat >"$FAKE_BIN/security" <<'SH'
#!/bin/bash
exit 0
SH

chmod 0755 "$SPARKLE_BIN/generate_keys" "$FAKE_BIN/swift" "$FAKE_BIN/security"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.name 'Detach Tests'
git -C "$TEST_REPO" config user.email 'detach-tests@example.invalid'
git -C "$TEST_REPO" add .
git -C "$TEST_REPO" commit -qm 'release preflight fixture'
git -C "$TEST_REPO" tag v1.2.3

release_stdout="$TMP_ROOT/release.stdout"
release_stderr="$TMP_ROOT/release.stderr"
if (
  cd -P "$TMP_ROOT"
  env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$TMP_ROOT/home" \
    CLANG_MODULE_CACHE_PATH="$TMP_ROOT/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$TMP_ROOT/module-cache" \
    FAKE_GENERATE_KEYS_LOG="$TMP_ROOT/generate-keys.log" \
    FAKE_PUBLIC_KEY="$PUBLIC_KEY" \
    FAKE_SWIFT_LOG="$TMP_ROOT/swift.log" \
    DETACH_CODESIGN_IDENTITY='Developer ID Application: Detach Tests' \
    DETACH_NOTARY_PROFILE=detach-tests \
    DETACH_BUILD_VERSION=1 \
    DETACH_SPARKLE_FEED_URL=https://example.invalid/appcast.xml \
    DETACH_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
    DETACH_SPARKLE_DOWNLOAD_URL_PREFIX=https://example.invalid/releases/v1.2.3/ \
    DETACH_DOWNLOAD_URL=https://example.invalid/releases \
    DETACH_INITIAL_RELEASE=1 \
    "$TEST_APP/scripts/release.sh"
) >"$release_stdout" 2>"$release_stderr"; then
  printf 'release preflight unexpectedly completed successfully\n' >&2
  exit 1
fi

# The fake signing identity is intentionally unavailable. Reaching this check
# proves the local Sparkle tools and matching public key passed preflight.
grep -F 'Developer ID signing identity is not installed or valid' \
  "$release_stderr" >/dev/null || {
  printf 'release stopped before the signing-identity preflight\n' >&2
  sed -n '1,20p' "$release_stderr" >&2
  exit 1
}
[ ! -e "$TMP_ROOT/swift.log" ] || {
  printf 'release unexpectedly resolved SwiftPM despite an existing Sparkle tool\n' >&2
  exit 1
}
grep -Fx -- '-p --account dev.tsarev.detach' "$TMP_ROOT/generate-keys.log" >/dev/null || {
  printf 'release used an unexpected default Sparkle key account\n' >&2
  exit 1
}

printf 'Detach release preflight tests passed\n'
