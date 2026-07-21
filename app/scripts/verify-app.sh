#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
APP="${DETACH_APP_PATH:-$APP_ROOT/build/Detach.app}"
PAYLOAD="$APP/Contents/Resources/DetachCLI"
INFO="$APP/Contents/Info.plist"
AGENT="$APP/Contents/Library/LaunchAgents/dev.tsarev.detach.power-watchdog.plist"
POWER_DAEMON="$APP/Contents/Library/LaunchDaemons/dev.tsarev.detach.power-helper.plist"
EXPECTED_VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
EXPECTED_MINIMUM_SYSTEM_VERSION="26.0"
SPARKLE_VERSION="${DETACH_SPARKLE_VERSION:-2.9.4}"
SPARKLE_LICENSE_SOURCE="$APP_ROOT/Resources/ThirdParty/Sparkle/LICENSE.txt"
SPARKLE_LICENSE_SHA256="389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
REQUIRE_SPARKLE_CONFIG="${DETACH_REQUIRE_SPARKLE_CONFIG:-0}"
VERIFY_PRODUCTION="${DETACH_VERIFY_PRODUCTION:-0}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK_VERSION_ROOT="$FRAMEWORK/Versions/B"
TMUX_BUILDER="$REPO_ROOT/scripts/build-tmux.sh"
TMUX_BINARY="$APP/Contents/MacOS/tmux"
STATE_BINARY="$APP/Contents/MacOS/detach-state"
POWER_BINARY="$APP/Contents/MacOS/detach-power"
POWER_HELPER_BINARY="$APP/Contents/MacOS/DetachPowerHelper"
TMUX_THIRD_PARTY="$APP/Contents/Resources/ThirdParty/tmux"
SPARKLE_LICENSE="$APP/Contents/Resources/ThirdParty/Sparkle/LICENSE.txt"
BUNDLE_MODE_POLICY="$APP_ROOT/scripts/bundle-modes.sh"
ENTITLEMENTS_DIR=""

cleanup() {
  [ -z "$ENTITLEMENTS_DIR" ] || rm -rf "$ENTITLEMENTS_DIR"
}
trap cleanup EXIT

[ -d "$APP" ] || { printf 'Missing app bundle: %s\n' "$APP" >&2; exit 1; }
[ -f "$BUNDLE_MODE_POLICY" ] || {
  printf 'App bundle mode policy is missing: %s\n' "$BUNDLE_MODE_POLICY" >&2
  exit 1
}
# shellcheck source=app/scripts/bundle-modes.sh
source "$BUNDLE_MODE_POLICY"
verify_detach_bundle_modes "$APP"
[[ "$REQUIRE_SPARKLE_CONFIG" = 0 || "$REQUIRE_SPARKLE_CONFIG" = 1 ]] || {
  printf 'DETACH_REQUIRE_SPARKLE_CONFIG must be 0 or 1\n' >&2; exit 1;
}
[[ "$VERIFY_PRODUCTION" = 0 || "$VERIFY_PRODUCTION" = 1 ]] || {
  printf 'DETACH_VERIFY_PRODUCTION must be 0 or 1\n' >&2; exit 1;
}
plutil -lint "$INFO" "$AGENT" "$POWER_DAEMON" >/dev/null
[ "$(plutil -extract CFBundleDevelopmentRegion raw -o - "$INFO")" = en ] || {
  printf 'App development localization must be English\n' >&2
  exit 1
}
for localization in en ru; do
  LOCALIZABLE="$APP/Contents/Resources/$localization.lproj/Localizable.strings"
  INFO_PLIST_STRINGS="$APP/Contents/Resources/$localization.lproj/InfoPlist.strings"
  [ -f "$LOCALIZABLE" ] && [ -f "$INFO_PLIST_STRINGS" ] || {
    printf 'Missing %s app localization\n' "$localization" >&2
    exit 1
  }
  plutil -lint "$LOCALIZABLE" "$INFO_PLIST_STRINGS" >/dev/null
done
for metadata in \
  "$INFO" \
  "$APP/Contents/Resources/en.lproj/InfoPlist.strings" \
  "$APP/Contents/Resources/ru.lproj/InfoPlist.strings"; do
  if plutil -extract NSAppleEventsUsageDescription raw -o - "$metadata" \
      >/dev/null 2>&1; then
    printf 'Obsolete Apple Events usage description remains in %s\n' "$metadata" >&2
    exit 1
  fi
