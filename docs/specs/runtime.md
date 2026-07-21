# Runtime, state, and session specification

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
  cross-provider `list`, UUID-aware `resume`, storage and reconcile previews,
  `power status`, configuration, doctor, repair, and uninstall surfaces, then
  invokes the core.
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

`detach-state` replaces the former jq dependency. Its stable typed commands
cover guarded metadata create/get/patch/match operations, JSONL validation and
summary, context/session JSON emission, health evaluation, reconcile plans,
and storage report/cleanup-plan JSON.
Storage accounting uses allocated blocks as the user-facing disk size, keeps
logical bytes separately for sparse files, never follows symlinks, excludes
provider storage, and treats an incomplete scan as ineligible for cleanup. Do
not reintroduce ad-hoc JSON text editing or a jq runtime requirement.

Per-session `meta.json` uses schema 1 and a `run_token`. A stale worker or
checkpoint loop must not overwrite metadata belonging to a replacement run.
New runs also publish `health_schema=1`, the exact worker/provider PIDs, worker
heartbeat time, and checkpoint epoch. Health is a typed state machine over
managed tmux/pane state, the matching run token, PID ownership and ancestry,
metadata validity, and heartbeat/checkpoint freshness. Stale freshness alone
must never classify a proven live provider as hung. A live recorded runtime
without managed tmux authorizes no signal, replacement start, recovery, or
deletion; wait for the exact processes to disappear rather than touching a
possibly foreign process.
Anything restored into provider storage must pass canonical path, symlink,
session-ID, and JSONL validation, be written to a temporary file, validated
again, and only then be moved into place.

State is private (`umask 077`) under
`~/.local/state/detach/{codex,claude}/sessions/<name>/` and contains full
conversation data. Codex's shared SQLite database may be backed up after an
integrity check but is never restored automatically.

Bulk cleanup may select only fully scanned `stopped` or `orphaned` sessions.
Before deletion the app must re-read and match the displayed status and byte
counts. Actual deletion continues through the provider command, holds the
checkpoint lock, rechecks managed tmux liveness/ownership under that lock, and
refuses symlinked or foreign-owned state/session directories. A partial failure
must leave every failed session in place and continue reporting it explicitly.

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
  --ready-file <absolute-path> --pid-file <absolute-path> -- <provider> ...
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
`power_protection_state`, `agent_turn_state`, opaque `agent_turn_id`, runtime
PIDs, health reason/actions, reconcile action, freshness, ownership proof, and
cleanup eligibility. Keep the emitter and Swift `Session` decoder synchronized.
Derive turn state only from structured provider lifecycle records, never
terminal text. Storage cleanup must consume typed `cleanup_eligible`, not infer
safety again from a display status.

### Provider identity and checkpoints

Claude gets a wrapper-owned UUID via `--session-id`. Codex identity is resolved
after launch by matching the run-token originator in rollout files and Codex's
SQLite threads, refusing an ambiguous first binding. When the provider later
switches to another run-owned user thread mid-run (for example `/clear`),
discovery rebinds identity, transcript, and checkpoints to the newest
originator-matched thread within one heartbeat or checkpoint tick, records the
superseded thread ids so the next switch is again unambiguous, and keeps the
current binding on a creation-time tie. Subagent threads never rebind a
session. Wrapper-owned provider flags are rejected; policy defaults apply only
when the user did not supply an allowed override.

Checkpoints run every `DETACH_<PROVIDER>_CHECKPOINT_INTERVAL` seconds (300 by
default) under a per-session lock and include metadata, validated provider
JSONL, tmux pane capture, and canonical repository-root context found from a
real `.git` ancestor without invoking Git. Codex adds an integrity-checked
SQLite backup. Claude atomically archives the matching project session, file
history, session environment, tasks, and teams. `/bin/sync` follows unless the
provider-specific `DETACH_*_SYNC=0` test override is set.

Only allowlisted provider flags are serialized to `resume-args.bin`. A provider
flag that should survive Resume or Recover must be added deliberately.
