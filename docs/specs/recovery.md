# Provider identity and recovery specification

<a id="qc-runtime-transition"></a>

## Provider identity and checkpoints

Claude gets a wrapper-owned UUID via `--session-id`. Resume uses `--resume` with
a valid transcript or matching checkpoint. It uses `--session-id` only if both
are absent. A present invalid transcript fails closed. Startup companions such
as `session-env/<uuid>` or `tasks/session-<short>` are not transcript evidence
and do not block that path. Claude can continue a conversation under a new
UUID in the same process. The bound transcript then has a `continued-in`
record that names the successor. Discovery follows at most 8 such records,
within one heartbeat or checkpoint tick, and rebinds identity and transcript.
Each successor must have a valid transcript in the same Claude project
directory. A later user or assistant record in the bound transcript cancels
its continuation. A missing or invalid successor keeps the current binding.
Discovery reads the successor from the bound project directory, so a copy in
another project cannot block it. Until a Claude run binds its first
transcript, each heartbeat looks for it.
Codex binds identity
after launch by matching the run-token originator in rollout files and SQLite.
Detach rejects `--remote` and adds `--no-daemon` when `codex --help` lists it.
A shared or remote app-server creates the thread with its own originator, so
discovery cannot bind it. A release without that flag has no shared app-server.
Root user threads with source `cli` or `vscode` are eligible. These source labels
do not identify the launch UI. The known-thread snapshot uses the same filter.
The project path must match, including after worktree creation. Subagents and
guardian review threads remain ineligible, even with the same originator.
An ambiguous first binding fails. Discovery records its outcome as
`identity_state` when the outcome changes: `pending` until an eligible thread
exists, `bound`, `foreign` when a new root user thread in the project has
another Detach run's originator, `ambiguous`, or `unavailable` when the thread database
query fails. Claude records `ambiguous` for duplicate valid transcripts and
`bound` on binding. The first change to a failed outcome writes one
checkpoint log line. If the provider switches to another run-owned
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

## Verification

Run the affected Resume and Recover parts in tests/run.sh and
tests/run-claude.sh. The public operations must reject foreign ownership and
retain the prior valid generation after a failed replacement.
