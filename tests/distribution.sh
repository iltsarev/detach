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
case "${1:-}" in
  print)
    case "${2:-}" in
      */dev.tsarev.detach.watchdog)
        [ "${FAKE_APP_WATCHDOG:-0}" = 1 ] && exit 0
        ;;
    esac
    exit 1
    ;;
esac
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
      @detach) printf '%s\n' 1 ;;
      @detach_pane_id) printf '%s\n' %1 ;;
    esac
    ;;
  display-message) printf '%s\n' 0 ;;
esac
SH
chmod 0755 "$TMP_ROOT/bin/fake-launchctl" "$TMP_ROOT/bin/fake-tmux"

export HOME="$TEST_HOME"
export DETACH_INSTALL_BIN_DIR="$TEST_HOME/.local/bin"
export DETACH_INSTALL_LIBEXEC_ROOT="$TEST_HOME/.local/libexec/detach"
export DETACH_STATE_ROOT="$TEST_HOME/.local/state/detach"
export DETACH_INSTALL_STATE_ROOT="$DETACH_STATE_ROOT"
export DETACH_CONFIG_ROOT="$TEST_HOME/.config/detach"
export DETACH_CODEX_STATE_ROOT="$DETACH_STATE_ROOT/codex"
export DETACH_CLAUDE_STATE_ROOT="$DETACH_STATE_ROOT/claude"
export DETACH_AMPHETAMINE_STATE_ROOT="$DETACH_STATE_ROOT/amphetamine"
export DETACH_AMPHETAMINE=0
export DETACH_AMPHETAMINE_APP_PATH="$TMP_ROOT/prerequisites/Amphetamine.app"
export DETACH_AMPHETAMINE_POWER_PROTECT_PATH="$TMP_ROOT/prerequisites/powerProtect.scpt"
export DETACH_CLI_WATCHDOG_PLIST_DEST="$TEST_HOME/Library/LaunchAgents/dev.tsarev.detach.cli-watchdog.plist"
export DETACH_LAUNCHCTL_BIN="$TMP_ROOT/bin/fake-launchctl"
export DETACH_TMUX_BIN="$TMP_ROOT/bin/fake-tmux"
export DETACH_USER_SHELL=/bin/zsh
export ZDOTDIR="$TEST_HOME"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
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

# App launches inherit a synthetic PATH that already contains ~/.local/bin.
# Shell setup must still configure every zsh startup mode and preserve a file
# that existed before Detach, including its missing final newline.
printf '%s' 'export DETACH_ZSHENV_SENTINEL=all' >"$TEST_HOME/.zshenv"
cp -p "$TEST_HOME/.zshenv" "$TMP_ROOT/zshenv.original"

payload_v1="$(make_payload v1 0.1.0)"
PATH="$DETACH_INSTALL_BIN_DIR:/usr/bin:/bin" \
  "$payload_v1/detach-install" install --source app --payload-dir "$payload_v1" \
  --version-file "$payload_v1/VERSION" --no-launch-agent

[ -L "$DETACH_INSTALL_BIN_DIR/detach" ]
[ "$("$DETACH_INSTALL_BIN_DIR/detach" __version)" = 0.1.0 ]
plutil -extract schema raw -o - "$DETACH_INSTALL_STATE_ROOT/install.json" | grep -qx 1
plutil -extract version raw -o - "$DETACH_INSTALL_STATE_ROOT/install.json" | grep -qx 0.1.0
plutil -extract source raw -o - "$DETACH_INSTALL_STATE_ROOT/install.json" | grep -qx app
grep -Fx AMPHETAMINE=1 "$DETACH_CONFIG_ROOT/config" >/dev/null
[ "$(grep -Fc '# Detach CLI PATH' "$TEST_HOME/.zshenv")" = 1 ]
[ "$(env -i HOME="$TEST_HOME" USER=detach-test LOGNAME=detach-test \
    SHELL=/bin/zsh PATH=/usr/bin:/bin /bin/zsh -lic 'command -v detach')" = \
  "$DETACH_INSTALL_BIN_DIR/detach" ]
[ "$(env -i HOME="$TEST_HOME" USER=detach-test LOGNAME=detach-test \
    SHELL=/bin/zsh PATH=/usr/bin:/bin /bin/zsh -ic 'command -v detach')" = \
  "$DETACH_INSTALL_BIN_DIR/detach" ]
zshenv_configured_sha="$(shasum -a 256 "$TEST_HOME/.zshenv" | awk '{print $1}')"
version_count="$(find "$DETACH_INSTALL_LIBEXEC_ROOT/versions" -mindepth 1 -maxdepth 1 -type d ! -name '.incoming-*' | wc -l | tr -d ' ')"
[ "$version_count" = 1 ]

