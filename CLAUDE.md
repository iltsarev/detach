# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

Detach is a macOS 14+ reliability harness for long-running Codex CLI and Claude
Code sessions. It launches a provider inside a persistent, Detach-owned tmux
server, keeps private recovery checkpoints every five minutes by default, and
can protect an active session from idle and closed-lid sleep.

The user installs and authenticates Codex and/or Claude separately. Detach does
not replace or redistribute either provider. Everything else required at
runtime is part of the app as Apple Silicon (`arm64`) code: tmux, the typed `detach-state` helper,
the unprivileged `detach-power` wrapper, the privileged power helper, the
background monitor, and Sparkle. There are no Homebrew runtime dependencies.

The self-contained runtime debuts in 0.2.0. Every release remains blocked on
the signed power smoke test and a supervised closed-lid hardware test; never
describe a release as published until it actually exists.

README.md is the user-facing contract for setup, lifecycle, recovery, provider
policy, and power safety. Keep it synchronized whenever behavior changes.

## Public repository and local-only material

This repository, its full pushed Git history, GitHub releases, and published
artifacts are public. Treat every tracked file, commit/tag message, issue or PR,
build log, manifest, and release asset as internet-visible. Public guidance,
including this file, must not contain private context.

- Never commit or publish local plans, backlogs, working specs, credentials,
  signing material, account data, conversation/session state, machine-specific
  absolute user paths, or private organization/client/project names.
- Keep local planning material in the ignored `docs/backlog.md` and
  `docs/superpowers/` paths. Keep secrets outside the repository, using the
  Keychain or environment variables as appropriate. Never bypass these guards
  with `git add -f`.
- `.gitignore` is a safety net, not permission to publish every other file.
  Before each commit and release, inspect the staged diff, tracked-file list,
  artifact contents, and metadata for private or machine-specific data.
- If private data appears in a commit or artifact, stop before pushing or
  publishing and remove it from the history or artifact. Deleting it in a later
  public commit is not sufficient.

## Verification commands

- `DETACH_TEST_TMUX_BIN="$PWD/app/build/Detach.app/Contents/Resources/DetachCLI/tmux" tests/run.sh`
  — hermetic Codex integration with a fake provider, private tmux
  socket/state roots, a fake native power wrapper, and an explicitly selected
  bundled tmux artifact.
- `DETACH_TEST_TMUX_BIN="$PWD/app/build/Detach.app/Contents/Resources/DetachCLI/tmux" tests/run-claude.sh`
  — the equivalent Claude integration. Build and verify the
  app first; repository integrations must not fall back to an ambient tmux.
- Add `DETACH_CODEX_TEST_KEEP=1` to the Codex command above to keep its
  temporary state and tmux server for inspection. Use
  `DETACH_CLAUDE_TEST_KEEP=1` with the Claude command.
- `tests/distribution.sh` — immutable install/upgrade/repair/doctor/uninstall
  coverage for the fixed payload (`detach`, `detach-core`, `detach-install`,
  `detach-state`, `detach-power`, and `tmux`) with a temporary home.
- `tests/tmux-runtime.sh` — pinned tmux source/provenance, arm64-only packaging,
  linkage, signing, and bundled native-helper contract checks.
- `tests/release-preflight.sh` and `tests/publish-preflight.sh` — hermetic release
  tooling, arm64 appcast, production-DMG verification, exact artifact allowlist,
  and explicit publication-confirmation guards.
- `cd app && swift test` — unit tests for DetachKit, app services, typed state
  operations, power lifecycle, lease policy, XPC policy, and presentation.
- `app/scripts/make-app.sh` followed by `app/scripts/verify-app.sh` — build and
  verify a local app. A normal build must contain only an `arm64` slice for the
  app, watchdog, tmux, state helper, power client, root helper, and embedded
  Sparkle executables. Intel Macs are not supported.
- `DETACH_ALLOW_REAL_POWER_TEST=1 tests/power-smoke.sh` — deliberately changes
  real system power state through an installed, signed, approved app. Never run
  it as routine verification. Before a release, run it only on supervised
  hardware whose initial sleep setting is normal, then separately verify actual
  closed-lid behavior.

There is no separate linter. Run the relevant shell integrations, Swift tests,
packaging contracts, shell syntax checks, and `git diff --check` for changes in
their scope.

