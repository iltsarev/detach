#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
BUILD_VERSION="${DETACH_BUILD_VERSION:-1}"
ARCHS="${DETACH_BUILD_ARCHS:-universal}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:--}"
RELEASE_BUILD="${DETACH_RELEASE_BUILD:-0}"
SPARKLE_VERSION="${DETACH_SPARKLE_VERSION:-2.9.4}"
SPARKLE_FEED_URL="${DETACH_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${DETACH_SPARKLE_PUBLIC_ED_KEY:-}"
DOWNLOAD_URL="${DETACH_DOWNLOAD_URL:-}"
APP="$APP_ROOT/build/Detach.app"
PAYLOAD="$APP/Contents/Resources/DetachCLI"
LAUNCH_AGENTS="$APP/Contents/Library/LaunchAgents"
FRAMEWORKS="$APP/Contents/Frameworks"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$APP_ROOT/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$APP_ROOT/.build/module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || {
  printf 'Invalid Detach version: %s\n' "$VERSION" >&2
  exit 1
}
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] || {
  printf 'DETACH_BUILD_VERSION must be a positive integer\n' >&2
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

ensure_app_rpath() {
  local binary="$1"
  local rpath

  if ! otool -l "$binary" | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ' | grep -Fx '@executable_path/../Frameworks' >/dev/null; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$binary"
  fi
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
  # binary artifact, so a universal build does not fetch dependencies twice.
  local scratch="$APP_ROOT/.build"
  local triple="$arch-apple-macosx14.0"
  swift build --disable-sandbox --disable-automatic-resolution \
    --package-path "$APP_ROOT" -c release --triple "$triple" \
    --scratch-path "$scratch"
  BUILT_BIN_PATH="$(swift build --disable-sandbox --disable-automatic-resolution \
    --package-path "$APP_ROOT" -c release --triple "$triple" \
    --scratch-path "$scratch" --show-bin-path)"
  BUILT_SPARKLE_FRAMEWORK="$(find_sparkle_framework "$scratch" "$BUILT_BIN_PATH")"
}

mkdir -p "$APP_ROOT/build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PAYLOAD" "$LAUNCH_AGENTS" "$FRAMEWORKS"

case "$ARCHS" in
  universal)
    build_arch arm64
    arm_bin="$BUILT_BIN_PATH"
    sparkle_framework="$BUILT_SPARKLE_FRAMEWORK"
    build_arch x86_64
    intel_bin="$BUILT_BIN_PATH"
    lipo -create "$arm_bin/DetachApp" "$intel_bin/DetachApp" \
      -output "$APP/Contents/MacOS/Detach"
    lipo -create "$arm_bin/DetachWatchdog" "$intel_bin/DetachWatchdog" \
      -output "$APP/Contents/MacOS/DetachWatchdog"
    ;;
  native)
    swift build --disable-sandbox --disable-automatic-resolution \
      --package-path "$APP_ROOT" -c release
    native_bin="$(swift build --disable-sandbox --disable-automatic-resolution \
      --package-path "$APP_ROOT" -c release --show-bin-path)"
    cp "$native_bin/DetachApp" "$APP/Contents/MacOS/Detach"
    cp "$native_bin/DetachWatchdog" "$APP/Contents/MacOS/DetachWatchdog"
    sparkle_framework="$(find_sparkle_framework "$APP_ROOT/.build" "$native_bin")"
    ;;
  *)
    printf 'DETACH_BUILD_ARCHS must be universal or native\n' >&2
    exit 1
    ;;
esac

framework_version="$(plutil -extract CFBundleShortVersionString raw -o - "$sparkle_framework/Resources/Info.plist")"
[ "$framework_version" = "$SPARKLE_VERSION" ] || {
  printf 'Expected Sparkle %s, found %s\n' "$SPARKLE_VERSION" "$framework_version" >&2
  exit 1
}
# Sparkle.framework is versioned and relies on its symlink layout. `ditto`
# preserves that layout while copying the SwiftPM binary artifact.
ditto "$sparkle_framework" "$FRAMEWORKS/Sparkle.framework"
[ -L "$FRAMEWORKS/Sparkle.framework/Versions/Current" ] && \
  [ -L "$FRAMEWORKS/Sparkle.framework/Sparkle" ] || {
    printf 'Sparkle framework symlinks were not preserved\n' >&2
    exit 1
  }
ensure_app_rpath "$APP/Contents/MacOS/Detach"

cp "$APP_ROOT/Resources/Detach.icns" "$APP/Contents/Resources/Detach.icns"
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
cp "$APP_ROOT/Resources/dev.tsarev.detach.watchdog.plist" \
  "$LAUNCH_AGENTS/dev.tsarev.detach.watchdog.plist"
cp "$APP_ROOT/Resources/dev.tsarev.codex-detached-watchdog.plist" \
  "$LAUNCH_AGENTS/dev.tsarev.codex-detached-watchdog.plist"
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
printf '%s\n' "$VERSION" >"$PAYLOAD/VERSION"
chmod 0644 "$PAYLOAD/VERSION"
install -m 0644 "$REPO_ROOT/launchagents/dev.tsarev.detach.cli-watchdog.plist" \
  "$PAYLOAD/dev.tsarev.detach.cli-watchdog.plist"
printf '%s\n' "$BUILD_VERSION" >"$PAYLOAD/BUILD"

detach_hash="$(shasum -a 256 "$PAYLOAD/detach" | awk '{print $1}')"
core_hash="$(shasum -a 256 "$PAYLOAD/detach-core" | awk '{print $1}')"
installer_hash="$(shasum -a 256 "$PAYLOAD/detach-install" | awk '{print $1}')"
payload_id="$(printf '%s\n%s\n%s\n%s\n%s\n' \
  "$VERSION" "$BUILD_VERSION" "$detach_hash" "$core_hash" "$installer_hash" | \
  shasum -a 256 | awk '{print $1}')"
printf '%s\n' "$payload_id" >"$PAYLOAD/PAYLOAD_ID"
printf '{"schema":1,"version":"%s","build":"%s","payload_id":"%s","files":{"detach":"%s","detach_core":"%s","detach_install":"%s"}}\n' \
  "$VERSION" "$BUILD_VERSION" "$payload_id" "$detach_hash" "$core_hash" "$installer_hash" \
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
  "$LAUNCH_AGENTS/dev.tsarev.detach.watchdog.plist" \
  "$LAUNCH_AGENTS/dev.tsarev.codex-detached-watchdog.plist" \
  "$PAYLOAD/dev.tsarev.detach.cli-watchdog.plist" >/dev/null

codesign_args=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  codesign_args+=(--timestamp)
fi
sign_sparkle_inside_out "$FRAMEWORKS/Sparkle.framework"
codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.watchdog \
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
  DETACH_VERIFY_UNIVERSAL="$([ "$ARCHS" = universal ] && printf 1 || printf 0)" \
  "$APP_ROOT/scripts/verify-app.sh"

printf 'Built %s %s (%s, %s)\n' "$APP" "$VERSION" "$BUILD_VERSION" "$ARCHS"
printf 'Run: open %s\n' "$APP"
