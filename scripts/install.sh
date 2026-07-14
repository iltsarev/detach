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
CAT_BIN="${DETACH_CAT_BIN:-/bin/cat}"
CP_BIN="${DETACH_CP_BIN:-/bin/cp}"
AWK_BIN="${DETACH_AWK_BIN:-/usr/bin/awk}"
TAIL_BIN="${DETACH_TAIL_BIN:-/usr/bin/tail}"
MKTEMP_BIN="${DETACH_MKTEMP_BIN:-/usr/bin/mktemp}"
DSCL_BIN="${DETACH_DSCL_BIN:-/usr/bin/dscl}"
ID_BIN="${DETACH_ID_BIN:-/usr/bin/id}"
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
SHELL_PATH_STATE_ROOT="${DETACH_SHELL_PATH_STATE_ROOT:-$INSTALL_STATE_ROOT/shell-path}"
CLI_WATCHDOG_PLIST_DEST="${DETACH_CLI_WATCHDOG_PLIST_DEST:-$HOME/Library/LaunchAgents/dev.tsarev.detach.cli-watchdog.plist}"
CLI_WATCHDOG_LABEL="dev.tsarev.detach.cli-watchdog"
LEGACY_CLI_WATCHDOG_PLIST_DEST="${DETACH_LEGACY_CLI_WATCHDOG_PLIST_DEST:-${DETACH_LEGACY_PLIST_DEST:-$HOME/Library/LaunchAgents/dev.tsarev.codex-detached-watchdog.plist}}"
LEGACY_CLI_WATCHDOG_LABEL="dev.tsarev.codex-detached-watchdog"
APP_WATCHDOG_LABEL="dev.tsarev.detach.watchdog"
SHELL_PATH_MARKER="# Detach CLI PATH"

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
  local source_dir link_target depth=0

  while [ -h "$source_path" ]; do
    depth=$((depth + 1))
    [ "$depth" -le 40 ] || return 1
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

shell_path_line() {
  local kind="$1"
  local quoted_bin
  quoted_bin="$(shell_quote "$BIN_DIR")"
  case "$kind" in
    posix)
      printf 'case ":${PATH:-}:" in *:%s:*) ;; *) export PATH=%s${PATH:+:${PATH}} ;; esac %s\n' \
        "$quoted_bin" "$quoted_bin" "$SHELL_PATH_MARKER"
      ;;
    csh)
      printf 'if ( " $path " !~ *%s* ) set path = ( %s $path ) %s\n' \
        "$(shell_quote " $BIN_DIR ")" "$quoted_bin" "$SHELL_PATH_MARKER"
      ;;
    fish)
      printf 'contains -- %s $PATH; or set -gx PATH %s $PATH %s\n' \
        "$quoted_bin" "$quoted_bin" "$SHELL_PATH_MARKER"
      ;;
    *) return 1 ;;
  esac
}

