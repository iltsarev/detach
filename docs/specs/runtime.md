# Runtime, state, and session specification

## Installed distribution

Detach.app installs an immutable payload below
`~/.local/libexec/detach/versions/<semver>-<hash>/` and switches
`~/.local/bin/detach` atomically. Payload order is `detach`, `detach-core`,
`detach-install`, `detach-state`, `detach-power`, and `tmux`.

Install and Repair validate the payload before activation; failure keeps the
active payload. A live or retained session defers replacement. One PATH entry
supports all shells. `--keep-state` keeps checkpoints. `--purge-state`
removes Detach state, not provider data. Uninstall restores an unchanged
profile or removes only its entry. Source edits require app sync or Repair.

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

`client switch` retries reads for 0.5 seconds. PID, UID, source, private socket,
and managed target must match. Framing must survive `LC_ALL=C`. Failed proof
causes no mutation. Attach can hold a frame until the target redraws.

Core self-reinvokes critical mutations under `lockf`. Start, Resume, Stop,
Recover, and Delete hold a session lock before install, project, and checkpoint
locks. Each lock covers the child; the install lock covers readiness and the
worst hold.

### Typed state boundary

`detach-state` is the JSON boundary. Never edit JSON in shell. It owns typed
metadata, JSONL, health, reconcile, storage, emit, and event operations.
`meta snapshots` enumerates one owned sessions root through anchored directory
descriptors. It rejects unsafe directories and opens only owned regular files
of at most 1 MiB with `O_NOFOLLOW`.
Integer conversion must not trap. Storage reports allocated and logical bytes,
excludes provider storage, does not follow symlinks, and authorizes cleanup
only after a complete scan with explicit `cleanup_eligible: true`.

Per-session `meta.json` schema 1 stores internal `session_name`, optional
`display_name`, and `run_token`; older documents remain valid. Each patch locks
its read-change-atomic-replace transaction, so concurrent writers keep disjoint
fields. Run tokens stop stale workers from overwriting replacement runs. New
runs publish `health_schema=1`, exact worker/provider PIDs, heartbeat, and
checkpoint epoch. Health combines tmux, run token, PID ownership, metadata, and
checkpoint freshness. Stale data cannot make a proven live provider hung. A
runtime without managed tmux blocks mutations until its exact processes exit.
`preserve_recovery_until_ready` is Boolean; `runtime_ready_at` and
`runtime_shutdown_observed_at` are strings. A mistyped primary is unusable.
Checkpoint metadata cannot replace it.

`list --json` reads Codex and Claude concurrently and emits that order. Each
uses one all-pane tmux snapshot and clock sample. `proc_pidinfo` reads recorded
PIDs and 64 parents. Empty tmux output is missing; wrong identity is collision.
Mutations recheck ownership, pane, run token, and process group. List jobs
`exec` cores; cleanup signals PIDs.

A retained dead pane is mutable only when its nonempty tmux token matches usable
primary metadata. A checkpoint cannot authorize removal. Start, Resume,
Recover, and Delete repeat this check under the operation lock. A tmux-only
remnant remains removable without state.

Typed state caches Codex checkpoint assessment by provider, session ID, and
file identity. A change forces a full scan. Restore ignores this receipt,
validates a temporary copy, then replaces the live file. List summaries use an
atomic receipt bound to provider, path, device, inode, size, and nanosecond
mtime. An unchanged identity skips the 256 KiB tail read.

State is private (`umask 077`) under
`~/.local/state/detach/{codex,claude}/sessions/<name>/` and contains full
conversations. Public operations reject symlinked or foreign-owned mutable
roots before traversal. The checked Codex SQLite backup is never restored
automatically.

Bulk cleanup selects only fully scanned `stopped` or `orphaned` sessions.
Before deletion, the app re-reads and matches the shown status and byte
counts. The provider command waits up to 30 s for the checkpoint lock,
then rechecks managed tmux liveness and ownership, rejecting symlinked or
foreign-owned state/session directories. A partial failure keeps and reports
each failed session.

### Session change events

`watch --json` execs the helper and follows parent. Hints require
`list --json`. FSEvents accepts only metadata-named transcripts. Exact vnode
sources cover 64 live transcripts, including old
runtimes. Bursts yield leading and 150 ms trailing hints. Drops or root changes
yield `resync`. Lifecycle signals refresh roots; heartbeats do not. The
publisher writes `session-change` under state root. Activation repairs loss.
Watcher shutdown drains native callbacks before its output can close.

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

Default starts form a provider/project history series. A fresh start refuses a
live member or second writer; otherwise it allocates a successor without
reusing saved state. No-`NAME` commands select the live member, then the highest
suffix. Older `session_name` values stay addressable; their metadata, logs,
and checkpoints remain until Delete or typed storage cleanup. Explicit names
stay deterministic and obey the same project lock and cleanup policy.

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
copy-mode and reach the pane while navigation/control keys stay. Off restores
the original copy tables immediately.

