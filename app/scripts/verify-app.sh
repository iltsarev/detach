#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
APP="${DETACH_APP_PATH:-$APP_ROOT/build/Detach.app}"
PAYLOAD="$APP/Contents/Resources/DetachCLI"
INFO="$APP/Contents/Info.plist"
AGENT="$APP/Contents/Library/LaunchAgents/dev.tsarev.detach.watchdog.plist"
MIGRATION_AGENT="$APP/Contents/Library/LaunchAgents/dev.tsarev.codex-detached-watchdog.plist"
EXPECTED_VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
SPARKLE_VERSION="${DETACH_SPARKLE_VERSION:-2.9.4}"
EXPECTED_APP_APPLE_EVENTS_DESCRIPTION="Detach управляет опциональным режимом keep-awake через Amphetamine."
EXPECTED_WATCHDOG_APPLE_EVENTS_DESCRIPTION="Detach manages optional keep-awake automation for detached sessions."
REQUIRE_SPARKLE_CONFIG="${DETACH_REQUIRE_SPARKLE_CONFIG:-0}"
VERIFY_PRODUCTION="${DETACH_VERIFY_PRODUCTION:-0}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK_VERSION_ROOT="$FRAMEWORK/Versions/B"
ENTITLEMENTS_DIR=""

cleanup() {
  [ -z "$ENTITLEMENTS_DIR" ] || rm -rf "$ENTITLEMENTS_DIR"
}
trap cleanup EXIT

[ -d "$APP" ] || { printf 'Missing app bundle: %s\n' "$APP" >&2; exit 1; }
[[ "$REQUIRE_SPARKLE_CONFIG" = 0 || "$REQUIRE_SPARKLE_CONFIG" = 1 ]] || {
  printf 'DETACH_REQUIRE_SPARKLE_CONFIG must be 0 or 1\n' >&2; exit 1;
}
[[ "$VERIFY_PRODUCTION" = 0 || "$VERIFY_PRODUCTION" = 1 ]] || {
  printf 'DETACH_VERIFY_PRODUCTION must be 0 or 1\n' >&2; exit 1;
}
plutil -lint "$INFO" "$AGENT" "$MIGRATION_AGENT" >/dev/null
[ "$(plutil -extract NSAppleEventsUsageDescription raw -o - "$INFO")" = \
  "$EXPECTED_APP_APPLE_EVENTS_DESCRIPTION" ] || {
  printf 'App Info.plist is missing the expected Amphetamine Apple Events description\n' >&2
  exit 1
}
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

[ -d "$FRAMEWORK_VERSION_ROOT" ] || {
  printf 'Missing embedded Sparkle.framework 2.x layout\n' >&2
  exit 1
}
for link in Versions/Current Sparkle Resources Autoupdate Updater.app XPCServices; do
  [ -L "$FRAMEWORK/$link" ] || {
    printf 'Sparkle framework symlink was not preserved: %s\n' "$link" >&2
    exit 1
  }
done
[ "$(readlink "$FRAMEWORK/Versions/Current")" = B ] || {
  printf 'Unexpected Sparkle framework current version\n' >&2
  exit 1
}
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$FRAMEWORK/Resources/Info.plist")" = "$SPARKLE_VERSION" ] || {
  printf 'Unexpected Sparkle framework version\n' >&2
  exit 1
}