# Idempotent sync reuses the immutable payload.
printf '%s\n' '# Detach settings' 'CUSTOM_SETTING=kept' 'AMPHETAMINE=0' \
  >"$DETACH_CONFIG_ROOT/config"
"$payload_v1/detach-install" install --source app --payload-dir "$payload_v1" \
  --version-file "$payload_v1/VERSION" --no-launch-agent
[ "$(find "$DETACH_INSTALL_LIBEXEC_ROOT/versions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 ]
[ "$(grep -Fc '# Detach CLI PATH' "$TEST_HOME/.zshenv")" = 1 ]
[ "$(shasum -a 256 "$TEST_HOME/.zshenv" | awk '{print $1}')" = "$zshenv_configured_sha" ]
grep -Fx AMPHETAMINE=1 "$DETACH_CONFIG_ROOT/config" >/dev/null
grep -Fx CUSTOM_SETTING=kept "$DETACH_CONFIG_ROOT/config" >/dev/null
! grep -Fx AMPHETAMINE=0 "$DETACH_CONFIG_ROOT/config" >/dev/null

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
doctor_check_index() {
  local report="$1" id="$2"
  plutil -p "$report" | awk -v wanted="$id" '
  $1 ~ /^[0-9]+$/ && $2 == "=>" && $3 == "{" { idx = $1 }
  $2 == "=>" && $3 == "\"" wanted "\"" { print idx; exit }
'
}
watchdog_index="$(doctor_check_index "$doctor_json" watchdog)"
[ -n "$watchdog_index" ]
plutil -extract "checks.$watchdog_index.required" raw -o - "$doctor_json" | grep -qx true
plutil -extract "checks.$watchdog_index.status" raw -o - "$doctor_json" | grep -qx error
for id in amphetamine_app amphetamine_power_protect; do
  prerequisite_index="$(doctor_check_index "$doctor_json" "$id")"
  [ -n "$prerequisite_index" ]
  plutil -extract "checks.$prerequisite_index.section" raw -o - "$doctor_json" | grep -qx base
  plutil -extract "checks.$prerequisite_index.required" raw -o - "$doctor_json" | grep -qx true
  plutil -extract "checks.$prerequisite_index.status" raw -o - "$doctor_json" | grep -qx error
done

# The two required prerequisite checks become healthy independently of the
# hermetic runtime override that disables real Amphetamine automation.
mkdir -p "$DETACH_AMPHETAMINE_APP_PATH"
: >"$DETACH_AMPHETAMINE_POWER_PROTECT_PATH"
prerequisites_json="$TMP_ROOT/doctor-prerequisites.json"
PATH="/usr/bin:/bin" "$DETACH_INSTALL_BIN_DIR/detach" doctor --json \
  >"$prerequisites_json" || true
for id in amphetamine_app amphetamine_power_protect; do
  prerequisite_index="$(doctor_check_index "$prerequisites_json" "$id")"
  plutil -extract "checks.$prerequisite_index.status" raw -o - \
    "$prerequisites_json" | grep -qx ok
done

# Direct CLI uninstall must not strand the app-owned SMAppService without its
# executable. Detach.app unregisters the helper before invoking the installer.
export FAKE_APP_WATCHDOG=1
if "$DETACH_INSTALL_BIN_DIR/detach" uninstall --keep-state; then
  printf 'uninstall unexpectedly ignored the app-owned watchdog\n' >&2
  exit 1
fi
[ -L "$DETACH_INSTALL_BIN_DIR/detach" ]
unset FAKE_APP_WATCHDOG

# Uninstall is all-or-nothing while a managed pane is alive.
export FAKE_TMUX_BUSY=1
if "$DETACH_INSTALL_BIN_DIR/detach" uninstall --keep-state; then
  printf 'uninstall unexpectedly accepted a live session\n' >&2
  exit 1
fi
[ -L "$DETACH_INSTALL_BIN_DIR/detach" ]
unset FAKE_TMUX_BUSY

mkdir -p "$DETACH_CODEX_STATE_ROOT/sessions/kept"
printf '%s\n' sentinel >"$DETACH_CODEX_STATE_ROOT/sessions/kept/value"
"$DETACH_INSTALL_BIN_DIR/detach" uninstall --keep-state
[ ! -e "$DETACH_INSTALL_BIN_DIR/detach" ]
cmp -s "$TMP_ROOT/zshenv.original" "$TEST_HOME/.zshenv"
[ ! -e "$DETACH_INSTALL_STATE_ROOT/shell-path" ]
grep -Fx sentinel "$DETACH_CODEX_STATE_ROOT/sessions/kept/value" >/dev/null
! grep -F 'bootout' "$LAUNCHCTL_LOG" >/dev/null

