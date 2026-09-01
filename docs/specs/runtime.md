# Runtime, state, and session specification

## Installed distribution

Detach.app installs an immutable payload under
`~/.local/libexec/detach/versions/<semver>-<hash>/`. It switches
`~/.local/bin/detach` atomically. Payload order is `detach`, `detach-core`,
`detach-install`, `detach-state`, `detach-power`, then `tmux`.

Install and Repair validate a complete payload before CLI activation. Failure
keeps the active payload. A live or retained managed session blocks
replacement; retry can succeed later. One PATH entry supports login
and interactive modes. `--keep-state` preserves checkpoints across reinstall.
`--purge-state` removes Detach state, not `~/.codex` or `~/.claude`. Uninstall
restores an unchanged profile, or removes only the Detach entry from a changed
profile. Source edits require app sync or Repair.

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

Tests may inject binary and state paths with `DETACH_*` variables. Production
must default tmux, `detach-state`, and `detach-power` to the immutable sibling
payload, never Homebrew or another ambient installation. Provider binaries
remain user-owned and are found through `PATH` or provider-specific test
overrides. macOS-supplied `sqlite3`, `tar`, `env`, and `lockf` stay explicit,
injectable platform utilities.

Critical mutations self-reinvoke core under `lockf`:
`__checkpoint_once_locked`, `__delete_locked`, and
`__start_tmux_session_locked`. Start, Resume, Stop, Recover, and Delete also
serialize through a per-session lock before narrower install, project, and
checkpoint locks. Keep this order and the lock around the whole child. The
install lock covers readiness; its timeout exceeds the worst hold.

### Typed state boundary

`detach-state` is the JSON boundary. Do not edit JSON in shell. It owns typed
metadata, JSONL, health, reconcile, storage, emit, and event operations.
`meta snapshots` enumerates one owned sessions root through anchored directory
descriptors, accepts no path stream, rejects unsafe session or checkpoint
directories, and opens only owned regular files of at most 1 MiB with
`O_NOFOLLOW`.
Integer conversion must not trap. Storage reports allocated and logical bytes,
excludes provider storage, does not follow symlinks, and authorizes cleanup
only after a complete scan with explicit `cleanup_eligible: true`.

Per-session `meta.json` uses schema 1, internal `session_name`, optional
`display_name`, and a `run_token`. Older documents without `display_name`
remain valid. A stale worker or checkpoint loop must not overwrite replacement
run metadata. New runs publish `health_schema=1`, exact worker/provider PIDs,
worker heartbeat time, and checkpoint epoch. Health combines managed tmux/pane
state, run token, PID ownership and ancestry, valid metadata, heartbeat, and
checkpoint freshness. Stale data alone cannot classify a proven live provider
as hung. A recorded live runtime without managed tmux permits no signal,
replacement, recovery, or deletion. Wait for the exact processes to exit.
Anything restored into provider storage passes canonical path, symlink,
session-ID, and JSONL validation, is written to a temporary file, validated
again, and only then moved into place.

State is private (`umask 077`) under
`~/.local/state/detach/{codex,claude}/sessions/<name>/` and contains full
conversations. Public operations reject symlinked or foreign-owned mutable
roots before traversal. Codex's integrity-checked SQLite backup is never
restored automatically.

Bulk cleanup selects only fully scanned `stopped` or `orphaned` sessions.
Before deletion, the app re-reads and matches the displayed status and byte
counts. The provider command waits up to 30 seconds for the checkpoint lock,
then rechecks managed tmux liveness and ownership, rejecting symlinked or
foreign-owned state/session directories. A partial failure keeps each failed
session and reports it explicitly.

### Session change events

`watch --json` execs the state helper. Its schema-1 hints are not truth; each
requires full `list --json`. FSEvents filters the private signal and provider
JSONL. Bursts yield leading and 150 ms trailing hints; drops or root changes
yield `resync`. Lifecycle changes replace the signal after owned Start metadata
or Delete; heartbeats do not. Activation repairs missed delivery.

### Session lifecycle and tmux

`start` takes one cross-provider project lock, creates a safe identifier, sets
window `remain-on-exit` off and the provider pane on, then launches `__worker`.
Splits close on exit; provider logs and status remain. Without
`--name`, the identifier is
`detach-<provider>-<project-slug>-<project-hash>` for the first history;
successors use a monotonic `-r<12-hex>` suffix and persist the unsuffixed
`default_session_base`. An explicit human-readable
name is 1–100 UTF-8 bytes of printable text. Legacy-safe names retain the exact
`detach-<provider>-<name>` identifier; all other names derive a deterministic
ASCII slug plus a 12-hex content hash. A full
`detach-<provider>-<safe-name>` stays reserved as an explicit internal
identifier for backward compatibility; user input never becomes a tmux name or
state path unless it already satisfies that legacy-safe grammar.

The optional display name is persisted separately, emitted through typed state,
preserved across resume/recovery, and accepted by later lifecycle commands,
which resolve it deterministically to the same internal identifier. The
shared tmux daemon is anchored in persistent install state, not the first
project directory, and is addressed only through the private
`$DETACH_INSTALL_STATE_ROOT/tmux/tmux.sock`, never ambient `TMUX_TMPDIR`.
Install migration checks the older default socket and the historical
`-L dev.tsarev.detach` socket before switching payloads. Each worker starts
from stable install state, then enters the canonical project beneath its
cleanup trap.

Tmux environment arguments stay in memory; provider credentials are never
session scratch data.

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
Codex or Claude stop on terminal I/O. On provider exit, the worker records
status, attempts a final checkpoint, and leaves the pane retained for logs.

Stop revalidates the managed run, pane, owned PID, and process group before
each TERM or KILL. Delete removes a retained tmux session even
without a state directory and never reports success over leftover state.

Closing Terminal or Detach.app only removes clients. The Detach tmux server,
worker, provider, checkpoint loop, and power wrapper continue in the macOS user
session. They do not promise survival across logout or reboot; an explicit
kill of tmux/provider ends the live run. Recovery checkpoints remain available.
Provider test parts use private roots; the parent orders and requires all.
Small hosts use three Codex and two Claude parts.

Detach status options use session-local `@detach*` keys and never touch a
foreign server. The strip shows identity, power, and time. Sessions set
`Detach · <project basename>` as the title. Finished sessions fade; failures
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
state, opaque turn ID, PIDs, health, reconcile, freshness, ownership,
and cleanup fields. Keep the emitter and Swift `Session` decoder synchronized.
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

Every 300 seconds by default, a per-session lock protects checkpoint creation.
A checkpoint contains metadata, validated provider JSONL, pane capture, and a
repository root from a real `.git` ancestor. Codex adds an integrity-checked
SQLite backup. Claude archives its matching project session and companions.
Provider-created hard links become independent regular files in staging;
archives and restore destinations still reject hard links and non-plain
entries. A provider test override can disable the final `/bin/sync`.

Only allowlisted provider flags are serialized to `resume-args.bin`; a flag
that should survive Resume or Recover must be added deliberately.