safe_shell_profile() {
  local profile="$1"
  local canonical_home resolved parent canonical_parent
  case "$profile" in
    "$HOME"/*) ;;
    *) return 1 ;;
  esac
  canonical_home="$(cd -P "$HOME" >/dev/null 2>&1 && pwd)" || return 1
  if [ -e "$profile" ] || [ -L "$profile" ]; then
    [ -f "$profile" ] || return 1
    resolved="$(resolve_path "$profile" 2>/dev/null)" || return 1
    case "$resolved" in "$canonical_home"/*) ;; *) return 1 ;; esac
    return 0
  fi
  parent="$(dirname "$profile")"
  while [ ! -d "$parent" ]; do
    case "$parent" in "$HOME"|/) break ;; esac
    parent="$(dirname "$parent")"
  done
  canonical_parent="$(cd -P "$parent" >/dev/null 2>&1 && pwd)" || return 1
  case "$canonical_parent" in "$canonical_home"|"$canonical_home"/*) ;; *) return 1 ;; esac
}

profile_has_line() {
  local profile="$1" line="$2"
  [ -f "$profile" ] && grep -Fqx -- "$line" "$profile" 2>/dev/null
}

profile_has_detach_marker() {
  local profile="$1"
  [ -f "$profile" ] && grep -Fq -- "$SHELL_PATH_MARKER" "$profile" 2>/dev/null
}

replace_shell_profile_line() {
  local profile="$1" old_line="$2" new_line="$3" expected_sha="$4"
  local resolved current_resolved current_sha tmp
  resolved="$(resolve_path "$profile" 2>/dev/null)" || return 1
  [ -f "$resolved" ] && [ ! -L "$resolved" ] || return 1
  tmp="$("$MKTEMP_BIN" "$(dirname "$resolved")/.detach-profile.XXXXXX")" || return 1
  "$CP_BIN" -p "$resolved" "$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  "$AWK_BIN" -v old="$old_line" -v new="$new_line" '
    $0 == old { print new; replaced = 1; next }
    { print }
    END { if (!replaced) exit 4 }
  ' "$profile" >"$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  current_resolved="$(resolve_path "$profile" 2>/dev/null)" || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  current_sha="$(sha256_file "$profile" 2>/dev/null)" || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  if [ "$current_resolved" != "$resolved" ] || [ "$current_sha" != "$expected_sha" ]; then
    "$RM_BIN" -f "$tmp"
    return 1
  fi
  "$MV_BIN" -f "$tmp" "$resolved" || { "$RM_BIN" -f "$tmp"; return 1; }
}

remove_shell_profile_line() {
  local profile="$1" line="$2" expected_sha="$3"
  local resolved current_resolved current_sha tmp
  resolved="$(resolve_path "$profile" 2>/dev/null)" || return 1
  [ -f "$resolved" ] && [ ! -L "$resolved" ] || return 1
  tmp="$("$MKTEMP_BIN" "$(dirname "$resolved")/.detach-profile.XXXXXX")" || return 1
  "$CP_BIN" -p "$resolved" "$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  "$AWK_BIN" -v owned="$line" '
    $0 == owned { removed = 1; next }
    { print }
    END { if (!removed) exit 4 }
  ' "$profile" >"$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  current_resolved="$(resolve_path "$profile" 2>/dev/null)" || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  current_sha="$(sha256_file "$profile" 2>/dev/null)" || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  if [ "$current_resolved" != "$resolved" ] || [ "$current_sha" != "$expected_sha" ]; then
    "$RM_BIN" -f "$tmp"
    return 1
  fi
  "$MV_BIN" -f "$tmp" "$resolved" || { "$RM_BIN" -f "$tmp"; return 1; }
}

restore_shell_profile_contents() {
  local profile="$1" source="$2" expected_sha="$3"
  local resolved current_resolved current_sha tmp
  resolved="$(resolve_path "$profile" 2>/dev/null)" || return 1
  [ -f "$resolved" ] && [ ! -L "$resolved" ] || return 1
  tmp="$("$MKTEMP_BIN" "$(dirname "$resolved")/.detach-profile.XXXXXX")" || return 1
  "$CP_BIN" -p "$resolved" "$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  "$CAT_BIN" "$source" >"$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  current_resolved="$(resolve_path "$profile" 2>/dev/null)" || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  current_sha="$(sha256_file "$profile" 2>/dev/null)" || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  if [ "$current_resolved" != "$resolved" ] || [ "$current_sha" != "$expected_sha" ]; then
    "$RM_BIN" -f "$tmp"
    return 1
  fi
  "$MV_BIN" -f "$tmp" "$resolved" || { "$RM_BIN" -f "$tmp"; return 1; }
}

write_shell_state_value() {
  local target="$1" value="$2" tmp="${1}.tmp.$$"
  "$RM_BIN" -f "$tmp"
  (umask 077; printf '%s\n' "$value" >"$tmp") || {
    "$RM_BIN" -f "$tmp"; return 1;
  }
  "$MV_BIN" -f "$tmp" "$target" || { "$RM_BIN" -f "$tmp"; return 1; }
}

remove_empty_shell_path_state_root() {
  "$RM_BIN" -d "$SHELL_PATH_STATE_ROOT" >/dev/null 2>&1 || true
}

stage_shell_profile_line() {
  local profile="$1" line="$2" existed="$3"
  local resolved tmp last pre_sha post_sha
  resolved="$(resolve_path "$profile" 2>/dev/null)" || return 1
  tmp="$("$MKTEMP_BIN" "$(dirname "$resolved")/.detach-profile.XXXXXX")" || return 1
  if [ "$existed" = 1 ]; then
    [ -f "$resolved" ] && [ ! -L "$resolved" ] || { "$RM_BIN" -f "$tmp"; return 1; }
    pre_sha="$(sha256_file "$profile" 2>/dev/null)" || { "$RM_BIN" -f "$tmp"; return 1; }
    "$CP_BIN" -p "$resolved" "$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  else
    pre_sha=""
    chmod 0600 "$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  fi
  if [ -s "$tmp" ]; then
    last="$("$TAIL_BIN" -c 1 "$tmp" 2>/dev/null || true)"
    [ -z "$last" ] || printf '\n' >>"$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$line" >>"$tmp" || { "$RM_BIN" -f "$tmp"; return 1; }
  post_sha="$(sha256_file "$tmp" 2>/dev/null)" || { "$RM_BIN" -f "$tmp"; return 1; }
  STAGED_PROFILE_TMP="$tmp"
  STAGED_PROFILE_RESOLVED="$resolved"
  STAGED_PROFILE_PRE_SHA="$pre_sha"
  STAGED_PROFILE_POST_SHA="$post_sha"
}

activate_staged_shell_profile() {
  local profile="$1" existed="$2"
  local current_resolved current_sha
  current_resolved="$(resolve_path "$profile" 2>/dev/null)" || return 1
  [ "$current_resolved" = "$STAGED_PROFILE_RESOLVED" ] || return 1
  if [ "$existed" = 1 ]; then
    current_sha="$(sha256_file "$profile" 2>/dev/null)" || return 1
    [ "$current_sha" = "$STAGED_PROFILE_PRE_SHA" ] || return 1
  else
    [ ! -e "$profile" ] && [ ! -L "$profile" ] && \
      [ ! -e "$STAGED_PROFILE_RESOLVED" ] && [ ! -L "$STAGED_PROFILE_RESOLVED" ] || return 1
  fi
  "$MV_BIN" -f "$STAGED_PROFILE_TMP" "$STAGED_PROFILE_RESOLVED"
}

ensure_shell_profile_line() {
  local id="$1" profile="$2" kind="$3"
  local line old_line state state_tmp parent existed post_sha previous_post
  local current_sha restore_exact resolved_profile stored_profile stored_resolved
  local stored_kind stored_existed stored_line exact_state_safe
  case "$id" in
    zshenv|zprofile|zshrc|bash_profile|bash_login|profile|bashrc|login|cshrc|fish) ;;
    *) die "invalid shell profile id: $id" ;;
  esac
  safe_shell_profile "$profile" || die "refusing unsafe shell profile: $profile"
  line="$(shell_path_line "$kind")" || die "unsupported shell profile kind: $kind"
  state="$SHELL_PATH_STATE_ROOT/$id"

  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] || die "invalid shell PATH state: $state"
    [ -f "$state/owned" ] && [ -f "$state/profile" ] && \
      [ -f "$state/kind" ] && [ -f "$state/existed" ] || \
      die "incomplete shell PATH ownership state: $state"
    IFS= read -r stored_profile <"$state/profile" || stored_profile=""
    [ "$stored_profile" = "$profile" ] || \
      die "shell profile location changed ($stored_profile -> $profile); uninstall and retry"
    IFS= read -r stored_kind <"$state/kind" || stored_kind=""
    [ "$stored_kind" = "$kind" ] || die "shell profile kind changed for $profile"
    IFS= read -r stored_existed <"$state/existed" || stored_existed=""
    case "$stored_existed" in 0) ;; 1)
      [ -f "$state/backup" ] && [ ! -L "$state/backup" ] || \
        die "shell profile backup is missing or unsafe: $state/backup"
      ;; *) die "invalid shell profile ownership state: $state" ;; esac
    if [ -f "$state/resolved-profile" ]; then
      IFS= read -r stored_resolved <"$state/resolved-profile" || stored_resolved=""
      resolved_profile="$(resolve_path "$profile" 2>/dev/null || true)"
      [ -n "$stored_resolved" ] && [ "$resolved_profile" = "$stored_resolved" ] || \
        die "shell profile target changed; refusing to update $profile"
    fi
    if profile_has_line "$profile" "$line"; then
      current_sha="$(sha256_file "$profile")" || die "cannot hash $profile"
      previous_post=""
      [ ! -f "$state/post-sha" ] || \
        IFS= read -r previous_post <"$state/post-sha" || previous_post=""
      stored_line=""
      [ ! -f "$state/line" ] || IFS= read -r stored_line <"$state/line" || stored_line=""
      restore_exact=0
      [ ! -f "$state/restore-exact" ] || \
        IFS= read -r restore_exact <"$state/restore-exact" || restore_exact=0
      exact_state_safe=1
      [ "$restore_exact" = 0 ] || [ "$restore_exact" = 1 ] || exact_state_safe=0
      [ -n "$previous_post" ] && [ "$current_sha" = "$previous_post" ] || exact_state_safe=0
      [ "$stored_line" = "$line" ] || exact_state_safe=0
      [ -f "$state/resolved-profile" ] || exact_state_safe=0
      if [ "$exact_state_safe" -eq 0 ]; then
        write_shell_state_value "$state/restore-exact" 0 || \
          die "cannot repair shell restore policy"
      fi
      if [ ! -f "$state/post-sha" ]; then
        write_shell_state_value "$state/post-sha" "$current_sha" || \
          die "cannot repair shell PATH state"
      fi
      if [ ! -f "$state/resolved-profile" ]; then
        resolved_profile="$(resolve_path "$profile" 2>/dev/null)" || \
          die "cannot resolve configured shell profile: $profile"
        write_shell_state_value "$state/resolved-profile" "$resolved_profile" || \
          die "cannot repair resolved shell profile state"
      fi
      [ -f "$state/restore-exact" ] || write_shell_state_value "$state/restore-exact" 0 || \
        die "cannot repair shell restore policy"
      write_shell_state_value "$state/line" "$line" || \
        die "cannot repair shell PATH line state"
      return 0
    fi
    old_line=""
    if [ -f "$state/line" ]; then
      IFS= read -r old_line <"$state/line" || old_line=""
    fi
    if [ -n "$old_line" ]; then
      case "$old_line" in *"$SHELL_PATH_MARKER"*) ;; *) old_line="" ;; esac
    fi
    if [ -n "$old_line" ] && profile_has_line "$profile" "$old_line"; then
      current_sha="$(sha256_file "$profile")" || die "cannot hash profile before PATH update: $profile"
      previous_post=""
      [ ! -f "$state/post-sha" ] || IFS= read -r previous_post <"$state/post-sha" || previous_post=""
      restore_exact=0
      if [ -f "$state/restore-exact" ]; then
        IFS= read -r restore_exact <"$state/restore-exact" || restore_exact=0
      fi
      [ "$restore_exact" = 1 ] && [ "$current_sha" = "$previous_post" ] || restore_exact=0
      # Make every interrupted migration non-destructive first. Exact restore
      # is re-enabled only after the profile and all related metadata agree.
      write_shell_state_value "$state/restore-exact" 0 || \
        die "cannot make shell PATH migration fail-safe"
      replace_shell_profile_line "$profile" "$old_line" "$line" "$current_sha" || \
        die "cannot update the Detach PATH entry in $profile"
      post_sha="$(sha256_file "$profile")" || die "cannot hash updated profile: $profile"
      resolved_profile="$(resolve_path "$profile" 2>/dev/null)" || \
        die "cannot resolve updated shell profile: $profile"
      write_shell_state_value "$state/post-sha" "$post_sha" || \
        die "cannot update shell PATH hash state"
      write_shell_state_value "$state/resolved-profile" "$resolved_profile" || \
        die "cannot update resolved shell profile state"
      write_shell_state_value "$state/line" "$line" || \
        die "cannot update shell PATH line state"
      write_shell_state_value "$state/restore-exact" "$restore_exact" || \
        die "cannot update shell restore policy"
      return 0
    fi
    profile_has_detach_marker "$profile" && \
      die "the Detach PATH entry in $profile was modified; remove it and retry"
    "$RM_BIN" -rf "$state" || die "cannot reset stale shell PATH state"
  fi

  # An identical line that predates Detach is already sufficient, but is not
  # ours to remove during uninstall.
  profile_has_line "$profile" "$line" && return 0
  profile_has_detach_marker "$profile" && \
    die "the Detach PATH entry in $profile was modified; remove it and retry"

  parent="$(dirname "$profile")"
  "$MKDIR_BIN" -p "$parent" || die "cannot create shell profile directory: $parent"
  "$INSTALL_BIN" -d -m 0700 "$SHELL_PATH_STATE_ROOT" || \
    die "cannot create shell PATH state directory"
  state_tmp="$SHELL_PATH_STATE_ROOT/.incoming-$id-$$"
  "$RM_BIN" -rf "$state_tmp"
  "$INSTALL_BIN" -d -m 0700 "$state_tmp" || die "cannot stage shell PATH state"

  existed=0
  if [ -f "$profile" ]; then
    existed=1
    : >"$state_tmp/backup" || die "cannot stage shell profile backup"
    chmod 0600 "$state_tmp/backup" || die "cannot secure shell profile backup"
    "$CAT_BIN" "$profile" >"$state_tmp/backup" || die "cannot back up $profile"
  fi
  STAGED_PROFILE_TMP=""
  STAGED_PROFILE_RESOLVED=""
  STAGED_PROFILE_PRE_SHA=""
  STAGED_PROFILE_POST_SHA=""
  if ! stage_shell_profile_line "$profile" "$line" "$existed"; then
    "$RM_BIN" -rf "$state_tmp"
    remove_empty_shell_path_state_root
    die "cannot stage the Detach PATH entry for $profile"
  fi
  post_sha="$STAGED_PROFILE_POST_SHA"
  resolved_profile="$STAGED_PROFILE_RESOLVED"
  if ! {
    printf '%s\n' "$existed" >"$state_tmp/existed" &&
    printf '%s\n' "$profile" >"$state_tmp/profile" &&
    printf '%s\n' "$kind" >"$state_tmp/kind" &&
    printf '%s\n' "$post_sha" >"$state_tmp/post-sha" &&
    printf '%s\n' "$resolved_profile" >"$state_tmp/resolved-profile" &&
    printf '%s\n' 1 >"$state_tmp/restore-exact" &&
    printf '%s\n' "$line" >"$state_tmp/line" &&
    : >"$state_tmp/owned"
  }; then
    "$RM_BIN" -f "$STAGED_PROFILE_TMP"
    "$RM_BIN" -rf "$state_tmp"
    remove_empty_shell_path_state_root
    die "cannot record shell PATH state"
  fi
  if ! "$MV_BIN" "$state_tmp" "$state"; then
    "$RM_BIN" -f "$STAGED_PROFILE_TMP"
    "$RM_BIN" -rf "$state_tmp"
    remove_empty_shell_path_state_root
    die "cannot activate shell PATH state"
  fi
  if ! activate_staged_shell_profile "$profile" "$existed"; then
    "$RM_BIN" -f "$STAGED_PROFILE_TMP"
    "$RM_BIN" -rf "$state"
    remove_empty_shell_path_state_root
    die "shell profile changed while configuring detach: $profile"
  fi
}

detect_user_shell() {
  local record user_name="${USER:-}" detected="${DETACH_USER_SHELL:-}"
  if [ -z "$user_name" ] && [ -x "$ID_BIN" ]; then
    user_name="$("$ID_BIN" -un 2>/dev/null || true)"
  fi
  if [ -z "$detected" ] && [ -x "$DSCL_BIN" ] && [ -n "$user_name" ]; then
    record="$("$DSCL_BIN" . -read "/Users/$user_name" UserShell 2>/dev/null || true)"
    case "$record" in UserShell:\ *) detected="${record#UserShell: }" ;; esac
  fi
  [ -n "$detected" ] || detected="${SHELL:-}"
  [ -n "$detected" ] || return 1
  printf '%s\n' "$detected"
}

visit_shell_profiles() {
  local callback="$1"
  local user_shell shell_name login_profile zsh_root fish_config_root
  case "$BIN_DIR" in *:*) die "CLI install directory cannot contain a colon: $BIN_DIR" ;; esac
  user_shell="$(detect_user_shell)" || \
    die "cannot determine the login shell; add $BIN_DIR to PATH manually"
  shell_name="${user_shell##*/}"
  DETECTED_USER_SHELL="$user_shell"

  case "$shell_name" in
    zsh)
      zsh_root="${ZDOTDIR:-$HOME}"
      # .zshenv is the one user startup file shared by login, interactive, and
      # non-interactive zsh. It is also read before a user file can change
      # ZDOTDIR, so Finder-launched installation cannot miss that redirect.
      "$callback" zshenv "$zsh_root/.zshenv" posix
      ;;
    bash)
      if [ -e "$HOME/.bash_profile" ] || [ -L "$HOME/.bash_profile" ]; then
        login_profile="$HOME/.bash_profile"; "$callback" bash_profile "$login_profile" posix
      elif [ -e "$HOME/.bash_login" ] || [ -L "$HOME/.bash_login" ]; then
        login_profile="$HOME/.bash_login"; "$callback" bash_login "$login_profile" posix
      elif [ -e "$HOME/.profile" ] || [ -L "$HOME/.profile" ]; then
        login_profile="$HOME/.profile"; "$callback" profile "$login_profile" posix
      else
        login_profile="$HOME/.bash_profile"; "$callback" bash_profile "$login_profile" posix
      fi
      "$callback" bashrc "$HOME/.bashrc" posix
      ;;
    fish)
      fish_config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
      "$callback" fish "$fish_config_root/fish/conf.d/detach.fish" fish
      ;;
    csh|tcsh)
      "$callback" login "$HOME/.login" csh
      "$callback" cshrc "$HOME/.cshrc" csh
      ;;
    sh|dash|ksh)
      "$callback" profile "$HOME/.profile" posix
      ;;
    *)
      die "unsupported login shell $user_shell; add $BIN_DIR to its PATH and retry"
      ;;
  esac
}

