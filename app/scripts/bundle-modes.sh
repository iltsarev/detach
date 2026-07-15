#!/bin/bash

# Shared app-bundle mode and symlink policy. This file is sourced by
# make-app.sh, verify-app.sh, and the packaging regression tests.

detach_bundle_executable_paths() {
  printf '%s\n' \
    Contents/MacOS/Detach \
    Contents/MacOS/DetachWatchdog \
    Contents/MacOS/detach-state \
    Contents/MacOS/detach-power \
    Contents/MacOS/DetachPowerHelper \
    Contents/MacOS/tmux \
    Contents/Resources/DetachCLI/detach \
    Contents/Resources/DetachCLI/detach-core \
    Contents/Resources/DetachCLI/detach-install \
    Contents/Resources/DetachCLI/detach-state \
    Contents/Resources/DetachCLI/detach-power \
    Contents/Resources/DetachCLI/tmux \
    Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle \
    Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
    Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater \
    Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer \
    Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader
}

detach_bundle_symlink_specs() {
  printf '%s\n' \
    'Contents/Frameworks/Sparkle.framework/Versions/Current|B' \
    'Contents/Frameworks/Sparkle.framework/Sparkle|Versions/Current/Sparkle' \
    'Contents/Frameworks/Sparkle.framework/Resources|Versions/Current/Resources' \
    'Contents/Frameworks/Sparkle.framework/Autoupdate|Versions/Current/Autoupdate' \
    'Contents/Frameworks/Sparkle.framework/Updater.app|Versions/Current/Updater.app' \
    'Contents/Frameworks/Sparkle.framework/XPCServices|Versions/Current/XPCServices' \
    'Contents/Frameworks/Sparkle.framework/Headers|Versions/Current/Headers' \
    'Contents/Frameworks/Sparkle.framework/PrivateHeaders|Versions/Current/PrivateHeaders' \
    'Contents/Frameworks/Sparkle.framework/Modules|Versions/Current/Modules'
}

detach_bundle_is_executable() {
  case "$1" in
    Contents/MacOS/Detach|\
    Contents/MacOS/DetachWatchdog|\
    Contents/MacOS/detach-state|\
    Contents/MacOS/detach-power|\
    Contents/MacOS/DetachPowerHelper|\
    Contents/MacOS/tmux|\
    Contents/Resources/DetachCLI/detach|\
    Contents/Resources/DetachCLI/detach-core|\
    Contents/Resources/DetachCLI/detach-install|\
    Contents/Resources/DetachCLI/detach-state|\
    Contents/Resources/DetachCLI/detach-power|\
    Contents/Resources/DetachCLI/tmux|\
    Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle|\
    Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate|\
    Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater|\
    Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer|\
    Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader)
      return 0
      ;;
  esac
  return 1
}

detach_bundle_expected_symlink_target() {
  case "$1" in
    Contents/Frameworks/Sparkle.framework/Versions/Current) printf '%s\n' B ;;
    Contents/Frameworks/Sparkle.framework/Sparkle) printf '%s\n' Versions/Current/Sparkle ;;
    Contents/Frameworks/Sparkle.framework/Resources) printf '%s\n' Versions/Current/Resources ;;
    Contents/Frameworks/Sparkle.framework/Autoupdate) printf '%s\n' Versions/Current/Autoupdate ;;
    Contents/Frameworks/Sparkle.framework/Updater.app) printf '%s\n' Versions/Current/Updater.app ;;
    Contents/Frameworks/Sparkle.framework/XPCServices) printf '%s\n' Versions/Current/XPCServices ;;
    Contents/Frameworks/Sparkle.framework/Headers) printf '%s\n' Versions/Current/Headers ;;
    Contents/Frameworks/Sparkle.framework/PrivateHeaders) printf '%s\n' Versions/Current/PrivateHeaders ;;
    Contents/Frameworks/Sparkle.framework/Modules) printf '%s\n' Versions/Current/Modules ;;
    *) return 1 ;;
  esac
}

