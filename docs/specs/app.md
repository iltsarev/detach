# Detach.app specification

## Contract

`app/` is a SwiftPM package with app, runtime, state, power, watchdog, and
helper targets. It bundles signed arm64 executables, the immutable CLI payload,
pinned dependencies, provenance, and license notices.

`ANSIParser` strips non-SGR sequences and preserves colors, bold, dim, italic,
underline, strikethrough, and reverse video. Reverse swaps colors against
`ANSIParser.terminalBackground`, also the `LogTextView` background. Font
scaling changes only the font.

The menu bar is display-only. Its prompt mark is filled for protected, dim for
sleep allowed, badged for attention, and outlined for unknown. Starting,
running, and recovering sessions are active; hung sessions are not. Green means
working and orange means waiting. Claude `AskUserQuestion` records with a
`tool_use` stop reason enter waiting; their matching user tool-result records
return to working. Waiting outranks working. A badge hides both tints so power
warnings stay visible. Monochrome states remain template; tints resolve from
label or system colors. VoiceOver names the session state. The first menu line
is `state · reason · freshness`.
Protected counts working sessions. Allowed names all-waiting or an unprotected
working session and never claims no sessions. Typed heartbeat and
`detach watch --json` sources supply them. A schema-1 hint, activation, or
`resync` starts a serialized `list --json`. Hints during a read share one ordered
trailing read. No list timer runs. Dead or unready watchers and failed lists retry
with 2–60 s backoff. Cold start waits 1 s for `ready`; a late `ready` repeats the
snapshot. UI never calls `pmset` or root XPC. The app, events, sessions,
checkpoints, and protection survive its last window. ⌘Q and Quit end the app.

The dashboard separates identity, status, and Mac Power. Identity is a thin
tmux-colored capsule. Status is a filled circle. Power uses a neutral surface
and semantic color. Clicking the UUID chip copies the full UUID and shows
**Copied**.

**Finished** bulk Delete stays outside `List`, uses typed Delete, asks once,
tolerates failures, and keeps transcripts. Select/Done keeps 12-point clearance.

A first-run setup card stays mounted during retry. App Start uses `--detach`,
keeps sheet errors, and selects the new session. Start, Resume, and Recover open
`detach <provider> attach --terminal-features sync <session>` in one visible
PTY. Live-to-live selection keeps it and asks the public CLI to switch its exact
tmux client. Closing the view ends the client.

Terminal I/O is event-driven. CoreGraphics repaints on changes and uses a
steady cursor. No terminal poller or frame loop runs. `Command-C/V/F` provide
native copy, paste, and find. `Ctrl-C` and `Ctrl-V` reach providers as
conventional control bytes. A Finder drop sends shell-safe paths without
reading files. Live views move Mac Power to metadata. An exited client offers
Reconnect.

Cold start paints at most 128 rows and 1 MiB from private preferences. Cached
rows grant no action, ownership, PID, cleanup, or power claim until a fresh
list arrives. A failed refresh keeps them visible but not authoritative. Only
presentation is stored.

Timer-free caches preload 12 non-live 500-line logs (three at once) and nine
live screens (two at once), with no PTY. Empty and failed reads wait for
a revision. Bursts keep active reads. The lifecycle ID blocks cache
inheritance after name reuse; older rows use creation and provider identity.
Detached live logs reread every 2 s. Cold attach uses one passive SwiftTerm
overlay; cached bytes never enter the live buffer. Live switching keeps its PTY.
tmux holds the frame until a synchronized redraw.
Metadata stays in one scrolling row. Selection keeps header, terminal, and
action geometry. The model and context gauge stay in the metadata row. They
cannot reduce the title to zero width in a narrow window or with large text.
A cold passive screen leaves within one second.
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
Notifications are opt-in and deduplicated. Stop intent is not failure;
`interrupted` and `hung` get one 350 ms recheck. Ordered detection never waits
for delivery.

SwiftTerm 1.19.0 is pinned. The exact SwiftTerm shader bundle is shipped and
verified.

Each readiness build puts one `detach-app-build:<UUID>` in its executable and
signed marker. UI smoke uses a stripped private copy below
`/private/tmp/detach-ui-e2e.*` without production payloads. An escaped path,
unsafe identity, build mismatch, or payload fails closed.

Smoke restores focus and the pointer, then sends ordered AppKit events to
controls. It covers all main surfaces, focus, session actions, and
onboarding. Stop disconnects first. Stages have deadlines. Coverage isolates
the normal bundle, instrumented copy, tests, binary, and profiles. The driver
detects clipped controls before an action.
