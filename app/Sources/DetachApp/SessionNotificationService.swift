import Combine
import DetachKit
import Foundation
import UserNotifications

enum SessionNotificationAuthorizationStatus: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized

    var canDeliver: Bool { self == .authorized }
}

struct SessionNotificationPayload: Equatable {
    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
}

@MainActor
protocol SessionNotificationCenterBackend {
    func authorizationStatus() async -> SessionNotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func deliver(_ payload: SessionNotificationPayload) async throws
}

/// App-level notification monitor. Its polling task is owned by this service,
/// not a window, so closing the main window does not stop notifications.
@MainActor
final class SessionNotificationService: ObservableObject {
    @Published private(set) var authorizationStatus: SessionNotificationAuthorizationStatus = .unknown
    @Published private(set) var errorMessage: String?

    private struct MonitorConfiguration: Equatable {
        let detachPath: String
        let interval: TimeInterval
    }

    private let center: SessionNotificationCenterBackend
    private let identifierProvider: () -> String
    private let cliFactory: (String) -> DetachCLIRunning
    private var detector = SessionTransitionDetector()
    private var pendingPayloads: [SessionNotificationPayload] = []
    private var pendingGeneration: UInt64 = 0
    private var isDelivering = false
    private var isEnabled = false
    private var configurationGeneration: UInt64 = 0
    private var authorizationStatusGeneration: UInt64 = 0
    private var authorizationRequestTask: Task<Bool, Error>?
    private var monitorConfiguration: MonitorConfiguration?
    private var monitorTask: Task<Void, Never>?
    private var monitorGeneration: UInt64 = 0

    init(identifierProvider: @escaping () -> String = { UUID().uuidString }) {
        center = SystemSessionNotificationCenter()
        self.identifierProvider = identifierProvider
        cliFactory = { path in
            ProcessDetachCLI(executable: URL(fileURLWithPath: path))
        }
    }

    init(
        center: SessionNotificationCenterBackend,
        identifierProvider: @escaping () -> String = { UUID().uuidString },
        cliFactory: @escaping (String) -> DetachCLIRunning = { path in
            ProcessDetachCLI(executable: URL(fileURLWithPath: path))
        }
    ) {
        self.center = center
        self.identifierProvider = identifierProvider
        self.cliFactory = cliFactory
    }

    func configureMonitoring(detachPath: String, interval: TimeInterval) {
        let next = MonitorConfiguration(
            detachPath: detachPath,
            interval: min(max(interval, 1), 60))
        guard next != monitorConfiguration else { return }
        monitorConfiguration = next
        restartMonitoring(resetBaseline: true)
    }

