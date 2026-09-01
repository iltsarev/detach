import AppKit
import Combine
import DetachKit

@MainActor
final class PetCoordinator: ObservableObject {
    static let enabledKey = "petEnabled"
    static let selectedPetIDKey = "selectedPetID"
    static let unreadSessionIDsKey = "petUnreadSessionIDs"
    static let lastObservedAtKey = "petLastObservedAt"
    static let pendingGeneratedPetIDKey = "petPendingGeneratedPetID"
    static let pendingGeneratedPetSessionIDKey =
        "petPendingGeneratedPetSessionID"
    static let pendingGeneratedPetPromptKey =
        "petPendingGeneratedPetPrompt"

    @Published private(set) var packages: [PetPackage] = []
    @Published private(set) var packageIssues: [PetPackageIssue] = []
    @Published private(set) var atlas: PetAtlas?
    @Published private(set) var activities: [PetActivity] = []
    @Published private(set) var loadError: String?
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
    private var latestSessions: [Session] = []
    private var tracker: PetActivityTracker

    init(
        defaults: UserDefaults,
        libraryRoot: URL = PetLibraryLoader.defaultRoot(),
        bundledLibraryRoot: URL? = PetLibraryLoader.bundledRoot()
    ) {
        self.defaults = defaults
        self.libraryRoot = libraryRoot
        self.bundledLibraryRoot = bundledLibraryRoot
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        selectedPetID = defaults.string(forKey: Self.selectedPetIDKey)
        let unread = Set(defaults.stringArray(
            forKey: Self.unreadSessionIDsKey) ?? [])
        tracker = PetActivityTracker(
            unreadTerminalSessionIDs: unread,
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
        let result = PetLibraryLoader.load(
            userRoot: libraryRoot,
            bundledRoot: bundledLibraryRoot)
        packages = result.packages
        packageIssues = result.issues
        loadError = nil
        if let pendingID = defaults.string(
            forKey: Self.pendingGeneratedPetIDKey),
           packages.contains(where: { $0.id == pendingID }) {
            defaults.removeObject(forKey: Self.pendingGeneratedPetIDKey)
            defaults.removeObject(
                forKey: Self.pendingGeneratedPetSessionIDKey)
            defaults.removeObject(
                forKey: Self.pendingGeneratedPetPromptKey)
            selectedPetID = pendingID
            return
        }
        if selectedPackage == nil {
            selectedPetID = packages.first?.id
        } else {
            loadSelectedAtlas()
        }
    }

    func selectPet(id: String) {
        guard packages.contains(where: { $0.id == id }) else { return }
        selectedPetID = id
    }

    @discardableResult
    func importPet(from source: URL) throws -> PetPackage {
        let imported = try PetLibraryInstaller.install(
            from: source,
            into: libraryRoot)
        reloadLibrary()
        selectPet(id: imported.id)
        return packages.first { $0.id == imported.id } ?? imported
    }

    func ensureLibraryDirectory() throws {
        try FileManager.default.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true)
    }

    func observe(_ sessions: [Session], at now: Date = Date()) {
        latestSessions = sessions
        tracker.observe(sessions, at: now)
        publishActivities()
        persistTracker()
    }

    func acknowledge(_ activity: PetActivity) {
        tracker.acknowledge(sessionID: activity.sessionID)
        publishActivities()
        persistTracker()
    }

    private func publishActivities() {
        activities = PetActivityResolver.resolve(
            sessions: latestSessions,
            unreadTerminalSessionIDs: tracker.unreadTerminalSessionIDs)
    }

    private func persistTracker() {
        defaults.set(
            Array(tracker.unreadTerminalSessionIDs).sorted(),
            forKey: Self.unreadSessionIDsKey)
        defaults.set(tracker.lastObservedAt, forKey: Self.lastObservedAtKey)
    }

    private func loadSelectedAtlas() {
        guard let package = selectedPackage else {
            atlas = nil
            onVisibilityChange?()
            return
        }
        do {
            atlas = try PetAtlas(package: package)
            loadError = nil
        } catch {
            atlas = nil
            loadError = error.localizedDescription
        }
        onVisibilityChange?()
    }
}
