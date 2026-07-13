#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
REPOSITORY="${DETACH_GITHUB_REPOSITORY:-}"
TAG="${DETACH_RELEASE_TAG:-v$VERSION}"
DMG="$APP_ROOT/build/Detach-$VERSION.dmg"
CHECKSUM="$DMG.sha256"

[ -n "$REPOSITORY" ] || {
  printf 'DETACH_GITHUB_REPOSITORY (owner/repository) is required\n' >&2
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
command -v gh >/dev/null 2>&1 || {
  printf 'GitHub CLI (gh) is required\n' >&2
  exit 1
}
[ -f "$DMG" ] && [ -f "$CHECKSUM" ] || {
  printf 'Release artifacts are missing; run app/scripts/release.sh first\n' >&2
  exit 1
}
(
  cd -P "$(dirname "$DMG")"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)
gh auth status >/dev/null
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  printf 'Release already exists; refusing to replace assets: %s %s\n' "$REPOSITORY" "$TAG" >&2
  exit 1
fi

gh release create "$TAG" "$DMG" "$CHECKSUM" \
  --repo "$REPOSITORY" \
  --title "Detach $VERSION" \
  --generate-notes
printf 'Published Detach %s to %s (%s)\n' "$VERSION" "$REPOSITORY" "$TAG"