`app/scripts/release.sh` and `app/scripts/publish-release.sh` are explicit,
strict release operations. They require Developer ID signing, notarization,
Sparkle credentials and keys, a clean tagged commit, provenance checks, and
publication confirmation. Publication additionally requires
`DETACH_CONFIRM_PUBLISH=owner/repository@tag` exactly; no generic confirmation
is accepted. Do not run, tag, notarize, upload, or publish as part of ordinary
implementation or verification.

## Installed distribution

The repository copies are not what runs on the machine. Detach.app installs an
immutable payload under
`~/.local/libexec/detach/versions/<semver>-<hash>/` and atomically switches
`~/.local/bin/detach`. The installed payload contains, in fixed manifest and
hash order:

1. `detach`
2. `detach-core`
3. `detach-install`
4. `detach-state`
5. `detach-power`
6. `tmux`

Installation owns one idempotent PATH entry for login and interactive shells.
Uninstall restores an unchanged profile byte-for-byte, or removes only the
exact Detach-owned entry if the user changed other content. Edits to `bin/` or
the native helpers take effect only after app synchronization or Repair.

App installation additionally registers the bundled power LaunchDaemon and
signed per-user watchdog through `SMAppService`. The root helper needs one-time
administrator approval. Do not recreate the removed portable CLI LaunchAgent.

## Runtime architecture

### Shell entry points

- **`bin/detach`** is the only command exposed on PATH. It resolves all owned
  executables as immutable siblings, selects `codex` or `claude`, owns the
  cross-provider `list`, UUID-aware `resume`, `power status`, configuration,
  doctor, repair, and uninstall surfaces, then invokes the core.
- **`bin/detach-core`** owns the provider-neutral session lifecycle, inline
  provider adaptations, checkpoint/recovery policy, tmux status, and internal
  self-reinvocation commands. It rejects direct invocation unless the frontend
  supplies `DETACH_CORE_ENTRYPOINT=1`.

Tests may inject binary and state paths with `DETACH_*` variables. Production
must default tmux, `detach-state`, and `detach-power` to the immutable sibling
payload, never to Homebrew or another ambient installation. Provider binaries
remain user-owned and are discovered through `PATH` or provider-specific test
overrides. macOS-supplied `sqlite3`, `tar`, `env`, and `lockf` remain explicit,
injectable platform utilities.

Critical shared-state operations run by self-reinvoking the core under `lockf`,
for example `__checkpoint_once_locked`, `__delete_locked`, and
`__start_tmux_session_locked`. New shared mutations should keep the lock around
the whole child process.

### Typed state boundary

`detach-state` replaces the former jq dependency. Its stable typed commands
cover guarded metadata create/get/patch/match operations, JSONL validation and
summary, and context/session JSON emission. Do not reintroduce ad-hoc JSON text
editing or a jq runtime requirement.

Per-session `meta.json` uses schema 1 and a `run_token`. A stale worker or
checkpoint loop must not overwrite metadata belonging to a replacement run.
Anything restored into provider storage must pass canonical path, symlink,
session-ID, and JSONL validation, be written to a temporary file, validated
again, and only then be moved into place.

State is private (`umask 077`) under
`~/.local/state/detach/{codex,claude}/sessions/<name>/` and contains full
conversation data. Codex's shared SQLite database may be backed up after an
integrity check but is never restored automatically.

### Session lifecycle and tmux

`start` takes one project lock shared by both providers, creates a session named
`detach-<provider>-<slug>-<project-hash>`, enables `remain-on-exit`, and launches
`__worker`. The shared tmux daemon is anchored in persistent install state, not
the first project directory. It is addressed only through the private absolute
`$DETACH_INSTALL_STATE_ROOT/tmux/tmux.sock`, never ambient `TMUX_TMPDIR`.
Install migration checks both the older default socket and the historical
`-L dev.tsarev.detach` socket before switching payloads. Each worker starts
from stable install state and then enters the canonical project beneath its
cleanup trap.

The worker starts checkpoint and power-status loops, then runs the provider only
through:

```text
detach-power run --session <name> --run-token <token>
  --ready-file <absolute-path> -- <provider> ...
```

