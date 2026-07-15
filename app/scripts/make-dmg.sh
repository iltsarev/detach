#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP="${DETACH_APP_PATH:-$APP_ROOT/build/Detach.app}"
OUTPUT="${DETACH_DMG_PATH:-$APP_ROOT/build/Detach.dmg}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:--}"
VERIFY_PRODUCTION="${DETACH_DMG_VERIFY_PRODUCTION:-0}"
VERIFY_APP="$APP_ROOT/scripts/verify-app.sh"
STAGING=""

cleanup() {
  [ -z "$STAGING" ] || rm -rf "$STAGING"
}
trap cleanup EXIT

[ -d "$APP" ] || {
  printf 'App bundle not found: %s\n' "$APP" >&2
  exit 1
}
[[ "$VERIFY_PRODUCTION" = 0 || "$VERIFY_PRODUCTION" = 1 ]] || {
  printf 'DETACH_DMG_VERIFY_PRODUCTION must be 0 or 1\n' >&2
  exit 1
}
if [ "$VERIFY_PRODUCTION" = 1 ]; then
  [ -x "$VERIFY_APP" ] || {
    printf 'App verifier not found: %s\n' "$VERIFY_APP" >&2
    exit 1
  }
  DETACH_APP_PATH="$APP" \
    DETACH_REQUIRE_SPARKLE_CONFIG=1 \
    DETACH_VERIFY_PRODUCTION=1 \
    "$VERIFY_APP"
fi

STAGING="$(mktemp -d "$APP_ROOT/build/dmg-root.XXXXXX")"
# APFS-backed images ignore hdiutil's -uid/-gid/-mode creation options. Set
# the source-folder root itself so an owners-enabled mount remains traversable
# by users other than the account that built the image.
chmod 0755 "$STAGING"
ditto "$APP" "$STAGING/Detach.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$OUTPUT"
hdiutil create -volname Detach -srcfolder "$STAGING" \
  -ov -format UDZO "$OUTPUT"
rm -rf "$STAGING"
STAGING=""

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUTPUT"
  codesign --verify --verbose=2 "$OUTPUT"
fi
hdiutil verify "$OUTPUT"
chmod 0644 "$OUTPUT"

(
  cd -P "$(dirname "$OUTPUT")"
  shasum -a 256 "$(basename "$OUTPUT")" >"$(basename "$OUTPUT").sha256"
  chmod 0644 "$(basename "$OUTPUT").sha256"
)
printf 'Built %s\n' "$OUTPUT"