SPARKLE_FEED_URL="$(plutil -extract SUFeedURL raw -o - "$INFO" 2>/dev/null || true)"
SPARKLE_PUBLIC_ED_KEY="$(plutil -extract SUPublicEDKey raw -o - "$INFO" 2>/dev/null || true)"
DOWNLOAD_URL="$(plutil -extract DetachDownloadURL raw -o - "$INFO" 2>/dev/null || true)"
if [ -n "$SPARKLE_FEED_URL" ] || [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
  [[ "$SPARKLE_FEED_URL" =~ ^https://[^[:space:]]+$ ]] || {
    printf 'SUFeedURL must be HTTPS\n' >&2
    exit 1
  }
  [[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    printf 'SUPublicEDKey is not a base64 Ed25519 public key\n' >&2
    exit 1
  }
elif [ "$REQUIRE_SPARKLE_CONFIG" = 1 ]; then
  printf 'Production verification requires SUFeedURL and SUPublicEDKey\n' >&2
  exit 1
fi
if [ -n "$DOWNLOAD_URL" ]; then
  [[ "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]] || {
    printf 'DetachDownloadURL must be HTTPS\n' >&2
    exit 1
  }
elif [ "$REQUIRE_SPARKLE_CONFIG" = 1 ]; then
  printf 'Production verification requires DetachDownloadURL\n' >&2
  exit 1
fi

otool -L "$APP/Contents/MacOS/Detach" | \
  grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null || {
    printf 'Detach is not linked to the embedded Sparkle framework\n' >&2
    exit 1
  }
otool -l "$APP/Contents/MacOS/Detach" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ' | grep -Fx '@executable_path/../Frameworks' >/dev/null || {
    printf 'Detach is missing the app Frameworks rpath\n' >&2
    exit 1
  }
UNSAFE_RPATHS="$(otool -l "$APP/Contents/MacOS/Detach" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ' | sort -u | grep '^/' | grep -Fvx '/usr/lib/swift' || true)"
[ -z "$UNSAFE_RPATHS" ] || {
  printf 'Detach contains build-host rpaths:\n%s\n' "$UNSAFE_RPATHS" >&2
  exit 1
}
! otool -L "$APP/Contents/MacOS/Detach" | grep -F '/.build/' >/dev/null || {
  printf 'Detach contains an absolute SwiftPM build dependency\n' >&2
  exit 1
}

bundle_program="$(plutil -extract BundleProgram raw -o - "$AGENT")"
[ "$bundle_program" = "Contents/MacOS/DetachWatchdog" ] || {
  printf 'Unexpected watchdog BundleProgram: %s\n' "$bundle_program" >&2
  exit 1
}
[ -x "$APP/$bundle_program" ] || { printf 'BundleProgram is missing: %s\n' "$bundle_program" >&2; exit 1; }
! plutil -p "$AGENT" | grep -F '/Users/' >/dev/null
[ "$(plutil -extract Label raw -o - "$AGENT")" = "dev.tsarev.detach.watchdog" ] || {
  printf 'Unexpected bundled watchdog label\n' >&2
  exit 1
}
[ "$(plutil -extract Label raw -o - "$MIGRATION_AGENT")" = \
    "dev.tsarev.codex-detached-watchdog" ] || {
  printf 'Unexpected migration watchdog label\n' >&2
  exit 1
}
[ "$(plutil -extract BundleProgram raw -o - "$MIGRATION_AGENT")" = "$bundle_program" ] || {
  printf 'Migration watchdog points to a different helper\n' >&2
  exit 1
}
[ "$(plutil -extract Label raw -o - "$PAYLOAD/dev.tsarev.codex-detached-watchdog.plist")" = \
    "dev.tsarev.codex-detached-watchdog" ] || {
  printf 'Legacy CLI-only watchdog label changed unexpectedly\n' >&2
  exit 1
}
[ ! -e "$PAYLOAD/dev.tsarev.detach.watchdog.plist" ] || {
  printf 'Signed-service watchdog leaked into the CLI-only payload\n' >&2
  exit 1
}
for own_binary in "$APP/Contents/MacOS/Detach" "$APP/Contents/MacOS/DetachWatchdog"; do
  if LC_ALL=C grep -a -F '/Users/' "$own_binary" >/dev/null; then
    printf 'Local build path leaked into %s\n' "$(basename "$own_binary")" >&2
    exit 1
  fi
done

bundle_executable() {
  local bundle="$1"
  local executable
  executable="$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist")"
  printf '%s\n' "$bundle/Contents/MacOS/$executable"
}

INSTALLER_XPC="$FRAMEWORK_VERSION_ROOT/XPCServices/Installer.xpc"
DOWNLOADER_XPC="$FRAMEWORK_VERSION_ROOT/XPCServices/Downloader.xpc"
AUTOUPDATE="$FRAMEWORK_VERSION_ROOT/Autoupdate"
UPDATER_APP="$FRAMEWORK_VERSION_ROOT/Updater.app"
INSTALLER_BINARY="$(bundle_executable "$INSTALLER_XPC")"
DOWNLOADER_BINARY="$(bundle_executable "$DOWNLOADER_XPC")"
UPDATER_BINARY="$(bundle_executable "$UPDATER_APP")"
SPARKLE_BINARY="$FRAMEWORK_VERSION_ROOT/Sparkle"

signed_objects=(
  "$INSTALLER_XPC"
  "$DOWNLOADER_XPC"
  "$AUTOUPDATE"
  "$UPDATER_APP"
  "$FRAMEWORK"
  "$APP/Contents/MacOS/DetachWatchdog"
  "$APP"
)
for signed_object in "${signed_objects[@]}"; do
  codesign --verify --strict --verbose=2 "$signed_object"
  signature="$(codesign -d --verbose=4 "$signed_object" 2>&1)"
  grep -F 'runtime)' <<<"$signature" >/dev/null || {
    printf 'Signed code is missing Hardened Runtime: %s\n' "$signed_object" >&2
    exit 1
  }
  if [ "$VERIFY_PRODUCTION" = 1 ]; then
    grep -F 'Authority=Developer ID Application:' <<<"$signature" >/dev/null || {
      printf 'Production code is not signed with Developer ID Application: %s\n' "$signed_object" >&2
      exit 1
    }
  fi
done
HELPER_SIGNATURE="$(codesign -d --verbose=4 "$APP/Contents/MacOS/DetachWatchdog" 2>&1)"
APP_SIGNATURE="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -F 'Identifier=dev.tsarev.detach.watchdog' <<<"$HELPER_SIGNATURE" >/dev/null || {
  printf 'Unexpected watchdog signing identifier\n' >&2; exit 1;
}
grep -F 'Identifier=dev.tsarev.detach' <<<"$APP_SIGNATURE" >/dev/null || {
  printf 'Unexpected app signing identifier\n' >&2; exit 1;
}

ENTITLEMENTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/detach-entitlements.XXXXXX")"
for arch in $(lipo -archs "$APP/Contents/MacOS/DetachWatchdog"); do
  otool -arch "$arch" -l "$APP/Contents/MacOS/DetachWatchdog" | awk '
    $1 == "sectname" && $2 == "__info_plist" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' || {
    printf 'Watchdog has no embedded Info.plist for %s\n' "$arch" >&2
    exit 1
  }
  HELPER_STRINGS="$(strings -arch "$arch" "$APP/Contents/MacOS/DetachWatchdog")"
  grep -F '<string>dev.tsarev.detach.watchdog</string>' <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Unexpected watchdog embedded bundle identifier for %s\n' "$arch" >&2
    exit 1
  }
  grep -F '<string>DetachWatchdog</string>' <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Unexpected watchdog embedded executable for %s\n' "$arch" >&2
    exit 1
  }
  grep -F '<key>NSAppleEventsUsageDescription</key>' <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Watchdog embedded Info.plist is missing NSAppleEventsUsageDescription for %s\n' \
      "$arch" >&2
    exit 1
  }
  grep -F "<string>$EXPECTED_WATCHDOG_APPLE_EVENTS_DESCRIPTION</string>" \
    <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Watchdog embedded Apple Events usage description is missing or unexpected for %s\n' \
      "$arch" >&2
    exit 1
  }
  grep -F "<string>$EXPECTED_VERSION</string>" <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Watchdog embedded version mismatch for %s\n' "$arch" >&2
    exit 1
  }
  grep -F "<string>$INFO_BUILD</string>" <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Watchdog embedded build mismatch for %s\n' "$arch" >&2
    exit 1
  }
