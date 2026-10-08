# Generated specification traceability

This file is generated from `quality/policy.tsv`. Do not edit it.
It lists current specification ownership and verification links.
Links identify evidence. Review must check the meaning of each assertion.

## Enforcement

- `critical_coverage`: **blocking**.
- `aggregate_coverage`: **advisory**.
- `test_identity`: **advisory**.
- `changed_line_coverage`: **advisory**.
- `contract_evidence`: **blocking**.
- Changed-line coverage target: 90 percent.

## `documentation`

- Path: `docs/specs/documentation.md`
- Summary: Agent context, specifications, and quality automation stay synchronized.
- Capabilities: `documentation`

### Owned path patterns

- `*.md`
- `*.sh`
- `.gitattributes`
- `.github/*`
- `.gitignore`
- `AGENTS.md`
- `CLAUDE.md`
- `README.md`
- `app/.gitignore`
- `docs/assets/*`
- `scripts/*`
- `tests/*`
- `tests/docs-contract.sh`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| [`QC-DOC-CONSISTENCY`](../../docs/specs/documentation.md#qc-doc-consistency) | `J-DOCS-CONSISTENCY` | `SC-DOCS-CONTRACT` (instrumented, `static`) | Durable documentation and generated quality views stay synchronized. |

Direct acceptance evidence for `QC-DOC-CONSISTENCY`: `SC-DOCS-CONTRACT`.



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
| [`QC-RUNTIME-OWNERSHIP`](../../docs/specs/runtime.md#qc-runtime-ownership) | `J-SESSION-CREATE`<br>`J-SESSION-STOP`<br>`J-SESSION-DELETE` | `SC-SESSION-CREATE-CODEX` (instrumented, `codex`)<br>`SC-SESSION-CREATE-CLAUDE` (instrumented, `claude`)<br>`SC-SESSION-STOP-CODEX` (instrumented, `codex`)<br>`SC-SESSION-STOP-CLAUDE` (instrumented, `claude`)<br>`SC-UI-SESSION-STOP` (instrumented, `ui-e2e`)<br>`SC-SESSION-OWNERSHIP-UNIT` (test-cases, `swift`)<br>`SC-SESSION-DELETE-CODEX` (instrumented, `codex`)<br>`SC-SESSION-DELETE-CLAUDE` (instrumented, `claude`)<br>`SC-UI-SESSION-DELETE` (instrumented, `ui-e2e`) | Session operations prove the exact run token and process ownership. |

Direct acceptance evidence for `QC-RUNTIME-OWNERSHIP`: `SC-SESSION-OWNERSHIP-UNIT`, `SC-SESSION-CREATE-CODEX`, `SC-SESSION-CREATE-CLAUDE`, `SC-SESSION-STOP-CODEX`, `SC-SESSION-STOP-CLAUDE`, `SC-UI-SESSION-STOP`, `SC-SESSION-DELETE-CODEX`, `SC-SESSION-DELETE-CLAUDE`, `SC-UI-SESSION-DELETE`.

- `DetachKitTests.SessionHealthTests/testForeignTmuxCollisionNeverOffersAnAction`
- `DetachKitTests.SessionHealthTests/testForeignProviderPIDIsNeverTreatedAsOwned`
- `DetachKitTests.SessionHealthTests/testProcessInspectorRejectsWrongPaneAndForeignOwnership`


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
| [`QC-RUNTIME-STATE`](../../docs/specs/state.md#qc-runtime-state) | `J-SESSION-PERSIST`<br>`J-STATE-CLEANUP` | `SC-SESSION-PERSIST-CODEX` (instrumented, `codex`)<br>`SC-SESSION-PERSIST-CLAUDE` (instrumented, `claude`)<br>`SC-TRANSCRIPT-TURN-UNIT` (test-cases, `swift`)<br>`SC-SESSION-DELETE-CODEX` (instrumented, `codex`)<br>`SC-SESSION-DELETE-CLAUDE` (instrumented, `claude`)<br>`SC-UI-SESSION-DELETE` (instrumented, `ui-e2e`) | Typed state is the only shared state mutation boundary. |
| [`QC-RUNTIME-STORAGE`](../../docs/specs/state.md#qc-runtime-storage) | `J-STATE-RECOVER` | `SC-SESSION-RECOVER-CODEX` (instrumented, `codex`)<br>`SC-SESSION-RECOVER-CLAUDE` (instrumented, `claude`)<br>`SC-STATE-RESTORE-UNIT` (test-cases, `swift`)<br>`SC-TRANSCRIPT-TURN-UNIT` (test-cases, `swift`) | Restores validate path, symlink, identity, and JSONL data before replacement. |

Direct acceptance evidence for `QC-RUNTIME-STATE`: `SC-SESSION-PERSIST-CODEX`, `SC-SESSION-PERSIST-CLAUDE`, `SC-SESSION-DELETE-CODEX`, `SC-SESSION-DELETE-CLAUDE`, `SC-UI-SESSION-DELETE`, `SC-TRANSCRIPT-TURN-UNIT`.

- `DetachKitTests.DetachStateTests/testClaudeSummaryResumesAfterFinalAnswer`
- `DetachKitTests.DetachStateTests/testClaudeStreamedActivityDoesNotReplaceExplicitInputOrUseSidechains`
- `DetachKitTests.DetachStateCommandTests/testMetaSnapshotsReclassifyStreamedClaudeWorkFromOldReceipt`
- `DetachKitTests.DetachStateCommandTests/testJSONLSuccessorPrintsAClaudeContinuationFromAnOwnedTranscript`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundReplayPreservesFailedLaunches`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundStopRequiresSuccessfulMatchingResult`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundCompletionRequiresTaskNotification`
- `DetachKitTests.DetachStateTests/testClaudeTaskEventsIgnoreNonConversationRecords`
- `DetachKitTests.DetachStateCommandTests/testMetaSnapshotsPreserveBackgroundStopUntilSuccessfulResult`
- `DetachKitTests.DetachStateCommandTests/testJSONLSummaryDoesNotResurrectFailedBackgroundLaunch`


Direct acceptance evidence for `QC-RUNTIME-STORAGE`: `SC-STATE-RESTORE-UNIT`, `SC-SESSION-RECOVER-CODEX`, `SC-SESSION-RECOVER-CLAUDE`, `SC-TRANSCRIPT-TURN-UNIT`.

- `DetachKitTests.DetachStateCommandTests/testCheckpointExchangeRejectsUnsafeNamesAndSymlinkedDirectories`
- `DetachKitTests.DetachStateCommandTests/testJSONLValidationRejectsWrongIdentityAndMalformedArguments`
- `DetachKitTests.DetachStateCommandTests/testJSONLValidateRejectsFinalComponentSymlink`
- `DetachKitTests.DetachStateTests/testClaudeSummaryResumesAfterFinalAnswer`
- `DetachKitTests.DetachStateTests/testClaudeStreamedActivityDoesNotReplaceExplicitInputOrUseSidechains`
- `DetachKitTests.DetachStateCommandTests/testMetaSnapshotsReclassifyStreamedClaudeWorkFromOldReceipt`
- `DetachKitTests.DetachStateCommandTests/testJSONLSuccessorPrintsAClaudeContinuationFromAnOwnedTranscript`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundReplayPreservesFailedLaunches`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundStopRequiresSuccessfulMatchingResult`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundCompletionRequiresTaskNotification`
- `DetachKitTests.DetachStateTests/testClaudeTaskEventsIgnoreNonConversationRecords`
- `DetachKitTests.DetachStateCommandTests/testMetaSnapshotsPreserveBackgroundStopUntilSuccessfulResult`
- `DetachKitTests.DetachStateCommandTests/testJSONLSummaryDoesNotResurrectFailedBackgroundLaunch`


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
| [`QC-POWER-ASSERTION`](../../docs/specs/power.md#qc-power-assertion) | `J-POWER-ENABLE` | `SC-POWER-UNIT` (test-cases, `swift`) | Power protection owns a user IOKit assertion. |
| [`QC-POWER-AUTH`](../../docs/specs/power.md#qc-power-auth) | `J-POWER-HELPER-LEASE` | `SC-POWER-HELPER` (test-cases, `swift`) | Helper authorization binds audit token, console user, signing, and deadline. |
| [`QC-POWER-LEASE`](../../docs/specs/power.md#qc-power-lease) | `J-POWER-ENABLE`<br>`J-POWER-HELPER-LEASE` | `SC-POWER-UNIT` (test-cases, `swift`)<br>`SC-POWER-HELPER` (test-cases, `swift`) | The root helper lease is bounded and ownership safe. |
| [`QC-POWER-XPC`](../../docs/specs/power.md#qc-power-xpc) | `J-POWER-HELPER-LEASE` | `SC-POWER-HELPER` (test-cases, `swift`) | The helper accepts only the typed power protocol. |
| [`QC-POWER-PROTECTION`](../../docs/specs/power.md#qc-power-protection) | `J-POWER-LOW-BATTERY`<br>`J-POWER-CLOSED-LID` | `SC-POWER-LOW-BATTERY` (test-cases, `swift`)<br>`SC-POWER-CLOSED-LID` (manual-release, `publish-preflight`) | Low battery fails safe. |
| [`QC-POWER-CLI`](../../docs/specs/power.md#qc-power-cli) | `J-POWER-ENABLE` | `SC-POWER-UNIT` (test-cases, `swift`) | The power command reports and enforces typed protection state. |
| [`QC-POWER-PLATFORM`](../../docs/specs/power.md#qc-power-platform) | `J-POWER-ENABLE` | `SC-POWER-UNIT` (test-cases, `swift`) | Platform power operations preserve the helper safety boundary. |

Direct acceptance evidence for `QC-POWER-ASSERTION`: `SC-POWER-UNIT`.

- `DetachKitTests.PowerProtectionTests/testProtectedRequiresBothAssertionAndClosedLidProtection`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireVerifiesBothProtectionsAndPersistsOwnershipBeforeMutation`
- `DetachKitTests.PowerAssertionControllerTests/testAcquireCreatesOneAssertionAndBecomesActive`
- `DetachKitTests.PowerAssertionControllerTests/testFailedReleaseStaysActiveAndCanRetry`
- `DetachKitTests.PowerHelperLeaseServiceTests/testReleaseRestoresNormalSleepOnlyWhenDetachOwnedTheMutation`
- `DetachKitTests.PowerHelperLeaseServiceTests/testStartupReconcileExpiresStaleLeaseAndRestoresOwnedState`
- `DetachKitTests.DetachPowerCommandTests/testStatusJSONAddsSchemaAndUsesSnakeCaseContract`
- `DetachKitTests.DetachPowerCommandTests/testUnconfirmedHelperLeaseRefusesChildAndAttemptsFullCleanup`
- `DetachKitTests.PowerHelperPlatformTests/testPMSetBackendReadsAndMutatesOnlyDisableSleepSetting`


Direct acceptance evidence for `QC-POWER-AUTH`: `SC-POWER-HELPER`.

- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsRootEvenWhileARegularConsoleUserIsActive`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsAnotherLocalUserAfterFastUserSwitching`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsLoginWindowAndLogoutWithoutAnActiveConsoleUser`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireRejectsAnExpiredRequestBeforePersisting`
- `DetachKitTests.PowerHelperXPCServiceTests/testStatusReturnsVersionedTypedSnapshot`
- `DetachKitTests.PowerHelperXPCServiceTests/testNonFiniteAcquireDeadlineIsRejectedBeforeLeaseMutation`
- `DetachKitTests.DetachPowerCommandTests/testHelperLifecycleCommandsUseNarrowXPCMethodsOnly`


Direct acceptance evidence for `QC-POWER-LEASE`: `SC-POWER-UNIT`, `SC-POWER-HELPER`.

- `DetachKitTests.PowerProtectionTests/testProtectedRequiresBothAssertionAndClosedLidProtection`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireVerifiesBothProtectionsAndPersistsOwnershipBeforeMutation`
- `DetachKitTests.PowerAssertionControllerTests/testAcquireCreatesOneAssertionAndBecomesActive`
- `DetachKitTests.PowerAssertionControllerTests/testFailedReleaseStaysActiveAndCanRetry`
- `DetachKitTests.PowerHelperLeaseServiceTests/testReleaseRestoresNormalSleepOnlyWhenDetachOwnedTheMutation`
- `DetachKitTests.PowerHelperLeaseServiceTests/testStartupReconcileExpiresStaleLeaseAndRestoresOwnedState`
- `DetachKitTests.DetachPowerCommandTests/testStatusJSONAddsSchemaAndUsesSnakeCaseContract`
- `DetachKitTests.DetachPowerCommandTests/testUnconfirmedHelperLeaseRefusesChildAndAttemptsFullCleanup`
- `DetachKitTests.PowerHelperPlatformTests/testPMSetBackendReadsAndMutatesOnlyDisableSleepSetting`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsRootEvenWhileARegularConsoleUserIsActive`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsAnotherLocalUserAfterFastUserSwitching`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsLoginWindowAndLogoutWithoutAnActiveConsoleUser`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireRejectsAnExpiredRequestBeforePersisting`
- `DetachKitTests.PowerHelperXPCServiceTests/testStatusReturnsVersionedTypedSnapshot`
- `DetachKitTests.PowerHelperXPCServiceTests/testNonFiniteAcquireDeadlineIsRejectedBeforeLeaseMutation`
- `DetachKitTests.DetachPowerCommandTests/testHelperLifecycleCommandsUseNarrowXPCMethodsOnly`


Direct acceptance evidence for `QC-POWER-XPC`: `SC-POWER-HELPER`.

- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsRootEvenWhileARegularConsoleUserIsActive`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsAnotherLocalUserAfterFastUserSwitching`
- `DetachKitTests.PowerHelperClientAuthorizationPolicyTests/testRejectsLoginWindowAndLogoutWithoutAnActiveConsoleUser`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireRejectsAnExpiredRequestBeforePersisting`
- `DetachKitTests.PowerHelperXPCServiceTests/testStatusReturnsVersionedTypedSnapshot`
- `DetachKitTests.PowerHelperXPCServiceTests/testNonFiniteAcquireDeadlineIsRejectedBeforeLeaseMutation`
- `DetachKitTests.DetachPowerCommandTests/testHelperLifecycleCommandsUseNarrowXPCMethodsOnly`


Direct acceptance evidence for `QC-POWER-PROTECTION`: `SC-POWER-LOW-BATTERY`, `SC-POWER-CLOSED-LID`.

- `DetachKitTests.PowerProtectionTests/testLowBatteryDoesNotClaimSleepUntilIdleAssertionIsReleased`
- `DetachKitTests.PowerHelperLeaseServiceTests/testLowBatteryRefusesProtectionAndDropsOwnedMutation`


Direct acceptance evidence for `QC-POWER-CLI`: `SC-POWER-UNIT`.

- `DetachKitTests.PowerProtectionTests/testProtectedRequiresBothAssertionAndClosedLidProtection`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireVerifiesBothProtectionsAndPersistsOwnershipBeforeMutation`
- `DetachKitTests.PowerAssertionControllerTests/testAcquireCreatesOneAssertionAndBecomesActive`
- `DetachKitTests.PowerAssertionControllerTests/testFailedReleaseStaysActiveAndCanRetry`
- `DetachKitTests.PowerHelperLeaseServiceTests/testReleaseRestoresNormalSleepOnlyWhenDetachOwnedTheMutation`
- `DetachKitTests.PowerHelperLeaseServiceTests/testStartupReconcileExpiresStaleLeaseAndRestoresOwnedState`
- `DetachKitTests.DetachPowerCommandTests/testStatusJSONAddsSchemaAndUsesSnakeCaseContract`
- `DetachKitTests.DetachPowerCommandTests/testUnconfirmedHelperLeaseRefusesChildAndAttemptsFullCleanup`
- `DetachKitTests.PowerHelperPlatformTests/testPMSetBackendReadsAndMutatesOnlyDisableSleepSetting`


Direct acceptance evidence for `QC-POWER-PLATFORM`: `SC-POWER-UNIT`.

- `DetachKitTests.PowerProtectionTests/testProtectedRequiresBothAssertionAndClosedLidProtection`
- `DetachKitTests.PowerHelperLeaseServiceTests/testAcquireVerifiesBothProtectionsAndPersistsOwnershipBeforeMutation`
- `DetachKitTests.PowerAssertionControllerTests/testAcquireCreatesOneAssertionAndBecomesActive`
- `DetachKitTests.PowerAssertionControllerTests/testFailedReleaseStaysActiveAndCanRetry`
- `DetachKitTests.PowerHelperLeaseServiceTests/testReleaseRestoresNormalSleepOnlyWhenDetachOwnedTheMutation`
- `DetachKitTests.PowerHelperLeaseServiceTests/testStartupReconcileExpiresStaleLeaseAndRestoresOwnedState`
- `DetachKitTests.DetachPowerCommandTests/testStatusJSONAddsSchemaAndUsesSnakeCaseContract`
- `DetachKitTests.DetachPowerCommandTests/testUnconfirmedHelperLeaseRefusesChildAndAttemptsFullCleanup`
- `DetachKitTests.PowerHelperPlatformTests/testPMSetBackendReadsAndMutatesOnlyDisableSleepSetting`


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
- `app/Sources/DetachApp/Sidebar*.swift`
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
| [`QC-HEALTH-FRESHNESS`](../../docs/specs/app.md#qc-health-freshness) | `J-APP-DASHBOARD` | `SC-UI-DASHBOARD` (instrumented, `ui-e2e`) | Health claims use typed fresh state. |
| [`QC-HEALTH-PRESENTATION`](../../docs/specs/app.md#qc-health-presentation) | `J-APP-DASHBOARD`<br>`J-APP-DETAIL`<br>`J-APP-EMPTY`<br>`J-APP-FAILURE`<br>`J-APP-FOCUS`<br>`J-APP-NEW-SESSION` | `SC-UI-DASHBOARD` (instrumented, `ui-e2e`)<br>`SC-UI-SESSION-DETAIL` (instrumented, `ui-e2e`)<br>`SC-TERMINAL-INPUT-UNIT` (test-cases, `swift`)<br>`SC-UI-EMPTY` (instrumented, `ui-e2e`)<br>`SC-UI-FAILURE` (instrumented, `ui-e2e`)<br>`SC-UI-FOCUS` (instrumented, `ui-e2e`)<br>`SC-UI-NEW-SESSION` (instrumented, `ui-e2e`) | The app presents typed health state without parsing terminal text. |
| [`QC-APP-TIPS`](../../docs/specs/app.md#qc-app-tips) | `J-APP-EMPTY` | `SC-UI-EMPTY` (instrumented, `ui-e2e`) | Session tips remain deterministic and user visible. |

Direct acceptance evidence for `QC-HEALTH-FRESHNESS`: `SC-UI-DASHBOARD`.



Direct acceptance evidence for `QC-HEALTH-PRESENTATION`: `SC-UI-DASHBOARD`, `SC-UI-SESSION-DETAIL`, `SC-UI-EMPTY`, `SC-UI-FAILURE`, `SC-UI-FOCUS`, `SC-UI-NEW-SESSION`, `SC-TERMINAL-INPUT-UNIT`.

- `DetachAppTests.SessionAttachTerminalTests/testCommandCCopiesNativeSelectionAndPreservesTmuxCopy`


Direct acceptance evidence for `QC-APP-TIPS`: `SC-UI-EMPTY`.



## `app-setup`

- Path: `docs/specs/app-setup.md`
- Summary: App setup, settings, diagnostics, and updates fail closed.
- Capabilities: `onboarding`, `settings`, `update`, `diagnostics`

### Owned path patterns

- `app/Sources/DetachApp/AppAppearance.swift`
- `app/Sources/DetachApp/Onboarding*.swift`
- `app/Sources/DetachApp/Settings*.swift`
- `app/Sources/DetachApp/SetupGuidance.swift`
- `app/Sources/DetachApp/TerminalAppearance.swift`
- `app/Sources/DetachApp/UpdaterService.swift`
- `app/Sources/DetachKit/DoctorReport.swift`
- `app/Sources/DetachKit/Localization.swift`
- `app/Sources/DetachKit/UpdateConfiguration.swift`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| [`QC-APP-DOCTOR`](../../docs/specs/app-setup.md#qc-app-doctor) | `J-DOCTOR-REPORT` | `SC-DOCTOR-REPORT` (instrumented, `distribution`) | Doctor output derives from typed runtime state. |
| [`QC-APP-ONBOARDING`](../../docs/specs/app-setup.md#qc-app-onboarding) | `J-ONBOARD-FIRST-RUN`<br>`J-ONBOARD-PROVIDER`<br>`J-ONBOARD-APPROVAL` | `SC-APP-ONBOARDING-UNIT` (test-cases, `swift`)<br>`SC-UI-ONBOARD-FIRST-RUN` (instrumented, `ui-e2e`)<br>`SC-UI-ONBOARD-PROVIDER` (instrumented, `ui-e2e`)<br>`SC-UI-ONBOARD-APPROVAL` (instrumented, `ui-e2e`) | Onboarding leads a new user through supported provider and approval setup. |
| [`QC-APP-SETTINGS`](../../docs/specs/app-setup.md#qc-app-settings) | `J-SETTINGS-CHANGE` | `SC-APP-SETTINGS-UNIT` (test-cases, `swift`)<br>`SC-UI-SETTINGS` (instrumented, `ui-e2e`) | Settings changes persist and affect only their declared behavior. |
| [`QC-APP-UPDATE`](../../docs/specs/app-setup.md#qc-app-update) | `J-UPDATE-CHECK`<br>`J-UPDATE-APPLY` | `SC-UPDATE-CHECK` (instrumented, `release-preflight`)<br>`SC-UPDATE-APPLY` (instrumented, `publish-preflight`)<br>`SC-RELEASE-WORKFLOW` (instrumented, `release-workflow`) | Update state and application preserve the signed arm64 contract. |

Direct acceptance evidence for `QC-APP-DOCTOR`: `SC-DOCTOR-REPORT`.



Direct acceptance evidence for `QC-APP-ONBOARDING`: `SC-APP-ONBOARDING-UNIT`, `SC-UI-ONBOARD-FIRST-RUN`, `SC-UI-ONBOARD-PROVIDER`, `SC-UI-ONBOARD-APPROVAL`.

- `DetachAppTests.OnboardingLivePollerTests/testRejectedPermissionReconcileIsRetriedOnNextTick`
- `DetachAppTests.OnboardingStepTests/testMissingProviderBlocksOnlyFirstOnboarding`


Direct acceptance evidence for `QC-APP-SETTINGS`: `SC-APP-SETTINGS-UNIT`, `SC-UI-SETTINGS`.

- `DetachAppTests.TmuxExtendedKeysSettingsControllerTests/testSaveSendsSetterAndKeepsValue`
- `DetachAppTests.TmuxExtendedKeysSettingsControllerTests/testSaveFailureRollsBackToPreviousValue`


Direct acceptance evidence for `QC-APP-UPDATE`: `SC-UPDATE-CHECK`, `SC-UPDATE-APPLY`, `SC-RELEASE-WORKFLOW`.



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
- `scripts/platform-probe`
- `scripts/quality-qualify`
- `scripts/release-impact`
- `scripts/release-lid-probe`
- `scripts/release-pr`
- `scripts/release-sbom`
- `scripts/release-toolchain`
- `scripts/release-version`
- `tests/publish-preflight.sh`
- `tests/release-impact.sh`
- `tests/release-pr*`
- `tests/release-preflight.sh`
- `tests/release-sbom*`
- `tests/release-workflow.sh`
- `tests/release_pr*`
- `tests/release_sbom*`
- `tools/platform_probe.swift`
- `tools/release_pr.py`
- `tools/release_sbom.py`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| [`QC-RELEASE-INSTALL`](../../docs/specs/release.md#qc-release-install) | `J-INSTALL-CLEAN`<br>`J-INSTALL-REPAIR`<br>`J-INSTALL-UNINSTALL` | `SC-INSTALL-CLEAN` (instrumented, `distribution`)<br>`SC-RUNTIME-PACKAGE` (instrumented, `tmux-runtime`)<br>`SC-INSTALL-REPAIR` (instrumented, `distribution`)<br>`SC-INSTALL-UNINSTALL` (instrumented, `distribution`) | Install, repair, and uninstall mutate only Detach-owned payloads and selected state. |
| [`QC-RELEASE-PUBLISH`](../../docs/specs/release.md#qc-release-publish) | `J-PUBLISH-ARTIFACTS` | `SC-PUBLISH-CONTRACT` (instrumented, `publish-preflight`)<br>`SC-RELEASE-SBOM` (instrumented, `gate-contract`)<br>`SC-RELEASE-PR` (instrumented, `gate-contract`) | Publication exposes only independently verified allowlisted artifacts. |

Direct acceptance evidence for `QC-RELEASE-INSTALL`: `SC-INSTALL-CLEAN`, `SC-RUNTIME-PACKAGE`, `SC-INSTALL-REPAIR`, `SC-INSTALL-UNINSTALL`.



Direct acceptance evidence for `QC-RELEASE-PUBLISH`: `SC-PUBLISH-CONTRACT`, `SC-RELEASE-SBOM`, `SC-RELEASE-PR`.



## `quality`

- Path: `docs/specs/quality.md`
- Summary: Quality checks bind direct evidence to reviewed contract changes.
- Capabilities: `quality-system`

### Owned path patterns

- `.github/dependabot.yml`
- `.github/workflows/documentation-care.yml`
- `.github/workflows/quality-care.yml`
- `.github/workflows/quality-gates.yml`
- `.github/workflows/quality-mutations.yml`
- `.github/workflows/security.yml`
- `docs/quality-gates.md`
- `docs/specs/quality.md`
- `docs/testing.md`
- `quality/*`
- `quality/policy.tsv`
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
- `tests/quality-*`
- `tests/quality_*`
- `tests/security-*`
- `tests/security_*`
- `tests/shell-safety*`
- `tests/source-rules*`
- `tests/test-suite-contract.sh`
- `tools/quality_baseline.py`
- `tools/quality_cache_warm.py`
- `tools/quality_care.py`
- `tools/quality_contract_change.py`
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
- `tools/quality_test_changes.py`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| [`QC-QUALITY-POLICY`](../../docs/specs/quality.md#qc-quality-policy) | `J-QUALITY-CHANGE` | `SC-POLICY-CONTRACT` (instrumented, `gate-contract`)<br>`SC-PROMOTION-CONTRACT` (instrumented, `gate-contract`)<br>`SC-MERGE-CONTRACT` (instrumented, `gate-contract`)<br>`SC-SECURITY-CONTRACT` (instrumented, `gate-contract`)<br>`SC-CONTRACT-CHANGE` (instrumented, `gate-contract`) | One current policy owns quality selection and traceability. |
| [`QC-QUALITY-SUPPLY-CHAIN`](../../docs/specs/quality.md#qc-quality-supply-chain) | `J-QUALITY-CHANGE` | `SC-POLICY-CONTRACT` (instrumented, `gate-contract`)<br>`SC-PROMOTION-CONTRACT` (instrumented, `gate-contract`)<br>`SC-MERGE-CONTRACT` (instrumented, `gate-contract`)<br>`SC-SECURITY-CONTRACT` (instrumented, `gate-contract`)<br>`SC-CONTRACT-CHANGE` (instrumented, `gate-contract`) | Bounded automation scans code and keeps dependency pins current. |

Direct acceptance evidence for `QC-QUALITY-POLICY`: `SC-CONTRACT-CHANGE`, `SC-POLICY-CONTRACT`, `SC-PROMOTION-CONTRACT`, `SC-MERGE-CONTRACT`, `SC-SECURITY-CONTRACT`.



Direct acceptance evidence for `QC-QUALITY-SUPPLY-CHAIN`: `SC-POLICY-CONTRACT`, `SC-PROMOTION-CONTRACT`, `SC-MERGE-CONTRACT`, `SC-SECURITY-CONTRACT`.



## `recovery`

- Path: `docs/specs/recovery.md`
- Summary: Provider identity and checkpoint replacement preserve recoverable state.
- Capabilities: `session-recovery`

### Owned path patterns

- `docs/specs/recovery.md`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| [`QC-RUNTIME-TRANSITION`](../../docs/specs/recovery.md#qc-runtime-transition) | `J-SESSION-RECOVER` | `SC-SESSION-RECOVER-CODEX` (instrumented, `codex`)<br>`SC-SESSION-RECOVER-CLAUDE` (instrumented, `claude`)<br>`SC-TRANSCRIPT-TURN-UNIT` (test-cases, `swift`) | Session transitions preserve exact process identity. |

Direct acceptance evidence for `QC-RUNTIME-TRANSITION`: `SC-SESSION-RECOVER-CODEX`, `SC-SESSION-RECOVER-CLAUDE`, `SC-TRANSCRIPT-TURN-UNIT`.

- `DetachKitTests.DetachStateTests/testClaudeSummaryResumesAfterFinalAnswer`
- `DetachKitTests.DetachStateTests/testClaudeStreamedActivityDoesNotReplaceExplicitInputOrUseSidechains`
- `DetachKitTests.DetachStateCommandTests/testMetaSnapshotsReclassifyStreamedClaudeWorkFromOldReceipt`
- `DetachKitTests.DetachStateCommandTests/testJSONLSuccessorPrintsAClaudeContinuationFromAnOwnedTranscript`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundReplayPreservesFailedLaunches`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundStopRequiresSuccessfulMatchingResult`
- `DetachKitTests.DetachStateTests/testClaudeBackgroundCompletionRequiresTaskNotification`
- `DetachKitTests.DetachStateTests/testClaudeTaskEventsIgnoreNonConversationRecords`
- `DetachKitTests.DetachStateCommandTests/testMetaSnapshotsPreserveBackgroundStopUntilSuccessfulResult`
- `DetachKitTests.DetachStateCommandTests/testJSONLSummaryDoesNotResurrectFailedBackgroundLaunch`


## `power-handoff`

- Path: `docs/specs/power-handoff.md`
- Summary: Service replacement requires a proven lifetime barrier.
- Capabilities: `power-handoff`

### Owned path patterns

- `app/Sources/DetachApp/PowerHelperService.swift`
- `app/Sources/DetachApp/ServiceManagementMutationAdmission.swift`
- `app/Sources/DetachApp/WatchdogService.swift`
- `docs/specs/power-handoff.md`

### Requirement verification

| Requirement | Journeys | Scenarios | Outcome |
| --- | --- | --- | --- |
| [`QC-POWER-HANDOFF`](../../docs/specs/power-handoff.md#qc-power-handoff) | `J-POWER-HANDOFF` | `SC-POWER-HANDOFF` (test-cases, `swift`) | Service registration handoff completes only after a proven lifetime barrier. |

Direct acceptance evidence for `QC-POWER-HANDOFF`: `SC-POWER-HANDOFF`.

- `DetachAppTests.PowerHelperServiceTests/testFailedUnregisterKeepsRootGateClosedAndSubmittedPhase`
- `DetachAppTests.WatchdogServiceTests/testAbsentRecordRejectionWithLiveRecordRemainsFailClosed`