# CLI-only installation owns its portable watchdog and reloads it only when changed.
: >"$LAUNCHCTL_LOG"
rm -f "$DETACH_CONFIG_ROOT/config"
"$payload_v2/detach-install" install --source install.sh --payload-dir "$payload_v2" \
  --version-file "$payload_v2/VERSION" \
  --launch-agent-plist "$ROOT/launchagents/dev.tsarev.detach.cli-watchdog.plist"
[ -f "$DETACH_CLI_WATCHDOG_PLIST_DEST" ]
plutil -extract Label raw -o - "$DETACH_CLI_WATCHDOG_PLIST_DEST" | \
  grep -qx dev.tsarev.detach.cli-watchdog
watchdog_command="$(plutil -extract ProgramArguments.2 raw -o - "$DETACH_CLI_WATCHDOG_PLIST_DEST")"
for expected_root in \
  "DETACH_STATE_ROOT='$DETACH_STATE_ROOT'" \
  "DETACH_INSTALL_STATE_ROOT='$DETACH_INSTALL_STATE_ROOT'" \
  "DETACH_AMPHETAMINE_STATE_ROOT='$DETACH_AMPHETAMINE_STATE_ROOT'"; do
  case "$watchdog_command" in
    *"$expected_root"*) ;;
    *)
      printf 'portable watchdog did not receive %s\n' "$expected_root" >&2
      exit 1
      ;;
  esac
done
grep -Fx AMPHETAMINE=1 "$DETACH_CONFIG_ROOT/config" >/dev/null
[ "$(grep -Fc 'bootstrap' "$LAUNCHCTL_LOG")" = 1 ]
"$payload_v2/detach-install" install --source install.sh --payload-dir "$payload_v2" \
  --version-file "$payload_v2/VERSION" \
  --launch-agent-plist "$ROOT/launchagents/dev.tsarev.detach.cli-watchdog.plist"
[ "$(grep -Fc 'bootstrap' "$LAUNCHCTL_LOG")" = 1 ]
mkdir -p "$HOME/.codex"
printf '%s\n' provider-sentinel >"$HOME/.codex/must-survive"
DETACH_CODEX_STATE_ROOT="$HOME/.local/state/../../.codex" \
  "$DETACH_INSTALL_BIN_DIR/detach" uninstall --purge-state
cmp -s "$TMP_ROOT/zshenv.original" "$TEST_HOME/.zshenv"
grep -Fx provider-sentinel "$HOME/.codex/must-survive" >/dev/null
grep -F 'bootout' "$LAUNCHCTL_LOG" >/dev/null

# Exercise every supported shell adapter in isolated homes so profile ownership
# cannot leak between cases or into the developer's real shell configuration.
SHELL_CASE_HOME=""
SHELL_CASE_SHELL=""
SHELL_CASE_SHASUM_BIN=/usr/bin/shasum

shell_case_env() {
  env \
    HOME="$SHELL_CASE_HOME" USER=detach-test LOGNAME=detach-test \
    SHELL="$SHELL_CASE_SHELL" PATH=/usr/bin:/bin \
    ZDOTDIR="$SHELL_CASE_HOME" XDG_CONFIG_HOME="$SHELL_CASE_HOME/.config" \
    DETACH_USER_SHELL="$SHELL_CASE_SHELL" \
    DETACH_INSTALL_BIN_DIR="$SHELL_CASE_HOME/.local/bin" \
    DETACH_INSTALL_LIBEXEC_ROOT="$SHELL_CASE_HOME/.local/libexec/detach" \
    DETACH_STATE_ROOT="$SHELL_CASE_HOME/.local/state/detach" \
    DETACH_INSTALL_STATE_ROOT="$SHELL_CASE_HOME/.local/state/detach" \
    DETACH_CONFIG_ROOT="$SHELL_CASE_HOME/.config/detach" \
    DETACH_CODEX_STATE_ROOT="$SHELL_CASE_HOME/.local/state/detach/codex" \
    DETACH_CLAUDE_STATE_ROOT="$SHELL_CASE_HOME/.local/state/detach/claude" \
    DETACH_AMPHETAMINE_STATE_ROOT="$SHELL_CASE_HOME/.local/state/detach/amphetamine" \
    DETACH_AMPHETAMINE=0 \
    DETACH_SHASUM_BIN="$SHELL_CASE_SHASUM_BIN" \
    DETACH_CLI_WATCHDOG_PLIST_DEST="$SHELL_CASE_HOME/Library/LaunchAgents/dev.tsarev.detach.cli-watchdog.plist" \
    DETACH_LAUNCHCTL_BIN="$TMP_ROOT/bin/fake-launchctl" \
    DETACH_TMUX_BIN="$TMP_ROOT/bin/fake-tmux" \
    FAKE_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    "$@"
}

