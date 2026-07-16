#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APPCAST_VERIFIER="$ROOT/app/scripts/verify-appcast.sh"
MAKE_DMG="$ROOT/app/scripts/make-dmg.sh"
BUNDLE_MODE_POLICY="$ROOT/app/scripts/bundle-modes.sh"
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
install -m 0755 "$MAKE_DMG" "$TEST_APP/scripts/make-dmg.sh"
install -m 0644 "$BUNDLE_MODE_POLICY" "$TEST_APP/scripts/bundle-modes.sh"
install -m 0755 /usr/bin/true "$SPARKLE_BIN/generate_appcast"
printf '%s\n' 1.2.3 >"$TEST_REPO/VERSION"

[ -x "$APPCAST_VERIFIER" ]
bash -n "$APPCAST_VERIFIER" "$MAKE_DMG" "$BUNDLE_MODE_POLICY"

cat >"$TMP_ROOT/appcast-valid.xml" <<'XML'
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item>
    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
  </item></channel>
</rss>
XML
"$APPCAST_VERIFIER" "$TMP_ROOT/appcast-valid.xml"

cat >"$TMP_ROOT/appcast-missing.xml" <<'XML'
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item/></channel>
</rss>
XML
if "$APPCAST_VERIFIER" "$TMP_ROOT/appcast-missing.xml" \
    >"$TMP_ROOT/appcast-missing.stdout" 2>"$TMP_ROOT/appcast-missing.stderr"; then
  printf 'appcast verifier accepted a missing hardware requirement\n' >&2
  exit 1
fi
grep -F 'exactly one sparkle:hardwareRequirements element' \
  "$TMP_ROOT/appcast-missing.stderr" >/dev/null

cat >"$TMP_ROOT/appcast-duplicate.xml" <<'XML'
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><item>
    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
  </item></channel>
</rss>
XML
if "$APPCAST_VERIFIER" "$TMP_ROOT/appcast-duplicate.xml" \
    >"$TMP_ROOT/appcast-duplicate.stdout" 2>"$TMP_ROOT/appcast-duplicate.stderr"; then
  printf 'appcast verifier accepted duplicate hardware requirements\n' >&2
  exit 1
fi
grep -F 'exactly one sparkle:hardwareRequirements element' \
  "$TMP_ROOT/appcast-duplicate.stderr" >/dev/null

sed 's/>arm64</>x86_64</' "$TMP_ROOT/appcast-valid.xml" \
  >"$TMP_ROOT/appcast-wrong.xml"
if "$APPCAST_VERIFIER" "$TMP_ROOT/appcast-wrong.xml" \
    >"$TMP_ROOT/appcast-wrong.stdout" 2>"$TMP_ROOT/appcast-wrong.stderr"; then
  printf 'appcast verifier accepted a non-arm64 hardware requirement\n' >&2
  exit 1
fi
grep -F 'hardware requirement must be exactly arm64' \
  "$TMP_ROOT/appcast-wrong.stderr" >/dev/null

sed 's/sparkle:hardwareRequirements/hardwareRequirements/g' \
  "$TMP_ROOT/appcast-valid.xml" >"$TMP_ROOT/appcast-wrong-namespace.xml"
if "$APPCAST_VERIFIER" "$TMP_ROOT/appcast-wrong-namespace.xml" \
    >"$TMP_ROOT/appcast-wrong-namespace.stdout" \
    2>"$TMP_ROOT/appcast-wrong-namespace.stderr"; then
  printf 'appcast verifier accepted an unnamespaced hardware requirement\n' >&2
  exit 1
fi
grep -F 'exactly one sparkle:hardwareRequirements element' \
  "$TMP_ROOT/appcast-wrong-namespace.stderr" >/dev/null

grep -F 'DETACH_BUILD_ARCHS=arm64 DETACH_BUILD_VERSION="$BUILD_VERSION"' \
  "$TEST_APP/scripts/release.sh" >/dev/null || {
  printf 'release must build an Apple Silicon-only application\n' >&2
  exit 1
}
grep -F 'DEFAULT_SPARKLE_GENERATE_APPCAST="$APP_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"' \
  "$TEST_APP/scripts/release.sh" >/dev/null || {
  printf 'release must resolve the pinned Sparkle appcast tool deterministically\n' >&2
  exit 1
}
grep -F '"$APPCAST_VERIFIER" "$APPCAST"' \
  "$TEST_APP/scripts/release.sh" >/dev/null || {
  printf 'release must verify arm64 appcast hardware requirements\n' >&2
  exit 1
}
grep -F 'DETACH_DMG_VERIFY_PRODUCTION=1' \
  "$TEST_APP/scripts/release.sh" >/dev/null || {
  printf 'release must enable production verification in the DMG builder\n' >&2
  exit 1
}
for public_mode_contract in \
  'chmod 0644 "$UPDATE_ZIP"' \
  'chmod 0644 "$DMG"' \
  'chmod 0644 "$(basename "$update_asset")"' \
  'chmod 0644 "$RELEASE_MANIFEST"'; do
  grep -F "$public_mode_contract" "$TEST_APP/scripts/release.sh" >/dev/null || {
    printf 'release is missing public artifact mode normalization: %s\n' \
      "$public_mode_contract" >&2
    exit 1
  }
