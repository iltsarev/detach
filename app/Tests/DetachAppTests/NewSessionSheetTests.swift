import UniformTypeIdentifiers
import XCTest
@testable import DetachApp

@MainActor
final class NewSessionSheetTests: XCTestCase {
    func testBuildsFormWithOptionalEmptyName() {
        _ = NewSessionSheet(detachPath: "/tmp/detach").body
    }

    func testBuildsFormWithHumanReadableName() {
        _ = NewSessionSheet(
            detachPath: "/tmp/detach",
            initialName: "Rev (ai)").body
    }

    func testBuildsInlineValidationForOversizedName() {
        _ = NewSessionSheet(
            detachPath: "/tmp/detach",
            initialName: String(repeating: "a", count: 101)).body
    }

    func testOtherAppChooserOpensApplicationBundles() {
        let panel = TerminalApplicationChooser.makeOpenPanel()
        XCTAssertEqual(panel.allowedContentTypes, [.applicationBundle])
        XCTAssertEqual(panel.directoryURL?.path, "/Applications")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
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
    }
}
