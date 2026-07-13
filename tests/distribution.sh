#!/bin/bash

set -eu
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-distribution-test.XXXXXX")"
TEST_HOME="$TMP_ROOT/home"
PAYLOADS="$TMP_ROOT/payloads"
LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$PAYLOADS" "$TMP_ROOT/bin"

cat >"$TMP_ROOT/bin/fake-launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
case "${1:-}" in print) exit 1 ;; esac
exit 0
SH

cat >"$TMP_ROOT/bin/fake-tmux" <<'SH'
#!/bin/bash
case "${1:-}" in
  list-sessions)
    [ "${FAKE_TMUX_BUSY:-0}" = 1 ] && printf '%s\n' detach-test
    ;;
  show-options)
    case "${*: -1}" in
      @codex_detached) printf '%s\n' 1 ;;
      @codex_detached_pane_id) printf '%s\n' %1 ;;
    esac
    ;;
  display-message) printf '%s\n' 0 ;;
esac
SH
chmod 0755 "$TMP_ROOT/bin/fake-launchctl" "$TMP_ROOT/bin/fake-tmux"

export HOME="$TEST_HOME"
export DETACH_INSTALL_BIN_DIR="$TEST_HOME/.local/bin"
export DETACH_INSTALL_LIBEXEC_ROOT="$TEST_HOME/.local/libexec/detach"
export DETACH_INSTALL_STATE_ROOT="$TEST_HOME/.local/state/detach"
export DETACH_CONFIG_ROOT="$TEST_HOME/.config/detach"
export CODEX_DETACHED_STATE_ROOT="$TEST_HOME/.local/state/codex-detached"
export CLAUDE_DETACHED_STATE_ROOT="$TEST_HOME/.local/state/claude-detached"
export DETACH_AMPHETAMINE_STATE_ROOT="$TEST_HOME/.local/state/codex-detached-amphetamine"
export DETACH_LEGACY_PLIST_DEST="$TEST_HOME/Library/LaunchAgents/dev.tsarev.codex-detached-watchdog.plist"
export DETACH_LAUNCHCTL_BIN="$TMP_ROOT/bin/fake-launchctl"
export DETACH_TMUX_BIN="$TMP_ROOT/bin/fake-tmux"
export FAKE_LAUNCHCTL_LOG="$LAUNCHCTL_LOG"

make_payload() {
  local name="$1"
  local version="$2"
  local build="${3:-1}"
  local dir="$PAYLOADS/$name"
  mkdir -p "$dir"
  install -m 0755 "$ROOT/bin/detach" "$ROOT/bin/detach-core" "$dir/"
  install -m 0755 "$ROOT/scripts/install.sh" "$dir/detach-install"
  printf '%s\n' "$version" >"$dir/VERSION"
  printf '%s\n' "$build" >"$dir/BUILD"
  printf '%s\n' "$dir"
}

payload_v1="$(make_payload v1 0.1.0)"
"$payload_v1/detach-install" install --source app --payload-dir "$payload_v1" \
  --version-file "$payload_v1/VERSION" --no-launch-agent

[ -L "$DETACH_INSTALL_BIN_DIR/detach" ]
[ "$("$DETACH_INSTALL_BIN_DIR/detach" __version)" = 0.1.0 ]
plutil -extract schema raw -o - "$DETACH_INSTALL_STATE_ROOT/install.json" | grep -qx 1
plutil -extract version raw -o - "$DETACH_INSTALL_STATE_ROOT/install.json" | grep -qx 0.1.0
plutil -extract source raw -o - "$DETACH_INSTALL_STATE_ROOT/install.json" | grep -qx app
grep -Fx AMPHETAMINE=0 "$DETACH_CONFIG_ROOT/config" >/dev/null
version_count="$(find "$DETACH_INSTALL_LIBEXEC_ROOT/versions" -mindepth 1 -maxdepth 1 -type d ! -name '.incoming-*' | wc -l | tr -d ' ')"
[ "$version_count" = 1 ]

# Idempotent sync reuses the immutable payload.
"$payload_v1/detach-install" install --source app --payload-dir "$payload_v1" \
  --version-file "$payload_v1/VERSION" --no-launch-agent
[ "$(find "$DETACH_INSTALL_LIBEXEC_ROOT/versions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 ]

# A malformed payload fails before the public symlink changes.
old_target="$(readlink "$DETACH_INSTALL_BIN_DIR/detach")"
bad_payload="$(make_payload bad 0.2.0)"
chmod 0644 "$bad_payload/detach-core"
if "$bad_payload/detach-install" install --source app --payload-dir "$bad_payload" \
    --version-file "$bad_payload/VERSION" --no-launch-agent; then
  printf 'invalid payload unexpectedly installed\n' >&2
  exit 1
fi
[ "$(readlink "$DETACH_INSTALL_BIN_DIR/detach")" = "$old_target" ]

# A newer payload installs alongside v1; the old immutable directory remains.
payload_v2="$(make_payload v2 0.2.0)"
"$payload_v2/detach-install" install --source app --payload-dir "$payload_v2" \
  --version-file "$payload_v2/VERSION" --no-launch-agent
[ "$("$DETACH_INSTALL_BIN_DIR/detach" __version)" = 0.2.0 ]
[ -d "$(dirname "$old_target")" ]

