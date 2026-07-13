#!/bin/bash

set -euo pipefail

APP_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
PRIVATE_KEY_FILE="${1:-}"

[ -n "$PRIVATE_KEY_FILE" ] && [ -r "$PRIVATE_KEY_FILE" ] || {
  printf 'Usage: %s <Sparkle Ed25519 private key file>\n' "$0" >&2
  exit 1
}

MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-$APP_ROOT/.build/module-cache}"
mkdir -p "$MODULE_CACHE"

# Sparkle 2.9 exports a private key as a base64-encoded 32-byte Ed25519 seed.
# Derive the corresponding public key without importing the secret into the
# login Keychain or exposing its contents in the process arguments.
SPARKLE_PRIVATE_KEY_FILE="$PRIVATE_KEY_FILE" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift -module-cache-path "$MODULE_CACHE" -e '
    import CryptoKit
    import Foundation

    guard let path = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY_FILE"] else {
        fatalError("SPARKLE_PRIVATE_KEY_FILE is missing")
    }
    let encoded = try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
        fatalError("Sparkle private key must be a base64-encoded 32-byte seed")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
  '