done
# `plutil -lint` only accepts property lists even though the other plutil
# operations support JSON. Parse the payload manifest explicitly as JSON.
plutil -p "$PAYLOAD/payload.json" >/dev/null
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")" = "$EXPECTED_VERSION" ]
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$INFO")" = \
  "$EXPECTED_MINIMUM_SYSTEM_VERSION" ] || {
  printf 'App minimum system version must be %s\n' \
    "$EXPECTED_MINIMUM_SYSTEM_VERSION" >&2
  exit 1
}
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

for name in detach detach-core detach-install detach-state detach-power tmux; do
  key="${name//-/_}"
  expected="$(plutil -extract "files.$key" raw -o - "$PAYLOAD/payload.json")"
  actual="$(shasum -a 256 "$PAYLOAD/$name" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { printf 'Payload hash mismatch: %s\n' "$name" >&2; exit 1; }
done
DETACH_HASH="$(shasum -a 256 "$PAYLOAD/detach" | awk '{print $1}')"
CORE_HASH="$(shasum -a 256 "$PAYLOAD/detach-core" | awk '{print $1}')"
INSTALLER_HASH="$(shasum -a 256 "$PAYLOAD/detach-install" | awk '{print $1}')"
STATE_HASH="$(shasum -a 256 "$PAYLOAD/detach-state" | awk '{print $1}')"
POWER_HASH="$(shasum -a 256 "$PAYLOAD/detach-power" | awk '{print $1}')"
TMUX_HASH="$(shasum -a 256 "$PAYLOAD/tmux" | awk '{print $1}')"
CALCULATED_PAYLOAD_ID="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$EXPECTED_VERSION" "$INFO_BUILD" "$DETACH_HASH" "$CORE_HASH" "$INSTALLER_HASH" \
  "$STATE_HASH" "$POWER_HASH" "$TMUX_HASH" | \
  shasum -a 256 | awk '{print $1}')"
[ "$(<"$PAYLOAD/PAYLOAD_ID")" = "$CALCULATED_PAYLOAD_ID" ]
[ "$(plutil -extract payload_id raw -o - "$PAYLOAD/payload.json")" = "$CALCULATED_PAYLOAD_ID" ]

for runtime_spec in \
  "$STATE_BINARY:$PAYLOAD/detach-state:detach-state" \
  "$POWER_BINARY:$PAYLOAD/detach-power:detach-power" \
  "$TMUX_BINARY:$PAYLOAD/tmux:tmux"; do
  app_binary="${runtime_spec%%:*}"
  payload_and_name="${runtime_spec#*:}"
  payload_binary="${payload_and_name%%:*}"
  runtime_name="${payload_and_name#*:}"
  [ -x "$app_binary" ] || {
    printf 'Missing bundled %s executable\n' "$runtime_name" >&2
    exit 1
  }
  [ -x "$payload_binary" ] || {
    printf 'Missing bundled %s in the install payload\n' "$runtime_name" >&2
    exit 1
  }
  cmp -s "$app_binary" "$payload_binary" || {
    printf 'The app and install payload contain different %s binaries\n' \
      "$runtime_name" >&2
    exit 1
  }
done
[ -x "$POWER_HELPER_BINARY" ] || {
  printf 'Missing privileged power helper executable\n' >&2
  exit 1
}

STATE_SMOKE="$("$STATE_BINARY" emit context packaging-smoke / false)"
[ "$(plutil -extract session_name raw -o - - <<<"$STATE_SMOKE")" = \
  packaging-smoke ] || {
  printf 'detach-state smoke test failed\n' >&2
  exit 1
}
POWER_SMOKE_ARGUMENT="__detach-packaging-smoke__"
POWER_SMOKE_EXIT=0
if POWER_SMOKE_OUTPUT="$("$POWER_BINARY" "$POWER_SMOKE_ARGUMENT" 2>&1)"; then
  printf 'detach-power offline smoke unexpectedly succeeded\n' >&2
  exit 1
else
  POWER_SMOKE_EXIT=$?
fi
[ "$POWER_SMOKE_EXIT" = 2 ] || {
  printf 'detach-power offline smoke returned %s instead of usage status 2\n' \
    "$POWER_SMOKE_EXIT" >&2
  exit 1
}
grep -F 'detach-power: usage: detach-power status --json' \
  <<<"$POWER_SMOKE_OUTPUT" >/dev/null || {
  printf 'detach-power offline smoke did not return usage output\n' >&2
  exit 1
}
[ "$("$TMUX_BINARY" -V)" = "tmux 3.7b" ] || {
  printf 'Unexpected bundled tmux version\n' >&2
  exit 1
}

for third_party_file in \
  tmux-ISC.txt \
  libevent-BSD-3-Clause.txt \
  utf8proc-MIT.txt \
  provenance.json; do
  [ -f "$TMUX_THIRD_PARTY/$third_party_file" ] || {
    printf 'Missing bundled tmux attribution: %s\n' "$third_party_file" >&2
    exit 1
  }
