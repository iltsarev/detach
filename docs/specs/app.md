# Detach.app specification

## Contract

`app/` is a SwiftPM package with app, runtime, state, power, watchdog, and
helper targets. It bundles signed arm64 executables, the immutable CLI payload,
pinned dependencies, provenance, and license notices.

`ANSIParser` strips non-SGR sequences and preserves colors, bold, dim, italic,
underline, strikethrough, and reverse video. Reverse swaps colors against
the selected terminal background, also the `LogTextView` background. Cached
logs retain semantic default and ANSI palette colors. A theme change resolves
these colors without another log read. Explicit RGB and extended palette
colors stay unchanged. Font scaling changes only the font. The light terminal
palette uses One Light colors. In both palettes, text has 7:1 contrast with the
background and 4.5:1 with the selection. Each ANSI color has 3:1 contrast with
the background; bright black and bright white have 2.5:1.

<a id="qc-health-presentation"></a>

The menu bar is display-only. Its prompt mark is filled for protected, dim for
sleep allowed, badged for attention, and outlined for unknown. Starting,
running, and recovering sessions are active; hung sessions are not. Green means
working and orange means waiting. Claude `AskUserQuestion` records with a
`tool_use` stop reason enter waiting; their matching user tool-result records
return to working. Waiting outranks working. A badge hides both tints so power
warnings stay visible. Monochrome states remain template; tints resolve from
label or system colors. VoiceOver names the session state. The first menu line
is `state · reason · freshness`. Each menu session line uses the sidebar status
label. The menu and the detail status pill follow the same snapshot authority
as the sidebar.
<a id="qc-health-freshness"></a>

Protected counts working sessions. Allowed names all-waiting or an unprotected
working session and never claims no sessions. Typed heartbeat and
`detach watch --json` sources supply them. A schema-1 hint, activation, or
`resync` starts a serialized `list --json`. Hints during a read share one ordered
trailing read. Stop discards queued reads and prevents old results from updating
the store. A new explicit read remains serialized with an active old read.
The app runs no list timer. While a session is live, the watcher repeats a
`changed` hint at the heartbeat stale threshold (45 s by default), so health
that changes with time alone, such as a stale heartbeat or an overdue
checkpoint, reaches List. Dead or unready watchers and failed lists retry
with 2–60 s backoff. A watcher that ends before its first event reads one List
before its restart. Cold start waits 1 s for `ready`; a late `ready` repeats the
snapshot. UI never calls `pmset` or root XPC. The app, events, sessions,
checkpoints, and protection survive its last window. ⌘Q and Quit end the app.
After a transcript file is replaced, registration of its new file observer
emits a refresh hint. Writes before registration must not leave the UI stale.

An active session operation can report `operation_in_progress` while it sets
up its runtime identity. This is a starting state with no mutation actions.
It is not a Problems row. A failed or completed operation restores the normal
typed health rules. A failed coherent List read keeps the previous rows.

The detail view separates identity, status, and Mac Power. Identity is a thin
tmux-colored capsule. Power uses a neutral surface and semantic color. Clicking
the UUID chip copies the full UUID and shows **Copied**.

