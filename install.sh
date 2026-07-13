#!/bin/bash

set -u
set -o pipefail

ROOT="$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)" || exit 1
exec "$ROOT/scripts/install.sh" install --source install.sh "$@"
