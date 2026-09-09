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
        TerminalApplicationChooser.presentOtherApp { choose(at: $0) }
    }

    @MainActor
    func choose(at url: URL) {
        let outcome = TerminalPreferenceSelection.outcome(for: url)
        if let identifier = outcome.bundleIdentifier {
            choiceError = nil
            bundleIdentifier = identifier
            refresh()
        } else {
            choiceError = outcome.error
        }
    }
}

enum TerminalPreferenceSelection {
    struct Outcome: Equatable {
        var bundleIdentifier: String?
        var error: String?
    }

    static func outcome(for url: URL) -> Outcome {
        guard let application = TerminalCatalog.application(at: url),
              !application.bundleIdentifier.isEmpty else {
            return Outcome(error: L10n.format(
                "%@ can't be used as a terminal because it has no bundle identifier.",
                url.deletingPathExtension().lastPathComponent))
        }
        return Outcome(bundleIdentifier: application.bundleIdentifier)
    }
}

enum WindowTopPin {
    private static var storedMaxYKey: UInt8 = 0

    static func frameKeepingTop(of frame: NSRect, pinnedMaxY: CGFloat) -> NSRect {
        var next = frame
        next.origin.y += pinnedMaxY - frame.maxY
        return next
    }

    static func associatedMaxY(on storage: NSObject) -> CGFloat? {
        (objc_getAssociatedObject(storage, &storedMaxYKey) as? NSNumber)
            .map { CGFloat(truncating: $0) }
    }

    static func store(_ maxY: CGFloat, on storage: NSObject) {
        objc_setAssociatedObject(
            storage,
            &storedMaxYKey,
            NSNumber(value: Double(maxY)),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

final class PinWindowTopEdgeView: NSView {
    private var pinnedMaxY: CGFloat?
    private var isAdjusting = false
    private var observer: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeResizeObserver()
        guard window != nil else {
            pinnedMaxY = nil
            return
        }
        startPinning()
    }

    override func layout() {
        super.layout()
        keepTopPinned()
    }

    deinit {
        removeResizeObserver()
    }

    func keepTopPinned() {
        guard !isAdjusting, window != nil else { return }
        applyPinnedTop()
    }

    func removeResizeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

// quality-coverage:begin window-pin
    func startPinning() {
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.keepTopPinned()
        }
        schedulePin(capture: true)
    }

    func schedulePin(capture: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if capture || self.pinnedMaxY == nil {
                self.pinnedMaxY = self.window?.frame.maxY
            }
            self.keepTopPinned()
        }
    }

    func applyPinnedTop() {
        guard let window else { return }
        let storage = window.sheetParent ?? window
        let pinnedMaxY = WindowTopPin.associatedMaxY(on: storage) ?? window.frame.maxY
        WindowTopPin.store(pinnedMaxY, on: storage)
        self.pinnedMaxY = pinnedMaxY
        let current = window.frame
        guard abs(current.maxY - pinnedMaxY) > 0.5 else { return }
        isAdjusting = true
        window.setFrameOrigin(
            NSPoint(
                x: current.minX,
                y: current.minY + pinnedMaxY - current.maxY))
        isAdjusting = false
    }
}

struct PinWindowTopEdge: NSViewRepresentable {
    func makeNSView(context: Context) -> PinWindowTopEdgeView {
        PinWindowTopEdgeView()
    }

    func updateNSView(_ nsView: PinWindowTopEdgeView, context: Context) {
        nsView.schedulePin()
    }
}
// quality-coverage:end window-pin

enum PanelHostWindow {
    static func preferred(keyWindow: NSWindow?, windows: [NSWindow]) -> NSWindow? {
        if let keyWindow {
            return keyWindow
        }
        return windows.first(where: { $0.sheetParent != nil })
            ?? windows.first(where: { $0.attachedSheet != nil })
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

struct OpenPanelRules: Equatable {
    var canChooseFiles: Bool
    var canChooseDirectories: Bool
    var allowsMultipleSelection: Bool
    var canCreateDirectories: Bool
    var allowedContentTypes: [UTType]?
    var directoryURL: URL?
    var prompt: String
}

enum OpenPanelPresentation {
    static func selectedURL(
        response: NSApplication.ModalResponse,
        url: URL?
    ) -> URL? {
        response == .OK ? url : nil
    }
}

enum TerminalApplicationChooser {
    static let applicationsDirectory = URL(
        fileURLWithPath: "/Applications",
        isDirectory: true)

    static var applicationBundleRules: OpenPanelRules {
        OpenPanelRules(
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            allowedContentTypes: [.applicationBundle],
            directoryURL: applicationsDirectory,
            prompt: L10n.string("Choose Another App…"))
    }
}

enum ProjectDirectoryChooser {
    static func directoryRules(startingAt directory: URL) -> OpenPanelRules {
        OpenPanelRules(
            canChooseFiles: false,
            canChooseDirectories: true,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            allowedContentTypes: nil,
            directoryURL: directory,
            prompt: L10n.string("Choose…"))
    }

    static func startingDirectory(
        selectedProject: URL?,
        defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        selectedProject?.deletingLastPathComponent()
            ?? defaultDirectory
    }
}

// quality-coverage:begin open-panel
extension PanelHostWindow {
    @MainActor
    static func current() -> NSWindow? {
        preferred(keyWindow: NSApp.keyWindow, windows: NSApp.windows)
    }
}

extension TerminalApplicationChooser {
    @MainActor
    static func makeOpenPanel() -> NSOpenPanel {
        apply(applicationBundleRules, to: NSOpenPanel())
    }

    @discardableResult
    static func apply(_ rules: OpenPanelRules, to panel: NSOpenPanel) -> NSOpenPanel {
        panel.canChooseFiles = rules.canChooseFiles
        panel.canChooseDirectories = rules.canChooseDirectories
        panel.allowsMultipleSelection = rules.allowsMultipleSelection
        panel.canCreateDirectories = rules.canCreateDirectories
        if let allowedContentTypes = rules.allowedContentTypes {
            panel.allowedContentTypes = allowedContentTypes
        }
        panel.directoryURL = rules.directoryURL
        panel.prompt = rules.prompt
        return panel
    }

    @MainActor
    static func presentOtherApp(completion: @escaping (URL) -> Void) {
        present(from: PanelHostWindow.current()) { url in
            guard let url else { return }
            completion(url)
        }
    }

    @MainActor
    static func present(from window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let saved = OpenPanelDirectoryMemory.snapshot()
        let panel = makeOpenPanel()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let url = OpenPanelPresentation.selectedURL(response: response, url: panel.url)
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

extension ProjectDirectoryChooser {
    @MainActor
    static func makeOpenPanel(startingAt directory: URL) -> NSOpenPanel {
        TerminalApplicationChooser.apply(directoryRules(startingAt: directory), to: NSOpenPanel())
    }

    @MainActor
    static func present(
        from window: NSWindow?,
        selectedProject: URL?,
        defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = makeOpenPanel(startingAt: startingDirectory(
            selectedProject: selectedProject,
            defaultDirectory: defaultDirectory))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let url = OpenPanelPresentation.selectedURL(response: response, url: panel.url)
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
// quality-coverage:end open-panel

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
