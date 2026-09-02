# Runtime, state, and session specification

## Installed distribution

Detach.app installs an immutable payload under
`~/.local/libexec/detach/versions/<semver>-<hash>/`. It switches
`~/.local/bin/detach` atomically. Payload order is `detach`, `detach-core`,
`detach-install`, `detach-state`, `detach-power`, then `tmux`.

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

- **`bin/detach`** is the only command on PATH. It resolves owned executables as
  immutable siblings and selects `codex` or `claude`. It owns cross-provider
  `list`, native `watch`, UUID-aware `resume`, storage and reconcile previews,
  `power status`, config, doctor, repair, and uninstall.
- **`bin/detach-core`** owns the provider-neutral session lifecycle, inline
  provider adaptations, checkpoint/recovery policy, tmux status, and internal
  self-reinvocation commands. It rejects direct invocation unless the frontend
  supplies `DETACH_CORE_ENTRYPOINT=1`.

Tests inject paths through explicit `DETACH_*` environments. An app CLI strips
them except in isolated UI tests. Production resolves tmux and state/power
helpers only as immutable siblings. Providers resolve through `PATH`.

`client switch` targets one exact attached client on the private tmux socket.
It needs its PID, user ID, expected source, and a live managed target. A
failed proof causes no mutation. Attach can declare synchronized-output support
to hold the complete frame until the target redraw.

Critical mutations self-reinvoke core under `lockf`. Start, Resume, Stop,
Recover, and Delete serialize through a per-session lock before narrower
install, project, and checkpoint locks. Keep this order and the lock around the
whole child. The install lock covers readiness and outlasts the worst hold.

### Typed state boundary

`detach-state` is the JSON boundary. Never edit JSON in shell. It owns typed
metadata, JSONL, health, reconcile, storage, emit, and event operations.
`meta snapshots` enumerates one owned sessions root through anchored directory
descriptors. It rejects unsafe directories and opens only owned regular files
of at most 1 MiB with `O_NOFOLLOW`.
Integer conversion must not trap. Storage reports allocated and logical bytes,
excludes provider storage, does not follow symlinks, and authorizes cleanup
only after a complete scan with explicit `cleanup_eligible: true`.

Per-session `meta.json` schema 1 has internal `session_name`, optional
`display_name`, and `run_token`. Older documents remain valid. Stale workers
cannot overwrite a replacement run. New runs publish `health_schema=1`, exact
worker/provider PIDs, heartbeat, and checkpoint epoch. Health uses tmux, run
token, PID ownership, metadata, and checkpoint freshness. Stale data cannot
make a proven live provider hung. A runtime without managed tmux blocks
mutations until its exact processes exit.

The JSON list reads both providers concurrently, Codex before Claude.
Each captures one all-pane tmux snapshot and one clock sample. `proc_pidinfo`
reads only recorded worker/provider PIDs and 64 parents. An empty tmux expansion
is missing; a present wrong identity is a collision. Mutations repeat ownership,
pane, run-token, and process-group checks.

Typed state caches Codex checkpoint assessment in a receipt bound to provider,
session ID, and file identity. A change forces a full scan. Restore ignores the
receipt, validates a temporary copy, then replaces the live file.

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

`watch --json` execs the state helper and exits with its parent or cancellation.
Lossy hints require `list --json`. FSEvents accepts only exact transcripts from
usable metadata in each provider `sessions` root. Bursts yield leading and
150 ms trailing hints. Drops or root changes yield `resync`. Lifecycle signals
refresh roots; heartbeats do not. Missing provider roots are omitted. The signal
path is standardized. Activation repairs loss.

### Session lifecycle and tmux

`start` takes one cross-provider project lock, creates a safe identifier, sets
window `remain-on-exit` off and the provider pane on, then launches `__worker`.
Splits close on exit; logs and status remain. Without
`--name`, the identifier is
`detach-<provider>-<project-slug>-<project-hash>` for the first history;
successors use a monotonic `-r<12-hex>` suffix and persist the unsuffixed
`default_session_base`. An explicit human-readable
name is 1–100 UTF-8 bytes of printable text. Legacy-safe names retain the exact
`detach-<provider>-<name>` identifier; all other names derive a deterministic
ASCII slug plus a 12-hex content hash. A full `detach-<provider>-<safe-name>`
stays reserved as an internal identifier; user input never becomes a tmux name
or state path unless it satisfies that legacy-safe grammar.

The optional display name is persisted separately, emitted through typed state,
preserved across resume/recovery, and resolved deterministically by later
lifecycle commands. The shared tmux daemon is anchored in install state, not
the first project directory, and is addressed only through the private
`$DETACH_INSTALL_STATE_ROOT/tmux/tmux.sock`, never ambient `TMUX_TMPDIR`.
Install migration checks the older default and historical
`-L dev.tsarev.detach` sockets before switching payloads. Each worker starts
from stable install state, then enters the canonical project beneath its
cleanup trap.

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

The power wrapper must confirm both protection layers, atomically mark the
ready file before launching the provider, then atomically publish the exact
spawned provider PID. The starter waits for both handshakes and one forced
runtime heartbeat and never prints `Started` before they arrive.
HUP/INT/TERM forward to the provider while the wrapper stays alive to release
its lease and assertion; explicit `detach stop` also releases idempotently by
session/run token. The provider must inherit the
wrapper's tmux foreground process group; a separate group makes interactive
Codex or Claude stop on terminal I/O. On provider exit the worker checkpoints
silently, records and publishes status, and leaves the pane retained for logs;
a tmux `pane-died` hook publishes once more. A terminal record with a live
owned pane and dead provider is finished, not hung.

Stop revalidates the managed run, pane, owned PID, and process group before
each TERM or KILL. Delete removes a retained tmux session even
without a state directory and never reports success over leftover state.

Closing Terminal or Detach.app only removes clients. The Detach tmux server,
worker, provider, checkpoint loop, and power wrapper continue in the macOS user
session. They do not promise survival across logout or reboot; killing
tmux or the provider ends the live run. Recovery checkpoints remain.
Provider test parts use private roots; the parent orders and needs all.
Small hosts use three Codex and two Claude parts.

Detach status options use session-local `@detach*` keys and never touch a
foreign server. The strip shows identity, power, and time. The title is
`Detach · <project basename>`. Finished sessions fade; failures
use red outside the eight identity hues. Allocation scans both providers under
the Start/Resume/Recover install lock. History keeps identity but reserves no
hue. Unknown is conservative. Keep a unique hue; otherwise use the stable
provider/project preference and duplicate after all eight.
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
and `stop_requested_at`, which Stop records before it signals. Keep the emitter and the Swift `Session` decoder in sync.
`watch --json` emits only change hints and never replaces this snapshot.
Provider lifecycle records, never terminal text, supply turn state
and the private run-token activity file defined in `power.md`.
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
backup. Claude archives its matching project session and companions.
Provider-created hard links become independent regular files in staging;
archives and restore destinations still reject hard links and non-plain
entries. A provider test override can disable the final `/bin/sync`.

Only allowlisted provider flags are serialized to `resume-args.bin`; a flag
that should survive Resume or Recover must be added deliberately.
