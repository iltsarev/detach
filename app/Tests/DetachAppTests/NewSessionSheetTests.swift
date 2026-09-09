import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import DetachKit
@testable import DetachApp

@MainActor
final class NewSessionSheetTests: XCTestCase {
    private func store() -> SessionStore {
        SessionStore(cli: NewSessionNoopCLI())
    }

    func testBuildsFormWithOptionalEmptyName() {
        _ = NewSessionSheet(store: store()).body
    }

    func testBuildsFormWithHumanReadableName() {
        _ = NewSessionSheet(
            store: store(),
            initialName: "Rev (ai)").body
    }

    func testBuildsInlineValidationForOversizedName() {
        _ = NewSessionSheet(
            store: store(),
            initialName: String(repeating: "a", count: 101)).body
    }

    func testBuildsExpandedAdvancedSection() {
        _ = NewSessionSheet(
            store: store(),
            showsAdvanced: true).body
    }

    func testBuildsFormWithASelectedProject() {
        _ = NewSessionSheet(
            store: store(),
            initialProjectDir: URL(fileURLWithPath: "/tmp/proj", isDirectory: true)).body
    }

    func testBuildsBothLaunchFailureBannerShapes() {
        _ = NewSessionSheet(
            store: store(),
            initialLaunchFailure: "start refused").body
    }

    func testPickerRefreshLoadsInstalledAndMissingSelections() {
        var installed = "com.apple.Terminal"
        _ = TerminalPreferencePicker(bundleIdentifier: Binding(
            get: { installed },
            set: { installed = $0 })).body

        var missing = "dev.example.missing-terminal"
        _ = TerminalPreferencePicker(
            bundleIdentifier: Binding(
                get: { missing },
                set: { missing = $0 }),
            accessibilityIdentifier: "new-session-terminal").body
    }

    func testPickerBodyShowsAChoiceError() {
        let box = IdentifierBox()
        let picker = TerminalPreferencePicker(bundleIdentifier: Binding(
            get: { box.value },
            set: { box.value = $0 }))
        picker.choose(at: URL(fileURLWithPath: "/tmp"))
        _ = picker.body
    }

