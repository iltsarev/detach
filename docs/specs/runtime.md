# Runtime and session specification

## Installed distribution

Detach.app installs an immutable payload below
`~/.local/libexec/detach/versions/<semver>-<hash>/` and switches
`~/.local/bin/detach` atomically. Payload order is `detach`, `detach-core`,
`detach-install`, `detach-state`, `detach-power`, and `tmux`. Payload members
are regular files.

Install and Repair stage and hash a replacement under `.incoming-*` before
they replace a live version directory. They switch `~/.local/bin/detach` only
after the version directory, install manifest, and direct `__version` proof
succeed. Failure keeps the active payload and its install manifest. A first
install that fails after it writes the manifest removes the new manifest. A
live or retained session defers replacement. One PATH entry supports all
shells. `--keep-state` keeps checkpoints. `--purge-state` removes Detach
state, not provider data.
Uninstall restores an unchanged profile or removes only its entry. Source
edits require app sync or Repair.

The app registers its power LaunchDaemon and per-user watchdog with
`SMAppService`. The root helper needs one administrator approval. The portable
CLI LaunchAgent stays removed.

## Runtime architecture

### Shell entry points

- **`bin/detach`** is the only PATH command. It resolves immutable sibling
  executables, selects the provider, and owns cross-provider commands.
- **`bin/detach-core`** owns the provider-neutral session lifecycle, inline
  provider adaptations, checkpoint/recovery policy, tmux status, and internal
  self-reinvocation commands. It rejects direct invocation unless the frontend
  supplies `DETACH_CORE_ENTRYPOINT=1`.

Tests inject paths through explicit `DETACH_*` environments. An app CLI strips
them except in isolated UI tests. Production resolves tmux and state/power
helpers only as immutable siblings. Providers resolve through `PATH`.

Bounded CLI calls drain outputs on dedicated threads and use process-group
TERM then KILL. Parallel calls cannot starve drains. Truncation makes typed
consumers keep the last valid state. Pipe descendants cannot extend deadlines.
The event process uses `exec` and ends on cancellation. GUI PATH sorts
NVM/mise Node directories by semantic version.
CLI children start with an empty signal mask. A dispatch thread's blocked
signals must not reach the private tmux server or its workers. The caller's
signal mask does not change.
If the bounded transcript tail has no Codex model, JSON List reads the model
from the provider database. The session ID and rollout path must both match.
An old database without the model column leaves the transcript result intact.
SQLite text values support paths with apostrophes on the system Bash.

`client switch` retries reads for 0.5 seconds. PID, UID, source, private socket,
and managed target must match. Framing must survive `LC_ALL=C`. Failed proof
causes no mutation. Attach can hold a frame until the target redraws.

<a id="qc-runtime-ownership"></a>

Core self-reinvokes critical mutations under `lockf`. Start, Resume, Stop,
Recover, and Delete hold a session lock before install, project, and checkpoint
locks. Each lock covers the child; the install lock covers readiness and the
worst hold.
List observes held session locks. It does not classify a placeholder pane as
a persistent fault while Start, Resume, or Recover configures its identity.
This observation never authorizes a mutation or suppresses a command error.

### Session lifecycle and tmux

`start` takes a cross-provider project lock, creates a safe identifier, sets
window `remain-on-exit` off and the provider pane on, then launches `__worker`.
Splits close on exit; logs and status remain. The first unnamed history is
`detach-<provider>-<project-slug>-<project-hash>`; successors add a monotonic
`-r<12-hex>` and store the base as `default_session_base`. Explicit names are
1–100 printable UTF-8 bytes. Legacy-safe names keep
`detach-<provider>-<name>`; others use a deterministic ASCII slug plus 12-hex
content hash. The full internal form stays reserved. User input becomes a tmux
name or state path only if it matches the legacy-safe grammar.

The optional display name is separate typed state, survives resume/recovery,
and resolves later lifecycle commands. The shared tmux daemon is anchored in
install state and uses only the private
`$DETACH_INSTALL_STATE_ROOT/tmux/tmux.sock`, never ambient `TMUX_TMPDIR`.
Migration checks older default and `-L dev.tsarev.detach` sockets before a
payload switch. Each worker starts from stable install state, then enters its
canonical project beneath the cleanup trap.

Tmux environment arguments stay in memory; credentials never touch disk.

The public `--terminal-size COLSxROWS` prefix accepts dimensions from 1 to 999
for explicit Start, Resume, and Recover commands. It sets the initial detached
window size before the provider starts. The hint crosses startup locks in
memory. It is not saved with provider options or copied into the provider
environment. Attached clients still control subsequent terminal dimensions.

When the provider pane dies, tmux detaches its clients. External terminals
return to their original shell.
The completion hook requires the exact pane ID and run token. It targets the
original tmux session ID. A dead user split cannot disconnect those clients.
The retained provider pane, metadata, and checkpoints remain available.
Ctrl-C that leaves the provider running does not detach its clients.
Completion without attached clients does not run a client command. The next
attachment shows the provider screen without a stored tmux client error.

