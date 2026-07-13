#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${DETACH_NOTARY_PROFILE:-}"
BUILD_VERSION="${DETACH_BUILD_VERSION:-}"
APP="$APP_ROOT/build/Detach.app"
DMG="$APP_ROOT/build/Detach-$VERSION.dmg"
ZIP="$APP_ROOT/build/Detach-$VERSION-notarization.zip"

[ -n "$IDENTITY" ] || {
  printf 'DETACH_CODESIGN_IDENTITY is required for a release\n' >&2
  exit 1
}
case "$IDENTITY" in
  'Developer ID Application: '*) ;;
  *)
    printf 'DETACH_CODESIGN_IDENTITY must name a Developer ID Application identity\n' >&2
    exit 1
    ;;
esac
[ -n "$NOTARY_PROFILE" ] || {
  printf 'DETACH_NOTARY_PROFILE is required for a release\n' >&2
  exit 1
}
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] || {
  printf 'DETACH_BUILD_VERSION is required and must be a positive monotonic integer\n' >&2
  exit 1
}

DETACH_BUILD_ARCHS=universal DETACH_BUILD_VERSION="$BUILD_VERSION" \
  DETACH_CODESIGN_IDENTITY="$IDENTITY" \
  "$APP_ROOT/scripts/make-app.sh"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

DETACH_CODESIGN_IDENTITY="$IDENTITY" DETACH_APP_PATH="$APP" \
  DETACH_DMG_PATH="$DMG" "$APP_ROOT/scripts/make-dmg.sh"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(
  cd -P "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256"
)

rm -f "$ZIP"
printf 'Release artifact ready: %s\n' "$DMG"