done
[ -f "$SPARKLE_LICENSE_SOURCE" ] && [ -f "$SPARKLE_LICENSE" ] || {
  printf 'Missing pinned Sparkle license notice\n' >&2
  exit 1
}
[ "$(/usr/bin/shasum -a 256 "$SPARKLE_LICENSE_SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$SPARKLE_LICENSE_SHA256" ] || {
  printf 'Pinned Sparkle license notice does not match Sparkle %s\n' \
    "$SPARKLE_VERSION" >&2
  exit 1
}
[ "$(/usr/bin/shasum -a 256 "$SPARKLE_LICENSE" | /usr/bin/awk '{print $1}')" = \
  "$SPARKLE_LICENSE_SHA256" ] || {
  printf 'Bundled Sparkle license notice does not match Sparkle %s\n' \
    "$SPARKLE_VERSION" >&2
  exit 1
}
cmp -s "$SPARKLE_LICENSE_SOURCE" "$SPARKLE_LICENSE" || {
  printf 'Bundled Sparkle license notice does not match the pinned source\n' >&2
  exit 1
}
[ "$(stat -f '%Lp' "$SPARKLE_LICENSE")" = 644 ] || {
  printf 'Bundled Sparkle license notice must have mode 0644\n' >&2
  exit 1
}
plutil -p "$TMUX_THIRD_PARTY/provenance.json" >/dev/null
[ -x "$TMUX_BUILDER" ] || {
  printf 'Bundled tmux builder is unavailable for provenance verification\n' >&2
  exit 1
}
EXPECTED_TMUX_PROVENANCE="$("$TMUX_BUILDER" metadata --json)"
ACTUAL_TMUX_PROVENANCE="$(<"$TMUX_THIRD_PARTY/provenance.json")"
[ "$ACTUAL_TMUX_PROVENANCE" = "$EXPECTED_TMUX_PROVENANCE" ] || {
  printf 'Bundled tmux provenance does not match the pinned build inputs\n' >&2
  exit 1
}

verify_dynamic_dependencies() {
  local binary="$1"
  local allow_sparkle="${2:-0}"
  local dependency

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      '@rpath/Sparkle.framework/Versions/B/Sparkle')
        [ "$allow_sparkle" = 1 ] || {
          printf '%s unexpectedly links Sparkle\n' "$binary" >&2
          exit 1
        }
        ;;
      *)
        printf '%s has a non-system dynamic dependency: %s\n' \
          "$binary" "$dependency" >&2
        exit 1
        ;;
    esac
  done < <(otool -L "$binary" | awk '/^[[:space:]]/ { print $1 }')

  if otool -L "$binary" | awk '/^[[:space:]]/' | \
      grep -E '(/opt/homebrew|/usr/local|/Users/|/\.build/|libevent|utf8proc)' \
      >/dev/null; then
    printf '%s retained a build-host or source-library dependency\n' \
      "$binary" >&2
    exit 1
  fi
}

verify_minimum_system_version() {
  local binary="$1"
  local minimum

  minimum="$(otool -l "$binary" | awk '
      $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build_version = 1; next }
      in_build_version && $1 == "minos" && !found { print $2; found = 1 }
    ')"
  [ "$minimum" = "$EXPECTED_MINIMUM_SYSTEM_VERSION" ] || {
    printf '%s minimum system version is %s, expected %s\n' \
      "$binary" "${minimum:-missing}" "$EXPECTED_MINIMUM_SYSTEM_VERSION" >&2
    exit 1
  }
}

for binary in \
  "$APP/Contents/MacOS/Detach" \
  "$APP/Contents/MacOS/DetachWatchdog" \
  "$STATE_BINARY" \
  "$POWER_BINARY" \
  "$POWER_HELPER_BINARY" \
  "$TMUX_BINARY"; do
  verify_minimum_system_version "$binary"