shell_case_install() {
  shell_case_env "$payload_v2/detach-install" install --source app \
    --payload-dir "$payload_v2" --version-file "$payload_v2/VERSION" \
    --no-launch-agent
}

shell_case_uninstall() {
  if [ -x "$SHELL_CASE_HOME/.local/bin/detach" ]; then
    shell_case_env "$SHELL_CASE_HOME/.local/bin/detach" uninstall --keep-state
  else
    shell_case_env "$payload_v2/detach-install" uninstall --keep-state
  fi
}

assert_single_path_marker() {
  [ "$(grep -Fc '# Detach CLI PATH' "$1")" = 1 ]
}

run_bash_profile_case() {
  local name="$1" expected="$2"
  local root="$TMP_ROOT/shell-$name"
  local original="$root/original"
  local file
  SHELL_CASE_HOME="$root/home"
  SHELL_CASE_SHELL=/bin/bash
  mkdir -p "$SHELL_CASE_HOME" "$original"
  case "$name" in
    bash-profile)
      printf '%s\n' 'export BASH_PROFILE_SENTINEL=1' >"$SHELL_CASE_HOME/.bash_profile"
      printf '%s\n' 'export BASH_LOGIN_SENTINEL=1' >"$SHELL_CASE_HOME/.bash_login"
      printf '%s\n' 'export PROFILE_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
      ;;
    bash-login)
      printf '%s\n' 'export BASH_LOGIN_SENTINEL=1' >"$SHELL_CASE_HOME/.bash_login"
      printf '%s\n' 'export PROFILE_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
      ;;
    bash-profile-fallback)
      printf '%s\n' 'export PROFILE_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
      ;;
  esac
  printf '%s\n' 'export BASHRC_SENTINEL=1' >"$SHELL_CASE_HOME/.bashrc"
  for file in .bash_profile .bash_login .profile .bashrc; do
    [ ! -f "$SHELL_CASE_HOME/$file" ] || cp -p "$SHELL_CASE_HOME/$file" "$original/$file"
  done

  shell_case_install >/dev/null
  assert_single_path_marker "$SHELL_CASE_HOME/$expected"
  assert_single_path_marker "$SHELL_CASE_HOME/.bashrc"
  for file in .bash_profile .bash_login .profile; do
    if [ "$file" != "$expected" ] && [ -f "$SHELL_CASE_HOME/$file" ]; then
      ! grep -F '# Detach CLI PATH' "$SHELL_CASE_HOME/$file" >/dev/null
    fi
  done
  [ "$(env -i HOME="$SHELL_CASE_HOME" USER=detach-test LOGNAME=detach-test \
      SHELL=/bin/bash PATH=/usr/bin:/bin /bin/bash -lc 'command -v detach')" = \
    "$SHELL_CASE_HOME/.local/bin/detach" ]
  [ "$(env -i HOME="$SHELL_CASE_HOME" USER=detach-test LOGNAME=detach-test \
      SHELL=/bin/bash PATH=/usr/bin:/bin /bin/bash -ic 'command -v detach')" = \
    "$SHELL_CASE_HOME/.local/bin/detach" ]

  shell_case_uninstall >/dev/null
  for file in .bash_profile .bash_login .profile .bashrc; do
    if [ -f "$original/$file" ]; then
      cmp -s "$original/$file" "$SHELL_CASE_HOME/$file"
    else
      [ ! -e "$SHELL_CASE_HOME/$file" ]
    fi
  done
}

run_bash_profile_case bash-profile .bash_profile
run_bash_profile_case bash-login .bash_login
run_bash_profile_case bash-profile-fallback .profile

# POSIX sh-family shells use .profile and restore it byte-for-byte.
SHELL_CASE_HOME="$TMP_ROOT/shell-sh/home"
SHELL_CASE_SHELL=/bin/sh
mkdir -p "$SHELL_CASE_HOME"
printf '%s' 'export SH_PROFILE_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
cp -p "$SHELL_CASE_HOME/.profile" "$TMP_ROOT/sh-profile.original"
shell_case_install >/dev/null
assert_single_path_marker "$SHELL_CASE_HOME/.profile"
[ "$(env -i HOME="$SHELL_CASE_HOME" USER=detach-test LOGNAME=detach-test \
    SHELL=/bin/sh PATH=/usr/bin:/bin /bin/sh -lc 'command -v detach')" = \
  "$SHELL_CASE_HOME/.local/bin/detach" ]