`tmux-extended-keys` defaults on and maps recognized `S-Enter` to stable
`M-Enter`; off restores the original binding or plain Enter. It adds
`*:extkeys` and `*:hyperlinks` once; OSC 8 links stay independent.

`list --json` emits JSONL schema 1 with optional `display_name`, power and turn
state, opaque turn ID, PIDs, health, reconcile, freshness, ownership, cleanup,
`stop_requested_at`, and a per-run opaque `lifecycle_id` distinct from the
mutation token. Keep the emitter and Swift `Session` decoder in sync.
`watch --json` emits only change hints and never replaces this snapshot.
Provider lifecycle records, never terminal text, supply turn state and the
private activity file in `power.md`. Bounded append caching retains typed turns;
an unseen oversized gap clears waiting to prevent stale Answer ready. A
main-chain Claude `AskUserQuestion` with `stop_reason: tool_use` and a tool ID
means waiting; only its matching user tool result restores working. Reducer
changes invalidate old receipts so unchanged prompts are reclassified.
Typed cleanup uses `cleanup_eligible`.

### Provider identity and checkpoints

Claude gets a wrapper-owned UUID via `--session-id`. Resume uses `--resume` with
a valid transcript or matching checkpoint. It uses `--session-id` only if both
are absent. A present invalid transcript fails closed. Codex binds identity
after launch by matching the run-token originator in rollout files and SQLite;
an ambiguous first binding fails. If the provider switches to another run-owned
user thread (for example `/clear`), discovery rebinds identity, transcript, and
checkpoints to the newest originator-matched thread within one heartbeat or
checkpoint tick, records superseded thread IDs so the next switch stays
unambiguous, and keeps the current binding on a creation-time tie. Subagent
threads never rebind a session. Wrapper-owned provider flags are rejected;
policy defaults apply only without an allowed override.

By default, a per-session lock protects a checkpoint every 300 s. It has
metadata, validated provider JSONL, pane capture, and a repository root from a
real `.git` ancestor. Codex removes temporary sidecars after its checked SQLite
backup. Claude archives its matching project session and companions. A writer
validates a private sibling, rechecks the exact worker, recovery binding, and
saved options, then atomically exchanges it with `checkpoint`. Readers cannot
see a partial generation. Safe prior diagnostics survive a failed refresh.
Checkpoint, discovery, and heartbeat writers recheck the primary run token,
worker PID, live managed pane, and pane PID while they hold the session lock.
An old writer cannot rebind or publish state. Recover holds this lock through
source validation, retained-pane removal, reselection, and restore. Resume and
Recover hold the install and project locks from occupancy check through start.
Provider-created hard links become independent regular files in staging;
archives and restore destinations still reject hard links and non-plain
entries. Before any write, List and Recover validate the selected Claude source,
companion trees, destinations, and `.detach.old` or `.detach.tmp` siblings.
Unsafe optional data blocks recovery without changing its source. Task names
match the UUID. Archived and existing team configs name that UUID as lead, so a
checkpoint cannot replace another session's team. A valid selected live
generation replaces an older checkpoint only after complete staging. Tests can
disable durability syncs.

Resume and Recover keep the last valid checkpoint and saved provider options
until replacement B passes power and provider readiness. A failed handshake
keeps that data. A fresh Start clears it. List and Recover share provider-source
and saved-options checks. A selected live primary generation includes its
provider ID, transcript, and options; Detach materializes the complete bundle
before another replacement. An older checkpoint is not equivalent, even with
the same run token. Every writer reads readiness from primary metadata and
requires an explicit run token.

The runtime syncs preserved recovery before primary metadata identifies B. It
syncs new options before readiness names them, and syncs an exchanged checkpoint
before it prunes prior options.

Codex recovery binds a UUID to one exact rollout path. Every existing path
component is a plain directory. A damaged rollout needs a matching database row
or embedded UUID. Recovery never overwrites another thread's rollout and uses a
private file plus atomic rename.

Primary metadata identifies replacement B while it may live. List and Recover
require durable shutdown observation. A dead worker and missing launch files do not
prove that its power wrapper stopped. Normal wrapper return does. Before
`respawn-pane`, removing the placeholder can prove shutdown; after that call,
missing launch files prove nothing. A signal exit without provider identity is
unknown and blocks mutation.

If sync after a checkpoint exchange fails, Detach exchanges the prior
generation back and removes the other only after rollback sync. An uncertain
rollback or post-exchange signal keeps both names. A later writer removes an
abandoned stage only after strict validation and canonical sync. Reset uses a
typed marker that names its exact prior generation; an empty directory is not
reset evidence.

Primary metadata, saved options, checkpoint logs, known thread IDs, and exit
status are plain files in the private session directory. Initialization checks
their types before it changes a checkpoint. Writers publish replacement files
with an atomic rename and never append through an untrusted path.

Only allowlisted provider flags are serialized to a run-token-bound options
file selected by typed metadata. Recover accepts the legacy `resume-args.bin`
file. A flag that should survive Resume or Recover must be added deliberately.
