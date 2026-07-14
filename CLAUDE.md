# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS harness that runs Codex or Claude Code detached inside a persistent tmux session, keeps the MacBook awake via Amphetamine Closed-Display Mode, and checkpoints provider session state every 5 minutes so an abrupt shutdown loses at most ~5 minutes of work. Pure Bash — no build, lint, or dependency step. README.md covers user-facing usage, install, recovery semantics, and provider policy; keep it in sync when behavior changes.

## Public repository and local-only material

This repository, its full pushed Git history, GitHub releases, and published
artifacts are public. Treat every tracked file, commit/tag message, issue or PR,
build log, manifest, and release asset as internet-visible. Public guidance,
including this file, must not contain private context.

- Never commit or publish local plans, backlogs, working specs, credentials,
  signing material, account data, conversation/session state, machine-specific
  absolute user paths, or private organization/client/project names.
- Keep local planning material in the ignored `docs/backlog.md` and
  `docs/superpowers/` paths. Keep secrets outside the repository, using the
  Keychain or environment variables as appropriate. Never bypass these guards
  with `git add -f`.
- `.gitignore` is a safety net, not permission to publish every other file.
  Before each commit and release, inspect the staged diff, tracked-file list,
  artifact contents, and metadata for private or machine-specific data.
- If private data appears in a commit or artifact, stop before pushing or
  publishing and remove it from the history or artifact. Deleting it in a
  later public commit is not sufficient.

## Commands

- `tests/run.sh` — integration test for the Codex adapter. Hermetic: fake provider binary (`tests/fake-codex`), private tmux server (own `-L` socket and `TMUX_TMPDIR`), temp state roots, Amphetamine disabled.
- `tests/run-claude.sh` — the same for the Claude adapter (`tests/fake-claude`).
- `tests/distribution.sh` — hermetic versioned install/upgrade/doctor/uninstall
  and portable CLI LaunchAgent coverage (fake tmux/launchctl, temp HOME).
- `DETACH_CODEX_TEST_KEEP=1 tests/run.sh` — preserve the temp state and tmux server after a run for inspection (`DETACH_CLAUDE_TEST_KEEP=1` does the same for `run-claude.sh`).
- `tests/amphetamine-smoke.sh` — optional system smoke test that enables REAL Amphetamine Closed-Display Mode and toggles real system sleep via Power Protect. Do not run it as routine verification.

- `cd app && swift test` — unit tests for `DetachKit` and the app-side updater
  error/fallback policy.
- `app/scripts/make-app.sh` — build the universal `Detach.app` bundle (release
  build, bundled CLI/helper/Sparkle, ad-hoc codesign by default) into
  `app/build/`.
- `app/scripts/make-dmg.sh` — create a local DMG. `app/scripts/release.sh` is the
  strict Developer ID + app/DMG notarization + Sparkle appcast pipeline. It
  requires credentials, a matching Ed25519 key, and a clean tagged commit.
- `app/scripts/publish-release.sh` — explicit GitHub Release publication; it
  verifies provenance, appcast destinations and checksums in a draft before
  publishing, and refuses to replace an existing tag's assets.

There is no separate linter; `run.sh` / `run-claude.sh` are the verification path for any change to `bin/`, `swift test` for `app/`.

The repo copies are not what runs on the machine. `./install.sh` or Detach.app
installs immutable payloads under
`~/.local/libexec/detach/versions/<semver>-<hash>/` and atomically switches
`~/.local/bin/detach`. Installation adds an owned, idempotent PATH entry to the
user's login and interactive shell profiles (`zsh`, `bash`, `fish`, `csh`/`tcsh`,
or POSIX `sh`/`dash`/`ksh`) so a new Terminal can invoke `detach` directly.
Uninstall restores unchanged profiles byte-for-byte and removes only the exact
Detach-owned entry from a profile that gained unrelated user edits. Edits to
`bin/` take effect only after Repair/reinstall.

## Architecture

Two internal executables that must live side by side (`detach` resolves the core as its sibling after following symlinks). Only `detach` is exposed on `PATH`; installation puts both files under `~/.local/libexec/detach` and symlinks the frontend into `~/.local/bin`:

- **`bin/detach`** — thin provider multiplexer. Sets `DETACH_PROVIDER=codex|claude` and execs the core. It owns the cross-provider `list`, UUID-aware `resume`, shared `config`, and distribution-wide `doctor`/`repair`/`uninstall` commands.
- **`bin/detach-core`** — the internal core (~3300 lines). It rejects direct invocation unless the frontend marks the call with `DETACH_CORE_ENTRYPOINT=1`; that marker is propagated into tmux for self-reinvocation. All logic lives here, parameterized by `$PROVIDER`; provider differences (session identity, checkpoint artifacts, resume-flag allowlists, policy defaults) are gated inline, not split into adapter files.

