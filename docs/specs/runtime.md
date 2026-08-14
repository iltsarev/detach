# Runtime, state, and session specification

## Installed distribution

Detach.app installs an immutable payload under
`~/.local/libexec/detach/versions/<semver>-<hash>/`. It switches
`~/.local/bin/detach` atomically. Order:

1. `detach`
2. `detach-core`
3. `detach-install`
4. `detach-state`
5. `detach-power`
6. `tmux`

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
  `list`, UUID-aware `resume`, storage and reconcile previews, `power status`,
  config, doctor, repair, and uninstall. Then it invokes the core.
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
`__start_tmux_session_locked`. Start, Resume, Stop, Recover, and Delete also
share a per-session operation lock so their whole state transitions serialize
before narrower install/project/checkpoint locks. New shared mutations should
keep the lock around the whole child process and preserve that lock order.

### Typed state boundary

`detach-state` is the JSON boundary. Do not edit JSON in shell. It owns typed
metadata, JSONL, health, reconcile, storage, and emit operations.
`meta snapshots` enumerates one owned sessions root through anchored directory
descriptors. It accepts no path stream. It rejects unsafe session or checkpoint
directories and opens only owned regular files of at most 1 MiB with
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
Anything restored into provider storage must pass canonical path, symlink,
session-ID, and JSONL validation, be written to a temporary file, validated
again, and only then be moved into place.

State is private (`umask 077`) under
`~/.local/state/detach/{codex,claude}/sessions/<name>/` and contains full
conversations. Public operations reject symlinked or foreign-owned mutable
roots before traversal. Codex's integrity-checked SQLite backup is never
restored automatically.

Bulk cleanup may select only fully scanned `stopped` or `orphaned` sessions.
Before deletion the app must re-read and match the displayed status and byte
counts. Actual deletion continues through the provider command, holds the
checkpoint lock, rechecks managed tmux liveness/ownership under that lock, and
refuses symlinked or foreign-owned state/session directories. A partial failure
must leave every failed session in place and continue reporting it explicitly.

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
ASCII slug plus a 12-hex content hash. A valid full
`detach-<provider>-<safe-name>` is reserved as an explicit internal identifier
for backward compatibility. User input never becomes a tmux name or state path
unless it already satisfies that legacy-safe grammar.

The optional display name is persisted separately, emitted through typed state,
preserved across resume/recovery, and accepted by later lifecycle commands,
which deterministically resolve it back to the same internal identifier. The
shared tmux daemon is anchored in persistent install state, not the first
project directory. It is addressed only through the private absolute
`$DETACH_INSTALL_STATE_ROOT/tmux/tmux.sock`, never ambient `TMUX_TMPDIR`.
Install migration checks both the older default socket and the historical
`-L dev.tsarev.detach` socket before switching payloads. Each worker starts
from stable install state and then enters the canonical project beneath its
cleanup trap.

Tmux environment arguments stay in memory; provider credentials are never
session scratch data.

Default starts form a provider/project history series. A fresh start refuses a
live member or second writer; otherwise it allocates a successor without
reusing saved state. No-`NAME` commands select the live member, then the highest
suffix. Older `session_name` values stay addressable, and their metadata, logs,
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

The power wrapper must confirm both protection layers and atomically mark the
ready file before launching the provider, then atomically publish the exact
spawned provider PID. The starter waits for both handshakes and one forced
runtime heartbeat and must never print `Started` before they arrive.
HUP/INT/TERM are forwarded to the provider while the wrapper remains alive long
enough to release its lease and assertion; explicit `detach stop` also performs
an idempotent release by session/run token. The provider must inherit the
wrapper's tmux foreground process group; launching it in a separate group makes
interactive Codex or Claude stop on terminal I/O. On provider exit, the worker
records status, attempts a final checkpoint, and leaves the pane retained for
logs and diagnosis.

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
eight-hue identity palette deliberately omits pure red. Color allocation scans
saved Codex and Claude sessions while Start/Resume/Recover holds the shared
install lock: keep an existing unique session color, otherwise walk from the
stable provider/project-derived preference to the first free hue, and permit a
duplicate only when all eight hues are occupied. This preserves identity
without avoidable collisions across providers. Every derived surface comes
from the single `blend_session_color` formula rather than per-color pairs. The
style snapshot saves and restores `status-right` and its
length alongside the left side; a snapshot from an older Detach that never
captured the right side must not clear the user's `status-right`. The text
Plain text is the primary power signal: `MAC AWAKE`, `MAC CAN SLEEP`, `LOW
BATTERY`, `MAC CAN SLEEP: TEMPERATURE`, `POWER UNAVAILABLE`, or a transition;
app wording is equivalent and icons are secondary.

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
Provider lifecycle records, never terminal text, supply turn state
and the private run-token activity file defined in `power.md`.
Typed cleanup uses `cleanup_eligible`. List batches metadata, health, and JSON
in two helpers.

### Provider identity and checkpoints

Claude gets a wrapper-owned UUID via `--session-id`. Resume uses `--resume`
if a transcript exists, else `--session-id` for that owned UUID. Codex
identity is resolved after launch by matching the run-token originator in
rollout files and Codex's SQLite threads, refusing an ambiguous first
binding. When the provider later switches to another run-owned user thread
(for example `/clear`), discovery rebinds identity, transcript, and
checkpoints to the newest originator-matched thread within one heartbeat or
checkpoint tick, records the superseded thread ids, and keeps the current
binding on a creation-time tie. Subagent threads never rebind a session.
Wrapper-owned provider flags are rejected; policy defaults apply only when
the user did not supply an allowed override.

A per-session lock protects checkpoint creation every 300 seconds.
A checkpoint contains metadata, validated provider JSONL, pane capture, and a
repository root from a real `.git` ancestor. Codex adds an integrity-checked
SQLite backup. Claude archives its matching project session and companions.
Staging copies provider hard links as regular files.
Archives and restore destinations still reject hard links and non-plain
entries. A provider test override can disable the final `/bin/sync`.

Only allowlisted provider flags are serialized to `resume-args.bin`. A provider
flag that should survive Resume or Recover must be added deliberately.
