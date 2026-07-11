# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS harness that runs Codex or Claude Code detached inside a persistent tmux session, keeps the MacBook awake via Amphetamine Closed-Display Mode, and checkpoints provider session state every 5 minutes so an abrupt shutdown loses at most ~5 minutes of work. Pure Bash — no build, lint, or dependency step. README.md covers user-facing usage, install, recovery semantics, and provider policy; keep it in sync when behavior changes.

## Commands

- `tests/run.sh` — integration test for the Codex adapter. Hermetic: fake provider binary (`tests/fake-codex`), private tmux server (own `-L` socket and `TMUX_TMPDIR`), temp state roots, Amphetamine disabled.
- `tests/run-claude.sh` — the same for the Claude adapter (`tests/fake-claude`).
- `CODEX_DETACHED_TEST_KEEP=1 tests/run.sh` — preserve the temp state and tmux server after a run for inspection.
- `tests/amphetamine-smoke.sh` — optional system smoke test that enables REAL Amphetamine Closed-Display Mode and toggles real system sleep via Power Protect. Do not run it as routine verification.

- `cd app && swift test` — unit tests for the Detach.app library (`DetachKit`).
- `app/scripts/make-app.sh` — build the `Detach.app` bundle (release build, ad-hoc codesign) into `app/build/`.

There is no separate linter; `run.sh` / `run-claude.sh` are the verification path for any change to `bin/`, `swift test` for `app/`.

The repo copies are not what runs on the machine: stable copies are installed to `~/.local/bin`, and the watchdog LaunchAgent references absolute `/Users/example/.local/bin` paths. Edits to `bin/` or the plist take effect only after re-running the install block in README.md.

## Architecture

Two internal executables that must live side by side (`detach` resolves the core as its sibling after following symlinks). Only `detach` is exposed on `PATH`; installation puts both files under `~/.local/libexec/detach` and symlinks the frontend into `~/.local/bin`:

- **`bin/detach`** — thin provider multiplexer. Sets `DETACH_PROVIDER=codex|claude` and execs the core. Owns only the cross-provider commands: `list` (concatenates both providers) and `resume` (detects a UUID's provider via the core's `__has_session_id` / `__session_context` internal calls; refuses ambiguous UUIDs).
- **`bin/detach-core`** — the internal core (~2800 lines). It rejects direct invocation unless the frontend marks the call with `DETACH_CORE_ENTRYPOINT=1`; that marker is propagated into tmux for self-reinvocation. All logic lives here, parameterized by `$PROVIDER`; provider differences (session identity, checkpoint artifacts, resume-flag allowlists, policy defaults) are gated inline, not split into adapter files.

### Core patterns

- **Self-reinvocation dispatch.** The `case` at the bottom of the core routes `__`-prefixed internal commands (`__worker`, `__checkpoint_once_locked`, `__amphetamine_acquire_locked`, `__reconcile_amphetamine`, ...) back into the same script. Critical sections run as `lockf <lockfile> "$SELF" __something_locked ...` so the lock brackets the whole child process. New shared-state mutations should follow this pattern.
- **Everything is env-injectable.** Every external binary (tmux, jq, sqlite3, tar, osascript, provider CLIs, ...) and every state path has a `DETACH_*` override with `CODEX_DETACHED_*` / `CLAUDE_DETACHED_*` fallbacks. This is what makes the tests hermetic — any new external dependency or path must get the same treatment.
- **Guarded metadata.** Per-session `meta.json` (schema 1) is updated only via jq through `json_update_meta_for_run`, guarded by a `run_token`, so a stale worker or checkpoint loop from a replaced session cannot clobber the current one.
- **Validate before restore.** Anything that writes into a provider's own store (`~/.claude/projects/...`, `~/.codex/sessions/...`) goes through `safe_*_path` (symlink/traversal rejection) and `valid_*` (session-id match, parseable JSONL) checks, writes to a tmp file, validates, then `mv -f`. A checkpoint never overwrites a valid live transcript that is newer/larger, and the Codex shared SQLite is backed up but never restored automatically.
- **State is private.** `umask 077`; checkpoints under `~/.local/state/{codex,claude}-detached/sessions/<name>/` contain full conversation data.
- Error handling is explicit `die`-based with `set -u` and `pipefail`; the `bin/` scripts deliberately do not use `set -e` (tests do use `set -eu`).

