#!/bin/bash

set -euo pipefail

PROGRAM="build-tmux"
SELF_DIR="$(cd -P "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -P "$SELF_DIR/.." && pwd)"

TMUX_VERSION=3.7b
TMUX_SOURCE_URL="https://github.com/tmux/tmux/releases/download/3.7b/tmux-3.7b.tar.gz"
TMUX_SHA256=87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96
LIBEVENT_VERSION=2.1.13
LIBEVENT_SOURCE_URL="https://github.com/libevent/libevent/archive/refs/tags/release-2.1.13-stable.tar.gz"
LIBEVENT_SHA256=1a0885e17dc78afbaeddf13cf849f9238bbc24acdc178464a0d1934d7c5ffbd5
UTF8PROC_VERSION=2.11.3
UTF8PROC_SOURCE_URL="https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v2.11.3.tar.gz"
UTF8PROC_SHA256=abfed50b6d4da51345713661370290f4f4747263ee73dc90356299dfc7990c78

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
    '  build-tmux.sh metadata --json' \
    '  build-tmux.sh build --arch arm64 --output PATH' \
    '  build-tmux.sh licenses --output-dir DIR'
}

metadata_json() {
  printf '%s\n' "{\"schema\":1,\"tmux\":{\"version\":\"$TMUX_VERSION\",\"license\":\"ISC\",\"source_url\":\"$TMUX_SOURCE_URL\",\"sha256\":\"$TMUX_SHA256\"},\"libevent\":{\"version\":\"$LIBEVENT_VERSION\",\"license\":\"BSD-3-Clause\",\"source_url\":\"$LIBEVENT_SOURCE_URL\",\"sha256\":\"$LIBEVENT_SHA256\"},\"utf8proc\":{\"version\":\"$UTF8PROC_VERSION\",\"license\":\"MIT AND Unicode-DFS-2015\",\"source_url\":\"$UTF8PROC_SOURCE_URL\",\"sha256\":\"$UTF8PROC_SHA256\"}}"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

fetch_source() {
  local name="$1" url="$2" checksum="$3" destination="$4"

  if [ -f "$destination" ] && [ "$(sha256_file "$destination")" = "$checksum" ]; then
    return 0
  fi
  rm -f "$destination"
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$destination" "$url" || die "could not download $name"
  [ "$(sha256_file "$destination")" = "$checksum" ] || {
    rm -f "$destination"
    die "$name source checksum mismatch"
  }
}

prepare_sources() {
  local cache="$1"

  mkdir -p "$cache"
  fetch_source tmux "$TMUX_SOURCE_URL" "$TMUX_SHA256" "$cache/tmux-$TMUX_VERSION.tar.gz"
  fetch_source libevent "$LIBEVENT_SOURCE_URL" "$LIBEVENT_SHA256" \
    "$cache/libevent-$LIBEVENT_VERSION.tar.gz"
  fetch_source utf8proc "$UTF8PROC_SOURCE_URL" "$UTF8PROC_SHA256" \
    "$cache/utf8proc-$UTF8PROC_VERSION.tar.gz"
}

extract_source() {
  local archive="$1" destination="$2"
  mkdir -p "$destination"
  /usr/bin/tar -xzf "$archive" -C "$destination" --strip-components 1
}

build_arch() {
  local arch="$1" output="$2"
  local cache="${DETACH_TMUX_SOURCE_CACHE:-$REPO_ROOT/app/.build/tmux-sources}"
  local root="${DETACH_TMUX_BUILD_ROOT:-$REPO_ROOT/app/.build/tmux-runtime}/$arch"
  local source_root="$root/sources" prefix="$root/prefix"
  local sdk cc ar ranlib cmake jobs common_cflags common_ldflags

  [ "$arch" = arm64 ] || die "unsupported architecture: $arch"
  [ -n "$output" ] || die "--output is required"
  case "$root" in "$REPO_ROOT"/app/.build/*|/tmp/*|/private/tmp/*) ;; *)
    die "unsafe tmux build root: $root" ;;
  esac

  prepare_sources "$cache"
  rm -rf "$root"
  mkdir -p "$source_root" "$prefix" "$(dirname "$output")"
  extract_source "$cache/libevent-$LIBEVENT_VERSION.tar.gz" "$source_root/libevent"
  extract_source "$cache/utf8proc-$UTF8PROC_VERSION.tar.gz" "$source_root/utf8proc"
  extract_source "$cache/tmux-$TMUX_VERSION.tar.gz" "$source_root/tmux"

  sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  cc="$(/usr/bin/xcrun --sdk macosx --find clang)"
  ar="$(/usr/bin/xcrun --sdk macosx --find ar)"
  ranlib="$(/usr/bin/xcrun --sdk macosx --find ranlib)"
  cmake="$(command -v cmake 2>/dev/null || true)"
  [ -x "$cmake" ] || die "cmake is required to build the pinned libevent source"
  jobs="$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || printf 4)"
  common_cflags="-arch $arch -isysroot $sdk -mmacosx-version-min=14.0 -O2"
  common_ldflags="-arch $arch -isysroot $sdk -mmacosx-version-min=14.0"

  (
    cd -P "$source_root/libevent"
    "$cmake" -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_COMPILER="$cc" \
      -DCMAKE_AR="$ar" \
      -DCMAKE_RANLIB="$ranlib" \
      -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
      -DCMAKE_OSX_SYSROOT="$sdk" \
      -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DEVENT__LIBRARY_TYPE=STATIC \
      -DEVENT__DISABLE_OPENSSL=ON \
      -DEVENT__DISABLE_SAMPLES=ON \
      -DEVENT__DISABLE_REGRESS=ON \
      -DEVENT__DISABLE_TESTS=ON
    "$cmake" --build build --parallel "$jobs"
    "$cmake" --install build
  )

  (
    cd -P "$source_root/utf8proc"
    /usr/bin/make -j"$jobs" libutf8proc.a \
      CC="$cc" AR="$ar" \
      CFLAGS="$common_cflags -fPIC -DUTF8PROC_EXPORTS"
    /usr/bin/install -d -m 0755 "$prefix/include" "$prefix/lib"
    /usr/bin/install -m 0644 utf8proc.h "$prefix/include/utf8proc.h"
    /usr/bin/install -m 0644 libutf8proc.a "$prefix/lib/libutf8proc.a"
  )

  (
    cd -P "$source_root/tmux"
    env CC="$cc" AR="$ar" RANLIB="$ranlib" PKG_CONFIG=false \
      CFLAGS="$common_cflags" \
      CPPFLAGS="-isysroot $sdk -D_DARWIN_C_SOURCE -I$prefix/include" \
      LDFLAGS="$common_ldflags" \
      LIBEVENT_CFLAGS="-I$prefix/include" \
      LIBEVENT_LIBS="$prefix/lib/libevent_core.a" \
      LIBUTF8PROC_CFLAGS="-I$prefix/include" \
      LIBUTF8PROC_LIBS="$prefix/lib/libutf8proc.a" \
      ./configure --prefix="$prefix" --enable-utf8proc
    /usr/bin/make -j"$jobs"
  )

  /usr/bin/install -m 0755 "$source_root/tmux/tmux" "$output"
  [ "$(/usr/bin/lipo -archs "$output")" = arm64 ] || \
    die "tmux output is not arm64-only"
  if /usr/bin/otool -L "$output" | \
      /usr/bin/grep -E '(/opt/homebrew|/usr/local|/Users/|libevent|utf8proc)' >/dev/null; then
    die "tmux retained a build-host or non-system dynamic dependency"
  fi
}

install_licenses() {
  local output_dir="$1"
  local cache="${DETACH_TMUX_SOURCE_CACHE:-$REPO_ROOT/app/.build/tmux-sources}"
  local temporary="${TMPDIR:-/tmp}/detach-tmux-licenses.$$"

  [ -n "$output_dir" ] || die "--output-dir is required"
  prepare_sources "$cache"
  rm -rf "$temporary"
  mkdir -p "$temporary" "$output_dir"
  trap 'rm -rf "$temporary"' RETURN
  extract_source "$cache/tmux-$TMUX_VERSION.tar.gz" "$temporary/tmux"
  extract_source "$cache/libevent-$LIBEVENT_VERSION.tar.gz" "$temporary/libevent"
  extract_source "$cache/utf8proc-$UTF8PROC_VERSION.tar.gz" "$temporary/utf8proc"
  /usr/bin/install -m 0644 "$temporary/tmux/COPYING" "$output_dir/tmux-ISC.txt"
  /usr/bin/install -m 0644 "$temporary/libevent/LICENSE" "$output_dir/libevent-BSD-3-Clause.txt"
  /usr/bin/install -m 0644 "$temporary/utf8proc/LICENSE.md" "$output_dir/utf8proc-MIT.txt"
  metadata_json >"$output_dir/provenance.json"
  rm -rf "$temporary"
  trap - RETURN
}

main() {
  local action="${1:-}" arch="" output="" output_dir=""
  [ "$#" -gt 0 ] && shift

  case "$action" in
    metadata)
      [ "${1:-}" = "--json" ] && [ "$#" -eq 1 ] || die "metadata requires --json"
      metadata_json
      ;;
    build)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --arch) [ "$#" -ge 2 ] || die "--arch requires a value"; arch="$2"; shift 2 ;;
          --output) [ "$#" -ge 2 ] || die "--output requires a value"; output="$2"; shift 2 ;;
          *) die "unknown build option: $1" ;;
        esac
      done
      [ -n "$arch" ] || die "--arch is required"
      build_arch "$arch" "$output"
      ;;
    licenses)
      [ "${1:-}" = "--output-dir" ] && [ "$#" -eq 2 ] || \
        die "licenses requires --output-dir DIR"
      output_dir="$2"
      install_licenses "$output_dir"
      ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