### Core patterns

- **Self-reinvocation dispatch.** The `case` at the bottom of the core routes `__`-prefixed internal commands (`__worker`, `__checkpoint_once_locked`, `__amphetamine_acquire_locked`, `__reconcile_amphetamine`, ...) back into the same script. Critical sections run as `lockf <lockfile> "$SELF" __something_locked ...` so the lock brackets the whole child process. New shared-state mutations should follow this pattern.
- **Everything is env-injectable.** Every external binary (tmux, jq, sqlite3, tar, osascript, provider CLIs, ...) and every state path has a canonical `DETACH_*` override. Provider-specific overrides use `DETACH_CODEX_*` or `DETACH_CLAUDE_*`. Provider-owned variables such as `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` keep their provider names. This is what makes the tests hermetic — any new external dependency or path must get the same treatment.
- **Distribution is immutable and locked.** `VERSION` is the logical app/CLI
  version; `scripts/install.sh` computes a payload hash, stages beside the
  target, validates frontend/core/version/hashes, atomically switches the
  public symlink, then writes `~/.local/state/detach/install.json`. App sync,
  CLI-only install, Repair, and Uninstall share this implementation and
  `install.lock`; session start takes the same lock before creating its worker,
  closing the uninstall/start race. Never overwrite an existing payload path,
  reuse active bytes as a Repair source, or ignore `BUILD` on downgrade checks.
  Shell PATH setup follows the same ownership rule: preserve existing profile
  content, track backups/hashes under install state, refuse unsafe paths, and
  never delete an entry that is not exactly Detach-owned.
- **Guarded metadata.** Per-session `meta.json` (schema 1) is updated only via jq through `json_update_meta_for_run`, guarded by a `run_token`, so a stale worker or checkpoint loop from a replaced session cannot clobber the current one.
- **Validate before restore.** Anything that writes into a provider's own store (`~/.claude/projects/...`, `~/.codex/sessions/...`) goes through `safe_*_path` (symlink/traversal rejection) and `valid_*` (session-id match, parseable JSONL) checks, writes to a tmp file, validates, then `mv -f`. A checkpoint never overwrites a valid live transcript that is newer/larger, and the Codex shared SQLite is backed up but never restored automatically.
- **State is private.** `umask 077`; checkpoints under `~/.local/state/detach/{codex,claude}/sessions/<name>/` contain full conversation data.
- Error handling is explicit `die`-based with `set -u` and `pipefail`; the `bin/` scripts deliberately do not use `set -e` (tests do use `set -eu`).

### Lifecycle

`start` takes the per-project lock (`DETACH_LOCKS_ROOT` is shared across providers — one detached agent per project root, total), creates a tmux session named `detach-<provider>-<slug>-<8-hex sha256 of project dir>` with `remain-on-exit on`, and runs `__worker` in the pane. Detach-owned tmux metadata and presentation use session-scoped `@detach*` options. The worker starts the checkpoint loop, runs the provider under `caffeinate -s`, and on exit records status into meta/`exit-status`, takes a final checkpoint, and releases the Amphetamine lease. The retained pane keeps `logs`/`status` useful; a new `start` replaces a completed retained pane but refuses a live one.

Each session gets a stable color from a fixed palette, hashed from provider and canonical project directory. The color is stored in `meta.json.session_color`, tmux `@detach_color`, and `list --json`; keep those three representations and the Swift `Session` decoder in sync. By default Detach applies only session-local tmux status options, updates them across running/completed/failed states, and leaves global/foreign tmux configuration untouched. `detach config tmux-style inherit` removes those local overrides; the shared config write is serialized by `install.lock`.

Session identity: Claude gets a preassigned UUID via wrapper-owned `--session-id`; Codex is discovered after launch by matching the `detach_<run_token>` originator (injected via `CODEX_INTERNAL_ORIGINATOR_OVERRIDE`) in rollout files against `~/.codex` SQLite threads, refusing ambiguity. The worker `die`s if user args include wrapper-owned flags (Claude: `--session-id/--resume/--continue/--fork-session/--background/--tmux/--worktree`; Codex: `-C/--cd`), and applies policy defaults only when the user did not pass their own (Codex approval/sandbox, Claude `--permission-mode auto`).

Checkpoints (every `DETACH_<PROVIDER>_CHECKPOINT_INTERVAL`, default 300s, under a per-session `lockf`): meta, transcript/rollout JSONL, tmux pane capture, git worktree status, plus per provider — Codex SQLite `.backup`; Claude companion dirs (project session dir, file-history, session-env, tasks, teams) packed atomically into `claude-session.tar`. A `/bin/sync` follows unless `DETACH_<PROVIDER>_SYNC=0`.

