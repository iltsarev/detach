# Detach.app specification

## Contract

`app/` is a SwiftPM package with app, runtime, state, power, watchdog, and
helper targets. It bundles signed arm64 executables, the immutable CLI payload,
pinned dependencies, provenance, and license notices.

`ANSIParser` strips non-SGR sequences and preserves colors, bold, dim, italic,
underline, strikethrough, and reverse video. Reverse swaps colors against
`ANSIParser.terminalBackground`, also the `LogTextView` background. Font
scaling changes only the font.

Onboarding uses `SetupGuidance.step(for:)`; failure outranks provider discovery.
An `.enabled` service alone never completes permissions. The live poller reads
without side effects and reconciles once after enablement. Only a finished
helper journal and an open root gate advance the step. `requiresApproval` is
not enabled. Done, Repair, and first-run sync reread the watchdog heartbeat.
Success needs a fresh heartbeat and records completion once. A long wait offers
monitor retry, never a bypass. A failed doctor refresh or a different runtime
identity withdraws earlier helper readiness.

After onboarding, bootstrap, refresh, power or provider regressions, and an
update held by active leases keep the dashboard. Settings shows errors; new
starts still require both power layers. Only an invalid app location or runtime
payload mismatch restores setup guidance. Provider installation uses the
official command in the user's terminal through the private `.command`
mechanism. Without an outcome channel it reports only that the CLI is not
detected. When helper/plist bytes change after an
app update, unregister, await completion, then use the bounded retry for the
transient SMAppService Code=1 race. Do not replace a helper with active leases:
defer the update. Report a normal outcome; retry on the next activation.

Each readiness build puts one `detach-app-build:<UUID>` in its executable and
signed marker. UI smoke uses a stripped private copy below
`/private/tmp/detach-ui-e2e.*` without production payloads. An escaped path,
unsafe identity, build mismatch, or payload fails closed.

Smoke restores focus and the pointer, then sends ordered AppKit events to
controls. It covers all main surfaces, focus, session actions, and
onboarding. Stop disconnects first. Stages have deadlines. Coverage isolates
the normal bundle, instrumented copy, tests, binary, and profiles. The driver
detects clipped controls before an action.

The per-user watchdog adds a launch-readiness rule: macOS can report an approved
agent as enabled while no launchd job loaded after approval. During first
onboarding or Repair, an enabled watchdog without a fresh heartbeat uses the
durable unregister/barrier/register transaction. Ordinary activation does not
replace it for a temporarily stale heartbeat.

The menu bar is display-only. Its prompt mark is filled for protected, dim for
sleep allowed, badged for attention, and outlined for unknown. Starting,
running, and recovering sessions are active; hung sessions are not. Green means
working and orange means waiting. Waiting outranks working. A badge hides both
tints so power warnings stay visible. Monochrome states remain template; tints
resolve from label or system colors. VoiceOver names
the session state. The first menu line is `state · reason · freshness`.
Protected counts working sessions. Allowed names all-waiting or an unprotected
working session and never claims no sessions. One typed heartbeat source and
one `detach watch --json` source supply them. A schema-1 hint, activation, or
`resync` triggers `list --json`; only the newest hint waits. No list timer runs.
A dead or never-ready watcher restarts with 2–60 s backoff; a failed list
retries alike. Cold start waits 1 s for `ready`; a late `ready` repeats its
snapshot.
UI never calls `pmset` or root XPC. Closing the
last window keeps the app, event source, and icon.
⌘Q and Quit end the app while sessions, checkpoints, and protection continue.
Settings → General owns both menu bar toggles. Settings → System keeps the only
Mac Power status and approval controls. Settings follows the hosting screen;
System scrolls. Temperature safety has its own warning shape and the
text **Mac can sleep: temperature**.

The dashboard separates identity, status, and Mac Power. Identity is a thin
tmux-colored capsule. Status is a filled circle. Power uses a neutral surface
and semantic color. Clicking the UUID chip copies the full UUID and shows
**Copied**.

**Finished** bulk Delete stays outside `List`, uses typed Delete, asks once,
tolerates failures, and keeps transcripts. Select/Done keeps 12-point clearance.

Bounded CLI calls drain both outputs and use process-group TERM then KILL.
They report truncation; typed consumers reject incomplete output and keep the
last valid state. Pipe-only descendants cannot extend the deadline. The native
event process uses `exec` and ends on cancellation. GUI PATH sorts
NVM/mise Node directories by semantic version.

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
released lock or a changed boot UUID; `unavailable` is insufficient. Errors
keep the journal and root gate closed. After an app crash, another console user
uses the root-created files to resume at `unregisterSubmitted`, never as a
pristine install.

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
is `unknown`. A vnode source reads atomic changes at once; one wall-clock
deadline marks silence stale. A timestamp-only write moves it and redraws the
age silently. Settings open and activation resync. No app-level
heartbeat timer runs. The first monitor read and explicit refreshes share one
sequence. A stale constructor snapshot cannot arrive after a newer document.