done

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
[ "$(plutil -extract Label raw -o - "$AGENT")" = "dev.tsarev.detach.power-watchdog" ] || {
  printf 'Unexpected bundled watchdog label\n' >&2
  exit 1
}
[ "$(find "$APP/Contents/Library/LaunchAgents" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ] || {
  printf 'The app must bundle exactly one user LaunchAgent definition\n' >&2
  exit 1
}
[ "$(find "$APP/Contents/Library/LaunchDaemons" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ] || {
  printf 'The app must bundle exactly one privileged LaunchDaemon definition\n' >&2
  exit 1
}
[ "$(plutil -extract Label raw -o - "$POWER_DAEMON")" = \
  dev.tsarev.detach.power-helper ] || {
  printf 'Unexpected privileged power helper label\n' >&2
  exit 1
}
[ "$(plutil -extract BundleProgram raw -o - "$POWER_DAEMON")" = \
  Contents/MacOS/DetachPowerHelper ] || {
  printf 'Unexpected privileged power helper BundleProgram\n' >&2
  exit 1
}
[ "$(plutil -extract 'MachServices.dev\.tsarev\.detach\.power-helper' raw -o - \
  "$POWER_DAEMON")" = true ] || {
  printf 'Privileged power helper Mach service is missing\n' >&2
  exit 1
}
[ "$(plutil -extract RunAtLoad raw -o - "$POWER_DAEMON")" = true ] || {
  printf 'Privileged power helper must reconcile state after load\n' >&2
  exit 1
}
[ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$POWER_DAEMON")" = \
  false ] || {
  printf 'Privileged power helper must restart after an abnormal exit\n' >&2
  exit 1
}
[ "$(plutil -extract ThrottleInterval raw -o - "$POWER_DAEMON")" = 10 ] || {
  printf 'Privileged power helper restart throttle is unexpected\n' >&2
  exit 1
}
POWER_DAEMON_KEYS="$(plutil -p "$POWER_DAEMON" | \
  sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | sort)"
[ "$POWER_DAEMON_KEYS" = \
  $'BundleProgram\nKeepAlive\nLabel\nMachServices\nRunAtLoad\nThrottleInterval' ] || {
  printf 'Privileged power helper plist has unexpected top-level keys\n' >&2
  exit 1
}
[ "$(plutil -p "$POWER_DAEMON" | \
  sed -n '/"MachServices" => {/,/^  }/p' | grep -c '=>')" = 2 ] || {
  printf 'Privileged power helper plist has unexpected Mach services\n' >&2
  exit 1
}
[ "$(plutil -p "$POWER_DAEMON" | \
  sed -n '/"KeepAlive" => {/,/^  }/p' | grep -c '=>')" = 2 ] || {
  printf 'Privileged power helper plist has unexpected keep-alive policy\n' >&2
  exit 1
}
[ -x "$APP/Contents/MacOS/DetachPowerHelper" ] || {
  printf 'Privileged power helper BundleProgram is missing\n' >&2
  exit 1
}
! plutil -p "$POWER_DAEMON" | grep -E '(/Users/|ProgramArguments)' >/dev/null
for leaked_agent in \
  "$PAYLOAD/dev.tsarev.detach.power-watchdog.plist" \
  "$PAYLOAD/dev.tsarev.detach.cli-watchdog.plist"; do
  [ ! -e "$leaked_agent" ] || {
    printf 'App service definition leaked into the CLI payload: %s\n' \
      "$leaked_agent" >&2
    exit 1
  }
done

for own_binary in \
  "$APP/Contents/MacOS/Detach" \
  "$APP/Contents/MacOS/DetachWatchdog" \
  "$STATE_BINARY" \
  "$POWER_BINARY" \
  "$POWER_HELPER_BINARY" \
  "$TMUX_BINARY" \
  "$PAYLOAD/detach-state" \
  "$PAYLOAD/detach-power" \
  "$PAYLOAD/tmux"; do
  if LC_ALL=C grep -a -F '/Users/' "$own_binary" >/dev/null; then
    printf 'Local build path leaked into %s\n' "$(basename "$own_binary")" >&2
    exit 1
  fi
done

verify_dynamic_dependencies "$APP/Contents/MacOS/Detach" 1
for system_only_binary in \
  "$APP/Contents/MacOS/DetachWatchdog" \
  "$STATE_BINARY" \
  "$POWER_BINARY" \
  "$POWER_HELPER_BINARY" \
  "$TMUX_BINARY" \
  "$PAYLOAD/detach-state" \
  "$PAYLOAD/detach-power" \
  "$PAYLOAD/tmux"; do
  verify_dynamic_dependencies "$system_only_binary"
done

