import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DetachKit

struct TerminalPreferencePicker: View {
    @Binding var bundleIdentifier: String
    var accessibilityIdentifier: String?

    @State private var applications: [TerminalApplication] = []
    @State private var unlisted: TerminalApplication?
    @State private var icons: [String: NSImage] = [:]
    @State private var choiceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $bundleIdentifier) {
                    ForEach(applications) { application in
                        row(for: application).tag(application.bundleIdentifier)
                    }
                    if let unlisted {
                        row(for: unlisted).tag(unlisted.bundleIdentifier)
                    } else if selectedIsMissing {
                        Text(L10n.string("Unavailable — choose another"))
                            .tag(bundleIdentifier)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(applications.isEmpty && unlisted == nil)
                .accessibilityIdentifier(accessibilityIdentifier ?? "terminal-preference")

                Button(L10n.string("Other…")) {
                    presentChooser()
                }
                .help(L10n.string("Choose Another App…"))
                .accessibilityLabel(L10n.string("Choose Another App…"))
            }

            if let choiceError {
                Text(choiceError)
                    .appFont(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: bundleIdentifier) {
            choiceError = nil
            refresh()
        }
    }

    private var selectedIsMissing: Bool {
        applications.contains { $0.bundleIdentifier == bundleIdentifier } == false
            && unlisted == nil
    }

    @ViewBuilder
    private func row(for application: TerminalApplication) -> some View {
        Label {
            Text(application.displayName)
        } icon: {
            if let icon = icons[application.bundleIdentifier] {
                Image(nsImage: icon)
            }
        }
    }

    @MainActor
    private func refresh() {
        applications = TerminalCatalog.installedApplications()
        if applications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            unlisted = nil
        } else {
            unlisted = TerminalCatalog.application(bundleIdentifier: bundleIdentifier)
        }
        var nextIcons: [String: NSImage] = [:]
        var candidates = applications
        if let unlisted { candidates.append(unlisted) }
        for application in candidates {
            guard let icon = NSWorkspace.shared
                .icon(forFile: application.applicationURL.path)
                .copy() as? NSImage else { continue }
            icon.size = NSSize(width: 16, height: 16)
            nextIcons[application.bundleIdentifier] = icon
        }
        icons = nextIcons
    }

    @MainActor
    private func presentChooser() {
        choiceError = nil
        TerminalApplicationChooser.present(from: PanelHostWindow.current()) { url in
            guard let url else { return }
            choose(at: url)
        }
    }

    @MainActor
    private func choose(at url: URL) {
        guard let application = TerminalCatalog.application(at: url),
              !application.bundleIdentifier.isEmpty else {
            choiceError = L10n.format(
                "%@ can't be used as a terminal because it has no bundle identifier.",
                url.deletingPathExtension().lastPathComponent)
            return
        }
        choiceError = nil
        bundleIdentifier = application.bundleIdentifier
        refresh()
    }
}

enum WindowTopPin {
    static func frameKeepingTop(of frame: NSRect, pinnedMaxY: CGFloat) -> NSRect {
        var next = frame
        next.origin.y += pinnedMaxY - frame.maxY
        return next
    }
}

struct PinWindowTopEdge: NSViewRepresentable {
    func makeNSView(context: Context) -> PinWindowTopEdgeView {
        PinWindowTopEdgeView()
    }

    func updateNSView(_ nsView: PinWindowTopEdgeView, context: Context) {}
}

final class PinWindowTopEdgeView: NSView {
    private var pinnedMaxY: CGFloat?
    private var isAdjusting = false
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        pinnedMaxY = window?.frame.maxY
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.keepTopPinned()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func keepTopPinned() {
        guard !isAdjusting, let window, let pinnedMaxY else { return }
        let current = window.frame
        guard abs(current.maxY - pinnedMaxY) > 0.5 else { return }
        isAdjusting = true
        window.setFrame(WindowTopPin.frameKeepingTop(of: current, pinnedMaxY: pinnedMaxY), display: true)
        isAdjusting = false
    }
}

enum PanelHostWindow {
    @MainActor
    static func current() -> NSWindow? {
        if let key = NSApp.keyWindow {
            return key
        }
        return NSApp.windows.first(where: { $0.sheetParent != nil })
            ?? NSApp.windows.first(where: { $0.attachedSheet != nil })
    }
}

enum OpenPanelDirectoryMemory {
    static let keys = [
        "NSNavLastRootDirectory",
        "NSOSPLastRootDirectory",
    ]

    @MainActor
    static func snapshot(defaults: UserDefaults = .standard) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            }
        }
        return values
    }

    @MainActor
    static func restore(_ values: [String: Any], defaults: UserDefaults = .standard) {
        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

enum TerminalApplicationChooser {
    @MainActor
    static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = L10n.string("Choose Another App…")
        return panel
    }

    @MainActor
    static func present(from window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let saved = OpenPanelDirectoryMemory.snapshot()
        let panel = makeOpenPanel()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let url = response == .OK ? panel.url : nil
            DispatchQueue.main.async {
                OpenPanelDirectoryMemory.restore(saved)
                completion(url)
            }
        }
        if let window = window ?? PanelHostWindow.current() {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

enum ProjectDirectoryChooser {
    @MainActor
    static func makeOpenPanel(startingAt directory: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.prompt = L10n.string("Choose…")
        return panel
    }

    static func startingDirectory(selectedProject: URL?) -> URL {
        selectedProject?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    @MainActor
    static func present(
        from window: NSWindow?,
        selectedProject: URL?,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = makeOpenPanel(startingAt: startingDirectory(selectedProject: selectedProject))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let url = response == .OK ? panel.url : nil
            DispatchQueue.main.async {
                completion(url)
            }
        }
        if let window = window ?? PanelHostWindow.current() {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

enum TerminalLaunchPresentation {
    static func title(terminalDisplayName: String) -> String {
        L10n.format("Launch in %@", terminalDisplayName)
    }

    @MainActor
    static func displayName(for bundleIdentifier: String) -> String {
        TerminalCatalog.application(bundleIdentifier: bundleIdentifier)?.displayName
            ?? L10n.string("Terminal")
    }
}
