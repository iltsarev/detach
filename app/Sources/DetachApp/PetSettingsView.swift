import AppKit
import DetachKit
import SwiftUI
import UniformTypeIdentifiers

enum PetPickerPresentation {
    static func title(
        for package: PetPackage,
        among packages: [PetPackage],
        sourceName: (PetPackage.Source) -> String
    ) -> String {
        let hasMatchingName = packages.contains {
            $0.id != package.id
                && $0.displayName.localizedCaseInsensitiveCompare(
                    package.displayName) == .orderedSame
        }
        guard hasMatchingName else { return package.displayName }
        return "\(package.displayName) — \(sourceName(package.source)) · \(package.id)"
    }
}

struct PetSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: PetCoordinator
    @ObservedObject var navigation: MainNavigation
    let sessionStore: SessionStore
    let detachPath: String
    @State private var isImportingPet = false
    @State private var importMessage: String?
    @State private var importError: String?
    @State private var generationError: String?
    @State private var isStartingGeneration = false
    @State private var showsGenerationConfirmation = false
    @AppStorage(
        PetCoordinator.pendingGeneratedPetIDKey,
        store: AppSettings.defaults)
    private var pendingGeneratedPetID = ""
    @AppStorage(
        PetCoordinator.pendingGeneratedPetSessionIDKey,
        store: AppSettings.defaults)
    private var pendingGeneratedPetSessionID = ""

    private var runtimeHelperURL: URL {
        PetGenerationSupport.runtimeHelperURL(detachPath: detachPath)
    }

    private var generationAvailability: PetGenerationAvailability {
        PetGenerationSupport.availability(
            libraryRoot: coordinator.libraryURL,
            runtimeHelperURL: runtimeHelperURL)
    }

    private var generationAvailable: Bool {
        generationAvailability.isAvailable
    }

    private var generationPhase: PetGenerationPhase {
        PetGenerationPhase.resolve(
            isAvailable: generationAvailable,
            isStarting: isStartingGeneration,
            pendingPetID: pendingGeneratedPetID,
            pendingSessionID: pendingGeneratedPetSessionID,
            pendingSessionStatus: pendingGenerationSession?.effectiveStatus,
            pendingTurnState: pendingGenerationSession?.agentTurnState,
            hasFreshSessionSnapshot: sessionStore.hasFreshSnapshot,
            trackingTimedOut: coordinator.generationTrackingTimedOut)
    }

    private var pendingGenerationSession: Session? {
        sessionStore.sessions.first(where: {
            $0.id == pendingGeneratedPetSessionID
        })
    }

    var body: some View {
        Form {
            Section(L10n.string("Floating pet")) {
                HStack(alignment: .center, spacing: 20) {
                    petPreview
                    VStack(alignment: .leading, spacing: 7) {
                        if let package = coordinator.selectedPackage {
                            Text(package.displayName)
                                .font(.headline)
                            packageSourceBadge(package.source)
                            Text(localizedDescription(for: package))
                                .settingsMessage()
                        } else {
                            Text(L10n.string("No pet selected"))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(
                    L10n.string("Wake Pet"),
                    isOn: Binding(
                        get: { coordinator.isEnabled },
                        set: { coordinator.isEnabled = $0 }))
                    .disabled(coordinator.packages.isEmpty)
                    .accessibilityIdentifier("settings-pet-enabled")
                Text(L10n.string(
                    "The pet stays above other windows and follows both Codex and Claude sessions."))
                    .settingsMessage()
            }

            Section(L10n.string("Pet library")) {
                if coordinator.packages.isEmpty {
                    Label(
                        L10n.string("No compatible Codex pets found"),
                        systemImage: "pawprint")
                        .foregroundStyle(.secondary)
                    Text(L10n.string(
                        "Add a compatible pet package or install one in Codex."))
                        .settingsMessage()
                } else {
                    Picker(
                        L10n.string("Choose a pet"),
                        selection: Binding(
                            get: { coordinator.selectedPetID ?? "" },
                            set: { coordinator.selectPet(id: $0) })
                    ) {
                        ForEach(coordinator.packages) { package in
                            Text(pickerTitle(for: package)).tag(package.id)
                        }
                    }
                    .accessibilityIdentifier("settings-pet-picker")
                    if let package = coordinator.selectedPackage {
                        Text(L10n.format(
                            "Codex pet format v%d", package.spriteVersionNumber))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(L10n.string(
                    "Detach reads compatible custom pets from your local Codex library. Use Refresh for pets added while this pane is open; Codex's built-in pets are not imported."))
                    .settingsMessage()

                HStack(spacing: 12) {
                    Button {
                        clearTransientMessages()
                        isImportingPet = true
                    } label: {
                        Label(L10n.string("Add Pet…"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("settings-pet-add")
                    Button(L10n.string("Refresh")) {
                        coordinator.reloadLibrary()
                    }
                    Button(L10n.string("Show in Finder")) {
                        revealPetsFolder()
                    }
                    Spacer()
                }
                .fileImporter(
                    isPresented: $isImportingPet,
                    allowedContentTypes: [.folder]
                ) { result in
                    guard case .success(let url) = result else { return }
                    importPet(from: url)
                }

                Text(L10n.string(
                    "Select the folder that contains pet.json and its PNG or WebP spritesheet."))
                    .settingsMessage()

                if let importMessage {
                    Text(importMessage).settingsMessage(color: .green)
                }
                if let importError {
                    Text(importError).settingsMessage(color: .red)
                }

                ForEach(
                    Array(coordinator.libraryAccessIssues.enumerated()),
                    id: \.offset
                ) { _, issue in
                    Text(libraryAccessMessage(for: issue))
                        .settingsMessage(color: .red)
                        .textSelection(.enabled)
                }

                if !coordinator.packageIssues.isEmpty {
                    DisclosureGroup(L10n.format(
                        "%d pet packages were skipped because they are invalid.",
                        coordinator.packageIssues.count)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(
                                Array(coordinator.packageIssues.enumerated()),
                                id: \.offset
                            ) { _, issue in
                                Text("\(issue.packageName): \(issue.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .foregroundStyle(.orange)
                }
                if let error = coordinator.loadError {
                    Text(error).settingsMessage(color: .red)
                }
            }

            Section(L10n.string("Create with Codex")) {
                HStack(spacing: 12) {
                    Button {
                        switch generationPhase {
                        case .idle:
                            showsGenerationConfirmation = true
                        case .running, .attention:
                            openPendingGenerationSession()
                        case .finished:
                            openPendingGenerationSession()
                        case .trackingTimedOut:
                            coordinator.resumeGeneratedPetTracking()
                        case .unavailable, .starting, .checkingSession,
                             .missingSession:
                            break
                        }
                    } label: {
                        generationButtonLabel
                    }
                    .disabled(
                        generationPhase != .idle
                            && generationPhase != .running
                            && generationPhase != .attention
                            && generationPhase != .finished
                            && generationPhase != .trackingTimedOut)
                    .accessibilityIdentifier("settings-pet-generation")

                    if !pendingGeneratedPetID.isEmpty {
                        Button(L10n.string("Stop Tracking")) {
                            clearPendingGeneration()
                            generationError = nil
                        }
                        .help(L10n.string(
                            "Stops Detach from watching for this pet. The Codex session keeps running."))
                    }
                    Spacer()
                }

                switch generationPhase {
                case .starting:
                    generationStatus(
                        L10n.string("Starting a managed Codex CLI session…"))
                case .running:
                    Text(L10n.string(
                        "Codex is creating the pet in a Detach session. You can open the session now; the finished pet will be selected automatically."))
                        .settingsMessage()
                case .attention:
                    Text(L10n.string(
                        "Pet generation needs attention. Open its Codex session to continue."))
                        .settingsMessage(color: .orange)
                case .finished:
                    Text(L10n.string(
                        "The Codex session finished before the pet package appeared. Detach is still watching; open the session for details or stop tracking."))
                        .settingsMessage(color: .orange)
                case .checkingSession:
                    generationStatus(
                        L10n.string("Checking the generation session…"))
                case .missingSession:
                    Text(L10n.string(
                        "The Codex session is no longer available. Detach is still watching for the pet package until you stop tracking."))
                        .settingsMessage(color: .orange)
                case .trackingTimedOut:
                    Text(L10n.string(
                        "Automatic tracking paused after one hour. Refresh the library or resume tracking to keep waiting for the package."))
                        .settingsMessage(color: .orange)
                case .idle:
                    Text(L10n.string(
                        "Starts a managed Codex session and creates one new random v2 pet in your local library."))
                        .settingsMessage()
                case .unavailable:
                    Text(generationUnavailableMessage)
                        .settingsMessage(color: .orange)
                }

                if let generationError {
                    Text(generationError).settingsMessage(color: .red)
                }
                if let issue = coordinator.generationPackageIssue {
                    Text(L10n.format(
                        "Waiting for a valid pet package: %@", issue))
                        .settingsMessage(color: .orange)
                        .textSelection(.enabled)
                }
            }

            Section(L10n.string("Activity")) {
                if coordinator.activities.isEmpty {
                    Label(
                        L10n.string("No active pet alerts"),
                        systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.activities) { activity in
                        Button {
                            openActivity(activity)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(activityColor(for: activity.state))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(activity.provider.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(activityLabel(for: activity.state))
                                    .font(.caption)
                                    .foregroundStyle(
                                        activityColor(for: activity.state))
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "settings-pet-activity-\(activity.lifecycleID)")
                    }
                    Text(L10n.string(
                        "Select an activity to open that session in Detach."))
                        .settingsMessage()
                }

                HStack(spacing: 8) {
                    ForEach(PetActivityState.allCases, id: \.rawValue) { state in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(activityColor(for: state))
                                .frame(width: 8, height: 8)
                            Text(activityLabel(for: state))
                                .font(.caption)
                        }
                    }
                }
                Text(L10n.string(
                    "Needs input takes priority, followed by Blocked, Ready, and Running."))
                    .settingsMessage()
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings-pets")
        .padding(20)
        .task { coordinator.reloadLibrary() }
        .confirmationDialog(
            L10n.string("Create a random pet with Codex?"),
            isPresented: $showsGenerationConfirmation
        ) {
            Button(L10n.string("Create Pet")) {
                Task { await startRandomPetGeneration() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "Generation can take several minutes and runs in a new Codex session managed by Detach."))
        }
    }

    private func startRandomPetGeneration() async {
        guard !isStartingGeneration, generationAvailable else { return }
        isStartingGeneration = true
        clearTransientMessages()
        defer { isStartingGeneration = false }
        clearPendingGeneration()

        do {
            try coordinator.ensureLibraryDirectory()
        } catch {
            generationError = L10n.format(
                "Could not prepare pets folder: %@",
                error.localizedDescription)
            return
        }

        let request = RandomPetGenerationRequest.random(
            libraryRoot: coordinator.libraryURL)
        let result = await sessionStore.startDetached(
            provider: .codex,
            projectDirectory: coordinator.libraryURL,
            name: request.sessionName,
            prompt: request.prompt,
            providerArguments: request.codexProviderArguments(
                runtimeHelperURL: runtimeHelperURL))
        if let message = result.message {
            generationError = L10n.format(
                "Could not start pet generation: %@", message)
            return
        }
        guard let sessionID = result.sessionID else {
            generationError = L10n.string(
                "Detach could not identify the new pet generation session.")
            return
        }
        pendingGeneratedPetSessionID = sessionID
        pendingGeneratedPetID = request.petID
        coordinator.beginGeneratedPetTracking(
            petID: request.petID,
            sessionID: sessionID)
    }

    private func clearPendingGeneration() {
        pendingGeneratedPetID = ""
        pendingGeneratedPetSessionID = ""
        coordinator.stopGeneratedPetTracking()
    }

    private func openPendingGenerationSession() {
        guard !pendingGeneratedPetSessionID.isEmpty else { return }
        navigation.requestSession(pendingGeneratedPetSessionID)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openActivity(_ activity: PetActivity) {
        PetSessionNavigator.open(
            activity,
            coordinator: coordinator,
            navigation: navigation) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private func importPet(from url: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let alreadyInstalled = url.deletingLastPathComponent()
                .standardizedFileURL == coordinator.libraryURL.standardizedFileURL
            let package = try coordinator.importPet(from: url)
            importMessage = alreadyInstalled
                ? L10n.format(
                    "Pet “%@” was already installed and is now selected.",
                    package.displayName)
                : L10n.format("Pet “%@” was added.", package.displayName)
            importError = nil
        } catch {
            importMessage = nil
            importError = L10n.format(
                "Could not add pet: %@", localizedPetError(error))
        }
    }

    private func revealPetsFolder() {
        do {
            try coordinator.ensureLibraryDirectory()
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: coordinator.libraryURL.path)
        } catch {
            importMessage = nil
            importError = L10n.format(
                "Could not open pets folder: %@", localizedPetError(error))
        }
    }

    private func clearTransientMessages() {
        importMessage = nil
        importError = nil
        generationError = nil
    }

    private func generationStatus(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .settingsMessage()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var generationButtonLabel: some View {
        switch generationPhase {
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Starting…"))
            }
        case .running:
            Label(
                L10n.string("Open Generation Session"),
                systemImage: "arrow.up.right.square")
        case .attention:
            Label(
                L10n.string("Continue Pet Generation"),
                systemImage: "arrow.right.circle")
        case .finished:
            Label(
                L10n.string("View Generation Session"),
                systemImage: "doc.text.magnifyingglass")
        case .checkingSession:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Checking Generation Session"))
            }
        case .missingSession:
            Label(
                L10n.string("Generation Session Unavailable"),
                systemImage: "exclamationmark.triangle")
        case .trackingTimedOut:
            Label(
                L10n.string("Resume Tracking"),
                systemImage: "arrow.clockwise")
        case .idle, .unavailable:
            Label(
                L10n.string("Generate Random Pet"),
                systemImage: "sparkles")
        }
    }

    private func packageSourceBadge(
        _ source: PetPackage.Source
    ) -> some View {
        Label(
            source == .bundled
                ? L10n.string("Included with Detach")
                : L10n.string("Codex library"),
            systemImage: source == .bundled ? "shippingbox" : "books.vertical")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private func pickerTitle(for package: PetPackage) -> String {
        PetPickerPresentation.title(
            for: package,
            among: coordinator.packages,
            sourceName: packageSourceName)
    }

    private func packageSourceName(_ source: PetPackage.Source) -> String {
        source == .bundled
            ? L10n.string("Included with Detach")
            : L10n.string("Codex library")
    }

    private func libraryAccessMessage(
        for issue: PetLibraryAccessIssue
    ) -> String {
        switch (issue.source, issue.reason) {
        case (.codexLibrary, .invalidRoot):
            L10n.string(
                "Codex pet library path must point to a regular folder.")
        case (.bundled, .invalidRoot):
            L10n.string(
                "Bundled pet library path must point to a regular folder.")
        case let (.codexLibrary, .unreadable(reason)):
            L10n.format("Could not read Codex pet library: %@", reason)
        case let (.bundled, .unreadable(reason)):
            L10n.format("Could not read bundled pet library: %@", reason)
        }
    }

    private func localizedPetError(_ error: Error) -> String {
        guard let accessError = error as? PetLibraryRootAccessError else {
            return error.localizedDescription
        }
        return libraryAccessMessage(for: accessError.issue)
    }

    private func localizedDescription(for package: PetPackage) -> String {
        if package.usesBundledLumiDescription {
            return L10n.string(
                "A bright little companion that follows your agent sessions.")
        }
        return package.description
    }

    private func activityLabel(for state: PetActivityState) -> String {
        switch state {
        case .needsInput: L10n.string("Needs input")
        case .blocked: L10n.string("Blocked")
        case .ready: L10n.string("Answer ready")
        case .running: L10n.string("Running")
        }
    }

    private func activityColor(for state: PetActivityState) -> Color {
        switch state {
        case .needsInput: .orange
        case .blocked: .red
        case .ready: Brand.indigo
        case .running: Brand.teal
        }
    }

    private var generationUnavailableMessage: String {
        switch generationAvailability {
        case .available:
            ""
        case .missingSkill:
            L10n.string("Install the hatch-pet Codex skill to generate pets.")
        case .missingHelper:
            L10n.string(
                "The Detach CLI runtime helper is unavailable. Repair the Detach installation.")
        case .missingRuntime:
            L10n.string(
                "The Codex workspace runtime is unavailable. Open Codex and try again.")
        }
    }

    @ViewBuilder
    private var petPreview: some View {
        if let atlas = coordinator.atlas,
           let image = atlas.frame(PetAtlasFrame(row: 0, column: 0)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 104)
                .accessibilityLabel(coordinator.selectedPackage?.displayName ?? "")
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(width: 96, height: 104)
                .accessibilityHidden(true)
        }
    }
}
