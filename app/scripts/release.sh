#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd -P "$APP_ROOT/.." && pwd)"
VERSION="${DETACH_VERSION:-$(<"$REPO_ROOT/VERSION")}"
IDENTITY="${DETACH_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${DETACH_NOTARY_PROFILE:-}"
BUILD_VERSION="${DETACH_BUILD_VERSION:-}"
SPARKLE_FEED_URL="${DETACH_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${DETACH_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_ED_KEY_FILE="${DETACH_SPARKLE_ED_KEY_FILE:-}"
SPARKLE_KEY_ACCOUNT="${DETACH_SPARKLE_KEY_ACCOUNT:-dev.tsarev.detach}"
REPOSITORY="${DETACH_GITHUB_REPOSITORY:-}"
TAG="${DETACH_RELEASE_TAG:-v$VERSION}"
DOWNLOAD_URL_PREFIX="${DETACH_SPARKLE_DOWNLOAD_URL_PREFIX:-}"
DOWNLOAD_URL="${DETACH_DOWNLOAD_URL:-}"
INITIAL_RELEASE="${DETACH_INITIAL_RELEASE:-0}"
APP="$APP_ROOT/build/Detach.app"
DMG="$APP_ROOT/build/Detach.dmg"
NOTARY_ZIP="$APP_ROOT/build/Detach-$VERSION-notarization.zip"
UPDATE_ASSETS="$APP_ROOT/build/update-assets"
UPDATE_ZIP="$UPDATE_ASSETS/Detach-$VERSION.zip"
APPCAST="$UPDATE_ASSETS/appcast.xml"
RELEASE_MANIFEST="$UPDATE_ASSETS/release-manifest.json"
NOTARY_EVIDENCE="$APP_ROOT/build/notarization-$VERSION"
APPCAST_VERIFIER="$APP_ROOT/scripts/verify-appcast.sh"
DEFAULT_SPARKLE_GENERATE_APPCAST="$APP_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$APP_ROOT/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$APP_ROOT/.build/module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

[ -n "$IDENTITY" ] || {
  printf 'DETACH_CODESIGN_IDENTITY is required for a release\n' >&2
  exit 1
}
case "$IDENTITY" in
  'Developer ID Application: '*) ;;
  *)
    printf 'DETACH_CODESIGN_IDENTITY must name a Developer ID Application identity\n' >&2
    exit 1
    ;;