    /// Synchronizes the app preference with macOS authorization. The system
    /// prompt appears only after the user explicitly enables notifications.
    func configure(enabled: Bool) async {
        configurationGeneration &+= 1
        let generation = configurationGeneration
        authorizationStatusGeneration &+= 1
        let statusGeneration = authorizationStatusGeneration
        isEnabled = enabled
        errorMessage = nil

        if !enabled {
            restartMonitoring(resetBaseline: true)
        }

        var status = await center.authorizationStatus()
        guard generation == configurationGeneration,
              statusGeneration == authorizationStatusGeneration else { return }
        authorizationStatus = status
        restartMonitoring(resetBaseline: status == .denied)
        guard enabled, status == .notDetermined else {
            if status == .denied { clearPendingPayloads() }
            return
        }

        do {
            guard !Task.isCancelled, generation == configurationGeneration, isEnabled else {
                return
            }
            let granted = try await requestAuthorizationOnce()
            guard generation == configurationGeneration else { return }
            authorizationStatusGeneration &+= 1
            let postRequestStatusGeneration = authorizationStatusGeneration
            status = granted ? await center.authorizationStatus() : .denied
            guard generation == configurationGeneration,
                  postRequestStatusGeneration == authorizationStatusGeneration else { return }
            authorizationStatus = status
            if status.canDeliver {
                await deliverPendingPayloads()
            } else {
                clearPendingPayloads()
            }
            restartMonitoring(resetBaseline: status == .denied)
        } catch {
            guard generation == configurationGeneration else { return }
            authorizationStatusGeneration &+= 1
            let failedRequestStatusGeneration = authorizationStatusGeneration
            let refreshedStatus = await center.authorizationStatus()
            guard generation == configurationGeneration,
                  failedRequestStatusGeneration == authorizationStatusGeneration else { return }
            authorizationStatus = refreshedStatus
            errorMessage = L10n.format(
                "Could not request notification permission: %@",
                error.localizedDescription)
            restartMonitoring(resetBaseline: refreshedStatus == .denied)
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatusGeneration &+= 1
        let statusGeneration = authorizationStatusGeneration
        let configurationAtStart = configurationGeneration
        let previousStatus = authorizationStatus
        let refreshedStatus = await center.authorizationStatus()
        guard statusGeneration == authorizationStatusGeneration,
              configurationAtStart == configurationGeneration else { return }

        authorizationStatus = refreshedStatus
        if refreshedStatus.canDeliver {
            await deliverPendingPayloads()
        } else if refreshedStatus == .denied {
            clearPendingPayloads()
        }
        restartMonitoring(resetBaseline:
            refreshedStatus == .denied || previousStatus == .denied)
    }

    /// Kept internal for deterministic tests; production calls it from the
    /// service-owned polling loop.
    func pollOnce(using cli: DetachCLIRunning) async {
        await pollOnce(using: cli, expectedMonitorGeneration: nil)
    }

    private func pollOnce(
        using cli: DetachCLIRunning,
        expectedMonitorGeneration: UInt64?
    ) async {
        do {
            let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
            guard result.exitCode == 0, !result.timedOut else { return }
            let parsed = SessionListParser.parse(result.stdout)
            guard !parsed.hadInvalidLines else { return }
            if let expectedMonitorGeneration,
               expectedMonitorGeneration != monitorGeneration {
                return
            }
            await observe(parsed.sessions)
        } catch {
            // Session UI exposes CLI diagnostics; notifications retry quietly.
        }
    }

    /// Always advances the detector for successful snapshots. While the
    /// permission sheet is open, transitions are queued and delivered after
    /// authorization instead of being lost.
    func observe(_ sessions: [Session]) async {
        let transitions = detector.observe(sessions)
        guard isEnabled else { return }

        switch authorizationStatus {
        case .authorized:
            pendingPayloads.append(contentsOf: transitions.map(payload(for:)))
            await deliverPendingPayloads()
        case .unknown, .notDetermined:
            pendingPayloads.append(contentsOf: transitions.map(payload(for:)))
        case .denied:
            clearPendingPayloads()
        }
    }

    private func requestAuthorizationOnce() async throws -> Bool {
        if let authorizationRequestTask {
            return try await authorizationRequestTask.value
        }
        let task = Task { @MainActor [center] in
            try await center.requestAuthorization()
        }
        authorizationRequestTask = task
        do {
            let result = try await task.value
            authorizationRequestTask = nil
            return result
        } catch {
            authorizationRequestTask = nil
            throw error
        }
    }

    private func restartMonitoring(resetBaseline: Bool) {
        monitorTask?.cancel()
        monitorTask = nil
        monitorGeneration &+= 1
        let generation = monitorGeneration
        if resetBaseline {
            detector = SessionTransitionDetector()
            clearPendingPayloads()
        }
        guard isEnabled,
              authorizationStatus != .denied,
              let configuration = monitorConfiguration else { return }

        let cli = cliFactory(configuration.detachPath)
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(
                    using: cli,
                    expectedMonitorGeneration: generation)
                do {
                    try await Task.sleep(nanoseconds: UInt64(
                        configuration.interval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func deliverPendingPayloads() async {
        guard isEnabled, authorizationStatus.canDeliver, !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }

        while isEnabled, authorizationStatus.canDeliver, !pendingPayloads.isEmpty {
            let generation = pendingGeneration
            let payload = pendingPayloads.removeFirst()
            do {
                try await center.deliver(payload)
                errorMessage = nil
            } catch {
                guard isEnabled else { return }
                errorMessage = L10n.format(
                    "Could not show notification: %@",
                    error.localizedDescription)
                if generation == pendingGeneration {
                    // Put the exact same payload back so a later poll retries
                    // with the same system identifier.
                    pendingPayloads.insert(payload, at: 0)
                    return
                }
                // The queue was intentionally reset while delivery was in
                // flight. Do not resurrect the old event; continue only if a
                // new generation already queued something.
            }
        }
    }

    private func clearPendingPayloads() {
        pendingGeneration &+= 1
        pendingPayloads.removeAll()
    }

    private func payload(for transition: SessionTransition) -> SessionNotificationPayload {
        let session = transition.session
        let title: String
        let detail: String
        switch transition.kind {
        case .completed:
            title = L10n.string("Session completed")
            detail = L10n.string("Work completed successfully")
        case .failed:
            title = L10n.string("Session failed")
            if let exitStatus = session.exitStatus {
                detail = L10n.format("Exit code: %d", exitStatus)
            } else {
                detail = L10n.string("Open Detach to view details")
            }
        case .recoverable:
            title = L10n.string("Session can be recovered")
            detail = L10n.string("Recovery from the latest checkpoint is available")
        case .waitingForUser:
            title = L10n.string("Agent response is ready")
            detail = L10n.string("Open the session to continue")
        }

        return SessionNotificationPayload(
            identifier: "detach.session.\(identifierProvider())",
            title: title,
            body: L10n.format(
                "%@ · %@\n%@",
                session.displayTitle,
                session.provider.rawValue,
                detail),
            threadIdentifier: session.id)
    }
}

@MainActor
private final class SystemSessionNotificationCenter: SessionNotificationCenterBackend {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status: SessionNotificationAuthorizationStatus
                switch settings.authorizationStatus {
                case .notDetermined:
                    status = .notDetermined
                case .denied:
                    status = .denied
                case .authorized, .provisional, .ephemeral:
                    status = .authorized
                @unknown default:
                    status = .unknown
                }
                continuation.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func deliver(_ payload: SessionNotificationPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.threadIdentifier = payload.threadIdentifier
        let request = UNNotificationRequest(
            identifier: payload.identifier, content: content, trigger: nil)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