Resume: only flags on the allowlist in `write_resume_args` are persisted to `resume-args.bin` and replayed by `resume`/`recover` — a new provider flag that should survive resume must be added there.

`list --json` emits one JSON object per session (JSONL, `schema: 1`, derived `effective_status`) for scripting and the Detach.app UI. `delete [--force]` removes a stopped session's state dir, retained pane, and stale lease; its destructive part runs under the session checkpoint lock via `__delete_locked` and never touches the provider stores.

### Amphetamine keep-awake

Amphetamine.app, Amphetamine Power Protect, and a registered background
watchdog are required prerequisites. `detach doctor` reports the app and Power
Protect script as two separate required base checks; their paths are injectable
through `DETACH_AMPHETAMINE_APP_PATH` and
`DETACH_AMPHETAMINE_POWER_PROTECT_PATH`. Installs canonicalize the config to
`AMPHETAMINE=1`. `DETACH_AMPHETAMINE=0` exists for hermetic integration tests;
do not use it to build a user-facing optional mode.

Reference-counted lease files under `~/.local/state/detach/amphetamine` are shared by both providers. The first session starts one infinite Closed-Display-Mode Amphetamine session and records ownership in `owner.json`; the last owned lease ends it only if the observable session properties are unchanged, and a pre-existing user session is never replaced or ended. `launchagents/dev.tsarev.detach.cli-watchdog.plist` runs `detach __reconcile_amphetamine` every 60s to expire stale leases after crashes and to leave Amphetamine off at/below the low-battery threshold.

### Detach.app (`app/`)

A SwiftPM package: `DetachKit` (tested parsing/process/distribution clients),
`DetachApp` (SwiftUI, macOS 14+), and the small `DetachWatchdog` helper. The app
bundles `DetachCLI`, syncs it on bootstrap, renders `doctor --json`, and always
registers its required static bundled LaunchAgent via `SMAppService`. Missing
Amphetamine or Power Protect and an unapproved background helper all block
onboarding readiness. The helper resolves
the stable per-user CLI at runtime and writes a heartbeat; never put user paths
into the signed plist. Its signed-service label `dev.tsarev.detach.watchdog`
is intentionally distinct from the CLI-only label
`dev.tsarev.detach.cli-watchdog`, so the signed helper and portable script agent
cannot collide in BackgroundTaskManagement. The standalone helper must retain its embedded
`__TEXT,__info_plist`. Distribution bootstrap is allowed only from
`/Applications`, not a DMG/App Translocation path.
When helper/plist bytes change, await unregister completion before registering
again and use the bounded retry for macOS' transient SMAppService Code=1 race.
The selected terminal is stored by bundle identifier. Interactive actions write
a private, self-deleting `.command` file and open it in the selected installed
terminal through `NSWorkspace`; terminal actions must not use Apple Events.
Terminal auto-detection treats any `CFBundleDocumentTypes` entry with the
`Shell` role for an executable flavor (shell-script UTIs, `public.unix-executable`,
or script extensions) as a terminal — editors declare only Editor/Viewer roles
and must stay excluded. The stored selection may also be an arbitrary app picked
manually in Settings, so launch-time resolution must not re-filter by
declarations; incompatible apps are caught by the launch acknowledgement
timeout.
Both the app and `DetachWatchdog` retain Automation solely for required
Amphetamine coordination: app-launched CLI stop/delete paths may release the
final lease, while the helper reconciles leases in the background. Session
operations still consume only the public CLI surface. App notifications are
opt-in and use one app-level polling service with a baseline and transition
deduplication. `list --json` exposes optional `agent_turn_state` and opaque
`agent_turn_id` fields. Derive them only from structured provider lifecycle
records: Codex task/turn start, complete, or abort events; and Claude main-chain
external user plus `system/turn_duration` events. Never infer attention from
terminal text. A completed turn means the live CLI is waiting for the next user
message; mid-turn permission and elicitation prompts are not covered by this
contract. On partially invalid `list --json`, keep the last good list; keep
`emit_list_json` and `Session` in sync.

Sparkle 2 is pinned in `Package.resolved`, embedded under `Contents/Frameworks`
with its symlink layout intact, and signed inside-out before the outer app.
Ad-hoc development builds alone use
`com.apple.security.cs.disable-library-validation`; it must never appear in a
Developer ID build. `UpdaterService` starts only when the packaged app is in
`/Applications` and has a valid HTTPS `SUFeedURL` plus 32-byte Ed25519 public
key. User update preferences belong to `SPUUpdater`/NSUserDefaults, not a
parallel `AppStorage` value. A Sparkle release updates only `.app`; bootstrap
then activates its immutable CLI payload without changing live sessions.
