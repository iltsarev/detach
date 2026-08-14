# Detach.app specification

## Contract

`app/` is a SwiftPM package containing `DetachKit`, `DetachApp`,
`DetachWatchdog`, `DetachState`, `DetachPower`, and `DetachPowerHelper`. The app
bundles and signs arm64-only macOS 15.0 executables, the immutable CLI
payload, pinned tmux sources/licenses/provenance, Sparkle, and the complete
pinned Sparkle license notice.

`ANSIParser` is the single terminal-preview decoder. It strips non-SGR control
sequences and preserves terminal foreground/background colors, bold, dim,
italic, underline, strikethrough, and reverse video. Reverse video swaps
against `ANSIParser.terminalBackground`, which is also the `LogTextView`
background; do not duplicate that canvas color. Font-size scaling may replace
only the font attribute and must preserve every ANSI-derived attribute.

Onboarding uses the pure reducer in `SetupGuidance.step(for:)`; a setup failure
outranks provider discovery. A bare
`SMAppService.status == .enabled` read never completes the permissions step.
The live poller reads status without side effects and reconciles once when it
becomes enabled. Only confirmed readiness (a
finished helper journal and an open root gate) advances the step. Registration
can stay in `requiresApproval`; do not treat it as enabled before macOS does.
The success card waits for a fresh watchdog heartbeat. Its dashboard action
stays disabled until then. After a long wait, it offers a monitor retry, not a
bypass. The store records completion only after that action, exactly once.
If a doctor refresh fails or detects another runtime identity, the app
withdraws the earlier helper-readiness confirmation.

After onboarding completes, `.idle`, `.syncing`, `.updateDeferred`, and
`.ready` present `.mainApp`. Bootstrap, refresh, and an update held by active
leases keep the dashboard mounted. Only a completed `.actionRequired` or
`.failed` result can show setup again. A missing provider also shows the
dashboard. Provider installation uses the official command,
launched visibly in the user's own terminal through the private `.command`
mechanism; never claim a guided install failed (there is no outcome channel),
only that the CLI is not detected yet. When helper/plist bytes change after an
app update, unregister, await completion, then use the bounded retry for the
transient SMAppService Code=1 race. Do not replace a helper with active leases:
defer the update. Report a normal reconciliation outcome and retry on a later
app activation.

Each readiness build stores one `detach-app-build:<UUID>` in its executable and
signed marker. UI smoke uses a stripped private copy at
`/private/tmp/detach-ui-e2e.*`. It excludes production CLI, watchdog, helper,
power, state, and tmux payloads. Injections stay below its root. An escape,
unsafe identity, build mismatch, or payload fails closed.

The smoke keeps the prior app focused. It posts AppKit events to measured
SwiftUI controls, then restores that app. Its semantic locator has no actions.
Each launch ends before its process deadline; the stage deadline is 40 seconds.
Journeys cover all main surfaces, Settings, onboarding, and focus. It
disconnects Stop before it proves that the real control invokes the action.
Only a visible control completes isolated onboarding.

Coverage validates the normal bundle, puts a coverage-enabled release
executable only in the stripped copy, and signs it. The executable and profiles
stay ignored or private and never enter a verified bundle or public artifact.
If an overlay scroller ignores a page event, the driver reveals the measured
semantic control, then posts the action to it.

The per-user watchdog has an additional launch-readiness rule. macOS can report
an approved agent as enabled while no launchd job was loaded after the approval
transition. During first onboarding, or an explicit Repair, an enabled watchdog
without a fresh heartbeat must be replaced through the same durable
unregister/barrier/register transaction. Ordinary activation refreshes must not
force replacement merely because a heartbeat is temporarily stale.

The menu bar item is display-only. Its image is the Detach prompt mark:
a filled dot means protected, the dimmed mark means sleep is allowed, an
exclamation badge means attention, and an outline means unknown. Active
sessions additionally tint the glyph's dot — green while working, orange when
a session waits for a reply (answer-ready outranks working; the badge states
suppress the tint so a power warning stays visible). The image stays template
while monochrome; only the tinted states draw with real color, using
label/system colors resolved at composite time, and VoiceOver names the
session state in words. The first menu line is `state · reason · freshness`.
Protected state counts working sessions. Allowed state names all-waiting or an
unprotected working session and never claims no sessions. The glyph and words
derive from the shared `checked_at`-based heartbeat reader and the
app-level shared session poller — never `pmset` or root XPC from UI, and
freshness comes from the document timestamp, not file mtime. One
`detach list --json` poller serves the window, notifications, and the menu
(foreground cadence with the window visible, slower idle cadence after it
closes — polling never stops while the app runs). Closing the last window keeps
the app and icon alive; ⌘Q and Quit genuinely terminate the app while sessions,
checkpoints, and protection continue. Settings → General owns the two menu bar
toggles; the Mac Power block in Settings → System remains the single place for
power status and approval controls. Temperature safety uses its own warning
shape and the text **Mac can sleep: temperature**.

