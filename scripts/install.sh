#!/bin/bash

set -u
set -o pipefail

umask 077
export LC_ALL=C

PROGRAM="detach installer"
SELF="$0"
SCRIPT_DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)" || exit 1
SELF="$SCRIPT_DIR/$(basename "$SELF")"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)" || exit 1

INSTALL_BIN="${DETACH_INSTALL_BIN:-/usr/bin/install}"
LOCKF_BIN="${DETACH_LOCKF_BIN:-/usr/bin/lockf}"
MV_BIN="${DETACH_MV_BIN:-/bin/mv}"
RM_BIN="${DETACH_RM_BIN:-/bin/rm}"
LN_BIN="${DETACH_LN_BIN:-/bin/ln}"
MKDIR_BIN="${DETACH_MKDIR_BIN:-/bin/mkdir}"
SHASUM_BIN="${DETACH_SHASUM_BIN:-/usr/bin/shasum}"
XATTR_BIN="${DETACH_XATTR_BIN:-/usr/bin/xattr}"
LAUNCHCTL_BIN="${DETACH_LAUNCHCTL_BIN:-/bin/launchctl}"
PLUTIL_BIN="${DETACH_PLUTIL_BIN:-/usr/bin/plutil}"
TMUX_BIN="${DETACH_TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"

BIN_DIR="${DETACH_INSTALL_BIN_DIR:-$HOME/.local/bin}"
LIBEXEC_ROOT="${DETACH_INSTALL_LIBEXEC_ROOT:-$HOME/.local/libexec/detach}"
STATE_ROOT="${DETACH_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/detach}"
INSTALL_STATE_ROOT="${DETACH_INSTALL_STATE_ROOT:-$STATE_ROOT}"
CONFIG_ROOT="${DETACH_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/detach}"
CODEX_STATE_ROOT="${DETACH_CODEX_STATE_ROOT:-$STATE_ROOT/codex}"
CLAUDE_STATE_ROOT="${DETACH_CLAUDE_STATE_ROOT:-$STATE_ROOT/claude}"
AMPHETAMINE_ROOT="${DETACH_AMPHETAMINE_STATE_ROOT:-$STATE_ROOT/amphetamine}"
CLI_WATCHDOG_PLIST_DEST="${DETACH_CLI_WATCHDOG_PLIST_DEST:-$HOME/Library/LaunchAgents/dev.tsarev.detach.cli-watchdog.plist}"
CLI_WATCHDOG_LABEL="dev.tsarev.detach.cli-watchdog"
APP_WATCHDOG_LABEL="dev.tsarev.detach.watchdog"

error() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

die() {
  error "$*"
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage:' \
    '  install.sh install [OPTIONS]' \
    '  install.sh uninstall [--keep-state|--purge-state]' \
    '' \
    'Install options:' \
    '  --source app|install.sh|repair' \
    '  --payload-dir DIR' \
    '  --version-file FILE' \
    '  --launch-agent-plist FILE' \
    '  --no-launch-agent' \
    '  --allow-downgrade' \
    '  --repair'
}

require_executable() {
  [ -n "$1" ] && [ -x "$1" ] || die "$2 is required: ${1:-not found}"
}

json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

resolve_path() {
  local source_path="$1"
  local source_dir link_target

  while [ -h "$source_path" ]; do
    source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)" || return 1
    link_target="$(readlink "$source_path")" || return 1
    case "$link_target" in
      /*) source_path="$link_target" ;;
      *) source_path="$source_dir/$link_target" ;;
    esac
  done
  source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)" || return 1
  printf '%s/%s\n' "$source_dir" "$(basename "$source_path")"
}

validate_managed_paths() {
  local path
  for path in "$BIN_DIR" "$LIBEXEC_ROOT" "$INSTALL_STATE_ROOT" "$CONFIG_ROOT" \
              "$CLI_WATCHDOG_PLIST_DEST"; do
    case "$path" in
      /*) ;;
      *) die "managed path must be absolute: $path" ;;
    esac
    case "$path" in
      /|/bin|/usr|/usr/*|/System|/System/*|/Library|/Library/*|*/../*|*/..)
        die "refusing unsafe managed path: $path" ;;
    esac
  done
}

