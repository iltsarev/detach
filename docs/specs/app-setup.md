# App setup, settings, and update specification

## Onboarding and readiness

Onboarding uses `SetupGuidance.step(for:)`; failure outranks provider discovery.
An `.enabled` service alone never completes permissions. The live poller reads
without side effects and reconciles once after enablement. Only a finished
helper journal and an open root gate advance the step. `requiresApproval` is
not enabled. Done, Repair, and first-run sync reread the watchdog heartbeat.
Success needs a fresh heartbeat and records completion once. A long wait offers
monitor retry, never a bypass. A failed doctor refresh or a different runtime
identity withdraws earlier helper readiness.

After onboarding, bootstrap, refresh, power or provider regressions, and an
update held by active leases keep the dashboard. Settings shows errors; new
starts still require both power layers. Only an invalid app location or runtime
payload mismatch restores setup guidance. Provider installation uses the
official command in the user's terminal through the private `.command`
mechanism. Without an outcome channel it reports only that the CLI is not
detected. When helper/plist bytes change after an
app update, unregister, await completion, then use the bounded retry for the
transient SMAppService Code=1 race. Do not replace a helper with active leases:
defer the update. Report a normal outcome; retry on the next activation.

The per-user watchdog adds a launch-readiness rule: macOS can report an approved
agent as enabled while no launchd job loaded after approval. During first
onboarding or Repair, an enabled watchdog without a fresh heartbeat uses the
durable unregister/barrier/register transaction. Ordinary activation does not
replace it for a temporarily stale heartbeat.

Bootstrap runs only from `/Applications`, not a DMG or App Translocation path.

## Settings and monitoring

Settings → General owns both menu bar toggles. Settings → System keeps the only
Mac Power status and approval controls. Settings follows the hosting screen;
System scrolls. Temperature safety has its own warning shape and the
text **Mac can sleep: temperature**.

Settings → System owns the only **Mac Power** status and approval block. Helper
Ready requires a doctor live XPC check. Registration alone is Needs attention.
During doctor or reconciliation, show Checking, not failure. Power
requires a healthy watchdog heartbeat no older than three minutes; otherwise it
is `unknown`. A vnode source reads atomic changes at once; one wall-clock
deadline marks silence stale. A timestamp-only write moves it and redraws the
age silently. Settings open and activation resync. No app-level
heartbeat timer runs. The first monitor read and explicit refreshes share one
sequence. A stale constructor snapshot cannot arrive after a newer document.

## Update contract

Sparkle 2 is pinned. Sparkle keeps its symlink layout and is signed inside-out.
Only ad-hoc builds disable library validation.
`UpdaterService` starts only in `/Applications` with a valid HTTPS feed URL and
32-byte Ed25519 public key.
A generated or published appcast must contain exactly one arm64 hardware
requirement, so Intel clients never see the update.
A Sparkle update replaces the app. Bootstrap activates the new
immutable CLI payload before the watcher and first fresh list start. It does
not rewrite live-session binaries. Sparkle errors
for a disk image or App Translocation say to move Detach to
`/Applications`. Temporary-directory and download errors say to check the
network and free disk space, then retry. Archive, signature,
validation, and installation errors provide the manual DMG path and the
Settings > System Repair path, and state that the active CLI did not
change. If replacement completes but CLI or helper sync fails, the prior CLI
stays active and Repair remains available. Background sync keeps
the dashboard; a later activation retries it.