verify_detach_bundle_symlinks() {
  local bundle="$1"
  local path relative target expected spec

  [ -d "$bundle" ] && [ ! -L "$bundle" ] || {
    printf 'App bundle root must be a real directory: %s\n' "$bundle" >&2
    return 1
  }

  while IFS='|' read -r relative expected; do
    path="$bundle/$relative"
    [ -L "$path" ] || {
      printf 'Required app bundle symlink is missing: %s\n' "$path" >&2
      return 1
    }
    target="$(readlink "$path")"
    [ "$target" = "$expected" ] || {
      printf 'Unexpected app bundle symlink target: %s -> %s (expected %s)\n' \
        "$path" "$target" "$expected" >&2
      return 1
    }
    [ -e "$path" ] || {
      printf 'App bundle contains a broken symlink: %s -> %s\n' \
        "$path" "$target" >&2
      return 1
    }
  done < <(detach_bundle_symlink_specs)

  while IFS= read -r -d '' path; do
    relative="${path#"$bundle"/}"
    expected="$(detach_bundle_expected_symlink_target "$relative")" || {
      printf 'App bundle contains an unexpected symlink: %s -> %s\n' \
        "$path" "$(readlink "$path")" >&2
      return 1
    }
    target="$(readlink "$path")"
    [ "$target" = "$expected" ] || {
      printf 'Unexpected app bundle symlink target: %s -> %s (expected %s)\n' \
        "$path" "$target" "$expected" >&2
      return 1
    }
  done < <(find -P "$bundle" -type l -print0)
}

verify_detach_bundle_structure() {
  local bundle="$1"
  local path relative

  verify_detach_bundle_symlinks "$bundle" || return 1

  while IFS= read -r -d '' path; do
    printf 'App bundle contains an unsupported filesystem node: %s\n' \
      "$path" >&2
    return 1
  done < <(find -P "$bundle" ! -type d ! -type f ! -type l -print0)

  while IFS= read -r relative; do
    path="$bundle/$relative"
    [ -f "$path" ] && [ ! -L "$path" ] || {
      printf 'Required app bundle executable is not a regular file: %s\n' \
        "$path" >&2
      return 1
    }
  done < <(detach_bundle_executable_paths)
}

normalize_detach_bundle_modes() {
  local bundle="$1"
  local path relative

  verify_detach_bundle_structure "$bundle" || return 1

  # find -P never follows Sparkle's versioned-framework symlinks.
  while IFS= read -r -d '' path; do
    chmod 0755 "$path"
  done < <(find -P "$bundle" -type d -print0)

  while IFS= read -r -d '' path; do
    chmod 0644 "$path"
  done < <(find -P "$bundle" -type f -print0)

  while IFS= read -r relative; do
    chmod 0755 "$bundle/$relative"
  done < <(detach_bundle_executable_paths)
}

verify_detach_bundle_modes() {
  local bundle="$1"
  local path relative mode expected

  verify_detach_bundle_structure "$bundle" || return 1

  while IFS= read -r -d '' path; do
    mode="$(stat -f '%Lp' "$path")"
    [ "$mode" = 755 ] || {
      printf 'App bundle directory must have mode 0755: %s (mode %s)\n' \
        "$path" "$mode" >&2
      return 1
    }
  done < <(find -P "$bundle" -type d -print0)

  while IFS= read -r -d '' path; do
    relative="${path#"$bundle"/}"
    expected=644
    detach_bundle_is_executable "$relative" && expected=755
    mode="$(stat -f '%Lp' "$path")"
    [ "$mode" = "$expected" ] || {
      if [ "$expected" = 755 ]; then
        printf 'App bundle executable must have mode 0755: %s (mode %s)\n' \
          "$path" "$mode" >&2
      else
        printf 'App bundle resource must have mode 0644: %s (mode %s)\n' \
          "$path" "$mode" >&2
      fi
      return 1
    }
  done < <(find -P "$bundle" -type f -print0)
}
