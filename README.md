# detach

`detach` runs Codex or Claude Code inside a persistent tmux session and keeps a
MacBook awake through Amphetamine Closed-Display Mode. Both providers share the
same lifecycle commands; provider-specific session storage is handled by
adapters. `detach` is the only public command; its `detach-core` executable is
an internal implementation detail and is not installed on `PATH`.

## Install

The preferred distribution is `Detach.dmg`: move `Detach.app` to
`/Applications`, open it, and follow onboarding. The app installs an immutable
versioned CLI under `~/.local`, then offers to enable its watchdog in Login
Items. New installs keep the optional Amphetamine integration off until it is
enabled in Settings.

For a CLI-only install from a checkout, make sure `tmux`, `jq`, and at least one
provider CLI are installed, then run:

```sh
brew install tmux jq
./install.sh
detach doctor
```

The installer stages and validates a payload under
`~/.local/libexec/detach/versions/<version>-<hash>`, atomically switches
`~/.local/bin/detach`, writes `~/.local/state/detach/install.json`, and installs
a portable per-user LaunchAgent. It never downgrades a newer CLI implicitly.
`~/.local/bin` must be on `PATH`.

Repair the active payload or uninstall it while preserving checkpoints:

```sh
detach repair
detach uninstall --keep-state
```

CLI Repair uses the pristine source recorded by the installer (normally the
installed `Detach.app` or the original checkout); it refuses to clone bytes
from a damaged immutable directory. For an app-first installation, uninstall
from Detach Settings so macOS can unregister the `SMAppService` Login Item
before the CLI is removed. CLI uninstall is the complete path for CLI-only
installs.

`detach uninstall --purge-state` additionally deletes Detach checkpoints after
an explicit request. It never deletes provider stores in `~/.codex` or
`~/.claude`, Amphetamine Power Protect, or sudoers configuration. Uninstall
refuses to run while a managed session is alive.

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

## Amphetamine (optional keep-awake)

Amphetamine 5.3.2 and Power Protect are needed only for Closed-Display Mode.
Without them, Detach still provides tmux persistence, checkpoints and
`caffeinate` while the lid is open. When keep-awake is enabled, the first task
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

Detach v1 is intentionally single-user. Multiple simultaneously logged-in
users on one Mac are unsupported because leases are per-user while Power
Protect changes system-wide sleep state.

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
ditto app/build/Detach.app /Applications/Detach.app
open /Applications/Detach.app
```

`make-app.sh` creates a universal ad-hoc-signed development bundle containing
the CLI payload and signed watchdog helper. The app deliberately refuses to
install CLI/Login Items while running from a DMG, App Translocation or another
ephemeral path. Build a local DMG with:

```sh
app/scripts/make-dmg.sh
```

The app embeds the pinned Sparkle 2 framework. Development bundles omit update
configuration and keep the updater disabled; production bundles require an
HTTPS appcast, a matching Ed25519 public key, and a manual-download URL.
Generate the permanent Sparkle key once (keep and back up the private key; do
not commit it):

```sh
swift package --package-path app resolve
app/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.tsarev.detach
```

Keep release credentials in the macOS Keychain rather than in the repository
or shell environment. Authenticate GitHub once with `gh auth login`. In Xcode,
open **Settings → Accounts → Manage Certificates…** and create or install a
**Developer ID Application** certificate, then store notarization credentials
under the profile name used by the release script:

```sh
gh auth login --hostname github.com --git-protocol https --web --clipboard
security find-identity -v -p codesigning
xcrun notarytool store-credentials detach-notary \
  --apple-id 'developer@example.com' \
  --team-id 'TEAMID'
```

`notarytool` securely prompts for an app-specific Apple ID password when
`--password` is omitted. Never pass the GitHub token, Apple password,
certificate private key, or Sparkle private key to the release command.

Production release is fail-closed and requires a clean worktree whose local
`v<VERSION>` tag points to `HEAD`, a Developer ID identity, a `notarytool`
keychain profile, the Sparkle key, and a GitHub downloads repository. For the
first release only, use `DETACH_INITIAL_RELEASE=1`; later releases must fetch
the published appcast and use a greater `CFBundleVersion`:

```sh
DETACH_BUILD_VERSION=3 \
DETACH_INITIAL_RELEASE=1 \
DETACH_CODESIGN_IDENTITY='Developer ID Application: …' \
DETACH_NOTARY_PROFILE=detach-notary \
DETACH_SPARKLE_KEY_ACCOUNT=dev.tsarev.detach \
DETACH_SPARKLE_PUBLIC_ED_KEY='<generate_keys output>' \
DETACH_GITHUB_REPOSITORY='owner/public-downloads' \
app/scripts/release.sh
```

This builds and signs nested code inside-out, notarizes and staples the app and
DMG, creates an EdDSA-signed update ZIP/appcast, records artifact hashes and
the source commit in `release-manifest.json`, and retains notarization evidence
under `app/build/`. A private key file exported for CI can be supplied with
`DETACH_SPARKLE_ED_KEY_FILE`; the script verifies that it matches the public
key embedded in the app.

Publication is separate and fail-closed. It verifies the manifest, exact
appcast destination, checksums, local tag/commit, and all remote draft assets
before making a new GitHub Release public; it never replaces an existing tag.
Push the matching tag when releases live in the source repository. For a
separate public downloads repository whose tag does not exist yet, explicitly
name the branch or commit from which GitHub may create that destination tag:

```sh
DETACH_GITHUB_REPOSITORY='owner/public-downloads' \
DETACH_SEPARATE_RELEASE_REPOSITORY=1 \
DETACH_GITHUB_RELEASE_TARGET='main' \
app/scripts/publish-release.sh
```

Separate-repository behavior is never inferred: without that explicit opt-in,
the remote tag/target must resolve to the source commit recorded in the
manifest. Without an existing remote tag or `DETACH_GITHUB_RELEASE_TARGET`,
publication also stops instead of silently tagging the remote default branch.
The published release is explicitly marked and then verified as `Latest`,
because the stable Sparkle feed uses GitHub's
`/releases/latest/download/appcast.xml` endpoint.

Installed production builds expose “Проверить наличие обновлений…” in the app
menu and a background-check toggle in Settings. Sparkle updates only the app;
on relaunch, the immutable distribution sync activates the bundled CLI and
watchdog for new sessions while live sessions keep their original code. A
build running outside `/Applications`, or an update-cycle failure, offers the
manual download page instead of attempting an unsafe update.

The app synchronizes its bundled CLI before polling sessions and uses
`detach doctor --json` for install/dependency diagnostics. Swift adds only
app-context checks such as `SMAppService` status. The normal session UI still
talks exclusively through the public CLI surface.

Future UI features and their acceptance criteria are tracked in
[`docs/backlog.md`](docs/backlog.md).
