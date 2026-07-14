#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP="${DETACH_APP_PATH:-$APP_ROOT/build/Detach.app}"
OUTPUT="${DETACH_DMG_PATH:-$APP_ROOT/build/Detach.dmg}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:--}"
STAGING=""

cleanup() {
  [ -z "$STAGING" ] || rm -rf "$STAGING"
}
trap cleanup EXIT

[ -d "$APP" ] || {
  printf 'App bundle not found: %s\n' "$APP" >&2
  exit 1
}

STAGING="$(mktemp -d "$APP_ROOT/build/dmg-root.XXXXXX")"
ditto "$APP" "$STAGING/Detach.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$OUTPUT"
hdiutil create -volname Detach -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT"
rm -rf "$STAGING"
STAGING=""

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUTPUT"
  codesign --verify --verbose=2 "$OUTPUT"
fi
hdiutil verify "$OUTPUT"

(
  cd -P "$(dirname "$OUTPUT")"
  shasum -a 256 "$(basename "$OUTPUT")" >"$(basename "$OUTPUT").sha256"
)
printf 'Built %s\n' "$OUTPUT"
