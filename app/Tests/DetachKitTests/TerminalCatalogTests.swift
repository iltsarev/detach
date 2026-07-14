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

    func testAcceptsShellRoleDeclaredForUnixExecutables() {
        // iTerm2 declares .command files under an Editor-role entry and the
        // Shell role only for public.unix-executable; the Shell entry alone
        // must qualify the app as a terminal.
        XCTAssertTrue(TerminalCatalog.declaresShellScriptSupport(iTermStyleInfoDictionary))
    }

    func testRejectsEditorsThatOnlyEditShellScripts() {
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Editor",
                "CFBundleTypeExtensions": ["sh", "command", "bashrc", "zshrc"],
            ]],
        ]))
    }

    func testRejectsShellRoleForUnrelatedDocumentTypes() {
        XCTAssertFalse(TerminalCatalog.declaresShellScriptSupport([
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Shell",
                "LSItemContentTypes": ["com.example.game-project"],
            ]],
        ]))
    }

    func testDiscoversTerminalsWithITermStyleDeclarations() throws {
        _ = try makeApplication(
            name: "UnixExecTerm",
            bundleIdentifier: "test.unixexec",
            documentTypes: iTermStyleInfoDictionary["CFBundleDocumentTypes"] as? [[String: Any]])

        let applications = TerminalCatalog.installedApplications(
            registeredApplicationURLs: [],
            searchRoots: [root],
            fileManager: .default)

        XCTAssertEqual(applications.map(\.bundleIdentifier), ["test.unixexec"])
    }

    func testResolvesManuallyChosenApplicationWithoutDeclarations() throws {
        let applicationURL = try makeApplication(
            name: "BareTerm", bundleIdentifier: "test.bare", documentTypes: nil)

        let application = TerminalCatalog.application(at: applicationURL)

        XCTAssertEqual(application?.bundleIdentifier, "test.bare")
        XCTAssertEqual(application?.displayName, "BareTerm")
    }

    private var iTermStyleInfoDictionary: [String: Any] {
        [
            "CFBundleDocumentTypes": [
                [
                    "CFBundleTypeRole": "Editor",
                    "CFBundleTypeExtensions": ["command", "tool", "sh", "zsh", "csh", "pl"],
                ],
                [
                    "CFBundleTypeRole": "Shell",
                    "LSItemContentTypes": ["public.unix-executable"],
                ],
            ],
        ]
    }

    private func makeApplication(
        name: String,
        bundleIdentifier: String,
        supportsCommandFiles: Bool
    ) throws -> URL {
        try makeApplication(
            name: name,
            bundleIdentifier: bundleIdentifier,
            documentTypes: supportsCommandFiles
                ? [[
                    "CFBundleTypeRole": "Shell",
                    "LSItemContentTypes": [TerminalCatalog.shellScriptContentType],
                ]]
                : nil)
    }

    private func makeApplication(
        name: String,
        bundleIdentifier: String,
        documentTypes: [[String: Any]]?
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
        if let documentTypes {
            info["CFBundleDocumentTypes"] = documentTypes
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return applicationURL
    }
}