shell_case_uninstall >/dev/null
cmp -s "$TMP_ROOT/sh-profile.original" "$SHELL_CASE_HOME/.profile"

# A hash failure while staging the first managed profile must be atomic: no
# profile marker, ownership state, or public CLI may become visible. A normal
# retry must still install and uninstall back to the exact original bytes.
cat >"$TMP_ROOT/bin/fail-staged-profile-shasum" <<'SH'
#!/bin/bash
last="${!#}"
case "$last" in
  */.detach-profile.*)
    printf '%s\n' 'injected staged-profile hash failure' >&2
    exit 1
    ;;
esac
exec /usr/bin/shasum "$@"
SH
chmod 0755 "$TMP_ROOT/bin/fail-staged-profile-shasum"

SHELL_CASE_HOME="$TMP_ROOT/shell-staged-profile-hash-failure/home"
SHELL_CASE_SHELL=/bin/sh
SHELL_CASE_SHASUM_BIN="$TMP_ROOT/bin/fail-staged-profile-shasum"
mkdir -p "$SHELL_CASE_HOME"
printf '%s' 'export HASH_FAILURE_ORIGINAL=1' >"$SHELL_CASE_HOME/.profile"
cp -p "$SHELL_CASE_HOME/.profile" "$TMP_ROOT/hash-failure-profile.original"
if shell_case_install >"$TMP_ROOT/hash-failure.stdout" \
    2>"$TMP_ROOT/hash-failure.stderr"; then
  printf 'staged-profile hash failure unexpectedly installed successfully\n' >&2
  exit 1
fi
grep -F 'cannot stage the Detach PATH entry' \
  "$TMP_ROOT/hash-failure.stderr" >/dev/null
cmp -s "$TMP_ROOT/hash-failure-profile.original" "$SHELL_CASE_HOME/.profile"
! grep -F '# Detach CLI PATH' "$SHELL_CASE_HOME/.profile" >/dev/null
[ ! -e "$SHELL_CASE_HOME/.local/state/detach/shell-path" ]
[ ! -e "$SHELL_CASE_HOME/.local/state/detach/install.json" ]
[ ! -e "$SHELL_CASE_HOME/.local/bin/detach" ]

SHELL_CASE_SHASUM_BIN=/usr/bin/shasum
shell_case_install >/dev/null
assert_single_path_marker "$SHELL_CASE_HOME/.profile"
[ -L "$SHELL_CASE_HOME/.local/bin/detach" ]
shell_case_uninstall >/dev/null
cmp -s "$TMP_ROOT/hash-failure-profile.original" "$SHELL_CASE_HOME/.profile"
[ ! -e "$SHELL_CASE_HOME/.local/state/detach/shell-path" ]
[ ! -e "$SHELL_CASE_HOME/.local/bin/detach" ]

# If a user edits an owned profile after installation, cleanup removes only the
# exact Detach line and preserves both the pre-existing and newly added text.
SHELL_CASE_HOME="$TMP_ROOT/shell-user-edited-profile/home"
SHELL_CASE_SHELL=/bin/sh
mkdir -p "$SHELL_CASE_HOME"
printf '%s\n' 'export ORIGINAL_PROFILE_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
shell_case_install >/dev/null
assert_single_path_marker "$SHELL_CASE_HOME/.profile"
printf '%s\n' 'export USER_ADDED_AFTER_INSTALL=1' >>"$SHELL_CASE_HOME/.profile"
shell_case_uninstall >/dev/null
printf '%s\n' \
  'export ORIGINAL_PROFILE_SENTINEL=1' \
  'export USER_ADDED_AFTER_INSTALL=1' >"$TMP_ROOT/user-edited-profile.expected"
cmp -s "$TMP_ROOT/user-edited-profile.expected" "$SHELL_CASE_HOME/.profile"
[ ! -e "$SHELL_CASE_HOME/.local/state/detach/shell-path" ]

# Reconstructing a lost post-install hash cannot prove the profile is
# unchanged. A repeat install must therefore disable exact restoration before
# uninstalling, so a user edit made after the first install survives.
SHELL_CASE_HOME="$TMP_ROOT/shell-missing-post-sha/home"
SHELL_CASE_SHELL=/bin/sh
mkdir -p "$SHELL_CASE_HOME"
printf '%s\n' 'export MISSING_POST_SHA_ORIGINAL=1' >"$SHELL_CASE_HOME/.profile"
shell_case_install >/dev/null
missing_post_sha_state="$SHELL_CASE_HOME/.local/state/detach/shell-path/profile"
printf '%s\n' 'export USER_EDIT_BEFORE_POST_SHA_REPAIR=1' \
  >>"$SHELL_CASE_HOME/.profile"
