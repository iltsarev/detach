# Native power protection specification

## Contract

Power protection has two required layers and one observable combined state:

1. `detach-power` is an unprivileged, signed wrapper. It holds the public IOKit
   user-idle-system-sleep assertion, acquires a root-helper lease over XPC, runs
   the provider with inherited cwd/environment/stdio, and returns its exit code.
2. `DetachPowerHelper` is a demand-launched root daemon registered from the app.
   It manages only the machine-wide closed-lid setting through absolute
   `/usr/bin/pmset` invocations and a renewable lease registry.

The root helper installs a listener-level Foundation code-signing requirement
before accepting XPC or reconciling power state. It accepts only valid code
signed as `dev.tsarev.detach.power` by the same Team ID and only when the
connection's audit-token-derived effective UID matches the non-root owner of
`/dev/console`. Root, loginwindow/no-console, and other local UIDs are rejected;
do not replace either audit-token check with PID-based validation. Its XPC
surface is limited to status, acquire, renew, release, and the typed
prepare/cancel unregistration lifecycle; it must never execute arbitrary paths,
shell strings, or provider commands as root.

The client opens a short-lived XPC connection for every request. After Fast
User Switching, the previous background user's next heartbeat, status, or
release request is rejected and an unrenewed lease expires through the normal
TTL; an RPC already in flight may finish before its connection is invalidated.
At logout/loginwindow `/dev/console` is root-owned, so new helper requests are
rejected. Detach does not promise session survival across logout.

Helper state is durable at `/var/db/dev.tsarev.detach/power-state.json`, with a
private `0700` directory, `0600` regular file, symlink rejection, atomic writes,
and file/directory fsync. Ownership intent is persisted before changing power
state. A pre-existing enabled setting is borrowed and never disabled. A setting
Detach enabled is restored after the last live lease, a stale lease, low
battery, or orderly SIGTERM/SIGINT handling. The state records the current
`kern.bootsessionuuid`; a different boot clears every old lease before power is
reconciled, and implausibly future renewal timestamps expire rather than live
forever. Do not manually change the same machine-wide boolean while Detach owns
it.

The client lease heartbeat remains every 30 seconds; the helper reconciles
machine power state every 10 seconds. Leases expire after 120 seconds without
renewal, with a maximum of 256. Transient renewal failures are retried; an
active failure is surfaced rather than silently reporting protection. Read-only
status returns a cached snapshot refreshed at startup, after mutations, and by
the reconciler. It must never invoke `pmset` or wait behind the root mutation
lock, so UI, watchdog, and tmux polling remain nonblocking.

The default initial acquire carries an eight-second absolute server deadline.
If protection is not confirmed before it, root rolls back only that request's
persisted lease, restores a previous matching lease when applicable, and
reconciles the owned setting before returning failure. This prevents a timed-out
caller from activating protection later. The outer XPC timeout remains 30
seconds so rollback can finish. Root `pmset` invocations have bounded output and
a two-second timeout. The readable tmux power label refreshes every ten seconds
rather than spawning one root status request every two seconds per session.

The low-battery threshold is 10% while on battery power. The helper releases
closed-lid protection it owns, the wrapper releases its IOKit assertion, and the
provider is allowed to finish only while the Mac remains awake. Initial
acquisition fails closed at low battery. A borrowed external setting cannot be
turned off, so status must never falsely report the low-battery safe state while
that setting remains active.

While the wrapper holds a confirmed protected run, it observes the documented
IOPMrootDomain clamshell notification. Each physical open-to-closed transition
requests `/usr/bin/pmset displaysleepnow` as the unprivileged console user so
macOS follows the user's normal Lock Screen policy without Apple Events,
Automation, or synthetic input. The initial clamshell state is only a baseline:
starting a run while the lid is already closed must not lock an external-display
workflow. Repeated closed notifications lock only once until the lid reopens.
This does not rewrite the user's password-delay setting. A MacBook run must
fail before provider launch if the clamshell notification cannot be installed;
a desktop Mac with no clamshell property continues without that monitor.

`pmset -a disablesleep 0|1` and its `SleepDisabled` output are undocumented
macOS interfaces. Parser/unit tests do not establish real closed-lid behavior.
Every release candidate must pass the explicitly opted-in signed smoke test and
a supervised test on real supported Apple Silicon hardware before publication.
Exact arm64 slice and launch verification remains required.
