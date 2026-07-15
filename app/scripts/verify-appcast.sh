#!/bin/bash

set -euo pipefail

APPCAST="${1:-}"

[ -n "$APPCAST" ] && [ -f "$APPCAST" ] || {
  printf 'Usage: %s APPCAST\n' "$0" >&2
  exit 2
}
[ "$#" -eq 1 ] || {
  printf 'Usage: %s APPCAST\n' "$0" >&2
  exit 2
}

xmllint --noout "$APPCAST"
HARDWARE_REQUIREMENT_COUNT="$(xmllint --xpath \
  'count(//*[local-name()="hardwareRequirements" and namespace-uri()="http://www.andymatuschak.org/xml-namespaces/sparkle"])' \
  "$APPCAST")"
[ "$HARDWARE_REQUIREMENT_COUNT" = 1 ] || {
  printf 'Appcast must contain exactly one sparkle:hardwareRequirements element\n' >&2
  exit 1
}
HARDWARE_REQUIREMENT="$(xmllint --xpath \
  'normalize-space(string((//*[local-name()="hardwareRequirements" and namespace-uri()="http://www.andymatuschak.org/xml-namespaces/sparkle"])[1]))' \
  "$APPCAST")"
[ "$HARDWARE_REQUIREMENT" = arm64 ] || {
  printf 'Appcast hardware requirement must be exactly arm64\n' >&2
  exit 1
}