Sidebar rows show a status symbol, name, trailing shortcut, and a second line
with status and provider. A row in Stopped shows its stop time instead of the
provider: a time today, yesterday with a time, a day and month this year, or a
date with the year. They have no tmux identity bar or colored badges.
Launch time, stop time, provider, and exit details remain in help and
accessible descriptions.
Text and status marks follow the app text size. Status colors keep contrast in
light and dark appearances. One custom selection surface preserves native
List selection and keyboard navigation. A group has a distinct row identity
in each section, so its count and collapse control refer to that section.
Each lifecycle and turn state has an explicit symbol. Marks have a consistent
size: 16 points at the default text size. Ready uses a circled check. Input
uses a circled exclamation mark. Stop and interruption use circled stop and
pause marks. Recovery data uses a return arrow. A live session without
transcript evidence (no model, context, or turn ID) has a plain circle and a
new-session label. A live session whose health reason is
`identity_unconfirmed` instead has a warning triangle, a not-linked label,
the input-request yellow, and a faint row fill; its detail chip says that
checkpoints and Resume are unavailable. Other missing status data has a circled dash and a
status-unavailable label. Stale data uses a history clock.
Errors keep distinct symbols for failure, hang, lost session, corrupt data,
and name collision. No state uses a question-mark or ellipsis placeholder.
Ready answers and completed sessions use green; explicit input requests use
yellow; errors use red. Stopped and uncertain states use neutral colors.
Ready answers, input requests, and errors have a faint row fill. Working rows
have no status fill, including when selected. Starting, working, and recovering
use the same small ring. It rotates only
when the snapshot is fresh, the row is visible, the app is active, and Reduce
Motion is off. Core Animation turns it on one shared clock. List refreshes, row
reuse, layout passes, and main-thread work cannot restart, move, or stall it. Cached or failed snapshots use neutral symbols, no animation,
and a last-known-status label.

The sidebar has Sessions and Stopped sections. Only stopped and interrupted
lifecycles enter Stopped. Completed and failed sessions remain in Sessions.
Working, ready, and input transitions do not move a row. Groups come first in
user order, then rows outside groups. Grouped rows start under the group name;
rows outside groups stay at the section edge. Within each upper group or ungrouped
set, assigned shortcuts sort first by number. Remaining rows sort by newest
creation time. Stopped rows sort by newest stop time within their groups; a
row without a stop time uses its creation time.

User groups are app-only preferences stored in `sidebarGroupsV1`. The CLI and
typed state never read them. Session names key assignments across Resume and
Recover. Unreadable, oversized, or unknown-schema documents mean no groups.
Only a fresh list removes assignments for missing sessions. Names are trimmed,
printable, unique without case, and at most 60 characters. Deleting a group
never deletes a session. Group collapse persists per section. Older group
assignments, order, and compatible collapse keys remain valid.
Stopped has its own persistent collapse setting. External selection opens the
section and group that hold the row. Bulk selection temporarily reveals every
finished candidate without changing those settings. Drops accept only current
session names. A row joins the target group; a drop on a section header removes
its group assignment. Groups never change actions or shortcut eligibility.

Select/Done appears at the first section header with 12-point clearance. Bulk
Delete stays outside `List`, uses typed Delete, asks once, tolerates partial
failures, and keeps provider transcripts. Its candidates still include
completed, failed, stopped, and interrupted sessions with Delete permission,
regardless of their sidebar section.

A first-run setup card stays mounted during retry. App Start uses `--detach`,
keeps sheet errors, and selects the new session. Start, Resume, and Recover open
`detach <provider> attach --terminal-features sync <session>` in one visible
PTY. Live-to-live selection keeps it and asks the public CLI to switch its exact
tmux client. Closing the view ends the client.
The PTY starts after the terminal has a window and a nonzero size. Selection
changes during cold attach wait for the first tmux frame before client lookup.
The latest selected session wins. A removed host cannot start a delayed PTY.
Resume uses the selected project, provider, managed name, and provider UUID.
If the project is missing, the public UUID resolver finds it. Resume and
Recover can open the terminal from a fresh attachable snapshot of the new run
before the command completes. The lifecycle ID must change, or a legacy row
must have a later creation time. An old or unidentified run waits for command
completion. An exited early client does not reconnect during preparation.
The preparation command still reports readiness failures.
Resume and Recover pass the visible terminal size before the provider starts.
The app measures this size with the terminal font and SwiftTerm layout. This
prevents initial output from wrapping at the default detached window width.
If an older CLI rejects the size prefix before startup, the app retries without
the hint. No startup failure or timeout permits this retry.

