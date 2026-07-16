#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
BUILDER="$ROOT/scripts/build-tmux.sh"
MAKE_APP="$ROOT/app/scripts/make-app.sh"
VERIFY_APP="$ROOT/app/scripts/verify-app.sh"
BUNDLE_MODE_POLICY="$ROOT/app/scripts/bundle-modes.sh"
DETACH="$ROOT/bin/detach"
CORE="$ROOT/bin/detach-core"
INSTALLER="$ROOT/scripts/install.sh"
POWER_SMOKE_TEST="$ROOT/tests/power-smoke.sh"
POWER_HELPER_MAIN="$ROOT/app/Sources/DetachPowerHelper/main.swift"
APP_RESOURCES="$ROOT/app/Resources"
POWER_DAEMON="$APP_RESOURCES/dev.tsarev.detach.power-helper.plist"
SPARKLE_LICENSE="$APP_RESOURCES/ThirdParty/Sparkle/LICENSE.txt"
SPARKLE_LICENSE_SHA256="389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-tmux-contract.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

[ -x "$BUILDER" ]
bash -n "$BUILDER"
bash -n "$MAKE_APP"
bash -n "$VERIFY_APP"
bash -n "$BUNDLE_MODE_POLICY"
bash -n "$DETACH"
bash -n "$CORE"
bash -n "$INSTALLER"
bash -n "$POWER_SMOKE_TEST"
"$BUILDER" metadata --json >"$TMP_ROOT/metadata.json"

# A restrictive caller umask must not leak into the app or its eventual DMG.
# Exercise the same shared policy used by packaging and verification, including
# the separate non-mutating treatment of framework symlinks.
# shellcheck source=app/scripts/bundle-modes.sh
source "$BUNDLE_MODE_POLICY"
MODE_FIXTURE="$TMP_ROOT/Mode Fixture.app"
(
  umask 077
  mkdir -p "$MODE_FIXTURE/Contents/Resources"
  printf 'metadata\n' >"$MODE_FIXTURE/Contents/Resources/metadata.txt"
  # An accidental executable bit on a resource must be removed rather than
  # promoted to a public executable mode.
  chmod 0700 "$MODE_FIXTURE/Contents/Resources/metadata.txt"
  while IFS= read -r relative; do
    path="$MODE_FIXTURE/$relative"
    mkdir -p "$(dirname "$path")"
    printf '#!/bin/sh\nexit 0\n' >"$path"
    chmod 0700 "$path"
  done < <(detach_bundle_executable_paths)

  framework="$MODE_FIXTURE/Contents/Frameworks/Sparkle.framework"
  mkdir -p \
    "$framework/Versions/B/Headers" \
    "$framework/Versions/B/PrivateHeaders" \
    "$framework/Versions/B/Modules" \
    "$framework/Versions/B/Resources"
  while IFS='|' read -r relative target; do
    path="$MODE_FIXTURE/$relative"
    mkdir -p "$(dirname "$path")"
    ln -s "$target" "$path"
  done < <(detach_bundle_symlink_specs)
)
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
normalize_detach_bundle_modes "$MODE_FIXTURE"
verify_detach_bundle_modes "$MODE_FIXTURE"
[ "$(stat -f '%Lp' "$MODE_FIXTURE")" = 755 ]
[ "$(stat -f '%Lp' "$MODE_FIXTURE/Contents/MacOS/Detach")" = 755 ]
[ "$(stat -f '%Lp' "$MODE_FIXTURE/Contents/Resources/metadata.txt")" = 644 ]
CURRENT_LINK="$MODE_FIXTURE/Contents/Frameworks/Sparkle.framework/Versions/Current"
[ -L "$CURRENT_LINK" ]
[ "$(readlink "$CURRENT_LINK")" = B ]

