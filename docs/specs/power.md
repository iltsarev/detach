# Native power protection specification

## Contract

Power protection has two required layers and one observable combined state:

1. `detach-power` is an unprivileged, signed wrapper. It holds the public IOKit
   user-idle-system-sleep assertion and a root-helper lease over XPC while its
   provider is working. It runs the provider with inherited
   cwd/environment/stdio and returns its exit code.
2. `DetachPowerHelper` is a demand-launched root daemon registered from the app.
   It manages only the machine-wide closed-lid setting through absolute
   `/usr/bin/pmset` invocations and a renewable lease registry.

The wrapper must acquire both layers before provider launch. It watches a
private, run-token-scoped activity file. Before it accepts `waiting`, it also
validates a recorded inode/mtime/size snapshot and starts an event watcher on the
exact provider transcript. It then stages the helper lease as
assertion-inactive, releases the IOKit assertion, and releases the helper lease.
Any transcript change immediately means `working` and reacquires both layers;
it does not wait for the idle runtime heartbeat. A transcript event belongs to
the watch generation that delivered it: an event from a cancelled watch must
not cancel its replacement or change the reported state. Missing, changed, or
malformed handoff state stays `working`. Transition failures are surfaced and
must not claim that sleep is safe. The provider continues while waiting.

Each working session owns a separate helper lease. Outside the low-battery and
thermal fail-safe states, the helper keeps the machine-wide closed-lid setting
active while at least one working lease exists. Detach can permit normal sleep
only after every live session is waiting or stopped. One waiting session must
never release another working session's protection. Acquire and renewal
confirmation are scoped to the requesting lease. A staged assertion-inactive
lease from another session must not fail an unrelated acquire or renewal. The
low-battery and thermal fail-safe refusals still fail closed for every
request.

The root helper installs a listener-level Foundation code-signing requirement
before accepting XPC or reconciling power state. It accepts only valid code
signed as `dev.tsarev.detach.power` by the same Team ID and only when the
connection's audit-token-derived effective UID matches the non-root owner of
`/dev/console`. Root, loginwindow/no-console, and other local UIDs are rejected;
do not replace either audit-token check with PID-based validation. Its XPC
surface is limited to status, acquire, renew, release, the typed
prepare/cancel unregistration lifecycle, and the typed low-battery threshold
mutation; it must never execute arbitrary paths, shell strings, or provider
commands as root.

Before it creates the listener or changes power state, the helper must pass a
strict check of its own signature with Security network access enabled. This
check lets macOS refresh the system trust result that the listener needs for
the same Developer ID chain. If trust cannot be proved, the helper exits and
launchd retries it. The listener requirement stays Apple-anchored and is not
weakened for an unavailable trust service.

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
battery, or orderly SIGTERM/SIGINT handling. After shutdown begins, the helper
refuses queued reconciliations, so a retained live lease cannot re-enable the
setting before exit. A state file that cannot be loaded is renamed aside with
a `.corrupt-<timestamp>` suffix, and the helper starts from a clean state
instead of a launchd crash loop. Unreadable state never proves
ownership, so a borrowed setting stays untouched. The state records the current
`kern.bootsessionuuid`; a different boot clears every old lease before power is
reconciled, and implausibly future renewal timestamps expire rather than live
forever. Do not manually change the same machine-wide boolean while Detach owns
it.

The client lease heartbeat remains every 30 seconds while protected; the helper
reconciles machine power state every 10 seconds. Leases expire after 120 seconds
without renewal, with a maximum of 256 live leases. Expired leases are pruned
before the count limit is enforced. The runtime health loop slows from ten
to 30 seconds while waiting, below its 45-second stale limit. Transient renewal
failures are retried; an active failure is surfaced rather than silently
reporting protection. Read-only
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
while working and every 30 seconds while waiting, rather than spawning one root
status request every two seconds per session.

The low-battery threshold is 10%, 15%, or 20% while on battery power. The
default and minimum is 10%. Settings → System writes the floor through the
typed helper XPC method. The helper persists it in helper state. A missing or
unknown stored value becomes 10%. Any other write is rejected. `detach config`
does not own this value. The helper releases closed-lid protection it owns, the
wrapper releases its IOKit assertion, and the provider is allowed to finish
only while the Mac remains awake. Initial acquisition fails closed at low
battery. A borrowed external setting cannot be turned off, so status must never
falsely report the low-battery safe state while that setting remains active.
The live floor crosses helper status, CLI JSON, and the watchdog heartbeat.

Thermal safety uses only public `ProcessInfo.thermalState`. `serious` and
`critical` latch safety immediately: the helper restores Detach-owned
closed-lid sleep, the wrapper releases its IOKit assertion without waiting for
a checkpoint, and initial acquisition is refused. A notification-time release
failure is retained and surfaced by the next heartbeat or protected-run result;
it must never disappear behind best-effort cleanup. Each heartbeat retries the
safety release and advances the cooldown. Only a confirmed release clears the
retained failure; a release that still fails stays surfaced. `nominal` and
`fair` must remain stable for 30 seconds before protection can return; the
helper persists this cooldown across restart, and an unknown reading cannot
clear it. The raw
`nominal|fair|serious|critical|unknown` value and latch cross helper status, CLI
JSON, watchdog, tmux, and app. Low battery wins the combined reason when both
guards are active, while the thermal fields remain visible. Borrowed external
`disablesleep` is never disabled, so neither safety state may falsely claim the
Mac can sleep while it remains active.

While the wrapper holds a confirmed protected run, it observes the documented
IOPMrootDomain clamshell notification. Each physical open-to-closed transition
requests `/usr/bin/pmset displaysleepnow` as the unprivileged console user so
macOS follows the user's normal Lock Screen policy without Apple Events,
Automation, or synthetic input. The lock request has bounded execution: a
two-second timeout with SIGTERM-to-SIGKILL escalation. A hung `pmset` must not
block the clamshell monitor or delay wrapper cleanup. The initial clamshell
state is only a baseline:
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