The power wrapper must confirm both protection layers and atomically mark the
ready file before launching the provider. The starter waits for that handshake
and must never print `Started` before it arrives. HUP/INT/TERM are forwarded to
the provider while the wrapper remains alive long enough to release its lease
and assertion; explicit `detach stop` also performs an idempotent release by
session/run token. The provider must inherit the wrapper's tmux foreground
process group; launching it in a separate group makes interactive Codex or
Claude stop on terminal I/O. On provider exit, the worker records status,
attempts a final checkpoint, and leaves the pane retained for logs and
diagnosis.

Closing Terminal or Detach.app only removes clients. The Detach tmux server,
worker, provider, checkpoint loop, and power wrapper continue in the macOS user
session. They do not promise survival across logout or reboot, and an explicit
kill of tmux/provider ends the live run. Recovery checkpoints remain available.
Integration tests must preserve this close-client lifetime contract.

Detach status options are session-local and use `@detach*`; never mutate a
foreign tmux server's configuration. The status line tints its whole strip with
a dense blend of the session identity color behind light plain-text labels,
plus a solid painted-space left edge (no font-dependent partial blocks), and
puts the power label and clock in `status-right`. Finished sessions keep a
faint tint of the same hue; failures tint the strip with the reserved red. The
eight-hue identity palette deliberately omits pure red, and every derived
surface comes from the single `blend_session_color` formula rather than
per-color pairs. The style snapshot saves and restores `status-right` and its
length alongside the left side; a snapshot from an older Detach that never
captured the right side must not clear the user's `status-right`. The text
status is the primary power signal: `MAC AWAKE`, `MAC CAN SLEEP`,
`LOW BATTERY`, `POWER UNAVAILABLE`, or a transition label. The app uses
equivalent readable text such as **Mac stays awake** and **Mac can sleep**.
Temporary icons are secondary.

Mouse input is on by default for managed sessions: copy-mode wheel steps are
rebound to one line for smooth scrolling, and mouse selections copy through the
Detach-owned server's `copy-command` into the macOS clipboard (`pbcopy`, plus
OSC 52 for terminals that support it). Those server options and key bindings
live only on the private Detach tmux server. `detach config tmux-mouse
[on|off]` (env override `DETACH_TMUX_MOUSE`) toggles the session `mouse`
option independently of the visual theme toggle.

`list --json` emits JSONL schema 1 and includes the optional
`power_protection_state`, `agent_turn_state`, and opaque `agent_turn_id`. Keep
the emitter and Swift `Session` decoder synchronized. Derive turn state only
from structured provider lifecycle records, never terminal text.

### Provider identity and checkpoints

Claude gets a wrapper-owned UUID via `--session-id`. Codex identity is resolved
after launch by matching the run-token originator in rollout files and Codex's
SQLite threads, refusing ambiguity. Wrapper-owned provider flags are rejected;
policy defaults apply only when the user did not supply an allowed override.

Checkpoints run every `DETACH_<PROVIDER>_CHECKPOINT_INTERVAL` seconds (300 by
default) under a per-session lock and include metadata, validated provider
JSONL, tmux pane capture, and canonical repository-root context found from a
real `.git` ancestor without invoking Git. Codex adds an integrity-checked
SQLite backup. Claude atomically archives the matching project session, file
history, session environment, tasks, and teams. `/bin/sync` follows unless the
provider-specific `DETACH_*_SYNC=0` test override is set.

Only allowlisted provider flags are serialized to `resume-args.bin`. A provider
flag that should survive Resume or Recover must be added deliberately.

## Native power protection

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

`pmset -a disablesleep 0|1` and its `SleepDisabled` output are undocumented
macOS interfaces. Parser/unit tests do not establish real closed-lid behavior.
Every release candidate must pass the explicitly opted-in signed smoke test and
a supervised test on real supported Apple Silicon hardware before publication.
Exact arm64 slice and launch verification remains required.

## Detach.app

`app/` is a SwiftPM package containing `DetachKit`, `DetachApp`,
`DetachWatchdog`, `DetachState`, `DetachPower`, and `DetachPowerHelper`. The app
bundles and signs arm64-only versions of every executable, the immutable CLI
payload, pinned tmux sources/licenses/provenance, Sparkle, and the complete
pinned Sparkle license notice.