chmod 0700 "$MODE_FIXTURE/Contents"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
chmod 0755 "$MODE_FIXTURE/Contents"
chmod 0644 "$MODE_FIXTURE/Contents/MacOS/Detach"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
chmod 0755 "$MODE_FIXTURE/Contents/MacOS/Detach"
chmod 0600 "$MODE_FIXTURE/Contents/Resources/metadata.txt"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
chmod 0644 "$MODE_FIXTURE/Contents/Resources/metadata.txt"
chmod 0755 "$MODE_FIXTURE/Contents/Resources/metadata.txt"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
chmod 0644 "$MODE_FIXTURE/Contents/Resources/metadata.txt"

ln -s metadata.txt "$MODE_FIXTURE/Contents/Resources/Extra"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
rm "$MODE_FIXTURE/Contents/Resources/Extra"
rm "$CURRENT_LINK"
ln -s A "$CURRENT_LINK"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
rm "$CURRENT_LINK"
ln -s B "$CURRENT_LINK"
mkfifo "$MODE_FIXTURE/Contents/Resources/pipe"
! verify_detach_bundle_modes "$MODE_FIXTURE" >/dev/null 2>&1
rm "$MODE_FIXTURE/Contents/Resources/pipe"
verify_detach_bundle_modes "$MODE_FIXTURE"

grep -F 'umask 022' "$MAKE_APP" >/dev/null
normalize_line="$(grep -nF 'normalize_detach_bundle_modes "$APP"' \
  "$MAKE_APP" | tail -1 | cut -d: -f1)"
sign_line="$(grep -nF 'sign_sparkle_inside_out "$FRAMEWORKS/Sparkle.framework"' \
  "$MAKE_APP" | tail -1 | cut -d: -f1)"
[ "$normalize_line" -lt "$sign_line" ]
grep -F 'verify_detach_bundle_modes "$APP"' "$VERIFY_APP" >/dev/null

