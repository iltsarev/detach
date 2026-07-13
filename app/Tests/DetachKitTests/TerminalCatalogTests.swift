import XCTest
@testable import DetachKit

final class TerminalCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscoversOnlyAppsThatDeclareCommandFileSupport() throws {
        _ = try makeApplication(
            name: "ZetaTerm", bundleIdentifier: "test.zeta", supportsCommandFiles: true)
        _ = try makeApplication(
            name: "Editor", bundleIdentifier: "test.editor", supportsCommandFiles: false)
        let alpha = try makeApplication(
            name: "AlphaTerm", bundleIdentifier: "test.alpha", supportsCommandFiles: true)

        let applications = TerminalCatalog.installedApplications(
            registeredApplicationURLs: [alpha],
            searchRoots: [root],
            fileManager: .default)

        XCTAssertEqual(applications.map(\.displayName), ["AlphaTerm", "ZetaTerm"])
        XCTAssertEqual(Set(applications.map(\.bundleIdentifier)), ["test.alpha", "test.zeta"])
    }

    func testRecognizesLegacyCommandExtensionDeclaration() {
        XCTAssertTrue(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Shell",
                "CFBundleTypeExtensions": ["COMMAND"],
            ]],
        ]))
    }

    func testRejectsEditorRoleEvenWhenItHandlesCommandFiles() {
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Editor",
                "LSItemContentTypes": [TerminalCatalog.shellScriptContentType],
            ]],
        ]))
    }

    private func makeApplication(
        name: String,
        bundleIdentifier: String,
        supportsCommandFiles: Bool
    ) throws -> URL {
        let applicationURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleDisplayName": name,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        if supportsCommandFiles {
            info["CFBundleDocumentTypes"] = [[
                "CFBundleTypeRole": "Shell",
                "LSItemContentTypes": [TerminalCatalog.shellScriptContentType],
            ]]
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return applicationURL
    }
}