The watchdog heartbeat carries the effective power state and typed raw
thermal state/latch. With notifications enabled, the app emits one
localized temperature-safety warning on each inactive-to-active latch
transition, including when borrowed external protection makes the effective
power state unavailable; repeated documents never duplicate the warning.

The watchdog is a signed per-user LaunchAgent with an embedded
`__TEXT,__info_plist`. It resolves `~/.local/bin/detach` at runtime, calls
`detach power status --json` through the same process-group runner with a
five-second deadline, and writes private health state. The privileged
daemon is a distinct demand-launched LaunchDaemon. Neither plist may contain a
user-specific path. Native power protection requires no Apple Events or
Automation entitlement.

Bootstrap runs only from `/Applications`, not a DMG or App Translocation path.
A first-run setup card stays mounted during retry. App Start uses `--detach`,
keeps sheet errors, and selects the new session. Start, Resume, and Recover open
`detach <provider> attach --terminal-features sync <session>` in one visible
PTY. Live-to-live selection keeps it and asks the public CLI to switch its exact
tmux client. Closing the view ends the client.

Terminal I/O is event-driven. CoreGraphics repaints on changes and uses a
steady cursor. No terminal poller or frame loop runs. `Command-C/V/F` provide
native copy, paste, and find. `Ctrl-V` reaches provider image paste. A Finder
drop sends shell-safe paths without reading files. Live views move Mac Power to
metadata. An exited client offers Reconnect.

Cold start paints at most 128 rows and 1 MiB from private preferences. Cached
rows grant no action, ownership, PID, cleanup, or power claim until a fresh
list arrives. A failed refresh keeps them visible but not authoritative. Only
presentation changes are stored.

Timer-free caches preload 12 non-live logs, three at once, and nine live
500-line screens, two at once. They retain no PTY. Empty or failed reads wait
for a typed revision. The opaque lifecycle ID prevents a reused name from
inheriting either cache; older rows use creation time and provider identity.
A detached live log rereads every 2 s. A cold attach can show one passive
SwiftTerm screen. Live switching uses no raster or replacement PTY. tmux holds
the frame until a synchronized redraw.
Metadata stays in one scrolling row. Selection keeps header, terminal, and
action geometry. A cold passive screen leaves within one second.
New session accepts an optional printable UTF-8 name up to 100 bytes and
rejects invalid input. Launch runs in Detach. Advanced holds the prompt
below a fixed top. Titles use `display_name`, then the project or internal name.
Command-N opens New session. Its chooser starts at the default project or the
selection's parent. Command-T starts the chosen provider in a private 0700
`detach-chat-<UUID>` below its folder (`/tmp` default). An event
selects an unambiguous `starting` session before readiness, without polling.
Invalid folders block launch.
Command-1 through Command-9 open main and select numbered Working or Answer
ready sessions. Numbers appear in rows and stay stable across both sections.
When a session leaves them, the earliest waiting session gets its number;
extras stay unnumbered. The sidebar guide shows Command-N, Command-T,
Command-comma, and terminal Command-F.
Notifications are opt-in. Snapshots deduplicate transitions. A typed Stop
intent is never a failure; a 350 ms recheck confirms other `interrupted` or
`hung` rows.

Sparkle 2 and SwiftTerm 1.19.0 are pinned. The exact SwiftTerm shader bundle is
shipped and verified. Sparkle keeps its symlink layout and is signed inside-out.
Only ad-hoc builds disable library validation.
`UpdaterService` starts only in `/Applications` with a valid HTTPS feed URL and
32-byte Ed25519 public key.
A generated or published appcast must contain exactly one arm64 hardware
requirement, so Intel clients never see the update.
A Sparkle update replaces only the app; bootstrap atomically activates its new
immutable CLI payload without rewriting live-session binaries. Sparkle errors
for a disk image or App Translocation say to move Detach to
`/Applications`. Temporary-directory and download errors say to check the
network and free disk space, then retry. Archive, signature,
validation, and installation errors provide the manual DMG path and the
Settings > System Repair path, and state that the active CLI did not
change. If replacement completes but CLI or helper sync fails, the prior CLI
stays active and Repair remains available. Background sync keeps
the dashboard; a later activation retries it.
