#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tests/quality_test_changes_contract.py"
printf 'Quality test change contracts passed\n'
