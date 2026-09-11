# Security policy

## Supported versions

Only the latest signed GitHub Release is supported. Source builds and ad-hoc
previews are research targets, not supported products.

## Report a vulnerability

Use GitHub private vulnerability reporting on this repository. Do not open a
public issue for helper, state, or update bugs.

Include the Detach version or commit, the macOS version, whether the helper is
registered, and a minimal local repro. Do not attach live checkpoints or
provider transcripts.

## What we fix

Privilege, ownership, private-state, and update-trust bugs in Detach. The
owning contracts are `docs/specs/power.md`, `state.md`, `runtime.md`,
`app-setup.md`, and `release.md`.

Codex CLI, Claude Code, and Apple issues go to those vendors. Attacks that
already have the console user's signed Detach identity, or that already have
root, are out of scope.

## Disclosure

We aim to publish a short advisory 90 days after the report, or 7 days after
a fixed signed release, whichever is first. The advisory names the affected
versions, the fixed tag, and the user action. It does not include exploit
steps.