done
codesign -d --entitlements "$ENTITLEMENTS_DIR/app.plist" --xml "$APP" >/dev/null 2>&1
codesign -d --entitlements "$ENTITLEMENTS_DIR/helper.plist" --xml \
  "$APP/Contents/MacOS/DetachWatchdog" >/dev/null 2>&1
[ "$(plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - \
  "$ENTITLEMENTS_DIR/app.plist")" = true ] || {
  printf 'App is missing the Automation Apple Events entitlement for Amphetamine cleanup\n' >&2
  exit 1
}
[ "$(plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - \
  "$ENTITLEMENTS_DIR/helper.plist")" = true ] || {
  printf 'Watchdog is missing the Automation Apple Events entitlement\n' >&2
  exit 1
}

if grep -F 'Signature=adhoc' <<<"$APP_SIGNATURE" >/dev/null; then
  [ "$VERIFY_PRODUCTION" = 0 ] || {
    printf 'Production app has an ad-hoc signature\n' >&2
    exit 1
  }
  [ "$(plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw -o - \
    "$ENTITLEMENTS_DIR/app.plist")" = true ] || {
      printf 'Ad-hoc app is missing the development library-validation exception\n' >&2
      exit 1
    }
else
  if plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw -o - \
    "$ENTITLEMENTS_DIR/app.plist" >/dev/null 2>&1; then
    printf 'Non-ad-hoc app contains the development library-validation exception\n' >&2
    exit 1
  fi
fi

if [ "$VERIFY_PRODUCTION" = 1 ]; then
  APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$APP_SIGNATURE")"
  [ -n "$APP_TEAM" ] || {
    printf 'Production app signature has no TeamIdentifier\n' >&2
    exit 1
  }
  for signed_object in "${signed_objects[@]}"; do
    object_signature="$(codesign -d --verbose=4 "$signed_object" 2>&1)"
    [ "$(sed -n 's/^TeamIdentifier=//p' <<<"$object_signature")" = "$APP_TEAM" ] || {
      printf 'Nested code TeamIdentifier mismatch: %s\n' "$signed_object" >&2
      exit 1
    }
  done
fi

if [ "${DETACH_VERIFY_UNIVERSAL:-1}" = 1 ]; then
  universal_binaries=(
    "$APP/Contents/MacOS/Detach"
    "$APP/Contents/MacOS/DetachWatchdog"
    "$SPARKLE_BINARY"
    "$AUTOUPDATE"
    "$UPDATER_BINARY"
    "$INSTALLER_BINARY"
    "$DOWNLOADER_BINARY"
  )
  for universal_binary in "${universal_binaries[@]}"; do
    lipo "$universal_binary" -verify_arch arm64 x86_64
  done
fi

printf 'Verified %s\n' "$APP"