rm -f "$missing_post_sha_state/post-sha"

shell_case_install >/dev/null
[ -s "$missing_post_sha_state/post-sha" ]
grep -qx 0 "$missing_post_sha_state/restore-exact"
shell_case_uninstall >/dev/null
printf '%s\n' \
  'export MISSING_POST_SHA_ORIGINAL=1' \
  'export USER_EDIT_BEFORE_POST_SHA_REPAIR=1' >"$TMP_ROOT/missing-post-sha.expected"
cmp -s "$TMP_ROOT/missing-post-sha.expected" "$SHELL_CASE_HOME/.profile"
[ ! -e "$SHELL_CASE_HOME/.local/state/detach/shell-path" ]

# A managed-line format migration must revoke exact-backup restoration when the
# profile changed after the old post-install hash was recorded. Otherwise a
# later uninstall could overwrite a user's intervening edit with that backup.
SHELL_CASE_HOME="$TMP_ROOT/shell-owned-line-migration/home"
SHELL_CASE_SHELL=/bin/sh
mkdir -p "$SHELL_CASE_HOME"
printf '%s\n' 'export MIGRATION_ORIGINAL_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
shell_case_install >/dev/null
migration_state="$SHELL_CASE_HOME/.local/state/detach/shell-path/profile"
old_path_line="export PATH=\"$SHELL_CASE_HOME/.local/bin:\$PATH\" # Detach CLI PATH"
printf '%s\n' 'export MIGRATION_ORIGINAL_SENTINEL=1' "$old_path_line" \
  >"$SHELL_CASE_HOME/.profile"
printf '%s\n' "$old_path_line" >"$migration_state/line"
shasum -a 256 "$SHELL_CASE_HOME/.profile" | awk '{print $1}' \
  >"$migration_state/post-sha"
printf '%s\n' 1 >"$migration_state/restore-exact"
printf '%s\n' 'export USER_EDIT_DURING_MIGRATION=1' >>"$SHELL_CASE_HOME/.profile"

shell_case_install >/dev/null
assert_single_path_marker "$SHELL_CASE_HOME/.profile"
! grep -Fx -- "$old_path_line" "$SHELL_CASE_HOME/.profile" >/dev/null
grep -qx 0 "$migration_state/restore-exact"
shell_case_uninstall >/dev/null
printf '%s\n' \
  'export MIGRATION_ORIGINAL_SENTINEL=1' \
  'export USER_EDIT_DURING_MIGRATION=1' >"$TMP_ROOT/owned-line-migration.expected"
cmp -s "$TMP_ROOT/owned-line-migration.expected" "$SHELL_CASE_HOME/.profile"

# Simulate an interruption after a migration wrote the canonical profile and
# its new hash, but before it replaced the old owned-line metadata. Even though
# the hash matches, stale line metadata must make exact backup restore unsafe.
SHELL_CASE_HOME="$TMP_ROOT/shell-interrupted-owned-line-migration/home"
SHELL_CASE_SHELL=/bin/sh
mkdir -p "$SHELL_CASE_HOME"
printf '%s\n' 'export INTERRUPTED_MIGRATION_ORIGINAL=1' \
  >"$SHELL_CASE_HOME/.profile"
shell_case_install >/dev/null
interrupted_state="$SHELL_CASE_HOME/.local/state/detach/shell-path/profile"
canonical_path_line="$(grep -F '# Detach CLI PATH' "$SHELL_CASE_HOME/.profile")"
printf '%s\n' 'export USER_EDIT=1' >>"$SHELL_CASE_HOME/.profile"
shasum -a 256 "$SHELL_CASE_HOME/.profile" | awk '{print $1}' \
  >"$interrupted_state/post-sha"
interrupted_old_path_line="export PATH=\"$SHELL_CASE_HOME/bin:\$PATH\" # Detach CLI PATH"
printf '%s\n' "$interrupted_old_path_line" >"$interrupted_state/line"
printf '%s\n' 1 >"$interrupted_state/restore-exact"

shell_case_install >/dev/null
grep -qx 0 "$interrupted_state/restore-exact"
grep -Fx -- "$canonical_path_line" "$interrupted_state/line" >/dev/null
assert_single_path_marker "$SHELL_CASE_HOME/.profile"
shell_case_uninstall >/dev/null
printf '%s\n' \
  'export INTERRUPTED_MIGRATION_ORIGINAL=1' \
  'export USER_EDIT=1' >"$TMP_ROOT/interrupted-migration.expected"