valid_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

# Prints -1, 0, or 1. Build metadata is deliberately ignored for precedence.
semver_compare() {
  local left="${1%%+*}"
  local right="${2%%+*}"
  local left_core="${left%%-*}"
  local right_core="${right%%-*}"
  local left_pre=""
  local right_pre=""
  local l_major l_minor l_patch r_major r_minor r_patch
  local index lpart rpart
  local -a lparts rparts

  [ "$left" = "$left_core" ] || left_pre="${left#*-}"
  [ "$right" = "$right_core" ] || right_pre="${right#*-}"
  IFS=. read -r l_major l_minor l_patch <<<"$left_core"
  IFS=. read -r r_major r_minor r_patch <<<"$right_core"

  for index in 1 2 3; do
    case "$index" in
      1) lpart="$l_major"; rpart="$r_major" ;;
      2) lpart="$l_minor"; rpart="$r_minor" ;;
      *) lpart="$l_patch"; rpart="$r_patch" ;;
    esac
    if [ "$lpart" -lt "$rpart" ]; then printf '%s\n' -1; return; fi
    if [ "$lpart" -gt "$rpart" ]; then printf '%s\n' 1; return; fi
  done

  if [ -z "$left_pre" ] && [ -z "$right_pre" ]; then printf '%s\n' 0; return; fi
  if [ -z "$left_pre" ]; then printf '%s\n' 1; return; fi
  if [ -z "$right_pre" ]; then printf '%s\n' -1; return; fi

  IFS=. read -r -a lparts <<<"$left_pre"
  IFS=. read -r -a rparts <<<"$right_pre"
  index=0
  while [ "$index" -lt "${#lparts[@]}" ] || [ "$index" -lt "${#rparts[@]}" ]; do
    if [ "$index" -ge "${#lparts[@]}" ]; then printf '%s\n' -1; return; fi
    if [ "$index" -ge "${#rparts[@]}" ]; then printf '%s\n' 1; return; fi
    lpart="${lparts[$index]}"
    rpart="${rparts[$index]}"
    if [[ "$lpart" =~ ^[0-9]+$ ]] && [[ "$rpart" =~ ^[0-9]+$ ]]; then
      if [ "$lpart" -lt "$rpart" ]; then printf '%s\n' -1; return; fi
      if [ "$lpart" -gt "$rpart" ]; then printf '%s\n' 1; return; fi
    elif [[ "$lpart" =~ ^[0-9]+$ ]]; then
      printf '%s\n' -1; return
    elif [[ "$rpart" =~ ^[0-9]+$ ]]; then
      printf '%s\n' 1; return
    else
      if [[ "$lpart" < "$rpart" ]]; then printf '%s\n' -1; return; fi
      if [[ "$lpart" > "$rpart" ]]; then printf '%s\n' 1; return; fi
    fi
    index=$((index + 1))
  done
  printf '%s\n' 0
}

sha256_file() {
  "$SHASUM_BIN" -a 256 "$1" | awk '{print $1}'
}

current_version() {
  local command="$BIN_DIR/detach"
  [ -x "$command" ] || return 1
  "$command" __version 2>/dev/null | head -n 1
}

manifest_field() {
  local key="$1"
  [ -f "$INSTALL_STATE_ROOT/install.json" ] && [ -x "$PLUTIL_BIN" ] || return 1
  "$PLUTIL_BIN" -extract "$key" raw -o - "$INSTALL_STATE_ROOT/install.json" 2>/dev/null
}

