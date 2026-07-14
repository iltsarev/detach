#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
REPOSITORY="${DETACH_GITHUB_REPOSITORY:-}"
TAG="${DETACH_RELEASE_TAG:-v$VERSION}"
DMG="$APP_ROOT/build/Detach.dmg"
CHECKSUM="$DMG.sha256"
UPDATE_ASSETS="$APP_ROOT/build/update-assets"
UPDATE_ZIP="$UPDATE_ASSETS/Detach-$VERSION.zip"
APPCAST="$UPDATE_ASSETS/appcast.xml"
RELEASE_MANIFEST="$UPDATE_ASSETS/release-manifest.json"
DOWNLOAD_URL_PREFIX="${DETACH_SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/$REPOSITORY/releases/download/$TAG/}"
DOWNLOAD_URL="${DETACH_DOWNLOAD_URL:-https://github.com/$REPOSITORY/releases/latest}"
FEED_URL="${DETACH_SPARKLE_FEED_URL:-https://github.com/$REPOSITORY/releases/latest/download/appcast.xml}"
RELEASE_TARGET="${DETACH_GITHUB_RELEASE_TARGET:-}"
SEPARATE_RELEASE_REPOSITORY="${DETACH_SEPARATE_RELEASE_REPOSITORY:-0}"

[ -n "$REPOSITORY" ] || {
  printf 'DETACH_GITHUB_REPOSITORY (owner/repository) is required\n' >&2
  exit 1
}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || {
  printf 'Invalid Detach version: %s\n' "$VERSION" >&2
  exit 1
}
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf 'Invalid GitHub repository: %s\n' "$REPOSITORY" >&2
  exit 1
}
[[ "$TAG" =~ ^v[0-9A-Za-z._+-]+$ ]] || {
  printf 'Invalid release tag: %s\n' "$TAG" >&2
  exit 1
}
[[ "$DOWNLOAD_URL_PREFIX" =~ ^https://[^[:space:]]+/$ ]] || {
  printf 'DETACH_SPARKLE_DOWNLOAD_URL_PREFIX must be HTTPS and end in /\n' >&2
  exit 1
}
[[ "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]] || {
  printf 'DETACH_DOWNLOAD_URL must be HTTPS\n' >&2
  exit 1
}
[[ "$FEED_URL" =~ ^https://[^[:space:]]+$ ]] || {
  printf 'DETACH_SPARKLE_FEED_URL must be HTTPS\n' >&2
  exit 1
}
if [ -n "$RELEASE_TARGET" ]; then
  [[ "$RELEASE_TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
    printf 'DETACH_GITHUB_RELEASE_TARGET must be a branch, tag, or commit without whitespace\n' >&2
    exit 1
  }
fi
[[ "$SEPARATE_RELEASE_REPOSITORY" = 0 || "$SEPARATE_RELEASE_REPOSITORY" = 1 ]] || {
  printf 'DETACH_SEPARATE_RELEASE_REPOSITORY must be 0 or 1\n' >&2
  exit 1
}
command -v gh >/dev/null 2>&1 || {
  printf 'GitHub CLI (gh) is required\n' >&2
  exit 1
}
[ -f "$DMG" ] && [ -f "$CHECKSUM" ] || {
  printf 'Release artifacts are missing; run app/scripts/release.sh first\n' >&2
  exit 1
}
[ -f "$UPDATE_ZIP" ] && [ -f "$UPDATE_ZIP.sha256" ] && \
  [ -f "$APPCAST" ] && [ -f "$APPCAST.sha256" ] && \
  [ -f "$RELEASE_MANIFEST" ] && [ -f "$RELEASE_MANIFEST.sha256" ] || {
    printf 'Sparkle update assets are missing; run app/scripts/release.sh first\n' >&2
    exit 1
  }
(
  cd -P "$(dirname "$DMG")"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)
xmllint --noout "$APPCAST"
EXPECTED_UPDATE_URL="$DOWNLOAD_URL_PREFIX$(basename "$UPDATE_ZIP")"
APPCAST_UPDATE_URL="$(xmllint --xpath \
  'string((//*[local-name()="enclosure"]/@url)[1])' "$APPCAST")"
[ "$APPCAST_UPDATE_URL" = "$EXPECTED_UPDATE_URL" ] || {
  printf 'Appcast update URL does not match repository/tag: %s\n' "$APPCAST_UPDATE_URL" >&2
  exit 1
}
APPCAST_LINK="$(xmllint --xpath \
  'string((//*[local-name()="item"]/*[local-name()="link"])[1])' "$APPCAST")"
[ "$APPCAST_LINK" = "$DOWNLOAD_URL" ] || {
  printf 'Appcast manual download link does not match publication target\n' >&2
  exit 1
}

manifest_value() {
  plutil -extract "$1" raw -o - "$RELEASE_MANIFEST"
}
[ "$(manifest_value version)" = "$VERSION" ] && \
  [ "$(manifest_value tag)" = "$TAG" ] && \
  [ "$(manifest_value feed_url)" = "$FEED_URL" ] && \
  [ "$(manifest_value update_url)" = "$EXPECTED_UPDATE_URL" ] && \
  [ "$(manifest_value download_url)" = "$DOWNLOAD_URL" ] || {
    printf 'Release manifest does not match publication inputs\n' >&2
    exit 1
  }
MANIFEST_BUILD="$(manifest_value build)"
APPCAST_BUILD="$(xmllint --xpath \
  'string((//*[local-name()="version"])[1])' "$APPCAST")"
[[ "$MANIFEST_BUILD" =~ ^[1-9][0-9]*$ ]] && \
  [ "$APPCAST_BUILD" = "$MANIFEST_BUILD" ] || {
    printf 'Appcast build does not match the release manifest\n' >&2
    exit 1
  }
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
UPDATE_SHA256="$(shasum -a 256 "$UPDATE_ZIP" | awk '{print $1}')"
APPCAST_SHA256="$(shasum -a 256 "$APPCAST" | awk '{print $1}')"
[ "$(manifest_value dmg_sha256)" = "$DMG_SHA256" ] && \
  [ "$(manifest_value update_sha256)" = "$UPDATE_SHA256" ] && \
  [ "$(manifest_value appcast_sha256)" = "$APPCAST_SHA256" ] || {
    printf 'Release artifact hashes do not match the manifest\n' >&2
    exit 1
  }
GIT_COMMIT="$(manifest_value git_commit)"
[[ "$GIT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'Release manifest contains an invalid git commit\n' >&2
  exit 1
}
[ "$(git -C "$REPO_ROOT" rev-parse --verify HEAD)" = "$GIT_COMMIT" ] && \
  [ "$(git -C "$REPO_ROOT" rev-list -n 1 "$TAG" 2>/dev/null || true)" = "$GIT_COMMIT" ] || {
    printf 'Current HEAD/tag do not match the built release manifest\n' >&2
    exit 1
  }

assets=("$DMG" "$CHECKSUM")
for update_asset in "$UPDATE_ASSETS"/*; do
  [ -f "$update_asset" ] && [ ! -L "$update_asset" ] || {
    printf 'Unexpected updater asset: %s\n' "$update_asset" >&2
    exit 1
  }
  case "$(basename "$update_asset")" in
    appcast*.xml|*.zip|*.delta|*.md|*.html|*.txt|*.json|*.sha256) ;;
    *)
      printf 'Refusing unexpected updater asset: %s\n' "$update_asset" >&2
      exit 1
      ;;
  esac
  assets+=("$update_asset")
done
for update_checksum in "$UPDATE_ASSETS"/*.sha256; do
  [ -f "$update_checksum" ] || {
    printf 'Updater checksum is missing\n' >&2
    exit 1
  }
  (
    cd -P "$UPDATE_ASSETS"
    shasum -a 256 -c "$(basename "$update_checksum")"
  )
done
gh auth status >/dev/null
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  printf 'Release already exists; refusing to replace assets: %s %s\n' "$REPOSITORY" "$TAG" >&2
  exit 1
fi

# GitHub otherwise creates a missing tag from the repository's default branch.
# An existing remote tag is explicit and is verified by `gh`. A separate
# downloads repository may instead opt into creating the tag from a named,
# resolved target; no implicit default-branch tag is allowed.
REMOTE_TAG_COMMIT="$(gh api "repos/$REPOSITORY/commits/$TAG" --jq .sha 2>/dev/null || true)"
release_tag_args=()
if [ -n "$REMOTE_TAG_COMMIT" ]; then
  [ "$SEPARATE_RELEASE_REPOSITORY" = 1 ] || \
    [ "$REMOTE_TAG_COMMIT" = "$GIT_COMMIT" ] || {
    printf 'Remote tag %s does not point to the built source commit\n' "$TAG" >&2
    exit 1
  }
  release_tag_args=(--verify-tag)
else
  [ -n "$RELEASE_TARGET" ] || {
    printf 'Remote tag %s is missing; push it or set DETACH_GITHUB_RELEASE_TARGET explicitly\n' \
      "$TAG" >&2
    exit 1
  }
  REMOTE_TARGET_COMMIT="$(gh api "repos/$REPOSITORY/commits/$RELEASE_TARGET" \
    --jq .sha 2>/dev/null || true)"
  [ -n "$REMOTE_TARGET_COMMIT" ] || {
    printf 'Cannot resolve GitHub release target: %s\n' "$RELEASE_TARGET" >&2
    exit 1
  }
  [ "$SEPARATE_RELEASE_REPOSITORY" = 1 ] || \
    [ "$REMOTE_TARGET_COMMIT" = "$GIT_COMMIT" ] || {
    printf 'GitHub release target does not match the built source commit\n' >&2
    exit 1
  }
  release_tag_args=(--target "$REMOTE_TARGET_COMMIT")
fi

gh release create "$TAG" "${assets[@]}" \
  --repo "$REPOSITORY" \
  --title "Detach $VERSION" \
  --generate-notes \
  "${release_tag_args[@]}" \
  --draft
remote_assets="$(gh release view "$TAG" --repo "$REPOSITORY" --json assets --jq '.assets[].name')"
for asset in "${assets[@]}"; do
  grep -Fx "$(basename "$asset")" <<<"$remote_assets" >/dev/null || {
    printf 'Draft release is missing asset: %s\n' "$asset" >&2
    exit 1
  }
done

verify_remote_digest() {
  local asset="$1"
  local expected_sha256="$2"
  local asset_name
  local remote_digest

  asset_name="$(basename "$asset")"
  remote_digest="$(gh release view "$TAG" --repo "$REPOSITORY" --json assets \
    --jq ".assets[] | select(.name == \"$asset_name\") | .digest")"
  [ "$remote_digest" = "sha256:$expected_sha256" ] || {
    printf 'Draft release asset digest mismatch: %s\n' "$asset_name" >&2
    exit 1
  }
}

verify_remote_digest "$DMG" "$DMG_SHA256"
verify_remote_digest "$UPDATE_ZIP" "$UPDATE_SHA256"
verify_remote_digest "$APPCAST" "$APPCAST_SHA256"

gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
LATEST_TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq .tagName)"
[ "$LATEST_TAG" = "$TAG" ] || {
  printf 'Published release did not become Latest; stable appcast would remain stale\n' >&2
  exit 1
}
printf 'Published Detach %s to %s (%s)\n' "$VERSION" "$REPOSITORY" "$TAG"
