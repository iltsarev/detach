# Typed state, storage, and event specification

## Typed state boundary

`detach-state` is the JSON boundary. Never edit JSON in shell. It owns typed
metadata, JSONL, health, reconcile, storage, emit, and event operations.
Codex and Claude JSONL validation reject a record that names a different
session.
`meta snapshots` enumerates one owned sessions root through anchored directory
descriptors. It rejects unsafe directories and opens only owned regular files
of at most 1 MiB with `O_NOFOLLOW`. Storage metadata, checkpoint fallback
metadata, and cached transcript validation use nonblocking file opens before
they check the file type. This includes validation receipts. A FIFO cannot
delay these reads while it waits for a writer.
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
uses batched all-pane tmux snapshots and one clock sample per attempt. `proc_pidinfo` reads recorded
PIDs and 64 parents. Empty tmux output is missing; wrong identity is collision.
List and mutation eligibility compare process creation time with recorded runtime readiness. A process
that started in a later second is a reused PID, not a surviving runtime.
Missing readiness or creation time keeps the conservative identity result.
Mutations recheck ownership, pane, run token, and process group. List jobs
`exec` cores; cleanup signals PIDs.

List buffers its output. Metadata health revisions and tmux identities must
match before and after assessment. A revision includes metadata validity,
source, generation, phase, process identity, shutdown evidence, checkpoint
directory identity, and operation lock state. Routine heartbeat and checkpoint timestamps do not change it.
List retries a changed observation up to three times. Continued changes fail
the read without partial rows. Each stable attempt uses two tmux reads and a
constant number of state helper processes, independent of the session count.

List checks the BSD session operation lock without waiting or creating a
file. While an operation holds the lock, provisional faults show actionless
`starting` with reason `operation_in_progress`. A proven live pane can still
offer Attach. List grants no mutation, reconcile, or cleanup action during the
operation. Normal fault rules apply after lock release. Mutation preflight
does not use this presentation rule.

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

Recover can rebuild an incomplete checkpoint from a valid live journal even
when an interrupted publication left staging directories. It validates those
directories before staging. It removes retained generations only after the
replacement checkpoint passes validation, atomic publication, and required
writeback. A failure before publication preserves the retained generations.

Bulk cleanup selects only fully scanned `stopped` or `orphaned` sessions.
Before deletion, the app re-reads and matches the shown status and byte
counts. The provider command waits up to 30 s for the checkpoint lock,
then rechecks managed tmux liveness and ownership, rejecting symlinked or
foreign-owned state/session directories. A partial failure keeps and reports
each failed session.

## Session change events

`watch --json` execs the helper and follows parent. Hints require
`list --json`. FSEvents accepts only metadata-named transcripts. Exact vnode
sources cover 64 live transcripts, including old
runtimes. Bursts yield leading and 150 ms trailing hints. Drops or root changes
yield `resync`. Lifecycle signals refresh roots; heartbeats do not. The
publisher writes `session-change` under state root. Activation repairs loss.
Watcher shutdown drains native callbacks before its output can close.

## Snapshot contract

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
A main-chain Claude assistant record with `stop_reason: end_turn` and nonempty
text also means waiting. Thinking-only, metadata, and tool-use blocks do not
prove a completed answer. Repeated final text and a later `turn_duration` keep
the waiting turn ID. A new user request or an assistant `tool_use` continuation
restores working. A pending `AskUserQuestion` still requires its matching
result. Schema-4 summary receipts invalidate earlier cached turn states.
Typed cleanup uses `cleanup_eligible`.