for cli_payload_service in "$PAYLOAD"/*.plist; do
  [ ! -e "$cli_payload_service" ] || {
    printf 'CLI payload unexpectedly contains a service definition: %s\n' \
      "$cli_payload_service" >&2
    exit 1
  }
done

if plutil -p "$INFO" | grep -Fi Amphetamine >/dev/null; then
  printf 'App metadata still references Amphetamine\n' >&2
  exit 1
fi

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
  "$STATE_BINARY"
  "$PAYLOAD/detach-state"
  "$POWER_BINARY"
  "$PAYLOAD/detach-power"
  "$POWER_HELPER_BINARY"
  "$TMUX_BINARY"
  "$PAYLOAD/tmux"
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
verify_signing_identifier() {
  local binary="$1"
  local expected_identifier="$2"
  local signature

  signature="$(codesign -d --verbose=4 "$binary" 2>&1)"
  grep -F "Identifier=$expected_identifier" <<<"$signature" >/dev/null || {
    printf 'Unexpected signing identifier for %s\n' "$binary" >&2
    exit 1
  }
}
codesign --verify --strict --verbose=2 "$TMUX_BINARY"
verify_signing_identifier "$STATE_BINARY" dev.tsarev.detach.state
verify_signing_identifier "$PAYLOAD/detach-state" dev.tsarev.detach.state
verify_signing_identifier "$POWER_BINARY" dev.tsarev.detach.power
verify_signing_identifier "$PAYLOAD/detach-power" dev.tsarev.detach.power
verify_signing_identifier "$POWER_HELPER_BINARY" dev.tsarev.detach.power-helper
verify_signing_identifier "$TMUX_BINARY" dev.tsarev.detach.tmux
verify_signing_identifier "$PAYLOAD/tmux" dev.tsarev.detach.tmux

WATCHDOG_SIGNATURE="$(codesign -d --verbose=4 "$APP/Contents/MacOS/DetachWatchdog" 2>&1)"
APP_SIGNATURE="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -F 'Identifier=dev.tsarev.detach.power-watchdog' <<<"$WATCHDOG_SIGNATURE" >/dev/null || {
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
  grep -F '<string>dev.tsarev.detach.power-watchdog</string>' <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Unexpected watchdog embedded bundle identifier for %s\n' "$arch" >&2
    exit 1
  }
  grep -F '<string>DetachWatchdog</string>' <<<"$HELPER_STRINGS" >/dev/null || {
    printf 'Unexpected watchdog embedded executable for %s\n' "$arch" >&2
    exit 1
  }
  if grep -F '<key>NSAppleEventsUsageDescription</key>' \
      <<<"$HELPER_STRINGS" >/dev/null; then
    printf 'Watchdog embedded Info.plist retains Apple Events metadata for %s\n' \
      "$arch" >&2
    exit 1
  fi
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
for entitlement_plist in \
  "$ENTITLEMENTS_DIR/app.plist" \
  "$ENTITLEMENTS_DIR/helper.plist"; do
  if plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - \
      "$entitlement_plist" >/dev/null 2>&1; then
    printf 'Obsolete Automation Apple Events entitlement remains in %s\n' \
      "$entitlement_plist" >&2
    exit 1
  fi
done

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

APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$APP_SIGNATURE")"
[ "$APP_TEAM" != "not set" ] || APP_TEAM=""
if [ "$VERIFY_PRODUCTION" = 1 ]; then
  [ -n "$APP_TEAM" ] || {
    printf 'Production app signature has no TeamIdentifier\n' >&2
    exit 1
  }
fi
if [ -n "$APP_TEAM" ]; then
  for signed_object in "${signed_objects[@]}"; do
    object_signature="$(codesign -d --verbose=4 "$signed_object" 2>&1)"
    [ "$(sed -n 's/^TeamIdentifier=//p' <<<"$object_signature")" = "$APP_TEAM" ] || {
      printf 'Nested code TeamIdentifier mismatch: %s\n' "$signed_object" >&2
      exit 1
    }
  done
fi

verify_arm64_only() {
  local binary="$1"
  local archs

  archs="$(/usr/bin/lipo -archs "$binary")" || {
    printf 'Cannot inspect bundled executable architectures: %s\n' "$binary" >&2
    exit 1
  }
  [ "$archs" = arm64 ] || {
    printf 'Bundled executable must be arm64-only, found %s: %s\n' \
      "$archs" "$binary" >&2
    exit 1
  }
}

arm64_binaries=(
  "$APP/Contents/MacOS/Detach"
  "$APP/Contents/MacOS/DetachWatchdog"
  "$STATE_BINARY"
  "$PAYLOAD/detach-state"
  "$POWER_BINARY"
  "$PAYLOAD/detach-power"
  "$POWER_HELPER_BINARY"
  "$TMUX_BINARY"
  "$PAYLOAD/tmux"
  "$SPARKLE_BINARY"
  "$AUTOUPDATE"
  "$UPDATER_BINARY"
  "$INSTALLER_BINARY"
  "$DOWNLOADER_BINARY"
)
for arm64_binary in "${arm64_binaries[@]}"; do
  verify_arm64_only "$arm64_binary"
done

printf 'Verified %s\n' "$APP"