plutil -extract schema raw -o - "$TMP_ROOT/metadata.json" | grep -qx 1
plutil -extract tmux.version raw -o - "$TMP_ROOT/metadata.json" | grep -qx 3.7b
plutil -extract tmux.license raw -o - "$TMP_ROOT/metadata.json" | grep -qx ISC
for component in tmux libevent utf8proc; do
  checksum="$(plutil -extract "$component.sha256" raw -o - "$TMP_ROOT/metadata.json")"
  [[ "$checksum" =~ ^[0-9a-f]{64}$ ]]
  source_url="$(plutil -extract "$component.source_url" raw -o - "$TMP_ROOT/metadata.json")"
  [[ "$source_url" =~ ^https:// ]]
done

# The app package supports Apple Silicon only. Both public build entry points
# must reject Intel explicitly before downloading or compiling anything.
if "$BUILDER" build --arch x86_64 --output "$TMP_ROOT/intel-tmux" \
    >"$TMP_ROOT/intel-tmux.log" 2>&1; then
  printf 'tmux builder unexpectedly accepted x86_64\n' >&2
  exit 1
fi
grep -F 'unsupported architecture: x86_64' "$TMP_ROOT/intel-tmux.log" >/dev/null
if DETACH_BUILD_ARCHS=x86_64 "$MAKE_APP" \
    >"$TMP_ROOT/intel-app.log" 2>&1; then
  printf 'app builder unexpectedly accepted x86_64\n' >&2
  exit 1
fi
grep -F 'DETACH_BUILD_ARCHS must be arm64' "$TMP_ROOT/intel-app.log" >/dev/null

grep -F 'ARCHS="${DETACH_BUILD_ARCHS:-arm64}"' "$MAKE_APP" >/dev/null
grep -F '[ "$ARCHS" = arm64 ]' "$MAKE_APP" >/dev/null
grep -F 'build_arch arm64' "$MAKE_APP" >/dev/null
grep -F '"$TMUX_BUILDER" build --arch arm64' "$MAKE_APP" >/dev/null
! grep -F 'x86_64' "$MAKE_APP" >/dev/null
! grep -F 'x86_64' "$VERIFY_APP" >/dev/null
! grep -F 'x86_64' "$BUILDER" >/dev/null
! grep -F 'lipo -create' "$MAKE_APP" >/dev/null
grep -F '"$TMUX_BUILDER" licenses --output-dir "$TMUX_THIRD_PARTY"' "$MAKE_APP" >/dev/null
grep -F -- '--identifier dev.tsarev.detach.tmux' "$MAKE_APP" >/dev/null
grep -F 'install -m 0755 "$TMUX_BINARY" "$PAYLOAD/tmux"' "$MAKE_APP" >/dev/null

# Verification is part of the packaging contract, not only a build-time
# courtesy: it checks the runnable version, provenance, linkage, signature,
# and the exact arm64-only architecture in the final bundle.
grep -F '"$TMUX_BINARY" -V' "$VERIFY_APP" >/dev/null
grep -F '"$TMUX_BINARY:$PAYLOAD/tmux:tmux"' "$VERIFY_APP" >/dev/null
grep -F 'verify_dynamic_dependencies "$system_only_binary"' "$VERIFY_APP" >/dev/null
grep -F '[ "$archs" = arm64 ]' "$VERIFY_APP" >/dev/null
grep -F 'verify_arm64_only "$arm64_binary"' "$VERIFY_APP" >/dev/null
grep -F 'codesign --verify --strict --verbose=2 "$TMUX_BINARY"' "$VERIFY_APP" >/dev/null
grep -F 'provenance.json' "$VERIFY_APP" >/dev/null

# Production runtime resolution is immutable and sibling-only. PATH lookup is
# reserved for user-owned provider CLIs and explicit DETACH_* test overrides;
# a host tmux or helper must never mask a corrupt Detach payload.
for runtime_script in "$DETACH" "$CORE"; do
  ! grep -E 'command -v (detach-state|detach-power|tmux)([[:space:]]|$)' \
    "$runtime_script" >/dev/null
done
! grep -E 'command -v tmux([[:space:]]|$)' "$INSTALLER" >/dev/null
grep -F 'STATE_BIN="${DETACH_STATE_BIN:-$SELF_DIR/detach-state}"' \
  "$DETACH" >/dev/null
grep -F 'POWER_BIN="${DETACH_POWER_BIN:-$SELF_DIR/detach-power}"' \
  "$DETACH" >/dev/null
grep -F 'TMUX_BIN="${DETACH_TMUX_BIN:-$SELF_DIR/tmux}"' "$DETACH" >/dev/null
grep -F 'STATE_BIN="${DETACH_STATE_BIN:-$SELF_DIR/detach-state}"' \
  "$CORE" >/dev/null
grep -F 'POWER_BIN="${DETACH_POWER_BIN:-$SELF_DIR/detach-power}"' \
  "$CORE" >/dev/null
grep -F 'TMUX_BIN="${DETACH_TMUX_BIN:-$SELF_DIR/tmux}"' "$CORE" >/dev/null
grep -F 'TMUX_BIN="${DETACH_TMUX_BIN:-$SCRIPT_DIR/tmux}"' \
  "$INSTALLER" >/dev/null
grep -F '  detach power status --json' "$DETACH" >/dev/null
! grep -F 'detach power status [--json]' "$DETACH" >/dev/null

# Every production entry point addresses one Detach-owned absolute socket under
# private install state. It must not inherit tmux's ambient TMUX_TMPDIR lookup.
# Tests can still isolate themselves with DETACH_TMUX_SOCKET_PATH.
for runtime_script in "$CORE" "$INSTALLER"; do
  grep -F 'DEFAULT_TMUX_SOCKET_PATH="$INSTALL_STATE_ROOT/tmux/tmux.sock"' \
    "$runtime_script" >/dev/null
  grep -F 'TMUX_SOCKET_PATH="${DETACH_TMUX_SOCKET_PATH:-$DEFAULT_TMUX_SOCKET_PATH}"' \
    "$runtime_script" >/dev/null
done
grep -F 'TMUX_CMD=("$TMUX_BIN" -S "$TMUX_SOCKET_PATH")' "$CORE" >/dev/null
grep -F 'managed_sessions_present_on path "$TMUX_SOCKET_PATH"' \
  "$INSTALLER" >/dev/null
grep -F 'LEGACY_NAMED_TMUX_SOCKET="dev.tsarev.detach"' "$INSTALLER" >/dev/null
! grep -F 'TMUX_SOCKET="${DETACH_TMUX_SOCKET' "$CORE" >/dev/null
! grep -F 'TMUX_SOCKET="${DETACH_TMUX_SOCKET' "$INSTALLER" >/dev/null

# Runtime project detection and checkpoints must never invoke Apple's Git/CLT
# shim. A real, non-symlink .git ancestor is sufficient for stable naming; the
# checkpoint records repository identity without requiring external Git.
! grep -E '(^|[[:space:]/])git([[:space:]]|$)' "$CORE" >/dev/null
grep -F 'repository-root: %s' "$CORE" >/dev/null

# Provider integrations must be opt-in against the exact bundled tmux binary,
# never whichever Homebrew/MacPorts tmux happens to be first on PATH.
for integration in "$ROOT/tests/run.sh" "$ROOT/tests/run-claude.sh"; do
  grep -F 'TMUX_TEST_BIN="${DETACH_TEST_TMUX_BIN:-}"' "$integration" >/dev/null
  ! grep -F 'TMUX_TEST_BIN="$(command -v tmux' "$integration" >/dev/null
done

# The rest of the self-contained runtime follows the same arm64-only packaging
# contract as tmux. SwiftPM emits one arm64 target triple, and the app retains
# byte-identical signed copies in the CLI payload where applicable.
for product in DetachApp DetachWatchdog detach-state detach-power detach-power-helper; do
  grep -F "\$arm_bin/$product" "$MAKE_APP" >/dev/null
done
for runtime_spec in \
  detach-state:STATE_BINARY \
  detach-power:POWER_BINARY \
  tmux:TMUX_BINARY; do
  runtime="${runtime_spec%%:*}"
  variable="${runtime_spec#*:}"
  grep -F "install -m 0755 \"\$$variable\" \"\$PAYLOAD/$runtime\"" \
    "$MAKE_APP" >/dev/null
  grep -F "\"\$$variable:\$PAYLOAD/$runtime:$runtime\"" "$VERIFY_APP" >/dev/null
done
grep -F 'cmp -s "$app_binary" "$payload_binary"' "$VERIFY_APP" >/dev/null
grep -F -- '--identifier dev.tsarev.detach.state' "$MAKE_APP" >/dev/null
grep -F -- '--identifier dev.tsarev.detach.power' "$MAKE_APP" >/dev/null
grep -F -- '--identifier dev.tsarev.detach.power-helper' "$MAKE_APP" >/dev/null
grep -F 'Contents/MacOS/DetachPowerHelper' "$VERIFY_APP" >/dev/null

# Sparkle ships as a universal binary artifact. Packaging must thin all five
# nested Mach-O files before inside-out signing, and verification must include
# both Sparkle and every nested executable in the exact-architecture pass.
[ -f "$SPARKLE_LICENSE" ]
[ "$(/usr/bin/shasum -a 256 "$SPARKLE_LICENSE" | /usr/bin/awk '{print $1}')" = \
  "$SPARKLE_LICENSE_SHA256" ]
for packaging_script in "$MAKE_APP" "$VERIFY_APP"; do
  grep -F "SPARKLE_LICENSE_SHA256=\"$SPARKLE_LICENSE_SHA256\"" \
    "$packaging_script" >/dev/null
done
grep -F 'install -m 0644 "$SPARKLE_LICENSE_SOURCE" "$SPARKLE_LICENSE"' \
  "$MAKE_APP" >/dev/null
grep -F 'cmp -s "$SPARKLE_LICENSE_SOURCE" "$SPARKLE_LICENSE"' \
  "$VERIFY_APP" >/dev/null
grep -F 'thin_sparkle_to_arm64 "$FRAMEWORKS/Sparkle.framework"' "$MAKE_APP" >/dev/null
for sparkle_path in \
  '$version_root/Sparkle' \
  '$version_root/Autoupdate' \
  '$version_root/Updater.app/Contents/MacOS/Updater' \
  '$version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer' \
  '$version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader'; do
  grep -F "$sparkle_path" "$MAKE_APP" >/dev/null
done
for packaged_binary in \
  STATE_BINARY POWER_BINARY POWER_HELPER_BINARY TMUX_BINARY \
  SPARKLE_BINARY AUTOUPDATE UPDATER_BINARY INSTALLER_BINARY DOWNLOADER_BINARY; do
  grep -F "\$$packaged_binary" "$VERIFY_APP" >/dev/null
done
! grep -F 'DETACH_VERIFY_UNIVERSAL' "$MAKE_APP" >/dev/null
! grep -F 'DETACH_VERIFY_UNIVERSAL' "$VERIFY_APP" >/dev/null

# Packaging verification must never query the installed production power
# helper: status reconciliation is allowed to mutate pmset. The smoke argument
# is a parser-only usage path whose no-helper-call behavior is unit tested.
! grep -F '"$POWER_BINARY" status --json' "$VERIFY_APP" >/dev/null
grep -F 'POWER_SMOKE_ARGUMENT="__detach-packaging-smoke__"' \
  "$VERIFY_APP" >/dev/null
grep -F '"$POWER_BINARY" "$POWER_SMOKE_ARGUMENT"' "$VERIFY_APP" >/dev/null
grep -F '[ "$POWER_SMOKE_EXIT" = 2 ]' "$VERIFY_APP" >/dev/null

# The privileged listener combines the exact signing requirement with the
# audit-token-derived effective UID and current /dev/console owner. Never
# regress to a PID lookup, which is subject to reuse races.
grep -F 'connection.effectiveUserIdentifier' "$POWER_HELPER_MAIN" >/dev/null
grep -F 'PowerHelperClientAuthorizationPolicy' "$POWER_HELPER_MAIN" >/dev/null
grep -F '"/dev/console"' "$POWER_HELPER_MAIN" >/dev/null
! grep -F 'connection.processIdentifier' "$POWER_HELPER_MAIN" >/dev/null

# The opt-in hardware smoke must conservatively recognize either spelling
# emitted by pmset and reject ambiguous/malformed output before changing a
# machine that already has sleep disabled. Parser-only mode never touches XPC,
# pmset, or system power state.
parse_pmset_fixture() {
  printf '%s' "$1" | DETACH_TEST_PMSET_PARSE_ONLY=1 "$POWER_SMOKE_TEST"
}
[ "$(parse_pmset_fixture $'System-wide power settings:\n SleepDisabled 1\n')" = 1 ]
[ "$(parse_pmset_fixture $'System-wide power settings:\n disablesleep 0\n')" = 0 ]
[ "$(parse_pmset_fixture $'System-wide power settings:\n sleep 1\n')" = 0 ]
if parse_pmset_fixture $'SleepDisabled 0\ndisablesleep 1\n' >/dev/null 2>&1; then
  printf 'power smoke parser accepted duplicate disable-sleep settings\n' >&2
  exit 1
fi
if parse_pmset_fixture $'SleepDisabled maybe\n' >/dev/null 2>&1; then
  printf 'power smoke parser accepted a malformed disable-sleep value\n' >&2
  exit 1
fi

# A release may itself run inside Detach. In that case the signed real-power
# smoke must add and remove exactly one lease without disturbing the existing
# protected baseline. Only complete, internally consistent Detach-owned states
# are accepted.
classify_power_baseline() {
  DETACH_TEST_BASELINE_CLASSIFY_ONLY=1 "$POWER_SMOKE_TEST" "$@"
}
[ "$(classify_power_baseline allowed 0 false false true false false 0)" = pristine ]
[ "$(classify_power_baseline protected 1 true true true false false 1)" = protected ]
[ "$(classify_power_baseline protected 7 true true true false false 1)" = protected ]
for unsafe_baseline in \
  'allowed 0 false false true false false 1' \
  'protected 0 true true true false false 1' \
  'protected 1 false true true false false 1' \
  'protected 1 true true true true false 1' \
  'protected 1 true true true false true 1' \
  'protected nope true true true false false 1'; do
  if classify_power_baseline $unsafe_baseline >/dev/null 2>&1; then
    printf 'power smoke accepted unsafe baseline: %s\n' "$unsafe_baseline" >&2
    exit 1
  fi
done

# The immutable CLI install computes this same digest in scripts/install.sh.
# Keep the app manifest and verifier in the canonical fixed order.
grep -F "payload_id=\"\$(printf '%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n'" \
  "$MAKE_APP" >/dev/null
grep -F '"$state_hash" "$power_hash" "$tmux_hash"' "$MAKE_APP" >/dev/null
grep -F "CALCULATED_PAYLOAD_ID=\"\$(printf '%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n'" \
  "$VERIFY_APP" >/dev/null
grep -F '"$STATE_HASH" "$POWER_HASH" "$TMUX_HASH"' "$VERIFY_APP" >/dev/null
grep -F '"detach_state":"%s","detach_power":"%s","tmux":"%s"' \
  "$MAKE_APP" >/dev/null
! grep -F 'install -m 0644 "$REPO_ROOT/launchagents/' "$MAKE_APP" >/dev/null

# The privileged daemon starts after registration/boot so it can reconcile
# durable ownership even if both the client and a previous helper crashed. It
# restarts only after failure; a clean SMAppService unregister stays stopped.
[ -f "$POWER_DAEMON" ]
plutil -lint "$POWER_DAEMON" >/dev/null
[ "$(plutil -extract Label raw -o - "$POWER_DAEMON")" = \
  dev.tsarev.detach.power-helper ]
[ "$(plutil -extract BundleProgram raw -o - "$POWER_DAEMON")" = \
  Contents/MacOS/DetachPowerHelper ]
[ "$(plutil -extract 'MachServices.dev\.tsarev\.detach\.power-helper' raw -o - \
  "$POWER_DAEMON")" = true ]
[ "$(plutil -extract RunAtLoad raw -o - "$POWER_DAEMON")" = true ]
[ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$POWER_DAEMON")" = \
  false ]
[ "$(plutil -extract ThrottleInterval raw -o - "$POWER_DAEMON")" = 10 ]
[ "$(plutil -p "$POWER_DAEMON" | \
  sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | sort)" = \
  $'BundleProgram\nKeepAlive\nLabel\nMachServices\nRunAtLoad\nThrottleInterval' ]
[ "$(plutil -p "$POWER_DAEMON" | \
  sed -n '/"MachServices" => {/,/^  }/p' | grep -c '=>')" = 2 ]
[ "$(plutil -p "$POWER_DAEMON" | \
  sed -n '/"KeepAlive" => {/,/^  }/p' | grep -c '=>')" = 2 ]

# Native power protection removes every Apple Events permission and user-facing
# Amphetamine usage string from the signed bundle and watchdog metadata.
for plist in \
  "$APP_RESOURCES/Info.plist" \
  "$APP_RESOURCES/DetachWatchdog-Info.plist" \
  "$APP_RESOURCES/Detach.entitlements" \
  "$APP_RESOURCES/DetachDevelopment.entitlements" \
  "$APP_RESOURCES/DetachWatchdog.entitlements" \
  "$APP_RESOURCES/en.lproj/InfoPlist.strings" \
  "$APP_RESOURCES/ru.lproj/InfoPlist.strings"; do
  plutil -lint "$plist" >/dev/null
  ! plutil -p "$plist" | grep -F 'NSAppleEventsUsageDescription' >/dev/null
  ! plutil -p "$plist" | grep -F 'com.apple.security.automation.apple-events' >/dev/null
  ! plutil -p "$plist" | grep -Fi Amphetamine >/dev/null
done

printf 'Bundled runtime packaging contract tests passed\n'