cmp -s "$TMP_ROOT/interrupted-migration.expected" "$SHELL_CASE_HOME/.profile"

# Missing exact-restore data is corruption, so cleanup leaves both the profile
# and its ownership state untouched instead of guessing or dropping the line.
SHELL_CASE_HOME="$TMP_ROOT/shell-missing-profile-backup/home"
SHELL_CASE_SHELL=/bin/sh
mkdir -p "$SHELL_CASE_HOME"
printf '%s\n' 'export MISSING_BACKUP_SENTINEL=1' >"$SHELL_CASE_HOME/.profile"
shell_case_install >/dev/null
missing_backup_state="$SHELL_CASE_HOME/.local/state/detach/shell-path/profile"
rm -f "$missing_backup_state/backup"
cp -p "$SHELL_CASE_HOME/.profile" "$TMP_ROOT/missing-backup-profile.configured"
shell_case_uninstall >"$TMP_ROOT/missing-backup.stdout" \
  2>"$TMP_ROOT/missing-backup.stderr"
grep -F 'shell profile backup is missing or unsafe' \
  "$TMP_ROOT/missing-backup.stderr" >/dev/null
cmp -s "$TMP_ROOT/missing-backup-profile.configured" "$SHELL_CASE_HOME/.profile"
assert_single_path_marker "$SHELL_CASE_HOME/.profile"
[ -d "$missing_backup_state" ]

# csh/tcsh share the .login + .cshrc adapter. Exercise each binary available on
# the host, including an actual interactive lookup through the generated line.
for c_shell in /bin/csh /bin/tcsh; do
  [ -x "$c_shell" ] || continue
  c_name="$(basename "$c_shell")"
  SHELL_CASE_HOME="$TMP_ROOT/shell-$c_name/home"
  SHELL_CASE_SHELL="$c_shell"
  mkdir -p "$SHELL_CASE_HOME"
  printf '%s\n' 'setenv DETACH_LOGIN_SENTINEL 1' >"$SHELL_CASE_HOME/.login"
  printf '%s\n' 'setenv DETACH_CSHRC_SENTINEL 1' >"$SHELL_CASE_HOME/.cshrc"
  cp -p "$SHELL_CASE_HOME/.login" "$TMP_ROOT/$c_name-login.original"
  cp -p "$SHELL_CASE_HOME/.cshrc" "$TMP_ROOT/$c_name-cshrc.original"
  shell_case_install >/dev/null
  assert_single_path_marker "$SHELL_CASE_HOME/.login"
  assert_single_path_marker "$SHELL_CASE_HOME/.cshrc"
  [ "$(env -i HOME="$SHELL_CASE_HOME" USER=detach-test LOGNAME=detach-test \
      SHELL="$c_shell" PATH="$SHELL_CASE_HOME/.local/bin-shadow:/usr/bin:/bin" \
      "$c_shell" -ic 'which detach' 2>/dev/null)" = \
    "$SHELL_CASE_HOME/.local/bin/detach" ]
  shell_case_uninstall >/dev/null
  cmp -s "$TMP_ROOT/$c_name-login.original" "$SHELL_CASE_HOME/.login"
  cmp -s "$TMP_ROOT/$c_name-cshrc.original" "$SHELL_CASE_HOME/.cshrc"
done

# Fish is not part of a stock macOS install. Its generated conf.d fragment is
# still covered as an exact fixture, and is executed as well when fish exists.
SHELL_CASE_HOME="$TMP_ROOT/shell-fish/home"
SHELL_CASE_SHELL=/opt/homebrew/bin/fish
mkdir -p "$SHELL_CASE_HOME"
shell_case_install >/dev/null
fish_profile="$SHELL_CASE_HOME/.config/fish/conf.d/detach.fish"
expected_fish_line="contains -- '$SHELL_CASE_HOME/.local/bin' \$PATH; or set -gx PATH '$SHELL_CASE_HOME/.local/bin' \$PATH # Detach CLI PATH"
grep -Fx -- "$expected_fish_line" "$fish_profile" >/dev/null
if command -v fish >/dev/null 2>&1; then
  fish_bin="$(command -v fish)"
  [ "$(env -i HOME="$SHELL_CASE_HOME" USER=detach-test LOGNAME=detach-test \
      SHELL="$fish_bin" PATH=/usr/bin:/bin "$fish_bin" -ic 'command -s detach')" = \
    "$SHELL_CASE_HOME/.local/bin/detach" ]