`ANSIParser` is the single terminal-preview decoder. It strips non-SGR control
sequences and preserves terminal foreground/background colors, bold, dim,
italic, underline, strikethrough, and reverse video. Reverse video swaps
against `ANSIParser.terminalBackground`, which is also the `LogTextView`
background; do not duplicate that canvas color. Font-size scaling may replace
only the font attribute and must preserve every ANSI-derived attribute.

Onboarding is a card assistant driven by the pure step reducer in
`SetupGuidance.step(for:)`; a setup failure outranks provider discovery. A bare
`SMAppService.status == .enabled` read never completes the permissions step:
the live poller reads statuses without side effects and runs one coordinated
reconciliation on the enable transition, and only confirmed readiness (helper
journal finished, root gate reopened) advances the step. Registration may
truthfully remain in `requiresApproval`; never treat it as enabled before macOS
does. The success card waits for the first fresh watchdog heartbeat; its
dashboard action remains disabled until then, and after a long wait it offers
an explicit monitor retry instead of a bypass. Completion is guarded again in
the store and is recorded only by that explicit action, exactly once.

After onboarding has ever completed, `.idle`, `.syncing`, and `.ready` all
present `.mainApp`. This is a first-frame invariant: cold-launch bootstrap and
scene-activation refresh must keep the existing dashboard mounted and must not
flash onboarding. Only a completed `.actionRequired` or `.failed` result may
surface setup again. A missing provider also shows the dashboard, not
onboarding. Provider installation is offered only as the official command,
launched visibly in the user's own terminal through the private `.command`
mechanism; never claim a guided install failed (there is no outcome channel),
only that the CLI is not detected yet. When helper/plist bytes change after an
app update, unregister, await completion, then use the bounded retry for the
transient SMAppService Code=1 race. Do not replace a helper with active leases:
defer the update.

The per-user watchdog has an additional launch-readiness rule. macOS can report
an approved agent as enabled while no launchd job was loaded after the approval
transition. During first onboarding, or an explicit Repair, an enabled watchdog
without a fresh heartbeat must be replaced through the same durable
unregister/barrier/register transaction. Ordinary activation refreshes must not
force replacement merely because a heartbeat is temporarily stale.

The menu bar item is display-only. Its template image is the Detach prompt mark:
a filled dot means protected, the dimmed mark means sleep is allowed, an
exclamation badge means attention, and an outline means unknown. The first menu
line is `state · reason · freshness`, reusing the Mac Power presentation words.
An allowed heartbeat with visible running sessions must say they are not
holding sleep protection, never claim there are no sessions. Both glyph and
words derive from the shared `checked_at`-based heartbeat reader and the
app-level shared session poller — never `pmset` or root XPC from UI, and
freshness comes from the document timestamp, not file mtime. One
`detach list --json` poller serves the window, notifications, and the menu
(foreground cadence with the window visible, slower idle cadence after it
closes — polling never stops while the app runs). Closing the last window keeps
the app and icon alive; ⌘Q and Quit genuinely terminate the app while sessions,
checkpoints, and protection continue. Settings → General owns the two menu bar
toggles; the Mac Power block in Settings → System remains the single place for
power status and approval controls.

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

The watchdog is a signed per-user LaunchAgent with its own embedded
`__TEXT,__info_plist`. It resolves `~/.local/bin/detach` at runtime, calls
`detach power status --json`, and writes private health state. The privileged
daemon is a distinct demand-launched LaunchDaemon. Neither plist may contain a
user-specific path. Native power protection requires no Apple Events or
Automation entitlement.

Distribution bootstrap is allowed only from `/Applications`, not a DMG or App
Translocation path. Terminal actions use a private self-deleting `.command`
file and `NSWorkspace`; they do not use Apple Events. Notifications are opt-in
and driven by one app-level poller with baseline and transition deduplication.

Sparkle 2 is pinned in `Package.resolved`, embedded with its symlink layout
intact, and signed inside-out before the outer app. Ad-hoc development builds
alone use `com.apple.security.cs.disable-library-validation`; it must never
appear in a Developer ID build. `UpdaterService` starts only for a packaged app
in `/Applications` with a valid HTTPS feed URL and 32-byte Ed25519 public key.
A generated or published appcast must contain exactly one arm64 hardware
requirement so Intel clients are never offered the unsupported update.
A Sparkle update replaces only the app; bootstrap atomically activates its new
immutable CLI payload without rewriting live-session binaries.