preflight_shell_profile_line() {
  local id="$1" profile="$2" kind="$3"
  local line old_line parent state stored_profile stored_resolved current_resolved
  local owned_previous=0
  case "$id" in
    zshenv|zprofile|zshrc|bash_profile|bash_login|profile|bashrc|login|cshrc|fish) ;;
    *) die "invalid shell profile id: $id" ;;
  esac
  safe_shell_profile "$profile" || die "refusing unsafe shell profile: $profile"
  state="$SHELL_PATH_STATE_ROOT/$id"
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] && [ -w "$state" ] || \
      die "invalid or unwritable shell PATH state: $state"
    if [ -f "$state/profile" ]; then
      IFS= read -r stored_profile <"$state/profile" || stored_profile=""
      [ "$stored_profile" = "$profile" ] || \
        die "shell profile location changed ($stored_profile -> $profile); uninstall and retry"
    fi
    if [ -f "$state/resolved-profile" ]; then
      IFS= read -r stored_resolved <"$state/resolved-profile" || stored_resolved=""
      current_resolved="$(resolve_path "$profile" 2>/dev/null || true)"
      [ -n "$stored_resolved" ] && [ "$current_resolved" = "$stored_resolved" ] || \
        die "shell profile target changed; refusing to update $profile"
    fi
    if [ -f "$state/line" ]; then
      IFS= read -r old_line <"$state/line" || old_line=""
      case "$old_line" in *"$SHELL_PATH_MARKER"*)
        profile_has_line "$profile" "$old_line" && owned_previous=1
        ;;
      esac
    fi
  fi
  line="$(shell_path_line "$kind")" || die "unsupported shell profile kind: $kind"
  profile_has_line "$profile" "$line" && return 0
  [ "$owned_previous" -eq 1 ] || ! profile_has_detach_marker "$profile" || \
    die "the Detach PATH entry in $profile was modified; remove it and retry"
  if [ -e "$profile" ] || [ -L "$profile" ]; then
    [ -w "$profile" ] || die "shell profile is not writable: $profile"
    return 0
  fi
  parent="$(dirname "$profile")"
  while [ ! -d "$parent" ]; do
    case "$parent" in "$HOME"|/) break ;; esac
    parent="$(dirname "$parent")"
  done
  case "$parent" in "$HOME"|"$HOME"/*) ;; *) die "unsafe shell profile parent: $parent" ;; esac
  [ -w "$parent" ] || die "shell profile directory is not writable: $parent"
}

preflight_shell_path() {
  local parent
  if [ -e "$SHELL_PATH_STATE_ROOT" ] || [ -L "$SHELL_PATH_STATE_ROOT" ]; then
    [ -d "$SHELL_PATH_STATE_ROOT" ] && [ ! -L "$SHELL_PATH_STATE_ROOT" ] && \
      [ -w "$SHELL_PATH_STATE_ROOT" ] || \
      die "invalid or unwritable shell PATH state: $SHELL_PATH_STATE_ROOT"
  else
    parent="$(dirname "$SHELL_PATH_STATE_ROOT")"
    [ -d "$parent" ] && [ -w "$parent" ] || \
      die "shell PATH state parent is not writable: $parent"
  fi
  DETECTED_USER_SHELL=""
  visit_shell_profiles preflight_shell_profile_line
}

configure_shell_path() {
  DETECTED_USER_SHELL=""
  "$INSTALL_BIN" -d -m 0700 "$SHELL_PATH_STATE_ROOT" || \
    die "cannot create shell PATH state directory"
  visit_shell_profiles ensure_shell_profile_line
  printf '%s\n' "$DETECTED_USER_SHELL" >"$SHELL_PATH_STATE_ROOT/login-shell" || \
    die "cannot record configured login shell"
}

cleanup_shell_path() {
  local state profile resolved_profile current_resolved kind existed post_sha current_sha
  local line restore_exact kept=0 state_kept
  [ -d "$SHELL_PATH_STATE_ROOT" ] && [ ! -L "$SHELL_PATH_STATE_ROOT" ] || return 0
  for state in "$SHELL_PATH_STATE_ROOT"/*; do
    [ -d "$state" ] && [ ! -L "$state" ] || continue
    state_kept=0
    [ -f "$state/owned" ] && [ -f "$state/profile" ] && \
      [ -f "$state/resolved-profile" ] && [ -f "$state/kind" ] && \
      [ -f "$state/existed" ] && [ -f "$state/post-sha" ] && \
      [ -f "$state/restore-exact" ] && [ -f "$state/line" ] || {
        error "keeping incomplete shell PATH state: $state"
        kept=1
        continue
      }
    IFS= read -r profile <"$state/profile" || {
      error "keeping unreadable shell profile state: $state"; kept=1; continue
    }
    IFS= read -r resolved_profile <"$state/resolved-profile" || {
      error "keeping unreadable resolved shell profile state: $state"; kept=1; continue
    }
    IFS= read -r kind <"$state/kind" || {
      error "keeping unreadable shell kind state: $state"; kept=1; continue
    }
    IFS= read -r existed <"$state/existed" || {
      error "keeping unreadable shell ownership state: $state"; kept=1; continue
    }
    IFS= read -r post_sha <"$state/post-sha" || {
      error "keeping unreadable shell hash state: $state"; kept=1; continue
    }
    IFS= read -r line <"$state/line" || {
      error "keeping unreadable shell PATH line state: $state"; kept=1; continue
    }
    IFS= read -r restore_exact <"$state/restore-exact" || {
      error "keeping unreadable shell restore policy: $state"; kept=1; continue
    }
    case "$kind" in posix|csh|fish) ;; *) error "keeping invalid shell PATH state: $state"; kept=1; continue ;; esac
    case "$existed" in 0|1) ;; *) error "keeping invalid shell PATH state: $state"; kept=1; continue ;; esac
    case "$restore_exact" in 0|1) ;; *) error "keeping invalid shell restore policy: $state"; kept=1; continue ;; esac
    safe_shell_profile "$profile" || {
      error "refusing to clean unsafe shell profile: $profile"
      kept=1
      continue
    }
    if [ ! -e "$profile" ] && [ ! -L "$profile" ] && [ "$existed" = 0 ]; then
      "$RM_BIN" -rf "$state"
      continue
    fi
    current_resolved="$(resolve_path "$profile" 2>/dev/null || true)"
    if [ -z "$current_resolved" ] || [ "$current_resolved" != "$resolved_profile" ]; then
      error "shell profile target changed; refusing to clean $profile"
      kept=1
      continue
    fi
    case "$line" in *"$SHELL_PATH_MARKER"*) ;; *)
      error "keeping shell state with an invalid owned PATH line: $state"
      kept=1
      continue
      ;;
    esac
    if [ -f "$profile" ]; then
      current_sha="$(sha256_file "$profile" 2>/dev/null || true)"
    else
      current_sha=""
    fi

    if [ "$restore_exact" = 1 ] && [ -n "$current_sha" ] && [ "$current_sha" = "$post_sha" ]; then
      if [ "$existed" = 1 ]; then
        if [ ! -f "$state/backup" ] || [ -L "$state/backup" ]; then
          error "shell profile backup is missing or unsafe: $state/backup"
          kept=1; state_kept=1
          continue
        fi
        restore_shell_profile_contents "$profile" "$state/backup" "$current_sha" || {
          error "cannot restore shell profile: $profile"
          kept=1; state_kept=1
          continue
        }
      else
        "$RM_BIN" -f "$profile" || {
          error "cannot remove Detach shell profile: $profile"
          kept=1; state_kept=1
          continue
        }
      fi
    elif profile_has_line "$profile" "$line"; then
      remove_shell_profile_line "$profile" "$line" "$current_sha" || {
        error "cannot update shell profile: $profile"
        kept=1; state_kept=1
        continue
      }
    else
      error "Detach PATH entry in $profile changed; it was left untouched"
      kept=1; state_kept=1
    fi
    [ "$state_kept" -eq 1 ] || "$RM_BIN" -rf "$state"
  done
  if [ "$kept" -eq 0 ]; then
    "$RM_BIN" -rf "$SHELL_PATH_STATE_ROOT"
  else
    "$RM_BIN" -f "$SHELL_PATH_STATE_ROOT/login-shell"
  fi
}

validate_managed_paths() {
  local path
  for path in "$BIN_DIR" "$LIBEXEC_ROOT" "$INSTALL_STATE_ROOT" "$CONFIG_ROOT" \
              "$SHELL_PATH_STATE_ROOT" "$CLI_WATCHDOG_PLIST_DEST" \
              "$LEGACY_CLI_WATCHDOG_PLIST_DEST"; do
    case "$path" in
      /*) ;;
      *) die "managed path must be absolute: $path" ;;
    esac
    case "$path" in
      /|/bin|/usr|/usr/*|/System|/System/*|/Library|/Library/*|*/../*|*/..)
        die "refusing unsafe managed path: $path" ;;
    esac
  done
  case "$SHELL_PATH_STATE_ROOT" in
    "$INSTALL_STATE_ROOT"/*) ;;
    *) die "shell PATH state must stay inside install state: $SHELL_PATH_STATE_ROOT" ;;
  esac
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

looks_like_legacy_flat_payload() {
  local candidate expected core
  [ -L "$1" ] || return 1
  candidate="$(resolve_path "$1" 2>/dev/null)" || return 1
  expected="$(resolve_path "$LIBEXEC_ROOT/detach" 2>/dev/null)" || return 1
  [ "$candidate" = "$expected" ] || return 1
  core="$(dirname "$candidate")/detach-core"
  [ -f "$candidate" ] && [ -x "$candidate" ] && \
    [ -f "$core" ] && [ -x "$core" ] || return 1
  grep -q 'DETACH_PROVIDER' "$candidate" 2>/dev/null && \
    grep -Eq 'CODEX_DETACHED|DETACH_CORE_ENTRYPOINT' "$core" 2>/dev/null
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

owned_cli_watchdog_plist() {
  local path="$1" expected_label="$2"
  local label argument0 argument1 argument2
  [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$PLUTIL_BIN" ] || return 1
  label="$("$PLUTIL_BIN" -extract Label raw -o - "$path" 2>/dev/null || true)"
  [ "$label" = "$expected_label" ] || return 1
  argument0="$("$PLUTIL_BIN" -extract ProgramArguments.0 raw -o - "$path" 2>/dev/null || true)"
  argument1="$("$PLUTIL_BIN" -extract ProgramArguments.1 raw -o - "$path" 2>/dev/null || true)"
  argument2="$("$PLUTIL_BIN" -extract ProgramArguments.2 raw -o - "$path" 2>/dev/null || true)"
  if [ "$argument0" = /bin/sh ] && [ "$argument1" = -c ]; then
    case "$argument2" in *__reconcile_amphetamine*) return 0 ;; esac
  fi
  case "$argument0:$argument1" in
    */.local/bin/detach:__reconcile_amphetamine) return 0 ;;
  esac
  return 1
}

