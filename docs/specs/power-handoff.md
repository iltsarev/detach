# Helper and watchdog replacement specification

## Contract

<a id="qc-power-handoff"></a>

App updates replace the helper through a durable `SMAppService` handoff. Only
the complete Developer ID release bundle may register or unregister the helper
or watchdog. The app, helper, and watchdog must have their exact code
identifiers and the same valid Team ID. An ad-hoc build or preview stays
read-only at this boundary.

An enabled registration needs a held root lifetime lock before the app calls
the helper's prepare method. A missing or released lifetime lock proves that no
helper process can answer. The app then skips XPC preparation and replays the
submitted unregister phase under the system and per-user transaction locks.
Only a busy lifetime lock permits the prepare call. A replacement is not
registered until the old lifetime lock is released or an exact absent-job
callback provides the required completion barrier. An absent-job callback is
`kSMErrorJobNotFound` or the `SMAppServiceErrorDomain` `EPERM` reply that
macOS 26 returns for a label without a Background Task Management record. The
app accepts either reply only with exact `notRegistered` status, or no
record (`notFound`), plus the lifetime-barrier wait; an `EPERM` reply for a
live record stays fail-closed.
The watchdog journal records the boot UUID before each unregister replay.
After a restart, `notRegistered` or no record completes it unless a live
process holds the lifetime lock.
Lifetime and system handoff probes reject special files without waiting for
a FIFO writer. File validation precedes lock acquisition. Activity and source
handoff readers also reject special files without blocking and keep the
session working.

An enabled registration with a matching bundled-definition digest is not
enough to prove liveness. At startup, a missing or released lifetime lock that
stays unheld after a three-second grace also forces the durable replacement
flow. The grace covers login, when the app and the service start together.
This repairs a stale Background Task Management parent UUID after an app
bundle is replaced with the same version. For a legacy watchdog without a
lifetime lock, the exact bundled executable may prove that the old
registration is still live.

Helper replacement is a durable fail-closed transaction. One versioned journal
records the phase, goal, target digest, boot UUID, and lifetime-barrier contract.
Each transition uses atomic rename and file/directory fsync before its side
effect. A per-user `flock` protects the journal. The root helper also creates a
stable root-owned `0644` inode under `/var/run`; every app user opens it read-only and holds one exclusive
kernel `flock` across the complete asynchronous SMAppService transaction. This
is the machine-wide single-writer barrier across Fast User Switching, and the
kernel releases it if the app crashes. Only the current non-root console user's
app may perform register or unregister mutations, checked again immediately
before each mutation. Root persists `unregistration_pending`, blocks
acquire/renew without a wall-clock expiry, and restores and reads back only the
setting Detach owns.

The helper takes a root-owned lifetime `flock` before its listener answers and
holds it until exit. An enabled job without this boot's lock is dead. The app
writes `unregisterSubmitted` only after it observes that lock. Registration
needs the fresh unregister callback, or exact `notRegistered` status plus the
released lock or a changed boot UUID with no live lock holder; `unavailable`
with a record is insufficient. Errors
keep the journal and root gate closed. After an app crash, another console user
uses the root-created files to resume at `unregisterSubmitted`, never as a
pristine install.

Before registering a replacement the app fsyncs `registering` with the target
digest. After macOS reports the new helper enabled, a successful cancel XPC
reply proves launch readiness and reopens the gate; only then is the definition
recorded and the journal cleared. Approval and retry failures remain pending for
the next launch. An ordinary helper SIGTERM/SIGINT uses only the process-local
termination gate and must not create persistent update state.

## Verification

Run PowerHelperServiceTests and WatchdogServiceTests. A replacement must wait
for the old service lifetime barrier. A failed transaction must retain its
journal and keep the root gate closed.
