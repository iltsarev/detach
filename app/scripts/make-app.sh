#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
BUILD_VERSION="${DETACH_BUILD_VERSION:-1}"
ARCHS="${DETACH_BUILD_ARCHS:-universal}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:--}"
APP="$APP_ROOT/build/Detach.app"
PAYLOAD="$APP/Contents/Resources/DetachCLI"
LAUNCH_AGENTS="$APP/Contents/Library/LaunchAgents"
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

build_arch() {
  local arch="$1"
  local scratch="$APP_ROOT/.build/distribution/$arch"
  local triple="$arch-apple-macosx14.0"
  swift build --disable-sandbox --package-path "$APP_ROOT" -c release --triple "$triple" \
    --scratch-path "$scratch"
  BUILT_BIN_PATH="$(swift build --disable-sandbox --package-path "$APP_ROOT" -c release --triple "$triple" \
    --scratch-path "$scratch" --show-bin-path)"
}

mkdir -p "$APP_ROOT/build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PAYLOAD" "$LAUNCH_AGENTS"

case "$ARCHS" in
  universal)
    build_arch arm64
    arm_bin="$BUILT_BIN_PATH"
    build_arch x86_64
    intel_bin="$BUILT_BIN_PATH"
    lipo -create "$arm_bin/DetachApp" "$intel_bin/DetachApp" \
      -output "$APP/Contents/MacOS/Detach"
    lipo -create "$arm_bin/DetachWatchdog" "$intel_bin/DetachWatchdog" \
      -output "$APP/Contents/MacOS/DetachWatchdog"
    ;;
  native)
    swift build --disable-sandbox --package-path "$APP_ROOT" -c release
    native_bin="$(swift build --disable-sandbox --package-path "$APP_ROOT" -c release --show-bin-path)"
    cp "$native_bin/DetachApp" "$APP/Contents/MacOS/Detach"
    cp "$native_bin/DetachWatchdog" "$APP/Contents/MacOS/DetachWatchdog"
    ;;
  *)
    printf 'DETACH_BUILD_ARCHS must be universal or native\n' >&2
    exit 1
    ;;
esac

cp "$APP_ROOT/Resources/Detach.icns" "$APP/Contents/Resources/Detach.icns"
cp "$APP_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$APP_ROOT/Resources/dev.tsarev.codex-detached-watchdog.plist" \
  "$LAUNCH_AGENTS/dev.tsarev.codex-detached-watchdog.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"

install -m 0755 "$REPO_ROOT/bin/detach" "$PAYLOAD/detach"
install -m 0755 "$REPO_ROOT/bin/detach-core" "$PAYLOAD/detach-core"
install -m 0755 "$REPO_ROOT/scripts/install.sh" "$PAYLOAD/detach-install"
printf '%s\n' "$VERSION" >"$PAYLOAD/VERSION"
chmod 0644 "$PAYLOAD/VERSION"
install -m 0644 "$REPO_ROOT/launchagents/dev.tsarev.codex-detached-watchdog.plist" \
  "$PAYLOAD/dev.tsarev.codex-detached-watchdog.plist"
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
plutil -lint "$APP/Contents/Info.plist" "$LAUNCH_AGENTS/dev.tsarev.codex-detached-watchdog.plist" >/dev/null

codesign_args=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" --identifier dev.tsarev.detach.watchdog \
  --entitlements "$APP_ROOT/Resources/Detach.entitlements" \
  "$APP/Contents/MacOS/DetachWatchdog"
codesign "${codesign_args[@]}" --entitlements "$APP_ROOT/Resources/Detach.entitlements" "$APP"
codesign --verify --strict --verbose=2 "$APP"

DETACH_APP_PATH="$APP" DETACH_VERSION="$VERSION" \
  DETACH_VERIFY_UNIVERSAL="$([ "$ARCHS" = universal ] && printf 1 || printf 0)" \
  "$APP_ROOT/scripts/verify-app.sh"

printf 'Built %s %s (%s, %s)\n' "$APP" "$VERSION" "$BUILD_VERSION" "$ARCHS"
printf 'Run: open %s\n' "$APP"
