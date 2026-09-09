# Generated specification traceability

This file is generated from `quality/policy.tsv`. Do not edit it.
It lists current specification ownership and verification links.

## `documentation`

- Path: `docs/specs/documentation.md`
- Summary: Agent context, specifications, and quality automation stay synchronized.
- Capabilities: `quality-system`, `documentation`

### Owned path patterns

- `*.md`
- `*.sh`
- `.gitattributes`
- `.github/*`
- `.github/dependabot.yml`
- `.github/workflows/documentation-care.yml`
- `.github/workflows/quality-care.yml`
- `.github/workflows/quality-gates.yml`
- `.github/workflows/quality-mutations.yml`
- `.github/workflows/security.yml`
- `.gitignore`
- `AGENTS.md`
- `CLAUDE.md`
- `README.md`
- `app/.gitignore`
- `docs/assets/*`
- `docs/quality-gates.md`
- `docs/testing.md`
- `quality/*`
- `quality/policy.tsv`
- `scripts/*`
- `scripts/quality-baseline`
- `scripts/quality-cache-warm`
- `scripts/quality-care`
- `scripts/quality-dashboard`
- `scripts/quality-evidence`
- `scripts/quality-gate`
- `scripts/quality-history`
- `scripts/quality-merge`
- `scripts/quality-metrics`
- `scripts/quality-mutation`
- `scripts/quality-policy`
- `scripts/quality-promote`
- `scripts/quality-scenarios`
- `scripts/quality-security`
- `scripts/quality-shard`
- `scripts/test`
- `tests/*`
- `tests/docs-contract.sh`
- `tests/quality-*`
- `tests/quality_*`
- `tests/security-*`
- `tests/security_*`
- `tests/shell-safety*`
- `tests/test-suite-contract.sh`
- `tools/quality_baseline.py`
- `tools/quality_cache_warm.py`
- `tools/quality_care.py`
- `tools/quality_dashboard.py`
- `tools/quality_evidence.py`
- `tools/quality_gate.py`
- `tools/quality_history.py`
- `tools/quality_merge.py`
- `tools/quality_metrics.py`
- `tools/quality_mutation.py`
- `tools/quality_policy.py`
- `tools/quality_products.py`
- `tools/quality_promote.py`
- `tools/quality_scenarios.py`
- `tools/quality_security.py`
- `tools/quality_shard.py`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-QUALITY-POLICY` | `J-QUALITY-CHANGE` | `SC-POLICY-CONTRACT` (automated, `gate-contract`)<br>`SC-PROMOTION-CONTRACT` (automated, `gate-contract`)<br>`SC-MERGE-CONTRACT` (automated, `gate-contract`)<br>`SC-SECURITY-CONTRACT` (automated, `gate-contract`) | One current policy owns quality selection and traceability. |
| `QC-QUALITY-SUPPLY-CHAIN` | `J-QUALITY-CHANGE` | `SC-POLICY-CONTRACT` (automated, `gate-contract`)<br>`SC-PROMOTION-CONTRACT` (automated, `gate-contract`)<br>`SC-MERGE-CONTRACT` (automated, `gate-contract`)<br>`SC-SECURITY-CONTRACT` (automated, `gate-contract`) | Bounded automation scans code and keeps dependency pins current. |
| `QC-DOC-CONSISTENCY` | `J-DOCS-CONSISTENCY` | `SC-DOCS-CONTRACT` (automated, `static`) | Durable documentation and generated quality views stay synchronized. |

## `runtime`

- Path: `docs/specs/runtime.md`
- Summary: Runtime and session operations preserve exact ownership.
- Capabilities: `session-lifecycle`

### Owned path patterns

- `app/Sources/DetachKit/*.swift`
- `app/Sources/DetachKit/ANSIText.swift`
- `app/Sources/DetachKit/BoundedProcessRunner.swift`
- `app/Sources/DetachKit/DetachCLI.swift`
- `app/Sources/DetachKit/LogPoller.swift`
- `app/Sources/DetachKit/Session*.swift`
- `app/Sources/DetachKit/Terminal*.swift`
- `app/Sources/DetachKit/Tip.swift`
- `app/Sources/DetachKit/Tmux*.swift`
- `bin/*`
- `bin/detach`
- `bin/detach-core`
- `install.sh`
- `scripts/build-tmux.sh`
- `scripts/install.sh`
- `tests/distribution.sh`
- `tests/fake-claude`
- `tests/fake-codex`
- `tests/run-claude.sh`
- `tests/run.sh`
- `tests/tmux-runtime.sh`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-RUNTIME-OWNERSHIP` | `J-SESSION-CREATE`<br>`J-SESSION-RECOVER`<br>`J-SESSION-STOP`<br>`J-SESSION-DELETE` | `SC-SESSION-CREATE-CODEX` (instrumented, `codex`)<br>`SC-SESSION-CREATE-CLAUDE` (instrumented, `claude`)<br>`SC-SESSION-RECOVER-CODEX` (instrumented, `codex`)<br>`SC-SESSION-RECOVER-CLAUDE` (instrumented, `claude`)<br>`SC-SESSION-STOP-CODEX` (instrumented, `codex`)<br>`SC-SESSION-STOP-CLAUDE` (instrumented, `claude`)<br>`SC-UI-SESSION-STOP` (instrumented, `ui-e2e`)<br>`SC-SESSION-DELETE-CODEX` (instrumented, `codex`)<br>`SC-SESSION-DELETE-CLAUDE` (instrumented, `claude`)<br>`SC-UI-SESSION-DELETE` (instrumented, `ui-e2e`) | Session operations prove the exact run token and process ownership. |
| `QC-RUNTIME-TRANSITION` | `J-SESSION-RECOVER` | `SC-SESSION-RECOVER-CODEX` (instrumented, `codex`)<br>`SC-SESSION-RECOVER-CLAUDE` (instrumented, `claude`) | Session transitions preserve exact process identity. |

## `state`

- Path: `docs/specs/state.md`
- Summary: Typed state, storage, and change events remain safe and coherent.
- Capabilities: `session-state`

### Owned path patterns

- `app/Sources/DetachKit/DetachState*.swift`
- `app/Sources/DetachKit/Session.swift`
- `app/Sources/DetachKit/SessionEvents.swift`
- `app/Sources/DetachKit/SessionMaintenance.swift`
- `app/Sources/DetachKit/Storage*.swift`
- `app/Sources/DetachState/*.swift`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-RUNTIME-STATE` | `J-SESSION-PERSIST`<br>`J-STATE-CLEANUP` | `SC-SESSION-PERSIST-CODEX` (instrumented, `codex`)<br>`SC-SESSION-PERSIST-CLAUDE` (instrumented, `claude`)<br>`SC-SESSION-DELETE-CODEX` (instrumented, `codex`)<br>`SC-SESSION-DELETE-CLAUDE` (instrumented, `claude`)<br>`SC-UI-SESSION-DELETE` (instrumented, `ui-e2e`) | Typed state is the only shared state mutation boundary. |
| `QC-RUNTIME-STORAGE` | `J-STATE-RECOVER` | `SC-SESSION-RECOVER-CODEX` (instrumented, `codex`)<br>`SC-SESSION-RECOVER-CLAUDE` (instrumented, `claude`) | Restores validate path, symlink, identity, and JSONL data before replacement. |

## `power`

- Path: `docs/specs/power.md`
- Summary: Power protection fails safe across both required layers.
- Capabilities: `power-protection`

### Owned path patterns

- `app/Resources/DetachWatchdog*`
- `app/Resources/dev.tsarev.detach.power-*`
- `app/Sources/DetachApp/InstallationStore.swift`
- `app/Sources/DetachApp/PowerHelper*.swift`
- `app/Sources/DetachApp/Watchdog*.swift`
- `app/Sources/DetachKit/ClamshellLockRunner.swift`
- `app/Sources/DetachKit/DetachPower*.swift`
- `app/Sources/DetachKit/Power*.swift`
- `app/Sources/DetachPower/*.swift`
- `app/Sources/DetachPowerHelper/*.swift`
- `app/Sources/DetachWatchdog/*.swift`
- `tests/power-smoke.sh`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-POWER-ASSERTION` | `J-POWER-ENABLE` | `SC-POWER-UNIT` (legacy-stage, `swift`) | Power protection owns a user IOKit assertion. |
| `QC-POWER-AUTH` | `J-POWER-HELPER-LEASE` | `SC-POWER-HELPER` (legacy-stage, `swift`) | Helper authorization binds audit token, console user, signing, and deadline. |
| `QC-POWER-LEASE` | `J-POWER-ENABLE`<br>`J-POWER-HELPER-LEASE` | `SC-POWER-UNIT` (legacy-stage, `swift`)<br>`SC-POWER-HELPER` (legacy-stage, `swift`) | The root helper lease is bounded and ownership safe. |
| `QC-POWER-XPC` | `J-POWER-HELPER-LEASE` | `SC-POWER-HELPER` (legacy-stage, `swift`) | The helper accepts only the typed power protocol. |
| `QC-POWER-PROTECTION` | `J-POWER-LOW-BATTERY`<br>`J-POWER-CLOSED-LID` | `SC-POWER-LOW-BATTERY` (legacy-stage, `swift`)<br>`SC-POWER-CLOSED-LID` (manual-release, `publish-preflight`) | Low battery fails safe. |
| `QC-POWER-CLI` | `J-POWER-ENABLE` | `SC-POWER-UNIT` (legacy-stage, `swift`) | The power command reports and enforces typed protection state. |
| `QC-POWER-PLATFORM` | `J-POWER-ENABLE` | `SC-POWER-UNIT` (legacy-stage, `swift`) | Platform power operations preserve the helper safety boundary. |

## `app`

- Path: `docs/specs/app.md`
- Summary: The app presents and changes only typed product state.
- Capabilities: `app-experience`

### Owned path patterns

- `app/Package.resolved`
- `app/Package.swift`
- `app/Resources/*`
- `app/Resources/Detach.entitlements`
- `app/Resources/Detach.icns`
- `app/Resources/DetachDevelopment.entitlements`
- `app/Resources/Info.plist`
- `app/Resources/en.lproj/*`
- `app/Resources/ru.lproj/*`
- `app/Sources/*`
- `app/Sources/DetachApp/*.swift`
- `app/Sources/DetachApp/DetachApp.swift`
- `app/Sources/DetachApp/EmptySessionsView.swift`
- `app/Sources/DetachApp/LogTextView.swift`
- `app/Sources/DetachApp/MenuBar*.swift`
- `app/Sources/DetachApp/NewSessionSheet.swift`
- `app/Sources/DetachApp/QuickChat.swift`
- `app/Sources/DetachApp/RootView.swift`
- `app/Sources/DetachApp/Session*.swift`
- `app/Sources/DetachApp/SidebarView.swift`
- `app/Sources/DetachApp/TerminalPreferencePicker.swift`
- `app/Sources/DetachApp/TextSize.swift`
- `app/Sources/DetachApp/Theme.swift`
- `app/Sources/DetachApp/TipsBar.swift`
- `app/Sources/DetachApp/TmuxExtendedKeysSettingsController.swift`
- `app/Sources/DetachApp/UIE2E*.swift`
- `app/Sources/DetachKit/SessionHealth.swift`
- `app/Tests/*`
- `tests/fake-ui-cli`
- `tests/ui-e2e-contract.sh`
- `tests/ui-e2e.sh`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-HEALTH-FRESHNESS` | `J-APP-DASHBOARD` | `SC-UI-DASHBOARD` (instrumented, `ui-e2e`) | Health claims use typed fresh state. |
| `QC-HEALTH-PRESENTATION` | `J-APP-DASHBOARD`<br>`J-APP-DETAIL`<br>`J-APP-EMPTY`<br>`J-APP-FAILURE`<br>`J-APP-FOCUS`<br>`J-APP-NEW-SESSION` | `SC-UI-DASHBOARD` (instrumented, `ui-e2e`)<br>`SC-UI-SESSION-DETAIL` (instrumented, `ui-e2e`)<br>`SC-UI-EMPTY` (instrumented, `ui-e2e`)<br>`SC-UI-FAILURE` (instrumented, `ui-e2e`)<br>`SC-UI-FOCUS` (instrumented, `ui-e2e`)<br>`SC-UI-NEW-SESSION` (instrumented, `ui-e2e`) | The app presents typed health state without parsing terminal text. |
| `QC-APP-TIPS` | `J-APP-EMPTY` | `SC-UI-EMPTY` (instrumented, `ui-e2e`) | Session tips remain deterministic and user visible. |

## `app-setup`

- Path: `docs/specs/app-setup.md`
- Summary: App setup, settings, diagnostics, and updates fail closed.
- Capabilities: `onboarding`, `settings`, `update`, `diagnostics`

### Owned path patterns

- `app/Sources/DetachApp/Onboarding*.swift`
- `app/Sources/DetachApp/Settings*.swift`
- `app/Sources/DetachApp/SetupGuidance.swift`
- `app/Sources/DetachApp/UpdaterService.swift`
- `app/Sources/DetachKit/DoctorReport.swift`
- `app/Sources/DetachKit/Localization.swift`
- `app/Sources/DetachKit/UpdateConfiguration.swift`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-APP-DOCTOR` | `J-DOCTOR-REPORT` | `SC-DOCTOR-REPORT` (instrumented, `distribution`) | Doctor output derives from typed runtime state. |
| `QC-APP-ONBOARDING` | `J-ONBOARD-FIRST-RUN`<br>`J-ONBOARD-PROVIDER`<br>`J-ONBOARD-APPROVAL` | `SC-APP-ONBOARDING-UNIT` (legacy-stage, `swift`)<br>`SC-UI-ONBOARD-FIRST-RUN` (instrumented, `ui-e2e`)<br>`SC-UI-ONBOARD-PROVIDER` (instrumented, `ui-e2e`)<br>`SC-UI-ONBOARD-APPROVAL` (instrumented, `ui-e2e`) | Onboarding leads a new user through supported provider and approval setup. |
| `QC-APP-SETTINGS` | `J-SETTINGS-CHANGE` | `SC-APP-SETTINGS-UNIT` (legacy-stage, `swift`)<br>`SC-UI-SETTINGS` (instrumented, `ui-e2e`) | Settings changes persist and affect only their declared behavior. |
| `QC-APP-UPDATE` | `J-UPDATE-CHECK`<br>`J-UPDATE-APPLY` | `SC-UPDATE-CHECK` (instrumented, `release-preflight`)<br>`SC-UPDATE-APPLY` (instrumented, `publish-preflight`)<br>`SC-RELEASE-WORKFLOW` (instrumented, `release-workflow`) | Update state and application preserve the signed arm64 contract. |

## `release`

- Path: `docs/specs/release.md`
- Summary: Distribution and publication preserve verified immutable artifacts.
- Capabilities: `installation`, `publication`

### Owned path patterns

- `BUILD`
- `VERSION`
- `app/Resources/ThirdParty/*`
- `app/scripts/*`
- `app/scripts/bundle-modes.sh`
- `app/scripts/make-app.sh`
- `app/scripts/make-dmg.sh`
- `app/scripts/publish-release.sh`
- `app/scripts/release.sh`
- `app/scripts/verify-appcast.sh`
- `scripts/release-impact`
- `scripts/release-lid-probe`
- `scripts/release-pr`
- `scripts/release-sbom`
- `scripts/release-version`
- `tests/publish-preflight.sh`
- `tests/release-impact.sh`
- `tests/release-pr*`
- `tests/release-preflight.sh`
- `tests/release-sbom*`
- `tests/release-workflow.sh`
- `tests/release_pr*`
- `tests/release_sbom*`
- `tools/release_pr.py`
- `tools/release_sbom.py`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| `QC-RELEASE-INSTALL` | `J-INSTALL-CLEAN`<br>`J-INSTALL-REPAIR`<br>`J-INSTALL-UNINSTALL` | `SC-INSTALL-CLEAN` (instrumented, `distribution`)<br>`SC-RUNTIME-PACKAGE` (instrumented, `tmux-runtime`)<br>`SC-INSTALL-REPAIR` (instrumented, `distribution`)<br>`SC-INSTALL-UNINSTALL` (instrumented, `distribution`) | Install, repair, and uninstall mutate only Detach-owned payloads and selected state. |
| `QC-RELEASE-PUBLISH` | `J-PUBLISH-ARTIFACTS` | `SC-PUBLISH-CONTRACT` (instrumented, `publish-preflight`)<br>`SC-RELEASE-SBOM` (automated, `gate-contract`)<br>`SC-RELEASE-PR` (automated, `gate-contract`) | Publication exposes only independently verified allowlisted artifacts. |
