#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'test-suite-contract: %s\n' "$*" >&2
  exit 1
}

[ -x "$ROOT/scripts/test" ] || fail 'scripts/test must be executable'
grep -F 'CLANG_MODULE_CACHE_PATH="$ROOT/app/.build/module-cache"' \
  "$ROOT/scripts/test" >/dev/null || fail 'Swift suites must use the private module cache'
grep -F 'SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"' \
  "$ROOT/scripts/test" >/dev/null || fail 'SwiftPM must share the private module cache'

critical="$($ROOT/scripts/test --plan critical)"
unit="$($ROOT/scripts/test --plan unit)"
coverage="$($ROOT/scripts/test --plan coverage)"
smoke="$($ROOT/scripts/test --plan smoke)"
full="$($ROOT/scripts/test --plan full)"

for suite in \
  ClamshellLockRunnerTests \
  DetachPowerExecutableTests \
  DispatchPowerHeartbeatRunnerTests \
  DistributionClientTests \
  InstallationStorePowerStateTests \
  WatchdogServiceTests \
  DetachPowerCommandTests \
  DetachStateCommandTests \
  DetachStateTests \
  PowerAssertionControllerTests \
  PowerHeartbeatReaderTests \
  PowerHelperClientAuthorizationPolicyTests \
  PowerHelperHandoffStoreTests \
  PowerHelperLeaseServiceTests \
  PowerHelperLifetimeBarrierTests \
  PowerHelperPlatformTests \
  PowerHelperServiceTests \
  PowerHelperSystemHandoffLockTests \
  PowerHelperXPCClientTests \
  PowerHelperXPCServiceTests \
  ProcessChildCommandRunnerTests \
  SessionHealthTests \
  SessionIdentityTests \
  SessionMaintenanceTests \
  SessionStoreTests \
  StorageInspectorTests \
  StorageStoreTests \
  TerminalLauncherTests \
  UpdaterServiceTests \
  WatchdogHandoffStoreTests; do
  [[ "$critical" = *"$suite"* ]] || fail "critical suite is missing $suite"
  grep -R -F "final class $suite" "$ROOT/app/Tests" >/dev/null ||
    fail "critical suite does not exist: $suite"
done
[[ "$critical" = *'tests/shell-safety.sh'* ]] || fail 'critical suite is missing shell safety'
[ "$unit" = 'unit: cd app && swift test --disable-sandbox' ] ||
  fail 'unit suite must run every Swift test without packaging'
[[ "$coverage" = *'swift test --enable-code-coverage --disable-sandbox'* ]] ||
  fail 'coverage suite must collect Swift coverage'
[[ "$coverage" = *'tests/quality-ratchet.sh'* ]] ||
  fail 'coverage suite must enforce locked coverage floors'
[[ "$coverage" = *'tests/quality-contracts.sh'* ]] ||
  fail 'coverage suite must enforce quality contracts'

for command in \
  app/scripts/make-app.sh \
  tests/ui-e2e-contract.sh \
  tests/ui-e2e.sh \
  tests/tmux-runtime.sh; do
  [[ "$smoke" = *"$command"* ]] || fail "smoke suite is missing $command"
done

[ "$full" = 'full: scripts/quality-gate --mode repository' ] ||
  fail 'full suite must delegate to the repository quality gate'

if "$ROOT/scripts/test" --plan unknown >"${TMPDIR:-/tmp}/detach-test-suite.out.$$" 2>&1; then
  rm -f "${TMPDIR:-/tmp}/detach-test-suite.out.$$"
  fail 'unknown suite unexpectedly succeeded'
fi
rm -f "${TMPDIR:-/tmp}/detach-test-suite.out.$$"

printf 'Test suite contracts passed\n'