    func testPickerChooseAcceptsATerminalURL() throws {
        let terminal = try XCTUnwrap(Self.terminalApplicationURL())
        let box = IdentifierBox()
        let picker = TerminalPreferencePicker(bundleIdentifier: Binding(
            get: { box.value },
            set: { box.value = $0 }))
        picker.choose(at: terminal)
        XCTAssertEqual(box.value, "com.apple.Terminal")
        picker.choose(at: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(box.value, "com.apple.Terminal")
    }

    func testPreferenceSelectionAcceptsTerminalAndRejectsABareFolder() throws {
        let terminal = try XCTUnwrap(Self.terminalApplicationURL())
        XCTAssertEqual(
            TerminalPreferenceSelection.outcome(for: terminal).bundleIdentifier,
            "com.apple.Terminal")

        let rejected = TerminalPreferenceSelection.outcome(
            for: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(rejected.bundleIdentifier)
        XCTAssertTrue(rejected.error?.contains("tmp") == true)
    }

    func testLaunchPlanOmitsABlankPromptAndKeepsText() {
        XCTAssertNil(NewSessionLaunch.trimmedPrompt("  \n"))
        XCTAssertEqual(NewSessionLaunch.trimmedPrompt("  go\n"), "go")
    }

    func testLaunchLabelCoversBothIdleAndBusyStates() {
        _ = NewSessionLaunch.label(isLaunching: false)
        _ = NewSessionLaunch.label(isLaunching: true)
    }

    func testLaunchStartsInAppAndSelectsTheTypedSession() async {
        let cli = NewSessionRecordingCLI()
        cli.responses["list --json"] = .success(CLIResult(
            exitCode: 0,
            stdout: #"{"schema":1,"provider":"claude","session_name":"detach-claude-p-1","name":"p-1","effective_status":"running","meta_status":"running","agent_session_id":"u1","project_dir":"/tmp/proj","created_at":"2026-08-29T00:00:00Z","last_checkpoint_at":null,"exit_status":null,"finished_at":null}"#,
            stderr: "",
            timedOut: false))
        var selectedID: String?
        let sheet = NewSessionSheet(
            store: SessionStore(cli: cli),
            selectedID: Binding(
                get: { selectedID },
                set: { selectedID = $0 }),
            initialProjectDir: URL(
                fileURLWithPath: "/tmp/proj",
                isDirectory: true))

        let result = await sheet.launch()

        XCTAssertEqual(result?.sessionID, "detach-claude-p-1")
        XCTAssertEqual(selectedID, "detach-claude-p-1")
        XCTAssertEqual(cli.calls, [["claude", "--detach"], ["list", "--json"]])
    }

    func testLaunchReturnsTheStartFailureWithoutSelectingASession() async {
        let cli = NewSessionRecordingCLI()
        cli.responses["claude --detach"] = .success(CLIResult(
            exitCode: 17,
            stdout: "",
            stderr: "start refused",
            timedOut: false))
        var selectedID: String?
        let sheet = NewSessionSheet(
            store: SessionStore(cli: cli),
            selectedID: Binding(
                get: { selectedID },
                set: { selectedID = $0 }),
            initialProjectDir: URL(
                fileURLWithPath: "/tmp/proj",
                isDirectory: true))

        let result = await sheet.launch()

        XCTAssertEqual(result?.message, "start refused")
        XCTAssertNil(selectedID)
        XCTAssertEqual(cli.calls, [["claude", "--detach"]])
        _ = sheet.body
    }

    func testLaunchTitleAndDisplayNameUseTheSelectedTerminal() {
        XCTAssertEqual(
            TerminalLaunchPresentation.title(terminalDisplayName: "iTerm"),
            "Launch in iTerm")
        XCTAssertEqual(
            TerminalLaunchPresentation.displayName(for: "com.apple.Terminal"),
            "Terminal")
        XCTAssertEqual(
            TerminalLaunchPresentation.displayName(for: "dev.example.missing-terminal"),
            "Terminal")
    }

    func testOtherAppChooserOpensApplicationBundles() {
        let rules = TerminalApplicationChooser.applicationBundleRules
        XCTAssertEqual(rules.allowedContentTypes, [.applicationBundle])
        XCTAssertEqual(rules.directoryURL?.path, "/Applications")
        XCTAssertTrue(rules.canChooseFiles)
        XCTAssertFalse(rules.canChooseDirectories)
        XCTAssertFalse(rules.allowsMultipleSelection)
        XCTAssertFalse(rules.canCreateDirectories)
    }

    func testOpenPanelsApplyTheirTypedRules() {
        let terminal = TerminalApplicationChooser.makeOpenPanel()
        XCTAssertTrue(terminal.canChooseFiles)
        XCTAssertFalse(terminal.canChooseDirectories)
        XCTAssertEqual(terminal.allowedContentTypes, [.applicationBundle])
        XCTAssertEqual(terminal.directoryURL?.path, "/Applications")

        let project = ProjectDirectoryChooser.makeOpenPanel(
            startingAt: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertFalse(project.canChooseFiles)
        XCTAssertTrue(project.canChooseDirectories)
        XCTAssertEqual(project.allowedContentTypes, [])
        XCTAssertEqual(project.directoryURL?.path, "/tmp")
    }

    func testProjectChooserStartsInTheSelectedProjectParent() {
        let project = URL(fileURLWithPath: "/Users/me/Projects/detach", isDirectory: true)
        XCTAssertEqual(
            ProjectDirectoryChooser.startingDirectory(selectedProject: project).path,
            "/Users/me/Projects")
        XCTAssertEqual(
            ProjectDirectoryChooser.startingDirectory(selectedProject: nil),
            FileManager.default.homeDirectoryForCurrentUser)
    }

    func testProjectChooserUsesTheConfiguredRootWhenNothingIsSelected() {
        let configured = URL(
            fileURLWithPath: "/tmp/Projects",
            isDirectory: true)
        XCTAssertEqual(
            ProjectDirectoryChooser.startingDirectory(
                selectedProject: nil,
                defaultDirectory: configured),
            configured)
    }

    func testOpenPanelPresentationKeepsOnlyAnOKSelection() {
        let url = URL(fileURLWithPath: "/Applications/Terminal.app")
        XCTAssertEqual(
            OpenPanelPresentation.selectedURL(response: .OK, url: url),
            url)
        XCTAssertNil(OpenPanelPresentation.selectedURL(response: .cancel, url: url))
    }

    func testWindowTopPinStoresAMaxYOnAPlainObject() {
        let storage = NSObject()
        XCTAssertNil(WindowTopPin.associatedMaxY(on: storage))
        WindowTopPin.store(240, on: storage)
        XCTAssertEqual(
            Double(WindowTopPin.associatedMaxY(on: storage) ?? -1),
            240,
            accuracy: 0.01)
    }

    func testWindowTopPinKeepsTheTopEdgeFixedWhenHeightGrows() {
        let original = CGRect(x: 100, y: 200, width: 520, height: 300)
        let grown = CGRect(x: 100, y: 150, width: 520, height: 400)
        let pinned = WindowTopPin.frameKeepingTop(of: grown, pinnedMaxY: original.maxY)
        XCTAssertEqual(pinned.maxY, original.maxY, accuracy: 0.01)
        XCTAssertEqual(pinned.height, 400, accuracy: 0.01)
    }

    func testOpenPanelDirectoryMemoryRestoresThePreviousRoot() {
        let defaults = UserDefaults(suiteName: "DetachOpenPanelMemoryTests")!
        defaults.removePersistentDomain(forName: "DetachOpenPanelMemoryTests")
        let key = OpenPanelDirectoryMemory.keys[1]
        defaults.set("file:///Users/me/Projects/", forKey: key)
        let snapshot = OpenPanelDirectoryMemory.snapshot(defaults: defaults)
        defaults.set("file:///Applications/", forKey: key)
        OpenPanelDirectoryMemory.restore(snapshot, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: key), "file:///Users/me/Projects/")
        OpenPanelDirectoryMemory.restore([:], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testProjectChooserPanelPicksDirectories() {
        let rules = ProjectDirectoryChooser.directoryRules(
            startingAt: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertTrue(rules.canChooseDirectories)
        XCTAssertFalse(rules.canChooseFiles)
        XCTAssertFalse(rules.canCreateDirectories)
        XCTAssertEqual(rules.directoryURL?.path, "/tmp")
    }

    func testPanelHostFallsBackWhenNoWindowIsKey() {
        XCTAssertNil(PanelHostWindow.preferred(keyWindow: nil, windows: []))
    }

    func testPanelHostPrefersAProvidedKeyWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        XCTAssertTrue(
            PanelHostWindow.preferred(keyWindow: window, windows: []) === window)
        XCTAssertNil(PanelHostWindow.preferred(keyWindow: nil, windows: [window]))
    }

    func testPinViewIgnoresHitsWhenDetached() {
        let pin = PinWindowTopEdgeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(pin.hitTest(NSPoint(x: 0, y: 0)))
        pin.viewDidMoveToWindow()
        pin.keepTopPinned()
        pin.layout()
    }

    func testPinViewKeepsAnAttachedWindowTopFixed() async {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 520, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true)
        let pin = PinWindowTopEdgeView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView = pin
        pin.removeResizeObserver()
        pin.startPinning()

        let scheduled = expectation(description: "pin scheduled")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        let pinnedMaxY = window.frame.maxY

        window.setFrame(
            NSRect(x: 100, y: 150, width: 520, height: 400),
            display: false)
        pin.applyPinnedTop()

        XCTAssertEqual(window.frame.maxY, pinnedMaxY, accuracy: 0.01)
        NotificationCenter.default.post(
            name: NSWindow.didResizeNotification,
            object: window)
        pin.removeResizeObserver()
    }

    private static func terminalApplicationURL() -> URL? {
        [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app",
        ]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct NewSessionNoopCLI: DetachCLIRunning {
    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

private final class NewSessionRecordingCLI: DetachCLIRunning, @unchecked Sendable {
    var responses: [String: Result<CLIResult, Error>] = [:]
    private(set) var calls: [[String]] = []

    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        calls.append(arguments)
        return try responses[arguments.joined(separator: " ")]?.get()
            ?? CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

private final class IdentifierBox {
    var value = "dev.example.missing-terminal"
}