fi
shell_case_uninstall >/dev/null
[ ! -e "$fish_profile" ]

# Unsupported shells fail explicitly and do not touch any startup profile.
SHELL_CASE_HOME="$TMP_ROOT/shell-unsupported/home"
SHELL_CASE_SHELL=/bin/unsupported-shell
mkdir -p "$SHELL_CASE_HOME"
printf '%s' 'unsupported-shell-sentinel' >"$SHELL_CASE_HOME/.profile"
cp -p "$SHELL_CASE_HOME/.profile" "$TMP_ROOT/unsupported-profile.original"
if shell_case_install >"$TMP_ROOT/unsupported-shell.stdout" \
    2>"$TMP_ROOT/unsupported-shell.stderr"; then
  printf 'unsupported shell unexpectedly installed successfully\n' >&2
  exit 1
fi
grep -F 'unsupported login shell' "$TMP_ROOT/unsupported-shell.stderr" >/dev/null
cmp -s "$TMP_ROOT/unsupported-profile.original" "$SHELL_CASE_HOME/.profile"
! grep -F '# Detach CLI PATH' "$SHELL_CASE_HOME/.profile" >/dev/null
shell_case_uninstall >/dev/null

# A startup-file symlink is accepted only when its target remains inside HOME.
SHELL_CASE_HOME="$TMP_ROOT/shell-internal-symlink/home"
SHELL_CASE_SHELL=/bin/zsh
mkdir -p "$SHELL_CASE_HOME/profiles"
printf '%s' 'internal-symlink-sentinel' >"$SHELL_CASE_HOME/profiles/zshenv"
cp -p "$SHELL_CASE_HOME/profiles/zshenv" "$TMP_ROOT/internal-zshenv.original"
ln -s profiles/zshenv "$SHELL_CASE_HOME/.zshenv"
shell_case_install >/dev/null
[ -L "$SHELL_CASE_HOME/.zshenv" ]
assert_single_path_marker "$SHELL_CASE_HOME/profiles/zshenv"
shell_case_uninstall >/dev/null
[ -L "$SHELL_CASE_HOME/.zshenv" ]
cmp -s "$TMP_ROOT/internal-zshenv.original" "$SHELL_CASE_HOME/profiles/zshenv"

SHELL_CASE_HOME="$TMP_ROOT/shell-external-symlink/home"
SHELL_CASE_SHELL=/bin/zsh
mkdir -p "$SHELL_CASE_HOME"
printf '%s' 'external-symlink-sentinel' >"$TMP_ROOT/external-zshenv"
cp -p "$TMP_ROOT/external-zshenv" "$TMP_ROOT/external-zshenv.original"
ln -s "$TMP_ROOT/external-zshenv" "$SHELL_CASE_HOME/.zshenv"
if shell_case_install >"$TMP_ROOT/external-symlink.stdout" \
    2>"$TMP_ROOT/external-symlink.stderr"; then
  printf 'external shell-profile symlink unexpectedly accepted\n' >&2
  exit 1
fi
grep -F 'refusing unsafe shell profile' "$TMP_ROOT/external-symlink.stderr" >/dev/null
cmp -s "$TMP_ROOT/external-zshenv.original" "$TMP_ROOT/external-zshenv"
shell_case_uninstall >/dev/null

# A symlinked ancestor must not redirect a generated fish fragment outside HOME.
SHELL_CASE_HOME="$TMP_ROOT/shell-external-ancestor/home"
SHELL_CASE_SHELL=/opt/homebrew/bin/fish
mkdir -p "$SHELL_CASE_HOME" "$TMP_ROOT/external-fish-config"
ln -s "$TMP_ROOT/external-fish-config" "$SHELL_CASE_HOME/.config"
if shell_case_install >"$TMP_ROOT/external-ancestor.stdout" \
    2>"$TMP_ROOT/external-ancestor.stderr"; then
  printf 'external shell-profile ancestor unexpectedly accepted\n' >&2
  exit 1
fi
grep -F 'refusing unsafe shell profile' "$TMP_ROOT/external-ancestor.stderr" >/dev/null
[ ! -e "$TMP_ROOT/external-fish-config/fish/conf.d/detach.fish" ]
shell_case_uninstall >/dev/null

! rg -n '<string>/Users/[^<]+/' "$ROOT/launchagents/dev.tsarev.detach.cli-watchdog.plist" >/dev/null
plutil -lint "$ROOT/launchagents/dev.tsarev.detach.cli-watchdog.plist" >/dev/null

printf 'Detach distribution tests passed\n'
