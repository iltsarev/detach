# detach

`detach` runs Codex or Claude Code inside a persistent tmux session and keeps a
MacBook awake through Amphetamine Closed-Display Mode. Both providers share the
same lifecycle commands; provider-specific session storage is handled by
adapters. `detach` is the only public command; its `detach-core` executable is
an internal implementation detail and is not installed on `PATH`.

## Install

The current LaunchAgent is configured for `/Users/example`. Install a stable
copy of the wrapper and load the watchdog:

```sh
install -d ~/.local/bin ~/.local/libexec/detach ~/Library/LaunchAgents
install -d -m 0700 ~/.local/state/codex-detached-amphetamine
install -m 0755 bin/detach bin/detach-core ~/.local/libexec/detach/
ln -sfn ../libexec/detach/detach ~/.local/bin/detach
rm -f ~/.local/bin/codex-detached
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/dev.tsarev.codex-detached-watchdog.plist 2>/dev/null || true
install -m 0644 launchagents/dev.tsarev.codex-detached-watchdog.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/dev.tsarev.codex-detached-watchdog.plist
launchctl kickstart -k "gui/$(id -u)/dev.tsarev.codex-detached-watchdog"
```

`~/.local/bin` must be on `PATH`. Check the installation with
`command -v detach`, `[ ! -e ~/.local/bin/codex-detached ]`, and
`launchctl print "gui/$(id -u)/dev.tsarev.codex-detached-watchdog"`.

## Usage

Start an agent for the current Git repository and attach to it:

```sh
detach codex
detach claude
```

Start with an initial prompt, or create without attaching:

```sh
detach codex -- "implement the queued task"
detach claude --detach -- "run the test suite and fix failures"
```

The tmux session name is stable for a project, but a normal start always creates
a new provider session. It replaces a completed retained pane; it refuses to
replace a task that is still running. Use `attach` to return to that live task.
Only one detached agent may be active for a given project root at a time, even
across providers:

```sh
detach claude --name migration
detach claude attach migration
detach claude stop migration
```

`list` combines all harness-managed sessions from both providers and includes
the UUID needed by `resume`. `resume` detects the provider and original project
from harness metadata, Codex SQLite, or the Claude transcript store, then
attaches to the right live session or starts the saved one. It refuses an
ambiguous UUID instead of guessing:

```sh
detach list
detach resume SESSION_UUID
detach resume --name migration --detach SESSION_UUID
```

`list --json` prints one JSON object per session (both providers) for
scripting and the Detach.app UI. `delete` removes a session's saved state
(checkpoints and metadata) after it stopped; provider transcripts in
`~/.claude` and `~/.codex` are never touched:

```sh
detach list --json
detach claude delete migration
```

Other management commands keep the provider explicit:

```sh
detach codex status migration
detach claude logs migration
detach codex stop migration
detach claude recover migration
```

Closing Terminal only detaches the tmux client. `Ctrl-b d` detaches without
closing it.

## Recovery

Every five minutes the launcher stores provider metadata, retained pane output,
and Git worktree status. It additionally checkpoints:

- Codex: the session UUID, rollout JSONL, and a consistent state SQLite backup;
- Claude: its preassigned session UUID, transcript JSONL, project companion
  directory, file history, and session environment.

Codex checkpoints live under `~/.local/state/codex-detached`; Claude checkpoints
live under `~/.local/state/claude-detached`. These private directories contain
full conversation data. A filesystem `sync` follows every checkpoint.

Use `detach resume SESSION_UUID` for normal provider resume semantics. After an
abrupt shutdown, use `detach <provider> recover` to restore that project's last
checkpoint. A damaged Codex rollout or Claude transcript and its companion
artifacts are restored before the provider is resumed. Recovery can lose work
since the last checkpoint, normally up to five minutes, and requires the first
valid transcript checkpoint to have completed. The Codex SQLite copy remains an
emergency artifact for manual repair; the wrapper does not overwrite Codex's
shared database automatically.

Change the interval for testing or special cases:

```sh
CODEX_DETACHED_CHECKPOINT_INTERVAL=600 detach codex
CLAUDE_DETACHED_CHECKPOINT_INTERVAL=600 detach claude
```

## Codex policy

On an unmanaged Mac, the launcher defaults to:

```text
--ask-for-approval never --sandbox workspace-write --no-alt-screen
```

This allows autonomous work inside the project without granting unrestricted
system access. Explicit Codex `--ask-for-approval` and `--sandbox` arguments
override the defaults. The wrapper owns `-C/--cd`; start it from the target
project instead.

When managed requirements disallow `approval_policy = "never"`, the launcher
does not request that forbidden value. It inherits the managed approval policy
and reviewer instead. On this Mac that means `on-request` with
`approvals_reviewer = "auto_review"`, matching a normal `codex` launch while
retaining `workspace-write` for the project.

## Claude policy

Claude defaults to `--permission-mode auto` for unattended work; an explicit
`--permission-mode` overrides it. The wrapper never enables
`--dangerously-skip-permissions`. It owns `--session-id`, `--resume`, and
`--background` so checkpoint identity and tmux lifetime remain deterministic.
Provider flags that collide with wrapper flags, such as Claude's own `--name`,
must be placed after `--`.

The Claude adapter disables the alternate screen so `logs` and retained pane
checkpoints remain useful. It runs Claude in the project directory selected by
the wrapper; Claude has no equivalent of Codex's `-C` option.

## Amphetamine

Amphetamine 5.3.2 and Power Protect must be installed. The first detached task
starts one infinite Amphetamine session with display sleep allowed and
Closed-Display Mode enabled. Additional detached tasks share it. The last task
ends it only when the launcher created it and the observable session properties
are unchanged.

A per-user LaunchAgent checks leases once per minute. If tmux or a worker is
killed without running cleanup, it restores normal sleep after the stale lease
expires. The watcher also reconciles state at login after an abrupt shutdown.

Do not manually replace the Amphetamine session while detached tasks are
running. A pre-existing session is never replaced or ended, but it must already
be infinite, non-Trigger, allow display sleep, and have Closed-Display Mode
enabled.

The watchdog uses the default Amphetamine lease directory
`~/.local/state/codex-detached-amphetamine`. If
`DETACH_AMPHETAMINE_STATE_ROOT`, `CODEX_DETACHED_AMPHETAMINE_STATE_ROOT`, or
`XDG_STATE_HOME` is customized, set the matching environment value in the
installed LaunchAgent too.

Keep the MacBook on a ventilated surface and preferably connected to power.
This setup enables Amphetamine's low-battery auto-end option at its configured
threshold (currently 10%). The watchdog leaves Amphetamine inactive at or below
that threshold so macOS can sleep instead of draining the battery completely.

## Development

Run the isolated tmux integration test:

```sh
tests/run.sh
tests/run-claude.sh
```

The optional system smoke test temporarily enables real Amphetamine
Closed-Display Mode and verifies that Power Protect disables and restores
system sleep:

```sh
tests/amphetamine-smoke.sh
```

## Detach.app

A SwiftUI companion app (`app/`) that lists all detach sessions with statuses
and log previews, opens them in Terminal.app, and drives stop/resume/recover/
delete/new-session through the CLI:

```sh
app/scripts/make-app.sh
open app/build/Detach.app
```

The app talks to the CLI only (`detach list --json`, `detach <provider> ...`);
point it at a different binary in Settings.

Future UI features and their acceptance criteria are tracked in
[`docs/backlog.md`](docs/backlog.md).