# Repair must restore from the pristine source recorded in the manifest, not
# clone corrupted bytes from the active immutable directory.
active_dir="$(dirname "$(readlink "$DETACH_INSTALL_BIN_DIR/detach")")"
printf '\n# corruption\n' >>"$active_dir/detach-core"
PATH="$DETACH_INSTALL_BIN_DIR:/usr/bin:/bin" \
  "$DETACH_INSTALL_BIN_DIR/detach" doctor --json >"$TMP_ROOT/corrupt-doctor.json" || true
plutil -extract checks.0.status raw -o - "$TMP_ROOT/corrupt-doctor.json" | grep -qx error
"$DETACH_INSTALL_BIN_DIR/detach" repair
[ "$(shasum -a 256 "$active_dir/detach-core" | awk '{print $1}')" = \
  "$(shasum -a 256 "$payload_v2/detach-core" | awk '{print $1}')" ]

# BUILD participates in downgrade prevention even when semver is unchanged.
payload_v2_build2="$(make_payload v2-build2 0.2.0 2)"
"$payload_v2_build2/detach-install" install --source app --payload-dir "$payload_v2_build2" \
  --version-file "$payload_v2_build2/VERSION" --no-launch-agent
[ "$(<"$(dirname "$(readlink "$DETACH_INSTALL_BIN_DIR/detach")")/BUILD")" = 2 ]
"$payload_v2/detach-install" install --source app --payload-dir "$payload_v2" \
  --version-file "$payload_v2/VERSION" --no-launch-agent
[ "$(<"$(dirname "$(readlink "$DETACH_INSTALL_BIN_DIR/detach")")/BUILD")" = 2 ]

# A stale app payload must never downgrade a newer CLI.
payload_old="$(make_payload old 0.1.5)"
"$payload_old/detach-install" install --source app --payload-dir "$payload_old" \
  --version-file "$payload_old/VERSION" --no-launch-agent
[ "$("$DETACH_INSTALL_BIN_DIR/detach" __version)" = 0.2.0 ]

# doctor remains machine-readable even when dependencies and watchdog are absent.
doctor_json="$TMP_ROOT/doctor.json"
PATH="/usr/bin:/bin" "$DETACH_INSTALL_BIN_DIR/detach" doctor --json >"$doctor_json" || true
plutil -extract schema raw -o - "$doctor_json" | grep -qx 1
plutil -extract checks.1.id raw -o - "$doctor_json" | grep -qx cli

# Uninstall is all-or-nothing while a managed pane is alive.
export FAKE_TMUX_BUSY=1
if "$DETACH_INSTALL_BIN_DIR/detach" uninstall --keep-state; then
  printf 'uninstall unexpectedly accepted a live session\n' >&2
  exit 1
fi
[ -L "$DETACH_INSTALL_BIN_DIR/detach" ]
unset FAKE_TMUX_BUSY

mkdir -p "$CODEX_DETACHED_STATE_ROOT/sessions/kept"
printf '%s\n' sentinel >"$CODEX_DETACHED_STATE_ROOT/sessions/kept/value"
"$DETACH_INSTALL_BIN_DIR/detach" uninstall --keep-state
[ ! -e "$DETACH_INSTALL_BIN_DIR/detach" ]
grep -Fx sentinel "$CODEX_DETACHED_STATE_ROOT/sessions/kept/value" >/dev/null
! grep -F 'bootout' "$LAUNCHCTL_LOG" >/dev/null

# CLI-only installation owns a portable legacy plist and reloads it only when changed.
: >"$LAUNCHCTL_LOG"
rm -f "$DETACH_CONFIG_ROOT/config"
"$payload_v2/detach-install" install --source install.sh --payload-dir "$payload_v2" \
  --version-file "$payload_v2/VERSION" \
  --launch-agent-plist "$ROOT/launchagents/dev.tsarev.codex-detached-watchdog.plist"
[ -f "$DETACH_LEGACY_PLIST_DEST" ]
grep -Fx AMPHETAMINE=1 "$DETACH_CONFIG_ROOT/config" >/dev/null # preserve legacy default
[ "$(grep -Fc 'bootstrap' "$LAUNCHCTL_LOG")" = 1 ]
"$payload_v2/detach-install" install --source install.sh --payload-dir "$payload_v2" \
  --version-file "$payload_v2/VERSION" \
  --launch-agent-plist "$ROOT/launchagents/dev.tsarev.codex-detached-watchdog.plist"
[ "$(grep -Fc 'bootstrap' "$LAUNCHCTL_LOG")" = 1 ]
mkdir -p "$HOME/.codex"
printf '%s\n' provider-sentinel >"$HOME/.codex/must-survive"
CODEX_DETACHED_STATE_ROOT="$HOME/.local/state/../../.codex" \
  "$DETACH_INSTALL_BIN_DIR/detach" uninstall --purge-state
grep -Fx provider-sentinel "$HOME/.codex/must-survive" >/dev/null
grep -F 'bootout' "$LAUNCHCTL_LOG" >/dev/null

! rg -n '<string>/Users/[^<]+/' "$ROOT/launchagents/dev.tsarev.codex-detached-watchdog.plist" >/dev/null
plutil -lint "$ROOT/launchagents/dev.tsarev.codex-detached-watchdog.plist" >/dev/null

printf 'Detach distribution tests passed\n'
