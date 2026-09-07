import AppKit
import Combine
import DetachKit

@MainActor
final class PetCoordinator: ObservableObject {
    private struct PreparedGeneratedPet {
        let package: PetPackage
        let atlas: PetAtlas
    }

    static let enabledKey = "petEnabled"
    static let selectedPetIDKey = "selectedPetID"
    static let unreadActivityIDsKey = "petUnreadActivityIDs"
    static let observedTerminalActivityIDsKey =
        "petObservedTerminalActivityIDs"
    static let legacyUnreadSessionIDsKey = "petUnreadSessionIDs"
    static let lastObservedAtKey = "petLastObservedAt"
    static let pendingGeneratedPetIDKey = "petPendingGeneratedPetID"
    static let pendingGeneratedPetSessionIDKey =
        "petPendingGeneratedPetSessionID"
    static let pendingGeneratedPetPromptKey =
        "petPendingGeneratedPetPrompt"

    @Published private(set) var packages: [PetPackage] = []
    @Published private(set) var packageIssues: [PetPackageIssue] = []
    @Published private(set) var libraryAccessIssues: [PetLibraryAccessIssue] = []
    @Published private(set) var atlas: PetAtlas?
    @Published private(set) var activities: [PetActivity] = []
    @Published private(set) var loadError: String?
    @Published private(set) var generationTrackingTimedOut = false
    @Published private(set) var generationPackageIssue: String?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            onVisibilityChange?()
        }
    }
    @Published var selectedPetID: String? {
        didSet {
            defaults.set(selectedPetID, forKey: Self.selectedPetIDKey)
            loadSelectedAtlas()
        }
    }

    var onVisibilityChange: (() -> Void)?

    private let defaults: UserDefaults
    private let libraryRoot: URL
    private let bundledLibraryRoot: URL?
    private let generationPackageCheckSleep:
        @Sendable (UInt64) async throws -> Void
    private let generationPackageCheckLimit: Int
    private let makeAtlas: @MainActor (PetPackage) throws -> PetAtlas
    private var latestSessions: [Session] = []
    private var tracker: PetActivityTracker
    private var legacyUnreadSessionIDs: Set<String>
    private var generatedPetWatchTask: Task<Void, Never>?
    private var watchedGeneratedPetID: String?

    init(
        defaults: UserDefaults,
        libraryRoot: URL = PetLibraryLoader.defaultRoot(),
        bundledLibraryRoot: URL? = PetLibraryLoader.bundledRoot(),
        generationPackageCheckSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        generationPackageCheckLimit: Int =
            PetGenerationSessionMonitor.maximumPackageChecks,
        makeAtlas: @escaping @MainActor (PetPackage) throws -> PetAtlas = {
            try PetAtlas(package: $0)
        }
    ) {
        self.defaults = defaults
        self.libraryRoot = libraryRoot
        self.bundledLibraryRoot = bundledLibraryRoot
        self.generationPackageCheckSleep = generationPackageCheckSleep
        self.generationPackageCheckLimit = generationPackageCheckLimit
        self.makeAtlas = makeAtlas
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        selectedPetID = defaults.string(forKey: Self.selectedPetIDKey)
        let unread = Set(defaults.stringArray(
            forKey: Self.unreadActivityIDsKey) ?? [])
        let observed = Set(defaults.stringArray(
            forKey: Self.observedTerminalActivityIDsKey) ?? [])
        legacyUnreadSessionIDs = Set(defaults.stringArray(
            forKey: Self.legacyUnreadSessionIDsKey) ?? [])
        tracker = PetActivityTracker(
            unreadTerminalActivityIDs: unread,
            observedTerminalActivityIDs: observed,
            lastObservedAt: defaults.object(
                forKey: Self.lastObservedAtKey) as? Date)
    }

    var selectedPackage: PetPackage? {
        packages.first { $0.id == selectedPetID }
    }

    var shouldShow: Bool {
        isEnabled && atlas != nil
    }

    var currentActivity: PetActivity? { activities.first }

    var libraryURL: URL { libraryRoot }

    func reloadLibrary() {
        reloadLibrary(preparedGeneratedPet: nil)
    }

    private func reloadLibrary(
        preparedGeneratedPet: PreparedGeneratedPet?
    ) {
        let result = PetLibraryLoader.load(
            userRoot: libraryRoot,
            bundledRoot: bundledLibraryRoot)
        packages = result.packages
        packageIssues = result.issues
        libraryAccessIssues = result.accessIssues
        includeSelectedPackageBeyondLimitIfNeeded()
        loadError = nil
        if let pendingID = defaults.string(
            forKey: Self.pendingGeneratedPetIDKey) {
            generationPackageIssue = result.issues.first {
                $0.packageName == pendingID
            }?.reason
            let prepared = preparedGeneratedPet?.package.id == pendingID
                ? preparedGeneratedPet
                : prepareGeneratedPet(
                    petID: pendingID,
                    discoveredPackage: packages.first {
                        $0.id == pendingID && $0.source == .codexLibrary
                    })
            if let prepared {
                // A just-generated package must remain discoverable even when
                // it sorts after the bounded general library scan. It also
                // takes precedence over a bundled package with the same id.
                packages.removeAll { $0.id == pendingID }
                packages.append(prepared.package)
                packages.sort {
                    $0.displayName.localizedCaseInsensitiveCompare(
                        $1.displayName) == .orderedAscending
                }
                clearGeneratedPetTracking()
                selectedPetID = pendingID
                atlas = prepared.atlas
                loadError = nil
                onVisibilityChange?()
                return
            }
        } else {
            generationPackageIssue = nil
        }
        if selectedPackage == nil {
            selectedPetID = packages.first?.id
        } else {
            loadSelectedAtlas()
        }
        startGeneratedPetWatchIfNeeded()
    }

    func selectPet(id: String) {
        guard packages.contains(where: { $0.id == id }) else { return }
        selectedPetID = id
    }

    @discardableResult
    func importPet(from source: URL) throws -> PetPackage {
        let sourcePackage = try PetLibraryLoader.loadPackage(
            from: source,
            fileManager: .default)
        _ = try makeAtlas(sourcePackage)
        let imported = try PetLibraryInstaller.install(
            from: source,
            into: libraryRoot)
        reloadLibrary()
        selectPet(id: imported.id)
        return packages.first { $0.id == imported.id } ?? imported
    }

    func ensureLibraryDirectory() throws {
        if let issue = PetLibraryLoader.rootStructureIssue(
            at: libraryRoot,
            fileManager: .default) {
            throw PetLibraryRootAccessError(issue: issue)
        }
        try FileManager.default.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true)
    }

    func beginGeneratedPetTracking(petID: String, sessionID: String) {
        generationTrackingTimedOut = false
        generationPackageIssue = nil
        defaults.set(petID, forKey: Self.pendingGeneratedPetIDKey)
        defaults.set(sessionID, forKey: Self.pendingGeneratedPetSessionIDKey)
        if !finishGeneratedPetIfPresent(petID: petID) {
            startGeneratedPetWatchIfNeeded()
        }
    }

    func stopGeneratedPetTracking() {
        clearGeneratedPetTracking()
    }

    func resumeGeneratedPetTracking() {
        guard defaults.string(forKey: Self.pendingGeneratedPetIDKey) != nil else {
            return
        }
        generationTrackingTimedOut = false
        generationPackageIssue = nil
        startGeneratedPetWatchIfNeeded()
    }

    func observe(_ sessions: [Session], at now: Date = Date()) {
        latestSessions = sessions
        if !legacyUnreadSessionIDs.isEmpty {
            tracker.migrateLegacyUnreadSessionIDs(
                legacyUnreadSessionIDs,
                sessions: sessions)
            legacyUnreadSessionIDs.removeAll()
        }
        tracker.observe(sessions, at: now)
        publishActivities()
        persistTracker()
    }

    func acknowledge(_ activity: PetActivity) {
        tracker.acknowledge(activityID: activity.lifecycleID)
        publishActivities()
        persistTracker()
    }

    private func publishActivities() {
        activities = PetActivityResolver.resolve(
            sessions: latestSessions,
            unreadTerminalActivityIDs: tracker.unreadTerminalActivityIDs)
    }

    private func persistTracker() {
        defaults.set(
            Array(tracker.unreadTerminalActivityIDs).sorted(),
            forKey: Self.unreadActivityIDsKey)
        defaults.set(
            Array(tracker.observedTerminalActivityIDs).sorted(),
            forKey: Self.observedTerminalActivityIDsKey)
        defaults.removeObject(forKey: Self.legacyUnreadSessionIDsKey)
        defaults.set(tracker.lastObservedAt, forKey: Self.lastObservedAtKey)
    }

    private func loadSelectedAtlas() {
        guard let package = selectedPackage else {
            atlas = nil
            onVisibilityChange?()
            return
        }
        do {
            atlas = try makeAtlas(package)
            loadError = nil
        } catch {
            atlas = nil
            loadError = error.localizedDescription
        }
        onVisibilityChange?()
    }

    /// Generation writes the package into a directory named after its id.
    /// Preserve that selected custom package across refreshes and relaunches
    /// even when the bounded general scan has already consumed its quota.
    private func includeSelectedPackageBeyondLimitIfNeeded() {
        guard let selectedPetID,
              !packages.contains(where: { $0.id == selectedPetID }),
              !libraryAccessIssues.contains(where: {
                  $0.source == .codexLibrary
              }),
              PetLibraryLoader.rootStructureIssue(
                  at: libraryRoot,
                  fileManager: .default) == nil else {
            return
        }
        let root = libraryRoot.standardizedFileURL
        let directory = root.appendingPathComponent(
            selectedPetID,
            isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              let package = try? PetLibraryLoader.loadPackage(
                from: directory,
                source: .codexLibrary,
                fileManager: .default),
              package.id == selectedPetID else {
            return
        }
        packages.append(package)
        packages.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    /// Package discovery stays app-scoped and deliberately avoids refreshing
    /// the session list. Session truth already arrives through `detach watch`;
    /// this lightweight loop only checks the local Codex pets directory.
    private func startGeneratedPetWatchIfNeeded() {
        guard let petID = defaults.string(
            forKey: Self.pendingGeneratedPetIDKey),
              !petID.isEmpty else {
            generatedPetWatchTask?.cancel()
            generatedPetWatchTask = nil
            watchedGeneratedPetID = nil
            return
        }
        guard !generationTrackingTimedOut else { return }
        guard watchedGeneratedPetID != petID
                || generatedPetWatchTask == nil else { return }

        generatedPetWatchTask?.cancel()
        watchedGeneratedPetID = petID
        let packageCheckSleep = generationPackageCheckSleep
        let packageCheckLimit = generationPackageCheckLimit
        generatedPetWatchTask = Task { [weak self] in
            for _ in 0..<packageCheckLimit {
                do {
                    try await packageCheckSleep(
                        PetGenerationSessionMonitor
                            .packageCheckIntervalNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                guard self.defaults.string(
                        forKey: Self.pendingGeneratedPetIDKey) == petID else {
                    return
                }
                if self.finishGeneratedPetIfPresent(petID: petID) {
                    return
                }
            }
            guard let self else { return }
            guard self.defaults.string(
                    forKey: Self.pendingGeneratedPetIDKey) == petID else {
                return
            }
            self.generatedPetWatchTask = nil
            self.watchedGeneratedPetID = nil
            self.generationTrackingTimedOut = true
        }
    }

    /// Loads only the requested package directory. A miss must not publish a
    /// new library snapshot or decode the selected atlas again.
    private func prepareGeneratedPet(
        petID: String,
        discoveredPackage: PetPackage? = nil
    ) -> PreparedGeneratedPet? {
        if libraryAccessIssues.contains(where: {
            $0.source == .codexLibrary
        }) {
            generationPackageIssue = nil
            return nil
        }
        guard PetLibraryLoader.rootStructureIssue(
            at: libraryRoot,
            fileManager: .default) == nil else {
            generationPackageIssue = L10n.string(
                "Codex pet library path must point to a regular folder.")
            return nil
        }
        let root = libraryRoot.standardizedFileURL
        let directory = root.appendingPathComponent(
            petID,
            isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == root else {
            generationPackageIssue = "generated pet id escapes the library"
            return nil
        }
        if discoveredPackage == nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory) else {
                generationPackageIssue = nil
                return nil
            }
        }
        do {
            let package = try discoveredPackage ?? PetLibraryLoader.loadPackage(
                from: directory,
                source: .codexLibrary,
                fileManager: .default)
            guard package.id == petID else {
                generationPackageIssue =
                    "generated package id does not match its target"
                return nil
            }
            let atlas = try makeAtlas(package)
            generationPackageIssue = nil
            return PreparedGeneratedPet(package: package, atlas: atlas)
        } catch {
            generationPackageIssue = error.localizedDescription
            return nil
        }
    }

    private func finishGeneratedPetIfPresent(petID: String) -> Bool {
        guard let prepared = prepareGeneratedPet(petID: petID) else {
            return false
        }
        reloadLibrary(preparedGeneratedPet: prepared)
        return selectedPetID == petID
    }

    private func clearGeneratedPetTracking() {
        defaults.removeObject(forKey: Self.pendingGeneratedPetIDKey)
        defaults.removeObject(forKey: Self.pendingGeneratedPetSessionIDKey)
        defaults.removeObject(forKey: Self.pendingGeneratedPetPromptKey)
        generatedPetWatchTask?.cancel()
        generatedPetWatchTask = nil
        watchedGeneratedPetID = nil
        generationTrackingTimedOut = false
        generationPackageIssue = nil
    }

    deinit {
        generatedPetWatchTask?.cancel()
    }
}