Terminal I/O is event-driven. CoreGraphics repaints on changes and uses a
steady cursor. No terminal poller or frame loop runs. `Command-C/V/F` provide
native copy, paste, and find. `Ctrl-C` and `Ctrl-V` reach providers as
conventional control bytes. An empty native selection cannot clear the
clipboard; tmux copies its mouse selection on release. Explicit and detected
links show an underline on hover and open on a plain click. A selection drag
does not open a link. A Finder drop sends shell-safe paths without
reading files. Live views move Mac Power to metadata. An exited client offers
Reconnect.

The embedded attach client always uses a UTF-8 character locale. A conflicting
inherited locale cannot change how tmux encodes its output. Native paste sends
Unicode text and line breaks with the provider's bracketed paste framing.
Without that framing, paste still sends the complete UTF-8 text. Enhanced
keyboard modes cannot encode a paste as one key or remove its line breaks.

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
The visible log view owns its read task. A terminal handoff cannot clear the
reader of a returned log view. The returned view shows and refreshes its log.
A log view opens at its end and follows new output until the user scrolls up.
A failed read shows the error. The next successful read replaces it.
tmux holds the frame until a synchronized redraw.
Metadata stays in one scrolling row. Selection keeps header, terminal, and
action geometry. The model and context gauge stay in the metadata row. They
cannot reduce the title to zero width in a narrow window or with large text.
A cold passive screen leaves within one second.
New session accepts an optional printable UTF-8 name up to 100 bytes and
rejects invalid input. Launch runs in Detach. Advanced holds the prompt
below a fixed top. Titles use `display_name`, then the project or internal name.
When Start returns the occupied Git project status, the sheet offers
**Create worktree** and **Cancel**. It shows the proposed sibling path and
states that uncommitted changes stay in the original folder. Only this CLI
outcome permits the offer; cached rows, errors, and timeouts do not. Consent
passes `--worktree PATH` with the selected provider, name, and prompt. The new
typed session must match the worktree path before the app selects it. A failed
creation or start stays in the sheet and does not create another worktree.
Command-N opens New session. Its chooser starts at the default project or the
selection's parent. Command-T starts the chosen provider in a private 0700
`detach-chat-<UUID>` below its folder. The default is
`~/Library/Application Support/Detach/Chats`, created on first use with 0700
permissions. Temporary and cache paths resolve to this default, including
symlink aliases and the old `/tmp` setting. Settings migrates a saved temporary
path and applies the same rule to folder choices. Launch repeats this check.
Custom persistent folders must exist. Stop and Delete retain project files.
Existing session paths and files do not move. An event
selects an unambiguous `starting` session before readiness, without polling.
Invalid folders block launch.
<a id="qc-app-tips"></a>

Command-1 through Command-9 open main and select numbered active or waiting
sessions. Numbers stay stable across working and waiting states. A finished
session or problem state releases its number to the earliest unnumbered
eligible session. At most nine sessions have numbers. The sidebar guide shows Command-N, Command-T,
Command-comma, and terminal Command-F.
Notifications are opt-in and deduplicated. Stop intent is not failure;
`interrupted` and `hung` get one 350 ms recheck. Snapshot bursts do not restart
that deadline. A new transition waits for the pending recheck, then gets its
own deadline. Stable state cancels an obsolete recheck. Each observation
lifetime confirms its own transitions. Status and session lifecycle changes
require a new confirmation, even when the session name stays the same.
Ordered detection never waits for delivery.

SwiftTerm 1.19.0 is pinned. The exact SwiftTerm shader bundle is shipped and
verified.

Each readiness build puts one `detach-app-build:<UUID>` in its executable and
signed marker. UI smoke uses a stripped private copy below
`/private/tmp/detach-ui-e2e.*` without production payloads. An escaped path,
unsafe identity, build mismatch, or payload fails closed.

Smoke restores focus and the pointer, then sends ordered AppKit events to
controls. Each mouse click uses one event number for both events.
Slider changes use the native control's Accessibility increment
action. It covers all main surfaces, focus, session actions, and
onboarding. Stop disconnects first. Stages have deadlines. Coverage isolates
the normal bundle, instrumented copy, tests, binary, and profiles. The driver
detects clipped controls before an action.
