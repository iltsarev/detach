import Foundation
import Observation

/// Drives the assistant's auto-advance while onboarding is visible: cheap
/// status reads on a short cadence, exactly one coordinated reconciliation on
/// the transition to fully-enabled services (the readiness barrier), and a
/// provider probe that triggers a doctor refresh only when a CLI first
/// appears. Never calls the heavy context refresh from a bare timer tick.
@Observable @MainActor
final class OnboardingLivePoller {
    private(set) var providerAvailability = ProviderAvailability()
    private(set) var heartbeatHealthy = false
    private(set) var heartbeatWaitIsLong = false
    private(set) var installedCopyPresent = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeStep: OnboardingStep?
    @ObservationIgnored private var reconcileRequested = false
    @ObservationIgnored private var providerRefreshRequested = false
    @ObservationIgnored private var heartbeatWaitStartedAt: Date?

    private let refreshStatuses: @MainActor () -> Void
    private let servicesEnabled: @MainActor () -> Bool
    private let readinessConfirmed: @MainActor () -> Bool
    private let providerCheckPassed: @MainActor () -> Bool
    private let reconcile: @MainActor () async -> Bool
    private let locate: () async -> ProviderAvailability
    private let heartbeatIsHealthy: @MainActor () -> Bool
    private let installedCopyExists: () -> Bool
    private let sleep: (UInt64) async throws -> Void

    convenience init(store: InstallationStore) {
        let locator = OnboardingProviderLocator()
        self.init(
            refreshStatuses: { store.refreshRegistrationStatusesOnly() },
            servicesEnabled: {
                store.powerHelperStatus == .enabled
                    && store.watchdogStatus == .enabled
            },
            readinessConfirmed: { store.powerHelperReadinessConfirmed },
            providerCheckPassed: { store.providerCheckPassed },
            reconcile: { await store.refreshContext() },
            locate: { await locator.locate() },
            heartbeatIsHealthy: { store.watchdogHeartbeat.healthy },
            installedCopyExists: {
                FileManager.default.fileExists(
                    atPath: "/Applications/Detach.app")
            })
    }

    init(
        refreshStatuses: @escaping @MainActor () -> Void,
        servicesEnabled: @escaping @MainActor () -> Bool,
        readinessConfirmed: @escaping @MainActor () -> Bool,
        providerCheckPassed: @escaping @MainActor () -> Bool,
        reconcile: @escaping @MainActor () async -> Bool,
        locate: @escaping () async -> ProviderAvailability,
        heartbeatIsHealthy: @escaping @MainActor () -> Bool,
        installedCopyExists: @escaping () -> Bool,
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.refreshStatuses = refreshStatuses
        self.servicesEnabled = servicesEnabled
        self.readinessConfirmed = readinessConfirmed
        self.providerCheckPassed = providerCheckPassed
        self.reconcile = reconcile
        self.locate = locate
        self.heartbeatIsHealthy = heartbeatIsHealthy
        self.installedCopyExists = installedCopyExists
        self.sleep = sleep
    }

    func update(for step: OnboardingStep) {
        guard step != activeStep else { return }
        activeStep = step
        task?.cancel()
        task = nil
        reconcileRequested = false
        providerRefreshRequested = false
        if step != .done {
            heartbeatWaitStartedAt = nil
            heartbeatWaitIsLong = false
        }

        let interval: UInt64
        switch step {
        case .moveToApplications: interval = 3_000_000_000
        case .permissions: interval = 3_000_000_000
        case .provider: interval = 5_000_000_000
        case .done: interval = 2_000_000_000
        case .autoSetup, .mainApp: return
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(step)
                guard let sleep = self?.sleep else { return }
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        activeStep = nil
    }

    /// One poll iteration; exposed for deterministic tests.
    func tick(_ step: OnboardingStep) async {
        switch step {
        case .moveToApplications:
            installedCopyPresent = installedCopyExists()

        case .permissions:
            refreshStatuses()
            guard servicesEnabled() else {
                // Re-arm so the next enable transition reconciles again.
                reconcileRequested = false
                return
            }
            guard !readinessConfirmed(), !reconcileRequested else { return }
            // The transition to `.enabled` is status-only evidence; run one
            // coordinated reconciliation to finish the helper journal and
            // reopen the root gate before the step may complete. A failure
            // surfaces on the card with an explicit Retry — never a silent
            // reconcile loop on every tick.
            reconcileRequested = true
            reconcileRequested = await reconcile()

        case .provider:
            let availability = await locate()
            providerAvailability = availability
            guard availability.any else {
                providerRefreshRequested = false
                return
            }
            guard !providerCheckPassed(), !providerRefreshRequested else {
                return
            }
            providerRefreshRequested = true
            providerRefreshRequested = await reconcile()

        case .done:
            if heartbeatWaitStartedAt == nil {
                heartbeatWaitStartedAt = Date()
            }
            heartbeatHealthy = heartbeatIsHealthy()
            if heartbeatHealthy {
                heartbeatWaitIsLong = false
            } else if let started = heartbeatWaitStartedAt {
                heartbeatWaitIsLong = Date().timeIntervalSince(started) > 90
            }

        case .autoSetup, .mainApp:
            break
        }
    }
}