Default starts form a provider/project history series. A fresh start refuses a
live member or second writer; otherwise it allocates a successor without
reusing saved state. No-`NAME` commands select the live member, then the highest
suffix. Older `session_name` values stay addressable; their metadata, logs,
and checkpoints remain until Delete or typed storage cleanup. Explicit names
stay deterministic and obey the same project lock and cleanup policy.

Start checks project occupancy before it removes a retained pane. A live
session in a Git worktree with a commit returns status 20 before startup
mutations. This check includes both providers and holds the project lock.
The caller releases all lifecycle locks before it offers a new worktree.
An interactive CLI asks for consent; other callers receive status 20.

Start accepts `--worktree PATH` as explicit creation consent. It uses
`/usr/bin/git`, ignores inherited Git location variables, and creates a unique
`detach/<UUID>` branch from a resolved HEAD commit. The target must be absent,
outside the source project, with an existing parent. A supplied session name
must be unused. Dirty and untracked source files stay in place. A new start
uses the new canonical project path and the normal lifecycle locks. A linked
worktree has its own project lock. No worktree is removed on startup failure,
Stop, Delete, or storage cleanup. Resume and Recover use the saved path.

The worker starts checkpoint and power-status loops, then runs the provider only
through:

```text
detach-power run --session <name> --run-token <token>
  --ready-file <absolute-path> --pid-file <absolute-path>
  --activity-file <absolute-path> --activity-source-file <absolute-path>
  -- <provider> ...
```

Metadata has a typed phase machine: `initializing`, `starting`, `running`,
`stopping`, `finalizing`, `terminal`. Invalid transitions fail; `status` stores
outcomes. List hides `initializing`. The worker emits `starting` only after its
metadata and tmux identity match; only then can provider PID be absent. The
power wrapper confirms both layers and publishes readiness and exact provider
PID. The starter proves ancestry before `running` and prints `Started` last.
HUP/INT/TERM forward while the wrapper releases its lease and assertion;
`detach stop` releases by run token. Providers get `COLORTERM=truecolor` and
the wrapper's tmux process group. Captures keep styles; I/O cannot stop it. The
worker publishes actionless `finalizing` with the intended status,
checkpoints, publishes `terminal`, and retains logs; `pane-died` publishes
again. A terminal record with an owned live pane and dead provider is finished.

Stop binds intent and mutations to the run token; failure changes nothing. It
publishes `stopping` and stopped, captures the pane, then signals. Stop intent
is monotonic. Actions and cleanup stay closed during live teardown; dead phases
converge. A live provider keeps full grace. Worker and Stop publish `terminal`
idempotently. Delete handles retained tmux without state and never reports
success over leftovers.

Closing Terminal or Detach.app only removes clients. The Detach tmux server,
worker, provider, checkpoint loop, and power wrapper continue in the macOS user
session. They do not promise survival across logout or reboot; killing
tmux or the provider ends the live run. Recovery checkpoints remain.
Provider test parts use private roots; the parent orders and needs all.
Small hosts use three Codex and two Claude parts.

Status uses session-local `@detach*` keys and never changes a foreign server.
The strip shows identity, power, and time; the title is
`Detach · <project basename>`. Finished sessions fade and failures use red.
Hue allocation scans both providers under the Start/Resume/Recover install
lock. It keeps
a unique hue, then uses the stable provider/project choice after all eight.
History reserves no hue; unknown is conservative.
Style snapshots restore both sides and lengths; an old one preserves the
user's `status-right`. Text is the primary power signal: `MAC AWAKE`,
`MAC CAN SLEEP`, `LOW BATTERY`, `MAC CAN SLEEP: TEMPERATURE`,
`POWER UNAVAILABLE`, or a transition. App wording is equivalent and icons are
secondary.

Managed input changes only the private server. `tmux-mouse` defaults on: wheel
steps are one line; selection copies without clearing, exiting, or snapping;
click clears it. ASCII/Cyrillic text, Space, Enter, and BSpace exit
copy-mode and reach the pane while bound navigation/control keys stay.
Unbound input, including bracketed paste, also leaves managed copy mode.
Paste preserves its UTF-8 bytes and the provider's paste framing. The copy
command reads UTF-8 regardless of the server locale. Attach updates older
managed input bindings without replacing their saved original tables. Off restores
the original copy tables immediately.

`tmux-extended-keys` defaults on and maps recognized `S-Enter` to stable
`M-Enter`; off restores the original binding or plain Enter. It adds
`*:extkeys` and `*:hyperlinks` once; OSC 8 links stay independent.

## Recovery boundary

Provider identity and checkpoint replacement follow
[the recovery specification](recovery.md). Read it for Resume, Recover, or
checkpoint changes.
