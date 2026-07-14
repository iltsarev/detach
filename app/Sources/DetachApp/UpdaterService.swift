import Combine
import DetachKit
import Foundation
import Sparkle
import SwiftUI

@MainActor
private final class UpdateCycleObserver: NSObject, SPUUpdaterDelegate {
    var didFinishUpdateCycle: ((Error?) -> Void)?
    var didFindValidUpdate: (() -> Void)?

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        didFinishUpdateCycle?(error)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        didFindValidUpdate?()
    }
}

@MainActor
final class UpdaterService: ObservableObject {
    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    let availability: Availability
    let updaterController: SPUStandardUpdaterController
    let manualDownloadURL: URL?

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var updateErrorMessage: String?
    @Published private(set) var lastCheckFoundNoUpdate = false

    private let updateCycleObserver: UpdateCycleObserver
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let bundle = Bundle.main
        let payload = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/DetachCLI", isDirectory: true)
        let isPackagedApplication = FileManager.default.fileExists(atPath: payload.path)
        let configuration = UpdateConfiguration(
            feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            downloadURLString: bundle.object(forInfoDictionaryKey: "DetachDownloadURL") as? String,
            applicationURL: bundle.bundleURL,
            isPackagedApplication: isPackagedApplication)
        manualDownloadURL = configuration.manualDownloadURL
        availability = Self.availability(
            for: configuration, isPackagedApplication: isPackagedApplication)
        let updateCycleObserver = UpdateCycleObserver()
        self.updateCycleObserver = updateCycleObserver
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updateCycleObserver,
            userDriverDelegate: nil)

        updateCycleObserver.didFinishUpdateCycle = { [weak self] error in
            self?.recordUpdateCycleResult(error)
        }
        updateCycleObserver.didFindValidUpdate = { [weak self] in
            self?.lastCheckFoundNoUpdate = false
        }

        guard isAvailable else { return }

        let updater = updaterController.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in
                self?.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)

        // SPUStandardUpdaterController displays a developer-error alert when it
        // starts with an invalid bundle configuration. We deliberately start it
        // only after validating the two required release settings above.
        updaterController.startUpdater()
    }

    var isAvailable: Bool {
        availability == .available
    }

    var unavailableReason: String? {
        guard case let .unavailable(reason) = availability else { return nil }
        return reason
    }

    var shouldOfferManualDownload: Bool {
        !isAvailable || updateErrorMessage != nil
    }

    var lastUpdateCheckDate: Date? {
        guard isAvailable else { return nil }
        return updaterController.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        guard isAvailable, updaterController.updater.canCheckForUpdates else { return }
        updateErrorMessage = nil
        lastCheckFoundNoUpdate = false
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    private func recordUpdateCycleResult(_ error: Error?) {
        updateErrorMessage = Self.fallbackMessage(for: error)
        lastCheckFoundNoUpdate = Self.provesApplicationIsCurrent(error)
    }

    /// Only Sparkle's explicit "no update found" result with an
    /// on-latest-version reason proves the app is current: a nil error can
    /// also end a cycle that installed an update, and code 1001 is likewise
    /// reported when a newer release exists but was filtered out as
    /// incompatible with this macOS version or hardware.
    static func provesApplicationIsCurrent(_ error: Error?) -> Bool {
        guard let nsError = error as NSError?,
              nsError.domain == SUSparkleErrorDomain,
              nsError.code == 1001,
              let reasonValue = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
              let reason = SPUNoUpdateFoundReason(rawValue: reasonValue.int32Value) else {
            return false
        }
        return reason == .onLatestVersion || reason == .onNewerThanLatestVersion
    }

    private static func availability(
        for configuration: UpdateConfiguration,
        isPackagedApplication: Bool
    ) -> Availability {
        guard !configuration.isAvailable else { return .available }
        let problems = configuration.issues.map { issue in
            switch issue {
            case .unstableApplicationLocation:
                return L10n.string("the app isn't running from /Applications")
            case .invalidFeedURL:
                return L10n.string("a valid HTTPS SUFeedURL isn't configured")
            case .invalidPublicKey:
                return L10n.string("a valid SUPublicEDKey isn't configured")
            }
        }
        let problemDescription = problems.joined(separator: ", ")
        let reason = isPackagedApplication
            ? L10n.format("Automatic updates are unavailable: %@.", problemDescription)
            : L10n.format(
                "Automatic updates are unavailable: %@. This is expected for local development.",
                problemDescription)
        return .unavailable(reason: reason)
    }

    static func fallbackMessage(for error: Error?) -> String? {
        guard let error else { return nil }

        let nsError = error as NSError
        // A normal "no update" result and explicit user cancellation are not
        // failures that warrant sending the user to a manual download.
        let nonActionableSparkleErrorCodes = [1001, 4007, 4008]
        guard nsError.domain != SUSparkleErrorDomain
                || !nonActionableSparkleErrorCodes.contains(nsError.code) else {
            return nil
        }
        return L10n.format(
            "Sparkle couldn't complete the update: %@", nsError.localizedDescription)
    }

}

struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterService

    var body: some View {
        Button(L10n.string("Check for updates…")) {
            updater.checkForUpdates()
        }
        .disabled(!updater.isAvailable || !updater.canCheckForUpdates)

        if updater.shouldOfferManualDownload {
            if let downloadURL = updater.manualDownloadURL {
                Link(L10n.string("Open download page…"), destination: downloadURL)
            } else {
                Button(L10n.string("Open download page…")) {}
                    .disabled(true)
            }
        }
    }
}