### Lifecycle

`start` takes the per-project lock (`DETACH_LOCKS_ROOT` is shared across providers — one detached agent per project root, total), creates a tmux session named `<provider>-detached-<slug>-<8-hex sha256 of project dir>` with `remain-on-exit on`, and runs `__worker` in the pane. The worker starts the checkpoint loop, runs the provider under `caffeinate -s`, and on exit records status into meta/`exit-status`, takes a final checkpoint, and releases the Amphetamine lease. The retained pane keeps `logs`/`status` useful; a new `start` replaces a completed retained pane but refuses a live one.

Session identity: Claude gets a preassigned UUID via wrapper-owned `--session-id`; Codex is discovered after launch by matching the `codex_detached_<run_token>` originator (injected via `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`) in rollout files against `~/.codex` SQLite threads, refusing ambiguity. The worker `die`s if user args include wrapper-owned flags (Claude: `--session-id/--resume/--continue/--fork-session/--background/--tmux/--worktree`; Codex: `-C/--cd`), and applies policy defaults only when the user did not pass their own (Codex approval/sandbox, Claude `--permission-mode auto`).

Checkpoints (every `*_CHECKPOINT_INTERVAL`, default 300s, under a per-session `lockf`): meta, transcript/rollout JSONL, tmux pane capture, git worktree status, plus per provider — Codex SQLite `.backup`; Claude companion dirs (project session dir, file-history, session-env, tasks, teams) packed atomically into `claude-session.tar`. A `/bin/sync` follows unless `*_SYNC=0`.

Resume: only flags on the allowlist in `write_resume_args` are persisted to `resume-args.bin` and replayed by `resume`/`recover` — a new provider flag that should survive resume must be added there.

`list --json` emits one JSON object per session (JSONL, `schema: 1`, derived `effective_status`) for scripting and the Detach.app UI. `delete [--force]` removes a stopped session's state dir, retained pane, and stale lease; its destructive part runs under the session checkpoint lock via `__delete_locked` and never touches the provider stores.

### Amphetamine keep-awake

Reference-counted lease files under `~/.local/state/codex-detached-amphetamine` (name kept for backward compatibility; shared by both providers). The first session starts one infinite Closed-Display-Mode Amphetamine session and records ownership in `owner.json`; the last owned lease ends it only if the observable session properties are unchanged, and a pre-existing user session is never replaced or ended. `launchagents/dev.tsarev.codex-detached-watchdog.plist` runs `detach __reconcile_amphetamine` every 60s to expire stale leases after crashes and to leave Amphetamine off at/below the low-battery threshold.

### Detach.app (`app/`)

A SwiftPM package: `DetachKit` (tested logic — JSONL parsing, status→section/action mapping, async Process CLI client, Terminal command composition with shell quoting) plus `DetachApp` (thin SwiftUI layer, macOS 14+). It consumes only the CLI surface — `list --json`, `logs`, `stop`, `delete --force`, and `attach`/`resume`/`recover` composed into Terminal.app via AppleScript — never the state dirs. On partially invalid `list --json` output the store keeps the last good list and shows an incompatible-CLI banner; keep `emit_list_json` and `Session` in sync when changing either side.

### Backward-compatibility constraints

Load-bearing legacy names that must not be renamed without a migration: `@codex_detached*` tmux session options (used for both providers), `CODEX_DETACHED_*` env fallbacks, the Codex state/session names, and the `codex-detached-amphetamine` state directory. `detach-core` is internal; `detach` is the sole public CLI.
