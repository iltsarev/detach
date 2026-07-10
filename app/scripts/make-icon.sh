#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET="build/Detach.iconset"
rm -rf "$ICONSET"
mkdir -p build Resources
swift scripts/render-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/Detach.icns
printf 'Built Resources/Detach.icns\n'
