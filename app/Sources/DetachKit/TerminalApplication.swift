import Foundation

#if canImport(AppKit)
import AppKit

public struct TerminalApplication: Identifiable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let applicationURL: URL

    public var id: String { bundleIdentifier }

    init?(applicationURL: URL) {
        guard let bundle = Bundle(url: applicationURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        self.init(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            applicationURL: applicationURL)
    }

    init(bundleIdentifier: String, displayName: String, applicationURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationURL = applicationURL
    }
}

public enum TerminalCatalog {
    public static let defaultBundleIdentifier = "com.apple.Terminal"
    static let shellScriptContentType = "com.apple.terminal.shell-script"

    @MainActor
    public static func installedApplications() -> [TerminalApplication] {
        let workspace = NSWorkspace.shared
        let fileManager = FileManager.default
        let probeDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "Detach-Terminal-Probe-\(UUID().uuidString)", isDirectory: true)
        let probeURL = probeDirectory.appendingPathComponent("probe.command")
        var registeredURLs: [URL] = []
        if (try? fileManager.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])) != nil {
            if fileManager.createFile(atPath: probeURL.path, contents: Data()) {
                registeredURLs = workspace.urlsForApplications(toOpen: probeURL)
            }
            try? fileManager.removeItem(at: probeDirectory)
        }
        if let terminalURL = workspace.urlForApplication(
            withBundleIdentifier: defaultBundleIdentifier) {
            registeredURLs.append(terminalURL)
        }
        return installedApplications(
            registeredApplicationURLs: registeredURLs,
            searchRoots: defaultSearchRoots,
            fileManager: .default)
    }

    /// Resolves the stored terminal preference. The preference is an explicit
    /// user choice, so no capability filtering happens here: an app that turns
    /// out not to run commands is reported by the launch acknowledgement
    /// timeout instead of being silently rejected before launch.
    @MainActor
    public static func application(bundleIdentifier: String) -> TerminalApplication? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier) {
            return TerminalApplication(applicationURL: url)
        }
        return installedApplications().first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Wraps a user-picked application bundle (for example from an open
    /// panel) so any installed terminal can be selected, including ones that
    /// declare no shell-script document types at all.
    public static func application(at url: URL) -> TerminalApplication? {
        TerminalApplication(applicationURL: url)
    }

    static var defaultSearchRoots: [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        ]
        roots.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true))
        return roots
    }

    static func installedApplications(
        registeredApplicationURLs: [URL],
        searchRoots: [URL],
        fileManager: FileManager
    ) -> [TerminalApplication] {
        var byBundleIdentifier: [String: TerminalApplication] = [:]

        for url in registeredApplicationURLs {
            if let bundle = Bundle(url: url),
               declaresShellScriptSupport(bundle.infoDictionary ?? [:]),
               let application = TerminalApplication(applicationURL: url) {
                byBundleIdentifier[application.bundleIdentifier] = application
            }
        }

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            let keys: [URLResourceKey] = [.isApplicationKey, .isDirectoryKey]
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      declaresShellScriptSupport(bundle.infoDictionary ?? [:]),
                      let application = TerminalApplication(applicationURL: url) else { continue }
                if byBundleIdentifier[application.bundleIdentifier] == nil {
                    byBundleIdentifier[application.bundleIdentifier] = application
                }
            }
        }

        return byBundleIdentifier.values.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }

    /// Content types and filename extensions whose Shell-role declaration
    /// marks an application that executes scripts. Terminals differ in which
    /// flavor they register (Terminal.app and Warp declare
    /// com.apple.terminal.shell-script, iTerm2 only public.unix-executable),
    /// so any executable flavor qualifies. Editors declare the same types
    /// with Editor/Viewer roles and stay excluded by the role check.
    static let executableContentTypes: Set<String> = [
        shellScriptContentType,
        "public.shell-script",
        "public.unix-executable",
        "public.executable",
        "public.script",
    ]

    static let executableExtensions: Set<String> = [
        "command", "tool", "sh", "zsh", "bash", "csh", "tcsh", "fish", "dash", "ksh",
    ]

    static func declaresShellScriptSupport(_ info: [String: Any]) -> Bool {
        guard let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] else {
            return false
        }
        return documentTypes.contains { documentType in
            guard let role = documentType["CFBundleTypeRole"] as? String,
                  role.caseInsensitiveCompare("Shell") == .orderedSame else {
                return false
            }
            if let contentTypes = documentType["LSItemContentTypes"] as? [String],
               contentTypes.contains(where: { executableContentTypes.contains($0.lowercased()) }) {
                return true
            }
            if let extensions = documentType["CFBundleTypeExtensions"] as? [String],
               extensions.contains(where: { executableExtensions.contains($0.lowercased()) }) {
                return true
            }
            return false
        }
    }
}
#endif