retire_legacy_cli_watchdog() {
  local original="$LEGACY_CLI_WATCHDOG_PLIST_DEST"
  local backup="$LEGACY_CLI_WATCHDOG_PLIST_DEST.detach-backup"
  if owned_cli_watchdog_plist "$original" "$LEGACY_CLI_WATCHDOG_LABEL"; then
    "$LAUNCHCTL_BIN" bootout "gui/$(id -u)/$LEGACY_CLI_WATCHDOG_LABEL" >/dev/null 2>&1 || true
    "$RM_BIN" -f "$original"
  fi
  if owned_cli_watchdog_plist "$backup" "$LEGACY_CLI_WATCHDOG_LABEL"; then
    "$RM_BIN" -f "$backup"
  fi
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
    if "$LAUNCHCTL_BIN" print "gui/$(id -u)/$CLI_WATCHDOG_LABEL" >/dev/null 2>&1; then
      retire_legacy_cli_watchdog
    fi
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
  # Only retire the older label after bootstrap of its replacement succeeds.
  retire_legacy_cli_watchdog
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
  require_executable "$CAT_BIN" cat
  require_executable "$CP_BIN" cp
  require_executable "$AWK_BIN" awk
  require_executable "$TAIL_BIN" tail
  require_executable "$MKTEMP_BIN" mktemp
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
    if [ -z "$active_dir" ] && ! looks_like_legacy_flat_payload "$BIN_DIR/detach"; then
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

  # Reject unsupported shells, unsafe symlinks, edited Detach entries, and
  # unwritable profiles before the immutable payload or public CLI changes.
  preflight_shell_path

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

  # Profile setup does not execute the CLI, so finish it before switching the
  # public command. A shell-specific failure cannot leave a new CLI activated.
  configure_shell_path

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
  printf 'Command: detach (open a new Terminal window)\n'
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

  require_executable "$MV_BIN" mv
  require_executable "$RM_BIN" rm
  require_executable "$CAT_BIN" cat
  require_executable "$CP_BIN" cp
  require_executable "$AWK_BIN" awk
  require_executable "$MKTEMP_BIN" mktemp
  require_executable "$SHASUM_BIN" shasum

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
  retire_legacy_cli_watchdog
  cleanup_shell_path
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