Every app CLI invocation runs in a fresh process group with concurrent bounded
stdout/stderr draining. Its deadline sends TERM and then KILL to the complete
group, and a descendant that only inherits a pipe cannot hold the caller past
the drain deadline. GUI PATH augmentation orders NVM and mise Node directories
by semantic version, with valid versions ahead of non-version aliases.

Helper replacement is a durable fail-closed transaction. One versioned JSON
journal records `preparing`, `unregisterSubmitted`, `removed`, or `registering`,
the install/remove goal, target digest, boot UUID, and lifetime-barrier contract.
Every transition is written by atomic rename and fsynced with its directory
before the corresponding side effect. A per-user `flock` protects that user's
journal. In addition, the root helper creates a stable root-owned `0644` inode
under `/var/run`; every app user opens it read-only and holds one exclusive
kernel `flock` across the complete asynchronous SMAppService transaction. This
is the machine-wide single-writer barrier across Fast User Switching, and the
kernel releases it if the app crashes. Only the current non-root console user's
app may perform register or unregister mutations, checked again immediately
before each mutation. Root persists `unregistration_pending`, blocks
acquire/renew without a wall-clock expiry, and restores and reads back only the
setting Detach owns.

The helper takes an exclusive, root-owned lifetime `flock` before its listener
can answer prepare and holds it until process exit. The app writes
`unregisterSubmitted` only after observing that lock. A fresh successful async
SMAppService callback is the normal process-reaped barrier. If a crash loses the
callback, exact `notRegistered` status plus acquisition of the released lifetime
lock (or a changed boot UUID) is required before registration; generic
`unavailable` is not sufficient. An unregister error keeps the journal and root
gate closed for retry rather than reopening it while a callback may still be
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
termination gate and must not create this persistent update state.

Settings → System contains one **Mac Power** block; do not duplicate its status
or approval controls elsewhere in that tab. It presents the sleep state in
words, helper and background-monitor health, the 10% battery rule, and the
appropriate approval, setup, repair, or refresh action. Its effective state is
read from a healthy watchdog heartbeat newer than three minutes and is
`unknown` when that snapshot is missing, stale, or malformed. Refresh the
installation context when Settings appears or the app becomes active. While the
System tab remains visible, publish a fresh heartbeat snapshot every ten seconds
so the displayed state cannot remain stale merely because SwiftUI did not
otherwise re-render.

The watchdog heartbeat carries both the effective power state and typed raw
thermal state/latch. When notifications are enabled, the app emits one
localized temperature-safety warning on each inactive-to-active latch
transition, including when borrowed external protection makes the effective
power state unavailable; repeated polls never duplicate the warning.

The watchdog is a signed per-user LaunchAgent with its own embedded
`__TEXT,__info_plist`. It resolves `~/.local/bin/detach` at runtime, calls
`detach power status --json` through the same process-group runner with a
five-second deadline, and writes private health state. The privileged
daemon is a distinct demand-launched LaunchDaemon. Neither plist may contain a
user-specific path. Native power protection requires no Apple Events or
Automation entitlement.

Distribution bootstrap runs only from `/Applications`, never a DMG or App
Translocation path. Terminal actions use `NSWorkspace`, not Apple Events. They
open a private self-deleting `.command` file and reuse a running terminal app.
If none runs, the launch environment sets a private `.zshenv` as outer
`ZDOTDIR`. It blocks startup prompts until payload removal, then restores the
original `ZDOTDIR` for that process. Open, Resume, and Recover use the selected
terminal, with Terminal as fallback.
The new-session sheet accepts an optional UTF-8 name up to 100 bytes. It rejects
control characters, explains invalid input, blocks launch, and passes one
shell-quoted `--name` argument. The app uses `display_name` as the title, with
the project/internal name fallback for old records.
Notifications are opt-in. One app poller deduplicates baseline and transitions.

Sparkle 2 is pinned in `Package.resolved`, embedded with its symlink layout
intact, and signed inside-out before the outer app. Ad-hoc development builds
alone use `com.apple.security.cs.disable-library-validation`; it must never
appear in a Developer ID build. `UpdaterService` starts only for a packaged app
in `/Applications` with a valid HTTPS feed URL and 32-byte Ed25519 public key.
A generated or published appcast must contain exactly one arm64 hardware
requirement so Intel clients are never offered the unsupported update.
A Sparkle update replaces only the app; bootstrap atomically activates its new
immutable CLI payload without rewriting live-session binaries. Sparkle errors
for a disk image or App Translocation tell the user to move Detach to
`/Applications`. Temporary-directory and download errors tell the user to
check the network and free disk space, then try again. Archive, signature,
validation, and installation errors provide the manual DMG path and the
Settings > System Repair path. These errors state that the active CLI did not
change. If app
replacement completes but CLI or helper synchronization fails, the prior CLI
stays active and Repair remains available. Background synchronization keeps
the dashboard. A later activation retries it.
