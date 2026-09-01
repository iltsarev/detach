import AppKit
import DetachKit
import SwiftUI
import UniformTypeIdentifiers

struct PetSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: PetCoordinator
    @ObservedObject var navigation: MainNavigation
    let sessionStore: SessionStore
    let detachPath: String
    @State private var isImportingPet = false
    @State private var importMessage: String?
    @State private var importError: String?
    @State private var generationMessage: String?
    @State private var generationError: String?
    @State private var isStartingGeneration = false
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

    private var generationAvailable: Bool {
        PetGenerationSupport.isAvailable(
            libraryRoot: coordinator.libraryURL,
            runtimeHelperURL: runtimeHelperURL)
    }

    private var generationPhase: PetGenerationPhase {
        PetGenerationPhase.resolve(
            isAvailable: generationAvailable,
            isStarting: isStartingGeneration,
            pendingPetID: pendingGeneratedPetID,
            pendingSessionID: pendingGeneratedPetSessionID,
            pendingSessionStatus: pendingGenerationSession?.effectiveStatus,
            pendingTurnState: pendingGenerationSession?.agentTurnState)
    }

    private var pendingGenerationSession: Session? {
        sessionStore.sessions.first(where: {
            $0.id == pendingGeneratedPetSessionID
        })
    }

    private var pendingGenerationTaskID: String {
        "\(pendingGeneratedPetID)|\(pendingGeneratedPetSessionID)"
    }

    var body: some View {
        Form {
            Section(L10n.string("Floating pet")) {
                Toggle(
                    L10n.string("Wake Pet"),
                    isOn: Binding(
                        get: { coordinator.isEnabled },
                        set: { coordinator.isEnabled = $0 }))
                    .disabled(coordinator.packages.isEmpty)
                Text(L10n.string(
                    "The pet stays above other windows and follows both Codex and Claude sessions."))
                    .settingsMessage()
            }

            Section(L10n.string("Pet")) {
                if coordinator.packages.isEmpty {
                    Label(
                        L10n.string("No compatible Codex pets found"),
                        systemImage: "pawprint")
                        .foregroundStyle(.secondary)
                    Text(L10n.string(
                        "Add a compatible pet package or install one in Codex."))
                        .settingsMessage()
                } else {
                    HStack(alignment: .center, spacing: 20) {
                        petPreview
                        VStack(alignment: .leading, spacing: 10) {
                            Picker(
                                L10n.string("Choose a pet"),
                                selection: Binding(
                                    get: { coordinator.selectedPetID ?? "" },
                                    set: { coordinator.selectPet(id: $0) })
                            ) {
                                ForEach(coordinator.packages) { package in
                                    Text(package.displayName).tag(package.id)
                                }
                            }
                            if let package = coordinator.selectedPackage {
                                Text(package.description)
                                    .settingsMessage()
                                Text(L10n.format(
                                    "Codex pet format v%d", package.spriteVersionNumber))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        importMessage = nil
                        importError = nil
                        isImportingPet = true
                    } label: {
                        Label(L10n.string("Add Pet…"), systemImage: "plus")
                    }
                    Button {
                        switch generationPhase {
                        case .idle:
                            Task { await startRandomPetGeneration() }
                        case .attention:
                            openPendingGenerationSession()
                        case .unavailable, .starting, .running:
                            break
                        }
                    } label: {
                        switch generationPhase {
                        case .starting, .running:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L10n.string("Generating Pet…"))
                            }
                        case .attention:
                            Label(
                                L10n.string("Continue Pet Generation"),
                                systemImage: "arrow.right.circle")
                        case .idle, .unavailable:
                            Label(
                                L10n.string("Generate Random Pet"),
                                systemImage: "sparkles")
                        }
                    }
                    .disabled(
                        generationPhase != .idle
                            && generationPhase != .attention)
                    Spacer()
                }

                switch generationPhase {
                case .starting:
                    generationStatus(
                        L10n.string("Starting a managed Codex CLI session…"))
                case .running:
                    Text(L10n.string(
                        "The pet is being generated in a Codex CLI session managed by Detach. Open that session from the sidebar to follow its progress. Detach will select the pet when its package appears."))
                        .settingsMessage()
                case .attention:
                    Text(L10n.string(
                        "Pet generation needs attention. Continue in its Codex CLI session; Detach will resume tracking it automatically."))
                        .settingsMessage(color: .orange)
                case .idle, .unavailable:
                    EmptyView()
                }

                HStack(spacing: 12) {
                    Button(L10n.string("Refresh")) {
                        coordinator.reloadLibrary()
                    }
                    Button(L10n.string("Show pets folder in Finder")) {
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

                if !generationAvailable {
                    Text(L10n.string(
                        "Random generation requires the hatch-pet skill and the Detach CLI runtime helper."))
                        .settingsMessage(color: .orange)
                }

                if let generationMessage {
                    Text(generationMessage).settingsMessage(color: .green)
                }
                if let generationError {
                    Text(generationError).settingsMessage(color: .red)
                }

                if let importMessage {
                    Text(importMessage).settingsMessage(color: .green)
                }
                if let importError {
                    Text(importError).settingsMessage(color: .red)
                }

                if !coordinator.packageIssues.isEmpty {
                    Text(L10n.format(
                        "%d pet packages were skipped because they are invalid.",
                        coordinator.packageIssues.count))
                        .settingsMessage(color: .orange)
                }
                if let error = coordinator.loadError {
                    Text(error).settingsMessage(color: .red)
                }
            }

            Section(L10n.string("Activity")) {
                Text(L10n.string(
                    "Needs input takes priority, followed by Blocked, Ready, and Running. Select the pet or an activity to open that session in Detach."))
                    .settingsMessage()
                Text(L10n.string(
                    "Detach copies added packages into your local Codex pets folder and never changes the selected source folder."))
                    .settingsMessage()
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task { coordinator.reloadLibrary() }
        .task(id: pendingGenerationTaskID) {
            await watchForGeneratedPet()
        }
    }

    private func startRandomPetGeneration() async {
        guard !isStartingGeneration, generationAvailable else { return }
        isStartingGeneration = true
        generationMessage = nil
        generationError = nil
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
    }

    private func watchForGeneratedPet() async {
        let petID = pendingGeneratedPetID
        let sessionID = pendingGeneratedPetSessionID
        guard !petID.isEmpty, !sessionID.isEmpty else { return }
        var missingPolls = 0
        for _ in 0..<1_800 {
            if Task.isCancelled { return }
            if finishGeneratedPetIfPresent(petID: petID) { return }

            await sessionStore.refresh()
            guard pendingGeneratedPetID == petID,
                  pendingGeneratedPetSessionID == sessionID else { return }
            if let session = sessionStore.sessions.first(where: {
                $0.id == sessionID
            }) {
                missingPolls = 0
                if PetGenerationSessionMonitor.state(
                    status: session.effectiveStatus,
                    turnState: session.agentTurnState) == .stopped {
                    if finishGeneratedPetIfPresent(petID: petID) { return }
                    clearPendingGeneration()
                    generationMessage = nil
                    generationError = L10n.string(
                        "Pet generation stopped before a package was installed. Open the Codex CLI session in Detach for details.")
                    return
                }
            } else {
                missingPolls += 1
                if missingPolls >= PetGenerationSessionMonitor.missingPollLimit {
                    clearPendingGeneration()
                    generationMessage = nil
                    generationError = L10n.string(
                        "The pet generation session is no longer available. Try again.")
                    return
                }
            }

            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        }
        if pendingGeneratedPetID == petID {
            clearPendingGeneration()
            generationMessage = nil
            generationError = L10n.string(
                "No pet package appeared before the waiting timeout. Check the Codex CLI session in Detach, then try again.")
        }
    }

    private func finishGeneratedPetIfPresent(petID: String) -> Bool {
        let result = PetLibraryLoader.load(from: coordinator.libraryURL)
        guard result.packages.contains(where: { $0.id == petID }) else {
            return false
        }
        coordinator.reloadLibrary()
        coordinator.selectPet(id: petID)
        generationMessage = L10n.string(
            "The random pet is ready and selected.")
        generationError = nil
        clearPendingGeneration()
        return true
    }

    private func clearPendingGeneration() {
        pendingGeneratedPetID = ""
        pendingGeneratedPetSessionID = ""
        AppSettings.defaults.removeObject(
            forKey: PetCoordinator.pendingGeneratedPetPromptKey)
    }

    private func openPendingGenerationSession() {
        guard !pendingGeneratedPetSessionID.isEmpty else { return }
        navigation.requestSession(
            pendingGeneratedPetSessionID,
            focusTerminal: true)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func importPet(from url: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let package = try coordinator.importPet(from: url)
            importMessage = L10n.format(
                "Pet “%@” was added.", package.displayName)
            importError = nil
        } catch {
            importMessage = nil
            importError = L10n.format(
                "Could not add pet: %@", error.localizedDescription)
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
                "Could not open pets folder: %@", error.localizedDescription)
        }
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