done

staple_line="$(grep -nF 'xcrun stapler staple "$APP"' \
  "$TEST_APP/scripts/release.sh" | cut -d: -f1)"
staple_umask_line="$(grep -nF 'umask 022' \
  "$TEST_APP/scripts/release.sh" | tail -1 | cut -d: -f1)"
validate_modes_line="$(grep -nF 'verify_detach_bundle_modes "$APP"' \
  "$TEST_APP/scripts/release.sh" | cut -d: -f1)"
stapler_validate_line="$(grep -nF 'xcrun stapler validate "$APP"' \
  "$TEST_APP/scripts/release.sh" | cut -d: -f1)"
[ "$staple_umask_line" -lt "$staple_line" ] && \
  [ "$staple_line" -lt "$validate_modes_line" ] && \
  [ "$validate_modes_line" -lt "$stapler_validate_line" ] || {
  printf 'release must create the stapled ticket under umask 022 and verify its modes\n' >&2
  exit 1
}
grep -F 'codesign --verify --strict --verbose=2 "$APP"' \
  "$TEST_APP/scripts/release.sh" >/dev/null || {
  printf 'release must revalidate the app signature after mode normalization\n' >&2
  exit 1
}

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

mkdir -p "$TEST_APP/build/Detach.app"
cat >"$TEST_APP/scripts/verify-app.sh" <<'SH'
#!/bin/bash
printf '%s|%s|%s\n' \
  "${DETACH_APP_PATH:-}" \
  "${DETACH_VERIFY_PRODUCTION:-}" \
  "${DETACH_REQUIRE_SPARKLE_CONFIG:-}" \
  >"${FAKE_VERIFY_APP_LOG:?}"
exit 73
SH
chmod 0755 "$TEST_APP/scripts/verify-app.sh"
DMG_VERIFY_EXIT=0
if FAKE_VERIFY_APP_LOG="$TMP_ROOT/verify-app.log" \
    DETACH_APP_PATH="$TEST_APP/build/Detach.app" \
    DETACH_DMG_VERIFY_PRODUCTION=1 \
    DETACH_CODESIGN_IDENTITY=- \
    "$TEST_APP/scripts/make-dmg.sh" \
    >"$TMP_ROOT/make-dmg.stdout" 2>"$TMP_ROOT/make-dmg.stderr"; then
  printf 'production DMG build unexpectedly ignored verifier failure\n' >&2
  exit 1
else
  DMG_VERIFY_EXIT=$?
fi
[ "$DMG_VERIFY_EXIT" = 73 ] || {
  printf 'production DMG build returned %s instead of verifier status 73\n' \
    "$DMG_VERIFY_EXIT" >&2
  exit 1
}
grep -Fx "$TEST_APP/build/Detach.app|1|1" "$TMP_ROOT/verify-app.log" >/dev/null

cat >"$FAKE_BIN/hdiutil" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"${FAKE_HDIUTIL_LOG:?}"
case "${1:-}" in
  create)
    output=""
    source_folder=""
    previous=""
    for argument in "$@"; do
      if [ "$previous" = -srcfolder ]; then
        source_folder="$argument"
      fi
      output="$argument"
      previous="$argument"
    done
    [ -n "$source_folder" ]
    printf 'source-mode %s\n' "$(stat -f '%Lp' "$source_folder")" \
      >>"${FAKE_HDIUTIL_LOG:?}"
    printf 'fake dmg\n' >"$output"
    chmod 0600 "$output"
    ;;
  verify) ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$FAKE_BIN/hdiutil"
HOSTILE_DMG="$TEST_APP/build/Hostile.dmg"
(
  umask 077
  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_HDIUTIL_LOG="$TMP_ROOT/hdiutil.log" \
    DETACH_APP_PATH="$TEST_APP/build/Detach.app" \
    DETACH_DMG_PATH="$HOSTILE_DMG" \
    DETACH_CODESIGN_IDENTITY=- \
    "$TEST_APP/scripts/make-dmg.sh"
) >"$TMP_ROOT/hostile-dmg.stdout" 2>"$TMP_ROOT/hostile-dmg.stderr"
[ "$(stat -f '%Lp' "$HOSTILE_DMG")" = 644 ]
[ "$(stat -f '%Lp' "$HOSTILE_DMG.sha256")" = 644 ]
grep -Fx 'source-mode 755' "$TMP_ROOT/hdiutil.log" >/dev/null || {
  printf 'DMG root does not have a portable owner/mode contract\n' >&2
  exit 1
}
! grep -E '(^| )-(uid|gid|mode)( |$)' "$TMP_ROOT/hdiutil.log" >/dev/null
(
  cd -P "$(dirname "$HOSTILE_DMG")"
  shasum -a 256 -c "$(basename "$HOSTILE_DMG").sha256" >/dev/null
)

printf 'Detach release preflight tests passed\n'
