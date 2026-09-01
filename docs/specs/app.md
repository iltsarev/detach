# Detach.app specification

## Contract

`app/` is a SwiftPM package with `DetachKit`, `DetachApp`,
`DetachWatchdog`, `DetachState`, `DetachPower`, and `DetachPowerHelper`. The app
bundles signed arm64-only executables, the immutable CLI payload, pinned tmux
sources/licenses/provenance, Sparkle, SwiftTerm, and their license notices.

`ANSIParser` strips non-SGR sequences and preserves colors, bold, dim, italic,
underline, strikethrough, and reverse video. Reverse swaps colors against
`ANSIParser.terminalBackground`, also the `LogTextView` background. Font
scaling changes only the font.

Onboarding uses the pure reducer in `SetupGuidance.step(for:)`; a setup failure
outranks provider discovery. A bare
`SMAppService.status == .enabled` read never completes the permissions step.
The live poller reads status without side effects and reconciles once when it
becomes enabled. Only confirmed readiness (a
finished helper journal and an open root gate) advances the step. Registration
can stay in `requiresApproval`; do not treat it as enabled before macOS does.
Each done-step poll rereads the watchdog heartbeat. The success card disables
its dashboard action until the heartbeat is fresh. After a long wait, it offers
a monitor retry, not a bypass. The store records completion exactly once, only
after that action. Repair and first-run synchronization also reread the
heartbeat before replacing a silent registration.
If a doctor refresh fails or detects another runtime identity, the app
withdraws the earlier helper-readiness confirmation.

After onboarding, `.idle`, `.syncing`, `.updateDeferred`, and `.ready` present
`.mainApp`. Bootstrap, refresh, and an update held by active leases keep the
dashboard. Only a completed `.actionRequired` or `.failed` result shows setup;
a missing provider keeps the dashboard. Provider installation uses the official command,
launched visibly in the user's own terminal through the private `.command`
mechanism; never claim a guided install failed (there is no outcome channel),
only that the CLI is not detected yet. When helper/plist bytes change after an
app update, unregister, await completion, then use the bounded retry for the
transient SMAppService Code=1 race. Do not replace a helper with active leases:
defer the update. Report a normal reconciliation outcome and retry on the next
activation.

Each readiness build puts one `detach-app-build:<UUID>` in its executable and
signed marker. UI smoke uses a stripped private copy below
`/private/tmp/detach-ui-e2e.*` without production payloads. An escaped path,
unsafe identity, build mismatch, or payload fails closed.

Smoke restores focus and the pointer and sends ordered AppKit events to measured
visible controls; semantic probes have no actions. It covers main surfaces,
Settings, onboarding, focus, Codex Recover, Claude Resume, reconnect, and App
Start through typed selection and PTY attach. Stop disconnects before control
invocation. Each stage has a deadline. Coverage isolates the normal bundle,
instrumented copy, Swift tests, binary, and profiles. UI precedes metrics; only
the private copy is instrumented. The driver reveals clipped controls before
posting an action.

The per-user watchdog adds a launch-readiness rule: macOS can report an approved
agent as enabled while no launchd job loaded after approval. During first
onboarding or Repair, an enabled watchdog without a fresh heartbeat uses the
durable unregister/barrier/register transaction. Ordinary activation does not
replace it for a temporarily stale heartbeat.

The display-only menu mark is filled for protected, dim for sleep allowed,
badged for attention, and outlined for unknown. Starting/running/recovering are
active; hung is not. Waiting wins over working. VoiceOver names every state.
`state · reason · freshness` uses typed heartbeat time, not mtime. Protected
counts workers; Allowed never claims no sessions while one is active. One
session poller serves the window, notifications, menu, and pet and only slows
when all are hidden. Closing windows keeps the app alive; Quit does not stop
sessions. General owns menu toggles; System owns scrolling Mac Power controls.

Pets loads regular v1 8x9 or v2 8x11 PNG/WebP packages. The bundled pet is a
read-only fallback; matching user IDs win. Import is atomic. Needs input needs
an event or terminal controls. Drag moves; click opens the top session or tie.

Generation requires regular `hatch-pet` and sibling `detach-state` files. It
starts one managed Codex CLI session and registers, for that invocation only, a
required stdio MCP exposing the read-only `load_workspace_dependencies` tool.
Global Codex config stays unchanged and the app stays closed. Settings
tracks IDs, spins while a turn works, opens its session for attention, and
selects a valid v2 package. Failure, disappearance, or timeout clears tracking.
Detach never synthesizes rows.

The dashboard separates identity, status, and Mac Power. Identity is a thin
tmux-colored capsule. Status is a filled circle. Power uses a neutral surface
and semantic color. Clicking the single UUID chip copies the full UUID and
shows **Copied**.

**Finished** bulk Delete stays outside `List`, uses typed Delete, asks once,
tolerates failures, and keeps transcripts. Select/Done keeps 12-point clearance.

Every app CLI invocation runs in a fresh process group that drains stdout and
stderr. Its deadline sends TERM then KILL to the group. A pipe-only descendant
cannot hold the caller past the drain deadline. GUI PATH orders NVM and mise
Node directories by semantic version.

