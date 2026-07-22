#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
BUILD_VERSION="${DETACH_BUILD_VERSION:-1}"
ARCHS="${DETACH_BUILD_ARCHS:-arm64}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:--}"
RELEASE_BUILD="${DETACH_RELEASE_BUILD:-0}"
SPARKLE_VERSION="${DETACH_SPARKLE_VERSION:-2.9.4}"
SPARKLE_FEED_URL="${DETACH_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${DETACH_SPARKLE_PUBLIC_ED_KEY:-}"
DOWNLOAD_URL="${DETACH_DOWNLOAD_URL:-}"
SPARKLE_LICENSE_SOURCE="$APP_ROOT/Resources/ThirdParty/Sparkle/LICENSE.txt"
SPARKLE_LICENSE_SHA256="389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
APP="$APP_ROOT/build/Detach.app"
PAYLOAD="$APP/Contents/Resources/DetachCLI"
LAUNCH_AGENTS="$APP/Contents/Library/LaunchAgents"
LAUNCH_DAEMONS="$APP/Contents/Library/LaunchDaemons"
FRAMEWORKS="$APP/Contents/Frameworks"
TMUX_BUILDER="$REPO_ROOT/scripts/build-tmux.sh"
TMUX_BINARY="$APP/Contents/MacOS/tmux"
STATE_BINARY="$APP/Contents/MacOS/detach-state"
POWER_BINARY="$APP/Contents/MacOS/detach-power"
POWER_HELPER_BINARY="$APP/Contents/MacOS/DetachPowerHelper"
POWER_DAEMON_SOURCE="$APP_ROOT/Resources/dev.tsarev.detach.power-helper.plist"
POWER_DAEMON="$LAUNCH_DAEMONS/dev.tsarev.detach.power-helper.plist"
# build-tmux rejects any output whose `otool -L` header contains a user path,
# just as it rejects such paths in actual dependencies. Keep intermediate
# products in a process-private system temporary path and copy only the
# verified arm64 result into the bundle.
TMUX_PRODUCT_ROOT="/private/tmp/detach-tmux-products.$$"
BUILD_MARKER_ROOT="/private/tmp/detach-app-build-marker.$$"
BUILD_MARKER_FILE="$BUILD_MARKER_ROOT/marker.txt"
TMUX_THIRD_PARTY="$APP/Contents/Resources/ThirdParty/tmux"
SPARKLE_LICENSE="$APP/Contents/Resources/ThirdParty/Sparkle/LICENSE.txt"
BUNDLE_MODE_POLICY="$APP_ROOT/scripts/bundle-modes.sh"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$APP_ROOT/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$APP_ROOT/.build/module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

