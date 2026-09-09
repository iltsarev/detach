---
name: detach
description: >-
  Operates the installed Detach harness through the public detach CLI.
  Inspects managed Codex and Claude Code sessions. Use when the user
  asks whether a Detach session finished, is waiting, or whether the Mac
  can sleep, or when they mention detach list, detach logs, detach power,
  a managed tmux run, or Mac sleep protection.
---

# Detach harness

Detach is the process, recovery, and power layer around Codex CLI and Claude
Code. `detach` is the public CLI. Prefer `--json`. Do not invent flags. Do not
wrap this CLI as an MCP server.

`AGENTS.md` is for people who change Detach. This skill is for any agent that
operates an installed harness on the same Mac.

## Location

This file is an Agent Skill (`SKILL.md`). Detach keeps the source at
`.agents/skills/detach/`. Copy this folder into a host or personal skills
directory when the host does not scan `.agents/skills/`.

## Default loop

Use this path when the user asks about a long Detach run (migration,
test-and-fix, audit) after they closed the terminal.

1. Confirm `detach` is on `PATH`. If it is missing, tell the user to open
   Detach.app and finish setup. Do not install from the git URL.
2. Run `detach list --json`. Output is JSONL schema 1, one object per session.
3. Match `display_name`, `session_name`, and `project_dir` to the user's project.
4. Read `effective_status`, `agent_turn_state`, and `power_protection_state`.
5. If the user needs recent output, run
   `detach <provider> logs -- <session_name>` and quote a short tail.
6. If they ask whether the Mac can sleep, run `detach power status --json`.
   Report that document. Do not call `pmset`.

Example start the user (or you, when they ask) already ran:

```bash
cd ~/work/billing
detach codex --detach --name "billing migration" -- "run the queued schema migration and fix the test suite"
```

Later, "Did the billing migration finish? Can the Mac sleep?" means steps 2–6.
It does not mean Attach, Stop, or a second start in that worktree.

## JSON fields

| Field | Use |
|---|---|
| `session_name` | Internal id for later commands |
| `display_name` | Human label from `--name` |
| `provider` | `codex` or `claude` |
| `project_dir` | Canonical project path |
| `effective_status` | Proven runtime state |
| `agent_turn_state` | `working`, `waiting`, or `interrupted` |
| `agent_turn_id` | Opaque turn id; do not parse it |
| `power_protection_state` | Per-session power label |
| `ownership_proven` | Required before any mutation |
| `cleanup_eligible` | Required before Delete or typed cleanup |
| `health_reason` | Why health is not `healthy` |

`waiting` means the provider finished a turn and wants a reply. Tell the user
to Attach in the terminal selected in Detach Settings. Do not type into the
pane.

`working` plus a quiet log is not hung. A long provider turn stays `running`
while the owned worker and provider are alive.

## Read commands

```bash
detach list --json
detach <provider> status -- <session_name>
detach <provider> logs -- <session_name>
detach power status --json
detach storage --json
detach doctor --json
detach reconcile --dry-run --json
detach storage cleanup --dry-run --json
detach cleanup --dry-run --json
```

Pass `--` before a `session_name` that could look like an option. Bound log
quotes. Do not dump a whole retained pane into the conversation.

## Start

Start only when the user asks for a new managed run.

```bash
cd "$PROJECT"
detach <provider> --detach --name "short label" -- "the task"
```

A live member in the same project refuses a second writer. Attach to it, or
ask before Stop. After a finished or orphaned run, a default start creates a
new history and keeps the old metadata.

Do not pass `-C`/`--cd`. Start from the project directory. Put provider flags
that collide with Detach flags after `--`.

## Do not

- Do not run `stop`, `recover`, `delete`, or `cleanup` without an explicit
  user request and `ownership_proven` (and `cleanup_eligible` for delete).
- Do not Attach from this skill. Attach is interactive. Name the action for
  the user: `detach <provider> attach -- <session_name>`.
- Do not send keys into tmux or the provider pane. Detach has no follow-up
  prompt API.
- Do not invoke `detach-core`, edit session JSON, or read
  `~/.local/state/detach/**` by hand.
- Do not read `~/.codex` or `~/.claude`. Cleanup does not own that storage.
- Do not claim the Mac can sleep from a missing helper, a borrowed
  `disablesleep` setting, or a stale heartbeat.

## Power

Protection is on only while at least one session is `working`. All live
sessions `waiting` or stopped allow sleep, unless a borrowed machine setting
remains. Low battery and serious thermal pressure also release Detach-owned
protection.

`detach power status --json` fields: `state`, `lease_count`,
`assertion_active`, `closed_lid_protection_active`, `helper_reachable`.
`state` values include `protected`, `allowed`, `low_battery`, `temperature`,
`unavailable`.