active_payload_dir() {
  local resolved versions_root
  [ -L "$BIN_DIR/detach" ] || return 1
  resolved="$(resolve_path "$BIN_DIR/detach" 2>/dev/null)" || return 1
  versions_root="$(cd -P "$LIBEXEC_ROOT/versions" 2>/dev/null && pwd)" || return 1
  case "$resolved" in
    "$versions_root"/*/detach) dirname "$resolved" ;;
    *) return 1 ;;
  esac
}

managed_sessions_running_on() {
  local socket="$1" config="$2"
  local session pane dead managed output
  local command=("$TMUX_BIN")
  [ -z "$socket" ] || command+=( -L "$socket" )
  [ -z "$config" ] || command+=( -f "$config" )

  if ! output="$("${command[@]}" list-sessions -F '#{session_name}' 2>&1)"; then
    case "$output" in
      ''|*'no server running'*|*'No such file or directory'*) return 1 ;;
      *) die "cannot inspect tmux sessions safely: $output" ;;
    esac
  fi
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    managed="$("${command[@]}" show-options -qv -t "=$session:" @detach 2>/dev/null || true)"
    [ "$managed" = "1" ] || continue
    pane="$("${command[@]}" show-options -qv -t "=$session:" @detach_pane_id 2>/dev/null || true)"
    [ -n "$pane" ] || return 0
    dead="$("${command[@]}" display-message -p -t "$pane" '#{pane_dead}' 2>/dev/null || true)"
    [ "$dead" = "1" ] || return 0
  done <<<"$output"
  return 1
}

managed_sessions_running() {
  require_executable "$TMUX_BIN" tmux
  managed_sessions_running_on "${DETACH_TMUX_SOCKET:-}" "${DETACH_TMUX_CONFIG:-}"
}

write_manifest() {
  local version="$1"
  local build="$2"
  local payload_id="$3"
  local source="$4"
  local target="$5"
  local payload_source="$6"
  local source_version_file="$7"
  local installer_source="$8"
  local tmp="$INSTALL_STATE_ROOT/install.json.tmp.$$"
  local installed_at
  installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  printf '{"schema":1,"version":"%s","build":"%s","payload_id":"%s","source":"%s","installed_at":"%s","executable_path":"%s","payload_source_path":"%s","version_file_path":"%s","installer_source_path":"%s","config_root":"%s","amphetamine_state_root":"%s"}\n' \
    "$(json_escape "$version")" "$(json_escape "$build")" \
    "$(json_escape "$payload_id")" "$(json_escape "$source")" \
    "$installed_at" "$(json_escape "$target/detach")" \
    "$(json_escape "$payload_source")" "$(json_escape "$source_version_file")" \
    "$(json_escape "$installer_source")" \
    "$(json_escape "$CONFIG_ROOT")" "$(json_escape "$AMPHETAMINE_ROOT")" >"$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  "$MV_BIN" -f "$tmp" "$INSTALL_STATE_ROOT/install.json"
}

write_required_config() {
  local config="$CONFIG_ROOT/config"
  local tmp="$CONFIG_ROOT/config.tmp.$$"
  local line found=0
  "$MKDIR_BIN" -p "$CONFIG_ROOT" || return 1
  chmod 0700 "$CONFIG_ROOT" || return 1
  if [ -e "$config" ]; then
    [ -f "$config" ] && [ ! -L "$config" ] || return 1
    : >"$tmp" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        AMPHETAMINE=*)
          if [ "$found" -eq 0 ]; then
            printf '%s\n' 'AMPHETAMINE=1' >>"$tmp" || return 1
            found=1
          fi
          ;;
        *) printf '%s\n' "$line" >>"$tmp" || return 1 ;;
      esac
    done <"$config"
    [ "$found" -eq 1 ] || printf '%s\n' 'AMPHETAMINE=1' >>"$tmp" || return 1
  else
    printf '%s\n' \
      '# Detach settings. Environment variables override these values.' \
      'AMPHETAMINE=1' >"$tmp" || return 1
  fi
  chmod 0600 "$tmp" || return 1
  "$MV_BIN" -f "$tmp" "$config"
}

install_cli_watchdog() {
  local source_plist="$1"
  local destination_dir
  local rendered="$INSTALL_STATE_ROOT/watchdog.plist.tmp.$$"
  local destination_tmp backup
  local command
  [ -f "$source_plist" ] || die "LaunchAgent plist not found: $source_plist"
  require_executable "$PLUTIL_BIN" plutil
  destination_dir="$(dirname "$CLI_WATCHDOG_PLIST_DEST")"
  "$INSTALL_BIN" -d -m 0755 "$destination_dir" || die "cannot create $destination_dir"
  "$INSTALL_BIN" -m 0600 "$source_plist" "$rendered" || die "cannot render LaunchAgent"
  command="/bin/mkdir -p $(shell_quote "$AMPHETAMINE_ROOT") && exec /usr/bin/env DETACH_CONFIG_ROOT=$(shell_quote "$CONFIG_ROOT") DETACH_STATE_ROOT=$(shell_quote "$STATE_ROOT") DETACH_INSTALL_STATE_ROOT=$(shell_quote "$INSTALL_STATE_ROOT") DETACH_AMPHETAMINE_STATE_ROOT=$(shell_quote "$AMPHETAMINE_ROOT") $(shell_quote "$BIN_DIR/detach") __reconcile_amphetamine >>$(shell_quote "$AMPHETAMINE_ROOT/watchdog.log") 2>&1"
  "$PLUTIL_BIN" -replace ProgramArguments.2 -string "$command" "$rendered" || \
    die "cannot set LaunchAgent command"
  "$PLUTIL_BIN" -lint "$rendered" >/dev/null || die "rendered LaunchAgent is invalid"

  if [ -f "$CLI_WATCHDOG_PLIST_DEST" ] && cmp -s "$rendered" "$CLI_WATCHDOG_PLIST_DEST"; then
    "$RM_BIN" -f "$rendered"
    return 0
  fi
  destination_tmp="$CLI_WATCHDOG_PLIST_DEST.tmp.$$"
  backup="$INSTALL_STATE_ROOT/watchdog.plist.backup.$$"
  "$RM_BIN" -f "$destination_tmp" "$backup"
  if [ -f "$CLI_WATCHDOG_PLIST_DEST" ]; then
    "$INSTALL_BIN" -m 0644 "$CLI_WATCHDOG_PLIST_DEST" "$backup" || die "cannot back up LaunchAgent"
  fi
  "$INSTALL_BIN" -m 0644 "$rendered" "$destination_tmp" || die "cannot stage LaunchAgent"
  "$LAUNCHCTL_BIN" bootout "gui/$(id -u)/$CLI_WATCHDOG_LABEL" >/dev/null 2>&1 || true
  "$MV_BIN" -f "$destination_tmp" "$CLI_WATCHDOG_PLIST_DEST" || die "cannot install LaunchAgent"
  "$RM_BIN" -f "$rendered"
  if ! "$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$CLI_WATCHDOG_PLIST_DEST"; then
    if [ -f "$backup" ]; then
      "$MV_BIN" -f "$backup" "$CLI_WATCHDOG_PLIST_DEST" || true
      "$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$CLI_WATCHDOG_PLIST_DEST" >/dev/null 2>&1 || true
    else
      "$RM_BIN" -f "$CLI_WATCHDOG_PLIST_DEST"
    fi
    die "cannot register LaunchAgent; previous definition was restored"
  fi
  "$RM_BIN" -f "$backup"
  "$LAUNCHCTL_BIN" kickstart -k "gui/$(id -u)/$CLI_WATCHDOG_LABEL" >/dev/null 2>&1 || true
}

install_locked() {
  local source="install.sh"
  local payload_dir=""
  local version_file=""
  local launch_agent_plist=""
  local install_launch_agent=1
  local allow_downgrade=0
  local repair=0
  local version build detach_hash core_hash installer_hash payload_id target
  local installed_version installed_build installed_payload comparison stage link_tmp current
  local active_dir manifest_version manifest_build manifest_payload manifest_executable

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        source="$2"; shift 2 ;;
      --payload-dir)
        [ "$#" -ge 2 ] || die "$1 requires a directory"
        payload_dir="$2"; shift 2 ;;
      --version-file)
        [ "$#" -ge 2 ] || die "$1 requires a file"
        version_file="$2"; shift 2 ;;
      --launch-agent-plist)
        [ "$#" -ge 2 ] || die "$1 requires a file"
        launch_agent_plist="$2"; shift 2 ;;
      --no-launch-agent) install_launch_agent=0; shift ;;
      --allow-downgrade) allow_downgrade=1; shift ;;
      --repair) repair=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown install option: $1" ;;
    esac
  done

  case "$source" in app|install.sh|repair) ;; *) die "invalid install source: $source" ;; esac
  if [ -z "$payload_dir" ]; then
    if [ -x "$SCRIPT_DIR/detach" ]; then payload_dir="$SCRIPT_DIR"; else payload_dir="$REPO_ROOT/bin"; fi
  fi
  if [ -z "$version_file" ]; then
    if [ -f "$payload_dir/VERSION" ]; then version_file="$payload_dir/VERSION"; else version_file="$REPO_ROOT/VERSION"; fi
  fi
  if [ -z "$launch_agent_plist" ]; then
    if [ -f "$payload_dir/dev.tsarev.detach.cli-watchdog.plist" ]; then
      launch_agent_plist="$payload_dir/dev.tsarev.detach.cli-watchdog.plist"
    else
      launch_agent_plist="$REPO_ROOT/launchagents/dev.tsarev.detach.cli-watchdog.plist"
    fi
  fi

  require_executable "$INSTALL_BIN" install
  require_executable "$MV_BIN" mv
  require_executable "$RM_BIN" rm
  require_executable "$LN_BIN" ln
  require_executable "$SHASUM_BIN" shasum
  [ -x "$payload_dir/detach" ] || die "payload detach is missing or not executable"
  [ -x "$payload_dir/detach-core" ] || die "payload detach-core is missing or not executable"
  [ -f "$version_file" ] || die "version file not found: $version_file"

  IFS= read -r version <"$version_file" || die "cannot read version file"
  valid_semver "$version" || die "invalid release version: $version"
  build="1"
  [ ! -f "$payload_dir/BUILD" ] || IFS= read -r build <"$payload_dir/BUILD"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] || die "invalid build number: $build"

  detach_hash="$(sha256_file "$payload_dir/detach")" || die "cannot hash detach"
  core_hash="$(sha256_file "$payload_dir/detach-core")" || die "cannot hash detach-core"
  if [ -x "$payload_dir/detach-install" ]; then
    installer_hash="$(sha256_file "$payload_dir/detach-install")" || die "cannot hash installer"
  else
    installer_hash="$(sha256_file "$SELF")" || die "cannot hash installer"
  fi
  payload_id="$(printf '%s\n%s\n%s\n%s\n%s\n' "$version" "$build" "$detach_hash" "$core_hash" "$installer_hash" | "$SHASUM_BIN" -a 256 | awk '{print $1}')"
  [ "${#payload_id}" -eq 64 ] || die "cannot calculate payload id"
  target="$LIBEXEC_ROOT/versions/$version-${payload_id:0:12}"

  if [ -e "$BIN_DIR/detach" ] || [ -L "$BIN_DIR/detach" ]; then
    if [ ! -L "$BIN_DIR/detach" ]; then
      die "refusing to replace an unmanaged file: $BIN_DIR/detach"
    fi
    active_dir="$(active_payload_dir 2>/dev/null || true)"
    if [ -z "$active_dir" ]; then
      die "refusing to replace an unmanaged detach symlink: $BIN_DIR/detach"
    fi
  else
    active_dir=""
  fi

  installed_version=""
  installed_build="0"
  installed_payload=""
  if [ -n "$active_dir" ]; then
    [ ! -f "$active_dir/VERSION" ] || IFS= read -r installed_version <"$active_dir/VERSION"
    [ ! -f "$active_dir/BUILD" ] || IFS= read -r installed_build <"$active_dir/BUILD"
    [ ! -f "$active_dir/PAYLOAD_ID" ] || IFS= read -r installed_payload <"$active_dir/PAYLOAD_ID"
  fi
  if ! valid_semver "$installed_version" 2>/dev/null; then
    installed_version="$(current_version 2>/dev/null || true)"
  fi
  [[ "$installed_build" =~ ^[1-9][0-9]*$ ]] || installed_build="0"

  manifest_version="$(manifest_field version 2>/dev/null || true)"
  manifest_build="$(manifest_field build 2>/dev/null || true)"
  manifest_payload="$(manifest_field payload_id 2>/dev/null || true)"
  manifest_executable="$(manifest_field executable_path 2>/dev/null || true)"
  if valid_semver "$manifest_version" 2>/dev/null && [[ "$manifest_build" =~ ^[1-9][0-9]*$ ]]; then
    if [ -z "$installed_version" ] || [ "$(semver_compare "$manifest_version" "$installed_version")" -gt 0 ] || \
       { [ "$manifest_version" = "$installed_version" ] && [ "$manifest_build" -gt "$installed_build" ]; }; then
      case "$manifest_executable" in
        "$LIBEXEC_ROOT"/versions/*/detach)
          installed_version="$manifest_version"
          installed_build="$manifest_build"
          installed_payload="$manifest_payload"
          active_dir="$(dirname "$manifest_executable")"
          ;;
      esac
    fi
  fi

  if [ -n "$installed_version" ] && valid_semver "$installed_version"; then
    comparison="$(semver_compare "$installed_version" "$version")"
    if [ "$comparison" -gt 0 ] && [ "$allow_downgrade" -eq 0 ]; then
      printf 'A newer detach CLI is already installed: %s (app payload: %s)\n' "$installed_version" "$version"
      return 0
    fi
    if [ "$comparison" -eq 0 ] && [ "$installed_build" -gt "$build" ] && \
       [ "$allow_downgrade" -eq 0 ]; then
      printf 'A newer detach build is already installed: %s (%s); app payload build: %s\n' \
        "$installed_version" "$installed_build" "$build"
      return 0
    fi
    if [ "$comparison" -eq 0 ] && [ "$installed_build" = "$build" ] && \
       [ -n "$installed_payload" ] && [ "$installed_payload" != "$payload_id" ] && \
       [ "$active_dir" != "$target" ] && [ "$allow_downgrade" -eq 0 ]; then
      die "conflicting payload for $version build $build; increment BUILD instead of replacing immutable code"
    fi
  fi

  "$INSTALL_BIN" -d -m 0755 "$BIN_DIR" "$LIBEXEC_ROOT/versions" || die "cannot create installation directories"
  "$INSTALL_BIN" -d -m 0700 "$INSTALL_STATE_ROOT" || die "cannot create install state directory"

  if [ -d "$target" ]; then
    if [ -x "$target/detach" ] && [ -x "$target/detach-core" ] && \
       [ -x "$target/detach-install" ] && [ -f "$target/VERSION" ] && \
       [ -f "$target/BUILD" ] && [ "$(head -n 1 "$target/BUILD")" = "$build" ] && \
       [ -f "$target/PAYLOAD_ID" ] && [ "$(head -n 1 "$target/PAYLOAD_ID")" = "$payload_id" ] && \
       [ "$(sha256_file "$target/detach")" = "$detach_hash" ] && \
       [ "$(sha256_file "$target/detach-core")" = "$core_hash" ] && \
       [ "$(sha256_file "$target/detach-install")" = "$installer_hash" ] && \
       [ "$("$target/detach" __version 2>/dev/null)" = "$version" ]; then
      :
    else
      [ "$repair" -eq 1 ] || die "existing immutable payload is invalid: $target (run Repair)"
      managed_sessions_running && die "Repair is unsafe while a detach session is running"
      "$RM_BIN" -rf "$target" || die "cannot remove invalid payload"
    fi
  fi

  if [ ! -d "$target" ]; then
    stage="$LIBEXEC_ROOT/versions/.incoming-$version-${payload_id:0:12}-$$"
    case "$stage" in "$LIBEXEC_ROOT/versions/.incoming-"*) ;; *) die "unsafe staging path" ;; esac
    "$RM_BIN" -rf "$stage" || die "cannot clear staging directory"
    "$INSTALL_BIN" -d -m 0755 "$stage" || die "cannot create staging directory"
    "$INSTALL_BIN" -m 0755 "$payload_dir/detach" "$stage/detach" || die "cannot stage detach"
    "$INSTALL_BIN" -m 0755 "$payload_dir/detach-core" "$stage/detach-core" || die "cannot stage detach-core"
    if [ -x "$payload_dir/detach-install" ]; then
      "$INSTALL_BIN" -m 0755 "$payload_dir/detach-install" "$stage/detach-install" || die "cannot stage installer"
    else
      "$INSTALL_BIN" -m 0755 "$SELF" "$stage/detach-install" || die "cannot stage installer"
    fi
    "$INSTALL_BIN" -m 0644 "$version_file" "$stage/VERSION" || die "cannot stage version"
    printf '%s\n' "$build" >"$stage/BUILD" || die "cannot stage build number"
    printf '%s\n' "$payload_id" >"$stage/PAYLOAD_ID" || die "cannot stage payload id"
    if [ -x "$XATTR_BIN" ]; then
      "$XATTR_BIN" -dr com.apple.quarantine "$stage" >/dev/null 2>&1 || true
    fi
    [ "$(sha256_file "$stage/detach")" = "$detach_hash" ] || die "staged detach hash mismatch"
    [ "$(sha256_file "$stage/detach-core")" = "$core_hash" ] || die "staged detach-core hash mismatch"
    [ "$(sha256_file "$stage/detach-install")" = "$installer_hash" ] || die "staged installer hash mismatch"
    [ "$("$stage/detach" __version 2>/dev/null)" = "$version" ] || die "staged CLI version mismatch"
    "$MV_BIN" "$stage" "$target" || die "cannot activate payload directory"
  fi

  link_tmp="$BIN_DIR/.detach-link.$$"
  "$RM_BIN" -f "$link_tmp"
  "$LN_BIN" -s "$target/detach" "$link_tmp" || die "cannot create CLI symlink"
  "$MV_BIN" -f "$link_tmp" "$BIN_DIR/detach" || die "cannot switch CLI symlink"
  write_manifest "$version" "$build" "$payload_id" "$source" "$target" \
    "$payload_dir" "$version_file" "$SELF" || die "cannot write install manifest"
  write_required_config || die "cannot configure required Amphetamine integration"

  if [ "$install_launch_agent" -eq 1 ]; then
    require_executable "$LAUNCHCTL_BIN" launchctl
    install_cli_watchdog "$launch_agent_plist"
  fi

  current="$("$BIN_DIR/detach" __version 2>/dev/null || true)"
  [ "$current" = "$version" ] || die "activated CLI failed validation"
  printf 'Installed detach %s (build %s, payload %s)\n' "$version" "$build" "${payload_id:0:12}"
  printf 'CLI: %s\n' "$BIN_DIR/detach"
}