cleanup() {
  case "$TMUX_PRODUCT_ROOT" in
    /private/tmp/detach-tmux-products.*) rm -rf "$TMUX_PRODUCT_ROOT" ;;
  esac
  case "$BUILD_MARKER_ROOT" in
    /private/tmp/detach-app-build-marker.*) rm -rf "$BUILD_MARKER_ROOT" ;;
  esac
}
trap cleanup EXIT

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || {
  printf 'Invalid Detach version: %s\n' "$VERSION" >&2
  exit 1
}
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] || {
  printf 'DETACH_BUILD_VERSION must be a positive integer\n' >&2
  exit 1
}
[ "$ARCHS" = arm64 ] || {
  printf 'DETACH_BUILD_ARCHS must be arm64\n' >&2
  exit 1
}
[[ "$RELEASE_BUILD" = 0 || "$RELEASE_BUILD" = 1 ]] || {
  printf 'DETACH_RELEASE_BUILD must be 0 or 1\n' >&2
  exit 1
}
if [ -n "$SPARKLE_FEED_URL" ] || [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
  [[ "$SPARKLE_FEED_URL" =~ ^https://[^[:space:]]+$ ]] || {
    printf 'DETACH_SPARKLE_FEED_URL must be a valid HTTPS URL\n' >&2
    exit 1
  }
  [[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    printf 'DETACH_SPARKLE_PUBLIC_ED_KEY must be a base64 Ed25519 public key\n' >&2
    exit 1
  }
elif [ "$RELEASE_BUILD" = 1 ]; then
  printf 'A production build requires DETACH_SPARKLE_FEED_URL and DETACH_SPARKLE_PUBLIC_ED_KEY\n' >&2
  exit 1
fi
if [ -n "$DOWNLOAD_URL" ]; then
  [[ "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]] || {
    printf 'DETACH_DOWNLOAD_URL must be a valid HTTPS URL\n' >&2
    exit 1
  }
elif [ "$RELEASE_BUILD" = 1 ]; then
  printf 'A production build requires DETACH_DOWNLOAD_URL\n' >&2
  exit 1
fi
if [ "$RELEASE_BUILD" = 1 ] && [ "$IDENTITY" = "-" ]; then
  printf 'A production build cannot use ad-hoc code signing\n' >&2
  exit 1
fi
[ -x "$TMUX_BUILDER" ] || {
  printf 'Bundled tmux builder is missing or not executable: %s\n' "$TMUX_BUILDER" >&2
  exit 1
}
[ -f "$BUNDLE_MODE_POLICY" ] || {
  printf 'App bundle mode policy is missing: %s\n' "$BUNDLE_MODE_POLICY" >&2
  exit 1
}
# shellcheck source=app/scripts/bundle-modes.sh
source "$BUNDLE_MODE_POLICY"
[ -f "$POWER_DAEMON_SOURCE" ] || {
  printf 'Privileged power helper service definition is missing: %s\n' \
    "$POWER_DAEMON_SOURCE" >&2
  exit 1
}
[ -f "$SPARKLE_LICENSE_SOURCE" ] || {
  printf 'Pinned Sparkle license notice is missing: %s\n' \
    "$SPARKLE_LICENSE_SOURCE" >&2
  exit 1
}
[ "$(/usr/bin/shasum -a 256 "$SPARKLE_LICENSE_SOURCE" | /usr/bin/awk '{print $1}')" = \
  "$SPARKLE_LICENSE_SHA256" ] || {
  printf 'Pinned Sparkle license notice does not match Sparkle %s\n' \
    "$SPARKLE_VERSION" >&2
  exit 1
}

codesign_args=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  codesign_args+=(--timestamp)
fi

# SwiftPM's standalone launch-agent executable needs an embedded Info.plist.
# Include the source plist digest in the generated path so any metadata change
# invalidates SwiftPM's linker command, even while iterating on one build number.
WATCHDOG_INFO_DIGEST="$(shasum -a 256 "$APP_ROOT/Resources/DetachWatchdog-Info.plist" | awk '{print substr($1, 1, 12)}')"
WATCHDOG_INFO_PLIST="$APP_ROOT/.build/DetachWatchdog-Info-$VERSION-$BUILD_VERSION-$WATCHDOG_INFO_DIGEST.plist"
cp "$APP_ROOT/Resources/DetachWatchdog-Info.plist" "$WATCHDOG_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$WATCHDOG_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$WATCHDOG_INFO_PLIST"
export DETACH_WATCHDOG_INFO_PLIST="$WATCHDOG_INFO_PLIST"

find_sparkle_framework() {
  local scratch="$1"
  local bin_path="$2"
  local candidate

  if [ -d "$bin_path/Sparkle.framework" ]; then
    printf '%s\n' "$bin_path/Sparkle.framework"
    return
  fi
  while IFS= read -r candidate; do
    [ -d "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return
  done < <(find "$scratch/artifacts" "$APP_ROOT/.build/artifacts" -type d \
    -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' 2>/dev/null | sort -u)
  printf 'SwiftPM did not produce Sparkle.framework\n' >&2
  exit 1
}

remove_build_host_rpaths() {
  local binary="$1"
  local rpath

  # Command-line SwiftPM builds may retain an Xcode-toolchain rpath that is
  # useful only on the build host. All shipped dependencies are either system
  # libraries or inside Contents/Frameworks, so remove that accidental path.
  while IFS= read -r rpath; do
    case "$rpath" in
      /Applications/Xcode*.app/*)
        install_name_tool -delete_rpath "$rpath" "$binary"
        ;;
    esac
  done < <(otool -l "$binary" | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" { print $2; in_rpath = 0 }
    ' | sort -u)
}

ensure_app_rpath() {
  local binary="$1"

  if ! otool -l "$binary" | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ' | grep -Fx '@executable_path/../Frameworks' >/dev/null; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$binary"
  fi
  remove_build_host_rpaths "$binary"
}

sign_sparkle_inside_out() {
  local framework="$1"
  local current_version
  local version_root

  current_version="$(readlink "$framework/Versions/Current")"
  version_root="$framework/Versions/$current_version"
  [ -d "$version_root" ] || {
    printf 'Broken Sparkle Versions/Current symlink\n' >&2
    exit 1
  }

  codesign "${codesign_args[@]}" "$version_root/XPCServices/Installer.xpc"
  codesign "${codesign_args[@]}" --preserve-metadata=entitlements \
    "$version_root/XPCServices/Downloader.xpc"
  codesign "${codesign_args[@]}" "$version_root/Autoupdate"
  codesign "${codesign_args[@]}" "$version_root/Updater.app"
  codesign "${codesign_args[@]}" "$framework"
}

build_arch() {
  local arch="$1"
  # SwiftPM already keeps target triples in separate product directories.
  # Sharing one scratch directory also shares the pinned Sparkle checkout and
  # binary artifact.
  local scratch="$APP_ROOT/.build"
  local triple="$arch-apple-macosx26.0"
  swift build --disable-sandbox --disable-automatic-resolution \
    --package-path "$APP_ROOT" -c release --triple "$triple" \
    --scratch-path "$scratch"
  BUILT_BIN_PATH="$(swift build --disable-sandbox --disable-automatic-resolution \
    --package-path "$APP_ROOT" -c release --triple "$triple" \
    --scratch-path "$scratch" --show-bin-path)"
  BUILT_SPARKLE_FRAMEWORK="$(find_sparkle_framework "$scratch" "$BUILT_BIN_PATH")"
}

build_tmux_runtime() {
  local TMUX_ARM_BINARY="$TMUX_PRODUCT_ROOT/arm64/tmux"

  rm -rf "$TMUX_PRODUCT_ROOT"
  mkdir -p "$TMUX_PRODUCT_ROOT/arm64"
  "$TMUX_BUILDER" build --arch arm64 --output "$TMUX_ARM_BINARY"
  install -m 0755 "$TMUX_ARM_BINARY" "$TMUX_BINARY"

  chmod 0755 "$TMUX_BINARY"
  /usr/bin/strip -S "$TMUX_BINARY"
  "$TMUX_BUILDER" licenses --output-dir "$TMUX_THIRD_PARTY"
  codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.tmux "$TMUX_BINARY"
}

thin_binary_to_arm64() {
  local binary="$1"
  local archs temporary mode

  archs="$(/usr/bin/lipo -archs "$binary")" || {
    printf 'Cannot inspect architectures for %s\n' "$binary" >&2
    exit 1
  }
  case " $archs " in
    *' arm64 '*) ;;
    *)
      printf 'Required arm64 slice is missing from %s\n' "$binary" >&2
      exit 1
      ;;
  esac
  if [ "$archs" != arm64 ]; then
    temporary="$binary.arm64.$$"
    mode="$(stat -f '%Lp' "$binary")"
    rm -f "$temporary"
    /usr/bin/lipo "$binary" -thin arm64 -output "$temporary"
    chmod "$mode" "$temporary"
    mv -f "$temporary" "$binary"
  fi
  [ "$(/usr/bin/lipo -archs "$binary")" = arm64 ] || {
    printf 'Binary is not arm64-only after thinning: %s\n' "$binary" >&2
    exit 1
  }
}

thin_sparkle_to_arm64() {
  local framework="$1"
  local current_version version_root binary

  current_version="$(readlink "$framework/Versions/Current")"
  version_root="$framework/Versions/$current_version"
  for binary in \
    "$version_root/Sparkle" \
    "$version_root/Autoupdate" \
    "$version_root/Updater.app/Contents/MacOS/Updater" \
    "$version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    [ -f "$binary" ] || {
      printf 'Missing Sparkle executable while thinning: %s\n' "$binary" >&2
      exit 1
    }
    thin_binary_to_arm64 "$binary"
  done
}

# The caller's umask must never leak into a distributable app. In particular,
# codesign rewrites Mach-O files and creates CodeResources using this umask.
umask 022
mkdir -p "$BUILD_MARKER_ROOT"
printf 'detach-app-build:%s\n' "$(/usr/bin/uuidgen)" >"$BUILD_MARKER_FILE"
chmod 0644 "$BUILD_MARKER_FILE"
export DETACH_APP_BUILD_MARKER_FILE="$BUILD_MARKER_FILE"
mkdir -p "$APP_ROOT/build"
rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources" \
  "$PAYLOAD" \
  "$LAUNCH_AGENTS" \
  "$LAUNCH_DAEMONS" \
  "$FRAMEWORKS"

build_arch arm64
arm_bin="$BUILT_BIN_PATH"
sparkle_framework="$BUILT_SPARKLE_FRAMEWORK"
cp "$arm_bin/DetachApp" "$APP/Contents/MacOS/Detach"
cp "$arm_bin/DetachWatchdog" "$APP/Contents/MacOS/DetachWatchdog"
cp "$arm_bin/detach-state" "$STATE_BINARY"
cp "$arm_bin/detach-power" "$POWER_BINARY"
cp "$arm_bin/detach-power-helper" "$POWER_HELPER_BINARY"

build_tmux_runtime

chmod 0755 "$STATE_BINARY" "$POWER_BINARY" "$POWER_HELPER_BINARY"
remove_build_host_rpaths "$STATE_BINARY"
remove_build_host_rpaths "$POWER_BINARY"
remove_build_host_rpaths "$POWER_HELPER_BINARY"
remove_build_host_rpaths "$APP/Contents/MacOS/DetachWatchdog"
# Strip before signing so both the app-local tools and their immutable payload
# copies have identical, host-path-free bytes.
/usr/bin/strip -S "$STATE_BINARY" "$POWER_BINARY" "$POWER_HELPER_BINARY"
codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.state \
  "$STATE_BINARY"
codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.power \
  "$POWER_BINARY"
codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.power-helper \
  "$POWER_HELPER_BINARY"

framework_version="$(plutil -extract CFBundleShortVersionString raw -o - "$sparkle_framework/Resources/Info.plist")"
[ "$framework_version" = "$SPARKLE_VERSION" ] || {
  printf 'Expected Sparkle %s, found %s\n' "$SPARKLE_VERSION" "$framework_version" >&2
  exit 1
}
# Sparkle.framework is versioned and relies on its symlink layout. `ditto`
# preserves that layout while copying the SwiftPM binary artifact.
ditto "$sparkle_framework" "$FRAMEWORKS/Sparkle.framework"
verify_detach_bundle_symlinks "$APP"
thin_sparkle_to_arm64 "$FRAMEWORKS/Sparkle.framework"
ensure_app_rpath "$APP/Contents/MacOS/Detach"

cp "$APP_ROOT/Resources/Detach.icns" "$APP/Contents/Resources/Detach.icns"
install -m 0644 "$BUILD_MARKER_FILE" "$APP/Contents/Resources/BUILD_MARKER"
install -d -m 0755 "$(dirname "$SPARKLE_LICENSE")"
install -m 0644 "$SPARKLE_LICENSE_SOURCE" "$SPARKLE_LICENSE"
cp "$APP_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
for localization in en ru; do
  source_lproj="$APP_ROOT/Resources/$localization.lproj"
  destination_lproj="$APP/Contents/Resources/$localization.lproj"
  mkdir -p "$destination_lproj"
  install -m 0644 "$source_lproj/Localizable.strings" \
    "$destination_lproj/Localizable.strings"
  install -m 0644 "$source_lproj/InfoPlist.strings" \
    "$destination_lproj/InfoPlist.strings"
done
cp "$APP_ROOT/Resources/dev.tsarev.detach.power-watchdog.plist" \
  "$LAUNCH_AGENTS/dev.tsarev.detach.power-watchdog.plist"
cp "$POWER_DAEMON_SOURCE" "$POWER_DAEMON"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
if [ -n "$SPARKLE_FEED_URL" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi
if [ -n "$DOWNLOAD_URL" ]; then
  /usr/libexec/PlistBuddy -c "Add :DetachDownloadURL string $DOWNLOAD_URL" "$APP/Contents/Info.plist"
fi

install -m 0755 "$REPO_ROOT/bin/detach" "$PAYLOAD/detach"
install -m 0755 "$REPO_ROOT/bin/detach-core" "$PAYLOAD/detach-core"
install -m 0755 "$REPO_ROOT/scripts/install.sh" "$PAYLOAD/detach-install"
install -m 0755 "$STATE_BINARY" "$PAYLOAD/detach-state"
install -m 0755 "$POWER_BINARY" "$PAYLOAD/detach-power"
install -m 0755 "$TMUX_BINARY" "$PAYLOAD/tmux"
printf '%s\n' "$VERSION" >"$PAYLOAD/VERSION"
chmod 0644 "$PAYLOAD/VERSION"
printf '%s\n' "$BUILD_VERSION" >"$PAYLOAD/BUILD"

detach_hash="$(shasum -a 256 "$PAYLOAD/detach" | awk '{print $1}')"
core_hash="$(shasum -a 256 "$PAYLOAD/detach-core" | awk '{print $1}')"
installer_hash="$(shasum -a 256 "$PAYLOAD/detach-install" | awk '{print $1}')"
state_hash="$(shasum -a 256 "$PAYLOAD/detach-state" | awk '{print $1}')"
power_hash="$(shasum -a 256 "$PAYLOAD/detach-power" | awk '{print $1}')"
tmux_hash="$(shasum -a 256 "$PAYLOAD/tmux" | awk '{print $1}')"
payload_id="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$VERSION" "$BUILD_VERSION" "$detach_hash" "$core_hash" "$installer_hash" \
  "$state_hash" "$power_hash" "$tmux_hash" | \
  shasum -a 256 | awk '{print $1}')"
printf '%s\n' "$payload_id" >"$PAYLOAD/PAYLOAD_ID"
printf '{"schema":1,"version":"%s","build":"%s","payload_id":"%s","files":{"detach":"%s","detach_core":"%s","detach_install":"%s","detach_state":"%s","detach_power":"%s","tmux":"%s"}}\n' \
  "$VERSION" "$BUILD_VERSION" "$payload_id" "$detach_hash" "$core_hash" "$installer_hash" \
  "$state_hash" "$power_hash" "$tmux_hash" \
  >"$PAYLOAD/payload.json"

chmod 0755 "$APP/Contents/MacOS/Detach" "$APP/Contents/MacOS/DetachWatchdog"
# SwiftPM leaves source and object-file paths in the Mach-O symbol table even
# for release builds. Strip debug symbols before signing so public artifacts
# do not disclose the local checkout or user name.
/usr/bin/strip -S "$APP/Contents/MacOS/Detach" "$APP/Contents/MacOS/DetachWatchdog"
plutil -lint "$APP/Contents/Info.plist" \
  "$APP/Contents/Resources/en.lproj/Localizable.strings" \
  "$APP/Contents/Resources/en.lproj/InfoPlist.strings" \
  "$APP/Contents/Resources/ru.lproj/Localizable.strings" \
  "$APP/Contents/Resources/ru.lproj/InfoPlist.strings" \
  "$LAUNCH_AGENTS/dev.tsarev.detach.power-watchdog.plist" \
  "$POWER_DAEMON" >/dev/null

normalize_detach_bundle_modes "$APP"
sign_sparkle_inside_out "$FRAMEWORKS/Sparkle.framework"
codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.power-watchdog \
  --entitlements "$APP_ROOT/Resources/DetachWatchdog.entitlements" \
  "$APP/Contents/MacOS/DetachWatchdog"
app_entitlements="$APP_ROOT/Resources/Detach.entitlements"
if [ "$IDENTITY" = "-" ]; then
  app_entitlements="$APP_ROOT/Resources/DetachDevelopment.entitlements"
fi
codesign "${codesign_args[@]}" --entitlements "$app_entitlements" "$APP"
codesign --verify --strict --verbose=2 "$APP"

DETACH_APP_PATH="$APP" DETACH_VERSION="$VERSION" \
  DETACH_SPARKLE_VERSION="$SPARKLE_VERSION" \
  DETACH_REQUIRE_SPARKLE_CONFIG="$RELEASE_BUILD" \
  DETACH_VERIFY_PRODUCTION="$RELEASE_BUILD" \
  "$APP_ROOT/scripts/verify-app.sh"

printf 'Built %s %s (%s, %s)\n' "$APP" "$VERSION" "$BUILD_VERSION" "$ARCHS"
printf 'Run: open %s\n' "$APP"
