#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
APP="${DETACH_APP_PATH:-$APP_ROOT/build/Detach.app}"
PAYLOAD="$APP/Contents/Resources/DetachCLI"
INFO="$APP/Contents/Info.plist"
AGENT="$APP/Contents/Library/LaunchAgents/dev.tsarev.codex-detached-watchdog.plist"
EXPECTED_VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
ENTITLEMENTS_DIR=""

cleanup() {
  [ -z "$ENTITLEMENTS_DIR" ] || rm -rf "$ENTITLEMENTS_DIR"
}
trap cleanup EXIT

[ -d "$APP" ] || { printf 'Missing app bundle: %s\n' "$APP" >&2; exit 1; }
plutil -lint "$INFO" "$AGENT" >/dev/null
# `plutil -lint` only accepts property lists even though the other plutil
# operations support JSON. Parse the payload manifest explicitly as JSON.
plutil -p "$PAYLOAD/payload.json" >/dev/null
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")" = "$EXPECTED_VERSION" ]
INFO_BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO")"
[[ "$INFO_BUILD" =~ ^[1-9][0-9]*$ ]]
[ "$(<"$PAYLOAD/VERSION")" = "$EXPECTED_VERSION" ]
[ "$(<"$PAYLOAD/BUILD")" = "$INFO_BUILD" ]
[ "$(plutil -extract version raw -o - "$PAYLOAD/payload.json")" = "$EXPECTED_VERSION" ]
[ "$(plutil -extract build raw -o - "$PAYLOAD/payload.json")" = "$INFO_BUILD" ]
[ "$("$PAYLOAD/detach" __version)" = "$EXPECTED_VERSION" ]
for script in "$PAYLOAD/detach" "$PAYLOAD/detach-core" "$PAYLOAD/detach-install"; do
  bash -n "$script"
done

for name in detach detach-core detach-install; do
  key="${name//-/_}"
  expected="$(plutil -extract "files.$key" raw -o - "$PAYLOAD/payload.json")"
  actual="$(shasum -a 256 "$PAYLOAD/$name" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { printf 'Payload hash mismatch: %s\n' "$name" >&2; exit 1; }
done
DETACH_HASH="$(shasum -a 256 "$PAYLOAD/detach" | awk '{print $1}')"
CORE_HASH="$(shasum -a 256 "$PAYLOAD/detach-core" | awk '{print $1}')"
INSTALLER_HASH="$(shasum -a 256 "$PAYLOAD/detach-install" | awk '{print $1}')"
CALCULATED_PAYLOAD_ID="$(printf '%s\n%s\n%s\n%s\n%s\n' \
  "$EXPECTED_VERSION" "$INFO_BUILD" "$DETACH_HASH" "$CORE_HASH" "$INSTALLER_HASH" | \
  shasum -a 256 | awk '{print $1}')"
[ "$(<"$PAYLOAD/PAYLOAD_ID")" = "$CALCULATED_PAYLOAD_ID" ]
[ "$(plutil -extract payload_id raw -o - "$PAYLOAD/payload.json")" = "$CALCULATED_PAYLOAD_ID" ]

bundle_program="$(plutil -extract BundleProgram raw -o - "$AGENT")"
[ -x "$APP/$bundle_program" ] || { printf 'BundleProgram is missing: %s\n' "$bundle_program" >&2; exit 1; }
! plutil -p "$AGENT" | grep -F '/Users/' >/dev/null
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/DetachWatchdog"
codesign --verify --strict --verbose=2 "$APP"
HELPER_SIGNATURE="$(codesign -d --verbose=4 "$APP/Contents/MacOS/DetachWatchdog" 2>&1)"
APP_SIGNATURE="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -F 'Identifier=dev.tsarev.detach.watchdog' <<<"$HELPER_SIGNATURE" >/dev/null || {
  printf 'Unexpected watchdog signing identifier\n' >&2; exit 1;
}
grep -F 'Identifier=dev.tsarev.detach' <<<"$APP_SIGNATURE" >/dev/null || {
  printf 'Unexpected app signing identifier\n' >&2; exit 1;
}
grep -F 'runtime)' <<<"$HELPER_SIGNATURE" >/dev/null || {
  printf 'Watchdog is missing Hardened Runtime\n' >&2; exit 1;
}
grep -F 'runtime)' <<<"$APP_SIGNATURE" >/dev/null || {
  printf 'App is missing Hardened Runtime\n' >&2; exit 1;
}

ENTITLEMENTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/detach-entitlements.XXXXXX")"
codesign -d --entitlements "$ENTITLEMENTS_DIR/app.plist" --xml "$APP" >/dev/null 2>&1
codesign -d --entitlements "$ENTITLEMENTS_DIR/helper.plist" --xml \
  "$APP/Contents/MacOS/DetachWatchdog" >/dev/null 2>&1
for entitlements in "$ENTITLEMENTS_DIR/app.plist" "$ENTITLEMENTS_DIR/helper.plist"; do
  [ "$(plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - "$entitlements")" = true ] || {
    printf 'Missing Automation Apple Events entitlement: %s\n' "$entitlements" >&2
    exit 1
  }
done

if [ "${DETACH_VERIFY_UNIVERSAL:-1}" = 1 ]; then
  lipo "$APP/Contents/MacOS/Detach" -verify_arch arm64 x86_64
  lipo "$APP/Contents/MacOS/DetachWatchdog" -verify_arch arm64 x86_64
fi

printf 'Verified %s\n' "$APP"