remove_detach_state_root() {
  local path="$1"
  local default_base="${XDG_STATE_HOME:-$HOME/.local/state}"
  local parent canonical_parent codex_store claude_store

  case "$path" in
    /*) ;;
    *) return 2 ;;
  esac
  case "/$path/" in */../*|*/./*) return 2 ;; esac
  case "$path" in "$default_base"/*|"$HOME/.local/state"/*) ;; *) return 2 ;; esac
  parent="$(dirname "$path")"
  canonical_parent="$(cd -P "$parent" 2>/dev/null && pwd)" || return 2
  codex_store="$(cd -P "$HOME" 2>/dev/null && pwd)/.codex"
  claude_store="$(cd -P "$HOME" 2>/dev/null && pwd)/.claude"
  case "$canonical_parent" in
    "$codex_store"|"$codex_store"/*|"$claude_store"|"$claude_store"/*) return 2 ;;
  esac
  "$RM_BIN" -rf "$path"
}

uninstall_locked() {
  local state_mode="ask"
  local path target kept_state=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep-state) state_mode="keep"; shift ;;
      --purge-state) state_mode="purge"; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown uninstall option: $1" ;;
    esac
  done

  managed_sessions_running && die "cannot uninstall while a detach session is running; stop it first"

  if [ -x "$LAUNCHCTL_BIN" ] && \
     "$LAUNCHCTL_BIN" print "gui/$(id -u)/$APP_WATCHDOG_LABEL" >/dev/null 2>&1; then
    die "watchdog is managed by Detach.app; uninstall it from the app so SMAppService can unregister cleanly"
  fi

  if [ "$state_mode" = "ask" ]; then
    state_mode="keep"
    if [ -t 0 ]; then
      printf 'Delete Detach checkpoints and session state too? [y/N] ' >&2
      IFS= read -r answer || true
      case "${answer:-}" in y|Y|yes|YES) state_mode="purge" ;; esac
    fi
  fi

  if [ -L "$BIN_DIR/detach" ]; then
    target="$(cd -P "$(dirname "$BIN_DIR/detach")" >/dev/null 2>&1 && readlink "$BIN_DIR/detach")"
    case "$target" in
      "$LIBEXEC_ROOT"/versions/*/detach|../libexec/detach/versions/*/detach)
        "$RM_BIN" -f "$BIN_DIR/detach" || die "cannot remove CLI symlink" ;;
      *) die "refusing to remove an unmanaged detach symlink: $BIN_DIR/detach -> $target" ;;
    esac
  elif [ -e "$BIN_DIR/detach" ]; then
    die "refusing to remove an unmanaged file: $BIN_DIR/detach"
  fi

  if [ -f "$CLI_WATCHDOG_PLIST_DEST" ]; then
    "$LAUNCHCTL_BIN" bootout "gui/$(id -u)/$CLI_WATCHDOG_LABEL" >/dev/null 2>&1 || true
    "$RM_BIN" -f "$CLI_WATCHDOG_PLIST_DEST"
  fi
  "$RM_BIN" -rf "$LIBEXEC_ROOT/versions"
  "$RM_BIN" -f "$INSTALL_STATE_ROOT/install.json"
  "$RM_BIN" -f "$LIBEXEC_ROOT/detach" "$LIBEXEC_ROOT/detach-core"

  if [ "$state_mode" = "purge" ]; then
    for path in "$CODEX_STATE_ROOT" "$CLAUDE_STATE_ROOT" "$AMPHETAMINE_ROOT"; do
      if ! remove_detach_state_root "$path"; then
        kept_state=1
        error "refusing to purge non-standard or unsafe state path: $path"
      fi
    done
    if [ "$kept_state" -eq 0 ]; then
      printf 'Removed Detach CLI and saved session state.\n'
    else
      printf 'Removed Detach CLI. Some non-standard state paths were kept; see warnings above.\n'
    fi
  else
    printf 'Removed Detach CLI. Saved session state was kept.\n'
  fi
  printf 'Amphetamine Power Protect and sudoers settings were not changed.\n'
}

with_lock() {
  local operation="$1"
  shift
  require_executable "$LOCKF_BIN" lockf
  "$MKDIR_BIN" -p "$INSTALL_STATE_ROOT" || die "cannot create install state directory"
  chmod 0700 "$INSTALL_STATE_ROOT" || die "cannot secure install state directory"
  exec "$LOCKF_BIN" -k "$INSTALL_STATE_ROOT/install.lock" "$SELF" __locked "$operation" "$@"
}

main() {
  local operation="${1:-install}"
  validate_managed_paths
  case "$operation" in
    install|uninstall) shift || true; with_lock "$operation" "$@" ;;
    __locked)
      shift
      operation="${1:-}"
      shift || true
      case "$operation" in
        install) install_locked "$@" ;;
        uninstall) uninstall_locked "$@" ;;
        *) die "invalid locked operation: $operation" ;;
      esac
      ;;
    -h|--help|help) usage ;;
    *) die "unknown operation: $operation" ;;
  esac
}

main "$@"