esac
[ -n "$NOTARY_PROFILE" ] || {
  printf 'DETACH_NOTARY_PROFILE is required for a release\n' >&2
  exit 1
}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || {
  printf 'Invalid Detach version: %s\n' "$VERSION" >&2
  exit 1
}
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] || {
  printf 'DETACH_BUILD_VERSION is required and must be a positive monotonic integer\n' >&2
  exit 1
}
[[ "$INITIAL_RELEASE" = 0 || "$INITIAL_RELEASE" = 1 ]] || {
  printf 'DETACH_INITIAL_RELEASE must be 0 or 1\n' >&2
  exit 1
}
[[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  printf 'DETACH_SPARKLE_PUBLIC_ED_KEY is required and must be a base64 Ed25519 public key\n' >&2
  exit 1
}
if [ -n "$SPARKLE_ED_KEY_FILE" ] && [ ! -r "$SPARKLE_ED_KEY_FILE" ]; then
  printf 'DETACH_SPARKLE_ED_KEY_FILE is not readable: %s\n' "$SPARKLE_ED_KEY_FILE" >&2
  exit 1
fi
[[ "$TAG" =~ ^v[0-9A-Za-z._+-]+$ ]] || {
  printf 'Invalid release tag: %s\n' "$TAG" >&2
  exit 1
}
if [ -n "$REPOSITORY" ]; then
  [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    printf 'Invalid GitHub repository: %s\n' "$REPOSITORY" >&2
    exit 1
  }
fi
if [ -z "$SPARKLE_FEED_URL" ] && [ -n "$REPOSITORY" ]; then
  SPARKLE_FEED_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
fi
[[ "$SPARKLE_FEED_URL" =~ ^https://[^[:space:]]+$ ]] || {
  printf 'DETACH_SPARKLE_FEED_URL is required and must be HTTPS\n' >&2
  exit 1
}
if [ -z "$DOWNLOAD_URL_PREFIX" ] && [ -n "$REPOSITORY" ]; then
  DOWNLOAD_URL_PREFIX="https://github.com/$REPOSITORY/releases/download/$TAG/"
fi
[[ "$DOWNLOAD_URL_PREFIX" =~ ^https://[^[:space:]]+/$ ]] || {
  printf 'DETACH_SPARKLE_DOWNLOAD_URL_PREFIX is required, must be HTTPS, and must end in /\n' >&2
  exit 1
}
if [ -z "$DOWNLOAD_URL" ] && [ -n "$REPOSITORY" ]; then
  DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/latest"
fi
[[ "$DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]] || {
  printf 'DETACH_DOWNLOAD_URL is required and must be HTTPS\n' >&2
  exit 1
}

GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"

verify_source_provenance() {
  local current_commit
  local tag_commit

  current_commit="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
  [ "$current_commit" = "$GIT_COMMIT" ] || {
    printf 'Repository HEAD changed during the release (%s -> %s)\n' \
      "$GIT_COMMIT" "$current_commit" >&2
    exit 1
  }
  [ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ] || {
    printf 'Production release requires a clean git worktree\n' >&2
    exit 1
  }
  tag_commit="$(git -C "$REPO_ROOT" rev-list -n 1 "$TAG" 2>/dev/null || true)"
  [ -n "$tag_commit" ] && [ "$tag_commit" = "$GIT_COMMIT" ] || {
    printf 'Release tag %s must exist locally and point to HEAD (%s)\n' \
      "$TAG" "$GIT_COMMIT" >&2
    exit 1
  }
}

verify_source_provenance

SPARKLE_GENERATE_APPCAST="${DETACH_SPARKLE_GENERATE_APPCAST:-$DEFAULT_SPARKLE_GENERATE_APPCAST}"
if [ -z "${DETACH_SPARKLE_GENERATE_APPCAST:-}" ] && \
    [ ! -x "$SPARKLE_GENERATE_APPCAST" ]; then
  # A clean checkout has no binary artifact yet. Resolving the pinned package
  # downloads Sparkle's framework and release tools without doing the much
  # more expensive application build.
  swift package --disable-sandbox --package-path "$APP_ROOT" resolve
  SPARKLE_GENERATE_APPCAST="$DEFAULT_SPARKLE_GENERATE_APPCAST"
fi
[ -x "$SPARKLE_GENERATE_APPCAST" ] || {
  printf 'Sparkle generate_appcast was not found; resolve SwiftPM dependencies first\n' >&2
  exit 1
}
SPARKLE_GENERATE_KEYS="${DETACH_SPARKLE_GENERATE_KEYS:-$(dirname "$SPARKLE_GENERATE_APPCAST")/generate_keys}"
[ -x "$SPARKLE_GENERATE_KEYS" ] || {
  printf 'Sparkle generate_keys was not found beside generate_appcast\n' >&2
  exit 1
}

if [ -n "$SPARKLE_ED_KEY_FILE" ]; then
  SIGNING_PUBLIC_ED_KEY="$("$APP_ROOT/scripts/sparkle-public-key.sh" "$SPARKLE_ED_KEY_FILE")"
else
  SIGNING_PUBLIC_ED_KEY="$("$SPARKLE_GENERATE_KEYS" -p --account "$SPARKLE_KEY_ACCOUNT")"
fi
[ "$SIGNING_PUBLIC_ED_KEY" = "$SPARKLE_PUBLIC_ED_KEY" ] || {
  printf 'DETACH_SPARKLE_PUBLIC_ED_KEY does not match the configured signing key\n' >&2
  exit 1
}

rm -rf "$NOTARY_EVIDENCE" "$UPDATE_ASSETS"
mkdir -p "$NOTARY_EVIDENCE" "$UPDATE_ASSETS"
CODESIGN_IDENTITIES="$(security find-identity -v -p codesigning)"
grep -F "\"$IDENTITY\"" <<<"$CODESIGN_IDENTITIES" >/dev/null || {
  printf 'Developer ID signing identity is not installed or valid: %s\n' "$IDENTITY" >&2
  exit 1
}
# Authenticate before spending time on the application build. The history is
# also useful retained evidence about which notary account accepted the run.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >"$NOTARY_EVIDENCE/notary-history.json"

if curl --fail --location --silent --show-error --max-time 30 \
    "$SPARKLE_FEED_URL" -o "$NOTARY_EVIDENCE/previous-appcast.xml" \
    2>"$NOTARY_EVIDENCE/previous-appcast-fetch.txt"; then
  xmllint --noout "$NOTARY_EVIDENCE/previous-appcast.xml"
  PREVIOUS_BUILDS="$(xmllint --xpath '//*[local-name()="version"]/text()' \
    "$NOTARY_EVIDENCE/previous-appcast.xml")"
  [ -n "$PREVIOUS_BUILDS" ] || {
    printf 'Existing appcast does not contain a Sparkle build version\n' >&2
    exit 1
  }
  while IFS= read -r previous_build; do
    [[ "$previous_build" =~ ^[1-9][0-9]*$ ]] || {
      printf 'Existing appcast contains a non-integer Sparkle build version\n' >&2
      exit 1
    }
  done <<<"$PREVIOUS_BUILDS"
  PREVIOUS_BUILD="$(sort -n <<<"$PREVIOUS_BUILDS" | tail -1)"
  [ "$BUILD_VERSION" -gt "$PREVIOUS_BUILD" ] || {
    printf 'DETACH_BUILD_VERSION must exceed the published build %s\n' "$PREVIOUS_BUILD" >&2
    exit 1
  }
else
  rm -f "$NOTARY_EVIDENCE/previous-appcast.xml"
  [ "$INITIAL_RELEASE" = 1 ] || {
    printf 'Cannot verify the previous appcast; retry or set DETACH_INITIAL_RELEASE=1 for the first release\n' >&2
    exit 1
  }
fi

submit_for_notarization() {
  local label="$1"
  local artifact="$2"
  local result="$NOTARY_EVIDENCE/$label-submit.json"
  local submission_id
  local status

  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json >"$result"
  status="$(plutil -extract status raw -o - "$result")"
  submission_id="$(plutil -extract id raw -o - "$result")"
  [ "$status" = Accepted ] || {
    printf 'Notarization was not accepted for %s (status: %s)\n' "$artifact" "$status" >&2
    exit 1
  }
  xcrun notarytool log "$submission_id" "$NOTARY_EVIDENCE/$label-log.json" \
    --keychain-profile "$NOTARY_PROFILE"
}

DETACH_BUILD_ARCHS=arm64 DETACH_BUILD_VERSION="$BUILD_VERSION" \
  DETACH_RELEASE_BUILD=1 \
  DETACH_CODESIGN_IDENTITY="$IDENTITY" \
  DETACH_SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  DETACH_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  DETACH_DOWNLOAD_URL="$DOWNLOAD_URL" \
  "$APP_ROOT/scripts/make-app.sh"

rm -f "$NOTARY_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
submit_for_notarization app "$NOTARY_ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" >"$NOTARY_EVIDENCE/app-stapler.txt" 2>&1
spctl --assess --type execute --verbose=2 "$APP" >"$NOTARY_EVIDENCE/app-gatekeeper.txt" 2>&1

# Sparkle update archives contain the already notarized and stapled app. The
# EdDSA signature for this archive is added to the generated appcast below.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATE_ZIP"
chmod 0644 "$UPDATE_ZIP"

DETACH_CODESIGN_IDENTITY="$IDENTITY" DETACH_APP_PATH="$APP" \
  DETACH_VERSION="$VERSION" DETACH_DMG_VERIFY_PRODUCTION=1 \
  DETACH_DMG_PATH="$DMG" "$APP_ROOT/scripts/make-dmg.sh"
submit_for_notarization dmg "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" >"$NOTARY_EVIDENCE/dmg-stapler.txt" 2>&1
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" \
  >"$NOTARY_EVIDENCE/dmg-gatekeeper.txt" 2>&1
hdiutil verify "$DMG" >"$NOTARY_EVIDENCE/dmg-hdiutil.txt" 2>&1
chmod 0644 "$DMG"
(
  cd -P "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256"
  chmod 0644 "$(basename "$DMG").sha256"
)

generate_appcast_args=(
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"
  --link "$DOWNLOAD_URL"
  --versions "$BUILD_VERSION"
  --maximum-deltas 0
  -o "$APPCAST"
)
if [ -n "$SPARKLE_ED_KEY_FILE" ]; then
  generate_appcast_args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
  generate_appcast_args+=(--account "$SPARKLE_KEY_ACCOUNT")
fi
"$SPARKLE_GENERATE_APPCAST" "${generate_appcast_args[@]}" "$UPDATE_ASSETS"
"$APPCAST_VERIFIER" "$APPCAST"
grep -F "url=\"$DOWNLOAD_URL_PREFIX$(basename "$UPDATE_ZIP")\"" "$APPCAST" >/dev/null || {
  printf 'Generated appcast has an unexpected update URL\n' >&2
  exit 1
}
GENERATED_BUILD="$(xmllint --xpath 'string((//*[local-name()="version"])[1])' "$APPCAST")"
[ "$GENERATED_BUILD" = "$BUILD_VERSION" ] || {
  printf 'Generated appcast has an unexpected build version\n' >&2
  exit 1
}
grep -F 'sparkle:edSignature=' "$APPCAST" >/dev/null || {
  printf 'Generated appcast does not contain an EdDSA signature\n' >&2
  exit 1
}

for update_asset in "$UPDATE_ASSETS"/*; do
  [ -f "$update_asset" ] || continue
  case "$update_asset" in
    *.sha256) continue ;;
  esac
  (
    cd -P "$UPDATE_ASSETS"
    chmod 0644 "$(basename "$update_asset")"
    shasum -a 256 "$(basename "$update_asset")" >"$(basename "$update_asset").sha256"
    chmod 0644 "$(basename "$update_asset").sha256"
  )
done

DMG_SHA256="$(awk '{print $1}' "$DMG.sha256")"
UPDATE_SHA256="$(awk '{print $1}' "$UPDATE_ZIP.sha256")"
APPCAST_SHA256="$(awk '{print $1}' "$APPCAST.sha256")"
# Package resolution and notarization are intentionally long-running. Recheck
# the source immediately before recording provenance so a changed HEAD,
# rewritten lockfile, or concurrent worktree edit can never be attributed to
# the preflight commit.
verify_source_provenance
# `plutil -insert` on a JSON input tries to round-trip through the unsupported
# OpenStep writer on some macOS versions. Build as an XML plist, then convert
# the finished dictionary to JSON atomically before checksumming it.
plutil -create xml1 "$RELEASE_MANIFEST"
plutil -insert schema -integer 1 "$RELEASE_MANIFEST"
plutil -insert version -string "$VERSION" "$RELEASE_MANIFEST"
plutil -insert build -string "$BUILD_VERSION" "$RELEASE_MANIFEST"
plutil -insert tag -string "$TAG" "$RELEASE_MANIFEST"
plutil -insert git_commit -string "$GIT_COMMIT" "$RELEASE_MANIFEST"
plutil -insert feed_url -string "$SPARKLE_FEED_URL" "$RELEASE_MANIFEST"
plutil -insert update_url -string "$DOWNLOAD_URL_PREFIX$(basename "$UPDATE_ZIP")" \
  "$RELEASE_MANIFEST"
plutil -insert download_url -string "$DOWNLOAD_URL" "$RELEASE_MANIFEST"
plutil -insert dmg_sha256 -string "$DMG_SHA256" "$RELEASE_MANIFEST"
plutil -insert update_sha256 -string "$UPDATE_SHA256" "$RELEASE_MANIFEST"
plutil -insert appcast_sha256 -string "$APPCAST_SHA256" "$RELEASE_MANIFEST"
plutil -convert json "$RELEASE_MANIFEST"
plutil -p "$RELEASE_MANIFEST" >/dev/null
chmod 0644 "$RELEASE_MANIFEST"
(
  cd -P "$UPDATE_ASSETS"
  shasum -a 256 "$(basename "$RELEASE_MANIFEST")" \
    >"$(basename "$RELEASE_MANIFEST").sha256"
  chmod 0644 "$(basename "$RELEASE_MANIFEST").sha256"
)

public_artifacts=(
  "$DMG"
  "$DMG.sha256"
  "$UPDATE_ZIP"
  "$UPDATE_ZIP.sha256"
  "$APPCAST"
  "$APPCAST.sha256"
  "$RELEASE_MANIFEST"
  "$RELEASE_MANIFEST.sha256"
)
for public_artifact in "${public_artifacts[@]}"; do
  [ -f "$public_artifact" ] && [ ! -L "$public_artifact" ] && \
    [ "$(stat -f '%Lp' "$public_artifact")" = 644 ] || {
      printf 'Public release artifact must be a regular file with mode 0644: %s\n' \
        "$public_artifact" >&2
      exit 1
    }
done

rm -f "$NOTARY_ZIP"
printf 'Release artifacts ready: %s and %s\n' "$DMG" "$UPDATE_ASSETS"
printf 'Notarization evidence retained: %s\n' "$NOTARY_EVIDENCE"