Helper replacement is a durable fail-closed transaction. One versioned JSON
journal records `preparing`, `unregisterSubmitted`, `removed`, or `registering`,
the install/remove goal, target digest, boot UUID, and lifetime-barrier contract.
Each transition uses atomic rename and file/directory fsync before its side
effect. A per-user `flock` protects the journal. In addition, the root helper
creates a stable root-owned `0644` inode
under `/var/run`; every app user opens it read-only and holds one exclusive
kernel `flock` across the complete asynchronous SMAppService transaction. This
is the machine-wide single-writer barrier across Fast User Switching, and the
kernel releases it if the app crashes. Only the current non-root console user's
app may perform register or unregister mutations, checked again immediately
before each mutation. Root persists `unregistration_pending`, blocks
acquire/renew without a wall-clock expiry, and restores and reads back only the
setting Detach owns.

The helper takes an exclusive, root-owned lifetime `flock` before its listener
can answer prepare and holds it until exit. An enabled job with no
lifetime barrier this boot is dead; unregister may proceed. The app writes
`unregisterSubmitted` only after observing that lock. A fresh successful async
SMAppService callback is the normal process-reaped barrier. If a crash loses the
callback, exact `notRegistered` status plus acquisition of the released lifetime
lock (or a changed boot UUID) is required before registration; generic
`unavailable` is not sufficient. An unregister error keeps the journal and root
gate closed for retry rather than reopening it while a callback may be
pending. If a different user acquires the system lock after the original app
crashed and has no local journal, the existing root-created lock/lifetime files
prove this is not a pristine install: it bootstraps at `unregisterSubmitted`,
replays asynchronous unregister, and cannot register until that fresh callback
or the exact absent-job plus released-lifetime recovery barrier completes.

Before registering a replacement the app fsyncs `registering` with the target
digest. After macOS reports the new helper enabled, a successful cancel XPC
reply proves launch readiness and reopens the gate; only then is the definition
recorded and the journal cleared. Approval and retry failures remain pending for
the next launch. An ordinary helper SIGTERM/SIGINT uses only the process-local
termination gate and must not create persistent update state.

Settings → System owns the only **Mac Power** status and approval block. Helper
Ready requires a doctor live XPC check. Registration alone is Needs attention.
During doctor or reconciliation, show Checking, not failure. Power
requires a healthy watchdog heartbeat no older than three minutes; otherwise it
is `unknown`. Refresh on Settings open, app activation, and every ten seconds
while visible.

The watchdog heartbeat carries the effective power state and typed raw
thermal state/latch. With notifications enabled, the app emits one
localized temperature-safety warning on each inactive-to-active latch
transition, including when borrowed external protection makes the effective
power state unavailable; repeated polls never duplicate the warning.

The watchdog is a signed per-user LaunchAgent with an embedded
`__TEXT,__info_plist`. It resolves `~/.local/bin/detach` at runtime, calls
`detach power status --json` through the same process-group runner with a
five-second deadline, and writes private health state. The privileged
daemon is a distinct demand-launched LaunchDaemon. Neither plist may contain a
user-specific path. Native power protection requires no Apple Events or
Automation entitlement.

Bootstrap runs only from `/Applications`, not a DMG or App Translocation path.
App Start uses `--detach`, keeps sheet errors, and selects one new session.
Start, Resume, and Recover use an ephemeral PTY on
`detach <provider> attach <session>`. Closing its view ends the client.
Terminal I/O is event-driven. Paused Metal redraws changes with a steady
cursor and no timer. Failure keeps CoreGraphics. No poller or continuous frame
loop runs. In a focused terminal, `Command-C/V/F`
stay native copy, paste, and find. `Ctrl-V` reaches provider image paste. A
Finder drop sends shell-safe paths without reading or storing files. Live views
move typed Mac Power to metadata and omit its strip. An exited client offers
Reconnect. The external terminal stays a `.command` fallback.
New session accepts an optional printable UTF-8 name of at most 100 bytes
and rejects invalid input. Launch runs in Detach. Advanced holds the prompt
below a fixed top. Titles use `display_name`, then the project or internal name.
Command-N opens New session. Its chooser starts at the default project or the
selection's parent. Command-T starts the chosen provider in a private 0700
`detach-chat-<UUID>` directory in the quick-chat folder (`/tmp` default). It
selects the typed `starting` session despite an overlapping poll, before runtime
readiness. Invalid folders block launch.
Command-1 through Command-9 open main and select numbered Working or Answer
ready sessions. Numbers appear in rows and stay stable across both sections.
When a session leaves them, the earliest waiting session gets its number;
extras stay unnumbered. The sidebar guide shows Command-N, Command-T,
Command-comma, and terminal Command-F.
Notifications are opt-in. One poller deduplicates baseline and transitions.

Sparkle 2 and SwiftTerm 1.19.0 are pinned. The exact SwiftTerm shader bundle is
shipped and verified. Sparkle keeps its symlink layout and is signed inside-out.
Only ad-hoc builds use `com.apple.security.cs.disable-library-validation`.
`UpdaterService` starts only in `/Applications` with a valid HTTPS feed URL and
32-byte Ed25519 public key.
A generated or published appcast must contain exactly one arm64 hardware
requirement so Intel clients are never offered the update.
A Sparkle update replaces only the app; bootstrap atomically activates its new
immutable CLI payload without rewriting live-session binaries. Sparkle errors
for a disk image or App Translocation tell the user to move Detach to
`/Applications`. Temporary-directory and download errors tell the user to
check the network and free disk space, then retry. Archive, signature,
validation, and installation errors provide the manual DMG path and the
Settings > System Repair path, and state that the active CLI did not
change. If replacement completes but CLI or helper sync fails, the prior CLI
stays active and Repair remains available. Background sync keeps
the dashboard; a later activation retries it.
