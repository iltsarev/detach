import Foundation
import DetachKit

enum DirectoryPreference {
    static func existingDirectoryURL(
        path: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func configuredOrFallback(
        path: String,
        fallback: URL,
        fileManager: FileManager = .default
    ) -> URL {
        existingDirectoryURL(path: path, fileManager: fileManager)
            ?? fallback
    }
}

enum QuickChatProjectDirectory {
    static func create(
        inside parent: URL,
        fileManager: FileManager = .default,
        id: UUID = UUID()
    ) throws -> URL {
        let name = "detach-chat-\(id.uuidString.lowercased())"
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
enum QuickChatLaunch {
    private enum Outcome: Sendable {
        case session(String?)
        case launch(SessionStartResult)
    }

    static func provider(rawValue: String) -> Provider {
        Provider(rawValue: rawValue) ?? .claude
    }

    static func existingSessionIDs(in sessions: [Session]) -> Set<String> {
        var ids: Set<String> = []
        for session in sessions {
            ids.insert(session.id)
        }
        return ids
    }

    static func start(
        store: SessionStore,
        providerRawValue: String,
        directoryPath: String,
        fileManager: FileManager = .default,
        onSessionAvailable: (@MainActor (String) -> Void)? = nil,
        createProjectDirectory: (URL, FileManager) throws -> URL = {
            try QuickChatProjectDirectory.create(inside: $0, fileManager: $1)
        },
        waitForSession: @escaping @MainActor @Sendable (
            SessionStore, Provider, URL, Set<String>
        ) async -> String? = { store, provider, directory, existingIDs in
            await store.waitForSession(
                provider: provider,
                projectDirectory: directory,
                excluding: existingIDs)
        }
    ) async -> SessionStartResult {
        guard let directory = DirectoryPreference.existingDirectoryURL(
            path: directoryPath,
            fileManager: fileManager) else {
            return SessionStartResult(message: L10n.format(
                "Quick chat folder is unavailable: %@",
                directoryPath))
        }
        let projectDirectory: URL
        do {
            projectDirectory = try createProjectDirectory(directory, fileManager)
        } catch {
            return SessionStartResult(message: L10n.format(
                "Quick chat folder is unavailable: %@",
                directoryPath))
        }
        let provider = provider(rawValue: providerRawValue)
        guard let onSessionAvailable else {
            return await store.startDetached(
                provider: provider,
                projectDirectory: projectDirectory,
                name: nil,
                prompt: nil)
        }

        let existingIDs = existingSessionIDs(in: store.sessions)
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                .launch(await store.startDetached(
                    provider: provider,
                    projectDirectory: projectDirectory,
                    name: nil,
                    prompt: nil))
            }
            group.addTask {
                .session(await waitForSession(
                    store, provider, projectDirectory, existingIDs))
            }

            var selectedEarly = false
            while let outcome = await group.next() {
                switch outcome {
                case .session(let sessionID):
                    guard let sessionID else { continue }
                    selectedEarly = true
                    onSessionAvailable(sessionID)
                case .launch(let result):
                    if !selectedEarly, let sessionID = result.sessionID {
                        onSessionAvailable(sessionID)
                    }
                    if selectedEarly, result.message != nil {
                        await store.refresh()
                    }
                    group.cancelAll()
                    return result
                }
            }
            return SessionStartResult(message: L10n.string(
                "Could not start quick chat"))
        }
    }
}

struct SidebarShortcutHint: Equatable, Identifiable {
    let shortcut: String
    let title: String

    var id: String { shortcut }
}

enum SidebarShortcutPresentation {
    static var hints: [SidebarShortcutHint] { [
        SidebarShortcutHint(
            shortcut: "⌘N",
            title: L10n.string("New session")),
        SidebarShortcutHint(
            shortcut: "⌘T",
            title: L10n.string("Quick chat")),
        SidebarShortcutHint(
            shortcut: "⌘,",
            title: L10n.string("Settings")),
        SidebarShortcutHint(
            shortcut: "⌘F",
            title: L10n.string("Find output")),
    ] }
}
